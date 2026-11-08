#import "FDMEngine.h"
#import "FDMStore.h"

static const void *FDMEngineQueueKey = &FDMEngineQueueKey;

@implementation FDMEngine {
    dispatch_queue_t _queue;
    NSOperationQueue *_delegates;
    NSURLSession *_session;
    NSMutableArray<NSMutableDictionary *> *_items;
    NSMutableDictionary<NSString *, NSURLSessionDownloadTask *> *_tasks;
    NSMutableDictionary<NSString *, NSMutableDictionary *> *_pauses;
    NSMutableDictionary<NSString *, NSArray *> *_samples;
    NSMutableSet<NSString *> *_deleted;
    NSString *_path;
    BOOL _restoring;
    BOOL _writable;
    BOOL _eventsFinished;
    BOOL _backgroundBatchConsumed;
    NSTimeInterval _lastSave;
    NSUInteger _backgroundSaveRetries;
    void (^_backgroundCompletion)(void);
    NSMutableArray *_additionalBackgroundCompletions;
}

+ (instancetype)shared {
    static FDMEngine *engine;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ engine = [[self alloc] init]; });
    return engine;
}

- (instancetype)init {
    return [self initWithConfiguration:[NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:FDMBackgroundSessionIdentifier]];
}

- (void)initializeStorage {
    _queue = dispatch_queue_create("FocusDM.download-owner", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_queue, FDMEngineQueueKey, (__bridge void *)self, NULL);
    _items = [NSMutableArray array];
    _tasks = [NSMutableDictionary dictionary];
    _pauses = [NSMutableDictionary dictionary];
    _samples = [NSMutableDictionary dictionary];
    _deleted = [NSMutableSet set];
    _path = [FDMDirectory(@"FocusDM") stringByAppendingPathComponent:@"tasks.json"];
    _writable = YES;
    _restoring = YES;
    [self sync:^{ [self load]; }];
    _delegates = [[NSOperationQueue alloc] init];
    _delegates.maxConcurrentOperationCount = 1;
    _delegates.underlyingQueue = _queue;
}

- (void)enumerateSystemTasks {
    [_session getAllTasksWithCompletionHandler:^(NSArray<__kindof NSURLSessionTask *> *tasks) {
        dispatch_async(self->_queue, ^{ [self reconcile:tasks]; });
    }];
}

- (instancetype)initWithConfiguration:(NSURLSessionConfiguration *)configuration {
    if ((self = [super init])) {
        [self initializeStorage];
        configuration.sessionSendsLaunchEvents = YES;
        configuration.discretionary = NO;
        _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:_delegates];
        [self enumerateSystemTasks];
    }
    return self;
}

#ifdef FDM_TESTING
- (instancetype)initForTestingWithSessionFactory:(NSURLSession * (^)(id<NSURLSessionDelegate>, NSOperationQueue *))factory {
    if ((self = [super init])) {
        [self initializeStorage];
        _session = factory(self, _delegates);
        [self enumerateSystemTasks];
    }
    return self;
}
- (void)drainForTesting { [self sync:^{}]; }
#endif

- (void)sync:(dispatch_block_t)block {
    if (dispatch_get_specific(FDMEngineQueueKey) == (__bridge void *)self) block();
    else dispatch_sync(_queue, block);
}

- (NSString *)deletionPath { return [[_path stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"deleted-task-ids.json"]; }

- (NSMutableDictionary *)normalizedRecord:(NSDictionary *)record {
    NSMutableDictionary *row = [record mutableCopy];
    NSString *key = FDMString(row[@"key"]);
    if (![row[@"schema"] isEqual:@2]) {
        row[@"legacyKey"] = key;
        row[@"key"] = [@"legacy-" stringByAppendingString:FDMLegacyHash(key)];
        row[@"schema"] = @2;
        row[@"generation"] = @0;
        row[@"url"] = row[@"url"] ?: key;
        row[@"legacyResumeRelativePath"] = [NSString stringWithFormat:@"FocusDM/resume/%@.resume", FDMLegacyHash(key)];
        NSString *path = FDMString(row[@"path"]);
        NSString *relative = path.length ? FDMRelativeDocumentPath(path) : nil;
        if (relative) row[@"relativePath"] = relative;
    }
    return row;
}

- (void)load {
    NSError *error = nil;
    id root = FDMReadJSON(_path, &error);
    if (root && ![root isKindOfClass:NSArray.class]) _writable = NO;
    if (!root && [[NSFileManager defaultManager] fileExistsAtPath:_path]) _writable = NO;
    for (id entry in [root isKindOfClass:NSArray.class] ? root : @[]) {
        if (!FDMValidStoredRecord(entry)) { _writable = NO; continue; }
        NSMutableDictionary *row = [self normalizedRecord:entry];
        NSDictionary *durable = [FDMStore.shared recordForKey:row[@"key"]];
        BOOL sameAttempt = [durable[@"schema"] isEqual:@2] && [durable[@"generation"] isEqual:row[@"generation"]];
        NSInteger terminal = [durable[@"state"] integerValue];
        if (sameAttempt && (terminal == FDMStateCompleted || terminal == FDMStateFailed)) {
            row = [durable mutableCopy];
        }
        row[@"speed"] = @0;
        [_items addObject:row];
    }
    id removed = FDMReadJSON([self deletionPath], nil);
    if ([removed isKindOfClass:NSArray.class]) {
        for (id key in removed) {
            if ([key isKindOfClass:NSString.class]) [_deleted addObject:key];
            else _writable = NO;
        }
    } else if ([[NSFileManager defaultManager] fileExistsAtPath:[self deletionPath]]) {
        _writable = NO;
    }
    if (!_writable) FDMLog(@"engine storage unreadable/unsupported; original files preserved");
    // Commit stable legacy IDs before attaching to a system session. No old resume file is moved/deleted.
    if (_writable && _items.count) [self persist:nil];
}

- (BOOL)persist:(NSError **)error {
    if (!_writable) { if (error) *error = FDMError(@"下载记录文件不可写或格式未知，原文件已保留"); return NO; }
    BOOL ok = FDMWriteJSON(_items, _path, error);
    if (ok) {
        _lastSave = NSDate.date.timeIntervalSince1970;
        if (_eventsFinished && _backgroundCompletion && !_restoring && !_pauses.count) {
            dispatch_async(_queue, ^{ [self finishBackgroundIfReady]; });
        }
    }
    else FDMLog(@"engine persistence failed");
    return ok;
}

- (NSMutableDictionary *)item:(NSString *)key {
    for (NSMutableDictionary *row in _items) if ([row[@"key"] isEqual:key] || [row[@"legacyKey"] isEqual:key]) return row;
    return nil;
}

- (NSString *)tokenForItem:(NSDictionary *)item {
    return [NSString stringWithFormat:@"fdm2:%@:%@", item[@"key"], item[@"generation"] ?: @0];
}

- (NSMutableDictionary *)itemForTask:(NSURLSessionTask *)task {
    NSString *token = task.taskDescription;
    for (NSMutableDictionary *row in _items) {
        NSString *key = row[@"key"];
        if ([_deleted containsObject:key]) continue;
        BOOL tokenMatches = [[self tokenForItem:row] isEqual:token];
        BOOL legacyMatches = [row[@"generation"] integerValue] == 0 && [row[@"legacyKey"] isEqual:token];
        if (!(tokenMatches || legacyMatches)) continue;
        NSNumber *identifier = row[@"taskIdentifier"];
        if (identifier && identifier.unsignedIntegerValue != task.taskIdentifier) continue;
        return row;
    }
    return nil;
}

- (BOOL)isValidResume:(NSData *)data {
    if (![data isKindOfClass:NSData.class] || !data.length) return NO;
    id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:nil];
    return [plist isKindOfClass:NSDictionary.class];
}

- (NSData *)resumeData:(NSDictionary *)item {
    if ([item[@"resumeRejected"] boolValue]) return nil;
    NSDictionary *normalized = [item[@"schema"] isEqual:@2] ? item : [self normalizedRecord:item];
    NSString *relative = FDMString(normalized[@"resumeRelativePath"]) ?: FDMString(normalized[@"legacyResumeRelativePath"]);
    if (!relative.length) return nil;
    NSString *path = FDMResolveDocumentPath(@{@"relativePath": relative});
    NSData *data = path.length ? [NSData dataWithContentsOfFile:path] : nil;
    return [self isValidResume:data] ? data : nil;
}

- (BOOL)saveResume:(NSData *)data item:(NSMutableDictionary *)item {
    if (![self isValidResume:data] || [_deleted containsObject:item[@"key"]]) return NO;
    NSString *relative = [NSString stringWithFormat:@"FocusDM/resume/%@-%@.resume", FDMLegacyHash(item[@"key"]), item[@"generation"]];
    NSString *path = [FDMDirectory(@"FocusDM/resume") stringByAppendingPathComponent:relative.lastPathComponent];
    NSError *error = nil;
    if (![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
        item[@"actionError"] = @"暂停数据保存失败，下次需要重新下载";
        FDMLog(@"resume persistence failed: %@", error.localizedDescription);
        return NO;
    }
    item[@"resumeRelativePath"] = relative;
    [item removeObjectForKey:@"resumeRejected"];
    return [self resumeData:item].length > 0;
}

- (BOOL)restoring {
    __block BOOL restoring;
    [self sync:^{ restoring = self->_restoring; }];
    return restoring;
}

- (BOOL)isRemovedKey:(NSString *)key {
    __block BOOL removed;
    [self sync:^{ removed = [self->_deleted containsObject:key]; }];
    return removed;
}

- (BOOL)canResumeKey:(NSString *)key {
    __block BOOL available = NO;
    [self sync:^{
        NSDictionary *row = [self item:key] ?: [FDMStore.shared recordForKey:key];
        available = row && [row[@"state"] integerValue] != FDMStateCompleted && ![self->_deleted containsObject:key] && [self resumeData:row].length > 0;
    }];
    return available;
}

- (NSArray<NSDictionary *> *)items {
    __block NSMutableArray *snapshot = [NSMutableArray array];
    [self sync:^{
        for (NSDictionary *row in self->_items) {
            if ([self->_deleted containsObject:row[@"key"]]) continue;
            NSMutableDictionary *copy = [row mutableCopy];
            copy[@"canResume"] = @([self resumeData:row].length > 0);
            copy[@"restoring"] = @(self->_restoring);
            [snapshot addObject:FDMImmutableRecord(copy)];
        }
    }];
    return [snapshot copy];
}

- (void)reconcile:(NSArray<NSURLSessionTask *> *)systemTasks {
    NSMutableSet *live = [NSMutableSet set];
    for (NSURLSessionTask *task in systemTasks) {
        NSString *token = task.taskDescription ?: @"";
        NSString *deletedKey = nil;
        if ([token hasPrefix:@"fdm2:"]) {
            NSRange separator = [token rangeOfString:@":" options:NSBackwardsSearch];
            if (separator.location > 5) deletedKey = [token substringWithRange:NSMakeRange(5, separator.location - 5)];
        } else if (token.length) {
            deletedKey = [@"legacy-" stringByAppendingString:FDMLegacyHash(token)];
        }
        if (deletedKey && [_deleted containsObject:deletedKey]) {
            if (task.state != NSURLSessionTaskStateCompleted) [task cancel];
            continue;
        }
        if (task.state == NSURLSessionTaskStateCompleted) continue;
        NSMutableDictionary *row = [self itemForTask:task];
        if (!row || ![task isKindOfClass:NSURLSessionDownloadTask.class]) continue;
        NSString *key = row[@"key"];
        _tasks[key] = (NSURLSessionDownloadTask *)task;
        row[@"taskIdentifier"] = @(task.taskIdentifier);
        [live addObject:key];
        if ([row[@"state"] integerValue] == FDMStateCompleted) continue;
        if (task.state == NSURLSessionTaskStateRunning || task.state == NSURLSessionTaskStateSuspended) {
            row[@"state"] = @(FDMStateDownloading);
            row[@"pausing"] = @NO;
            if ([row[@"pauseIntent"] boolValue]) [self beginPause:key];
            else if (task.state == NSURLSessionTaskStateSuspended) [task resume];
        }
    }
    _restoring = NO;
    for (NSMutableDictionary *row in [_items copy]) {
        NSString *key = row[@"key"];
        if ([_deleted containsObject:key]) { [_items removeObject:row]; continue; }
        if ([live containsObject:key]) continue;
        NSInteger state = [row[@"state"] integerValue];
        if (state == FDMStateDownloading || [row[@"pausing"] boolValue]) {
            row[@"state"] = @([row[@"pauseIntent"] boolValue] ? FDMStatePaused : FDMStateInterrupted);
            row[@"pausing"] = @NO;
            row[@"speed"] = @0;
        }
        if (state == FDMStateCompleted || state == FDMStateFailed) [self archive:row];
    }
    for (NSString *key in _deleted) {
        NSError *error = nil;
        if (![FDMStore.shared dropKey:key error:&error]) FDMLog(@"committed record deletion still pending history cleanup");
    }
    [self persist:nil];
    FDMLog(@"engine restore complete bound=%lu", (unsigned long)live.count);
    FDMNotifyRecordsChanged();
    [self finishBackgroundIfReady];
}

- (NSString *)startURL:(NSString *)url name:(NSString *)name error:(NSError **)error {
    NSError *invalid = nil;
    NSURL *address = FDMValidatedURL(url, &invalid);
    if (!address) { if (error) *error = invalid; return nil; }
    __block NSString *key;
    __block NSError *failure;
    [self sync:^{
        if (self->_restoring) { failure = FDMError(@"正在恢复系统下载任务，请稍后操作"); return; }
        key = NSUUID.UUID.UUIDString;
        NSMutableDictionary *row = [@{@"schema": @2, @"key": key, @"url": address.absoluteString,
            @"name": FDMSafeFilename(name.length ? name : address.lastPathComponent), @"generation": @0,
            @"state": @(FDMStatePaused), @"received": @0, @"total": @0, @"speed": @0,
            @"time": @(NSDate.date.timeIntervalSince1970)} mutableCopy];
        [self->_items insertObject:row atIndex:0];
        if (![self startItem:row resume:NO error:&failure]) { [self->_items removeObject:row]; key = nil; }
    }];
    if (failure && error) *error = failure;
    if (key) FDMNotifyRecordsChanged();
    return key;
}

- (BOOL)startItem:(NSMutableDictionary *)row resume:(BOOL)resume error:(NSError **)error {
    if ([row[@"state"] integerValue] == FDMStateCompleted) {
        if (error) *error = FDMError(@"该下载已完成；再次下载请新建任务");
        return NO;
    }
    if (_restoring || !_writable || [_deleted containsObject:row[@"key"]]) {
        if (error) *error = FDMError(@"下载记录尚未准备好，未创建新任务");
        return NO;
    }
    NSURL *url = FDMValidatedURL(row[@"url"], error);
    if (!url) return NO;
    NSData *data = resume ? [self resumeData:row] : nil;
    if (resume && !data.length) { if (error) *error = FDMError(@"没有有效的续传数据，请选择重新下载"); return NO; }
    NSMutableDictionary *previous = [row mutableCopy];
    NSURLSessionDownloadTask *task = data ? [_session downloadTaskWithResumeData:data] : [_session downloadTaskWithURL:url];
    row[@"generation"] = @([row[@"generation"] unsignedIntegerValue] + 1);
    task.taskDescription = [self tokenForItem:row];
    row[@"taskIdentifier"] = @(task.taskIdentifier);
    row[@"state"] = @(FDMStateDownloading);
    row[@"pausing"] = @NO;
    row[@"pauseIntent"] = @NO;
    row[@"speed"] = @0;
    row[@"usedResume"] = @(resume);
    [row removeObjectForKey:@"error"];
    [row removeObjectForKey:@"actionError"];
    [row removeObjectForKey:@"resumeRequested"];
    if (!resume) { row[@"received"] = @0; row[@"total"] = @0; }
    [row removeObjectForKey:@"resumeRelativePath"];
    [row removeObjectForKey:@"legacyResumeRelativePath"];
    [row removeObjectForKey:@"canResume"];
    NSString *key = row[@"key"];
    _tasks[key] = task;
    _samples[key] = @[@([row[@"received"] longLongValue]), @(NSDate.date.timeIntervalSince1970)];
    if (![self persist:error]) {
        [_tasks removeObjectForKey:key];
        [_samples removeObjectForKey:key];
        [task cancel];
        [row removeAllObjects];
        [row addEntriesFromDictionary:previous];
        return NO;
    }
    [task resume];
    FDMLog(@"engine start id=%@ attempt=%@ resumed=%d", key, row[@"generation"], (int)resume);
    return YES;
}

- (void)beginPause:(NSString *)key {
    NSMutableDictionary *row = [self item:key];
    key = row[@"key"] ?: key;
    NSURLSessionDownloadTask *task = _tasks[key];
    if (!row || [row[@"state"] integerValue] == FDMStateCompleted || [row[@"pausing"] boolValue]) return;
    row[@"pauseIntent"] = @YES;
    if (!task) { row[@"state"] = @(FDMStatePaused); [self persist:nil]; FDMNotifyRecordsChanged(); return; }
    NSString *token = task.taskDescription;
    row[@"pausing"] = @YES;
    _pauses[token] = [@{@"key": key, @"taskIdentifier": @(task.taskIdentifier), @"cancelSeen": @NO, @"completeSeen": @NO} mutableCopy];
    NSError *failure = nil;
    if (![self persist:&failure]) {
        row[@"pausing"] = @NO;
        row[@"pauseIntent"] = @NO;
        row[@"actionError"] = failure.localizedDescription;
        [_pauses removeObjectForKey:token];
        FDMNotifyRecordsChanged();
        return;
    }
    [task cancelByProducingResumeData:^(NSData *data) {
        dispatch_async(self->_queue, ^{
            NSMutableDictionary *current = [self itemForTask:task];
            NSMutableDictionary *pause = self->_pauses[token];
            if (!current || !pause) return;
            pause[@"cancelSeen"] = @YES;
            if ([self isValidResume:data]) {
                pause[@"resume"] = data;
                [self saveResume:data item:current];
                [self persist:nil];
            }
            [self settlePause:token];
        });
    }];
}

- (void)pauseKey:(NSString *)key {
    dispatch_async(_queue, ^{
        if (self->_restoring) return;
        [self beginPause:key];
        FDMNotifyRecordsChanged();
    });
}

- (void)settlePause:(NSString *)token {
    NSMutableDictionary *pause = _pauses[token];
    if (![pause[@"cancelSeen"] boolValue] || ![pause[@"completeSeen"] boolValue]) return;
    NSString *key = pause[@"key"];
    NSMutableDictionary *row = [self item:key];
    if (!row || (![[self tokenForItem:row] isEqual:token] && ![row[@"legacyKey"] isEqual:token])) { [_pauses removeObjectForKey:token]; return; }
    if ([row[@"state"] integerValue] != FDMStateCompleted) {
        if ([pause[@"resume"] length]) [self saveResume:pause[@"resume"] item:row];
        row[@"state"] = @(FDMStatePaused);
        row[@"pausing"] = @NO;
        row[@"speed"] = @0;
    }
    row[@"pausing"] = @NO;
    if ([row[@"state"] integerValue] == FDMStateCompleted) {
        row[@"pauseIntent"] = @NO;
        [row removeObjectForKey:@"resumeRequested"];
    }
    NSURLSessionTask *current = _tasks[key];
    if (current.taskIdentifier == [pause[@"taskIdentifier"] unsignedIntegerValue]) [_tasks removeObjectForKey:key];
    [_pauses removeObjectForKey:token];
    BOOL requested = [row[@"resumeRequested"] boolValue];
    [row removeObjectForKey:@"resumeRequested"];
    [self persist:nil];
    if (requested && [row[@"state"] integerValue] != FDMStateCompleted) {
        NSError *error = nil;
        if (![self startItem:row resume:YES error:&error]) row[@"actionError"] = error.localizedDescription;
    }
    if ([row[@"state"] integerValue] == FDMStateCompleted) [self archive:row];
    [self persist:nil];
    FDMNotifyRecordsChanged();
    [self finishBackgroundIfReady];
}

- (NSMutableDictionary *)restoreArchivedItem:(NSString *)key {
    NSMutableDictionary *row = [self item:key];
    if (row) return [row[@"state"] integerValue] == FDMStateCompleted ? nil : row;
    NSDictionary *record = [FDMStore.shared recordForKey:key];
    if (!record || [_deleted containsObject:key] || [record[@"state"] integerValue] == FDMStateCompleted) return nil;
    row = [self normalizedRecord:record];
    row[@"state"] = @(FDMStatePaused);
    [_items insertObject:row atIndex:0];
    return row;
}

- (void)dropLegacyAliasForRow:(NSDictionary *)row {
    NSString *legacy = FDMString(row[@"legacyKey"]);
    if (!legacy.length || [legacy isEqual:row[@"key"]]) return;
    NSDictionary *old = [FDMStore.shared recordForKey:legacy];
    if (!FDMLegacyAliasMatches(row, old)) return;
    NSError *error = nil;
    if (![FDMStore.shared dropKey:legacy error:&error]) FDMLog(@"legacy alias cleanup pending: %@", error.localizedDescription);
}

- (void)resumeKey:(NSString *)key {
    dispatch_async(_queue, ^{
        if (self->_restoring) return;
        NSMutableDictionary *row = [self restoreArchivedItem:key];
        if (!row) return;
        if ([row[@"pausing"] boolValue]) { row[@"resumeRequested"] = @YES; [self persist:nil]; return; }
        if (self->_tasks[row[@"key"]]) return;
        NSError *error = nil;
        if (![self startItem:row resume:YES error:&error]) { row[@"actionError"] = error.localizedDescription; [self persist:nil]; }
        else { [FDMStore.shared dropKey:key error:nil]; [self dropLegacyAliasForRow:row]; }
        FDMNotifyRecordsChanged();
    });
}

- (void)restartKey:(NSString *)key {
    dispatch_async(_queue, ^{
        if (self->_restoring) return;
        NSMutableDictionary *row = [self restoreArchivedItem:key];
        if (!row || self->_tasks[row[@"key"]] || [row[@"pausing"] boolValue]) return;
        NSError *error = nil;
        if (![self startItem:row resume:NO error:&error]) row[@"actionError"] = error.localizedDescription;
        else { [FDMStore.shared dropKey:key error:nil]; [self dropLegacyAliasForRow:row]; }
        [self persist:nil];
        FDMNotifyRecordsChanged();
    });
}

- (void)removeKey:(NSString *)key deleteFile:(BOOL)deleteFile completion:(void (^)(NSError *))completion {
    dispatch_async(_queue, ^{
        NSMutableDictionary *row = [self item:key];
        NSDictionary *record = row ?: [FDMStore.shared recordForKey:key];
        NSString *canonical = row[@"key"] ?: key;
        NSError *error = nil;
        BOOL fileRemoved = NO;
        if (!self->_writable) error = FDMError(@"下载存储格式未知或不可写；原文件保留，未删除记录或文件");
        else if (self->_restoring) error = FDMError(@"系统任务正在恢复，请稍后删除");
        else if (deleteFile && record) {
            NSString *path = FDMResolveDocumentPath(record);
            if (path.length) {
                BOOL existed = [[NSFileManager defaultManager] fileExistsAtPath:path];
                if (FDMRemoveOwnedFile(record, &error)) fileRemoved = existed;
            } else if (FDMString(record[@"path"]).length || FDMString(record[@"relativePath"]).length) {
                error = FDMError(@"文件路径无法确认，未删除文件或记录");
            }
        }
        if (!error) {
            NSMutableSet *next = [self->_deleted mutableCopy];
            [next addObject:canonical];
            if ([canonical isEqual:key] || FDMLegacyAliasMatches(record, [FDMStore.shared recordForKey:key])) [next addObject:key];
            NSString *legacy = FDMString(row[@"legacyKey"]);
            if (FDMLegacyAliasMatches(record, [FDMStore.shared recordForKey:legacy])) [next addObject:legacy];
            else legacy = nil;
            NSError *journalError = nil;
            if (!FDMWriteJSON(next.allObjects, [self deletionPath], &journalError)) {
                error = fileRemoved ? FDMError(@"本地文件已删除，但记录删除无法提交；请重试删除记录") : journalError;
            } else {
                // Durable journal is the commit point: all later callbacks and restoration are suppressed.
                self->_deleted = next;
                NSError *historyError = nil;
                [FDMStore.shared dropKey:canonical error:&historyError];
                if (![canonical isEqual:key] && [next containsObject:key]) [FDMStore.shared dropKey:key error:&historyError];
                if (legacy.length) [FDMStore.shared dropKey:legacy error:&historyError];
                NSURLSessionDownloadTask *task = self->_tasks[canonical];
                if (task) [task cancel];
                [self->_tasks removeObjectForKey:canonical];
                for (NSString *token in [self->_pauses.allKeys copy]) if ([self->_pauses[token][@"key"] isEqual:canonical]) [self->_pauses removeObjectForKey:token];
                if (row) [self->_items removeObject:row];
                NSError *persistError = nil;
                [self persist:&persistError];
                if (historyError || persistError) error = FDMError(@"记录删除已提交，存储清理待重试；本地文件未被额外删除");
            }
        }
        // NO never touches final/resume files, including the legacy resume candidate.
        FDMNotifyRecordsChanged();
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(error); });
    });
}

- (BOOL)commitTerminalRecord:(NSMutableDictionary *)row {
    if ([_deleted containsObject:row[@"key"]]) return NO;
    NSMutableDictionary *record = [row mutableCopy];
    record[@"source"] = @0;
    record[@"pausing"] = @NO;
    [record removeObjectForKey:@"resumeRequested"];
    if ([record[@"state"] integerValue] == FDMStateCompleted) record[@"pauseIntent"] = @NO;
    record[@"canResume"] = @([record[@"state"] integerValue] != FDMStateCompleted && [self resumeData:row].length > 0);
    NSError *error = nil;
    BOOL committed = [FDMStore.shared upsertRecord:record error:&error];
    if (!committed) { row[@"actionError"] = error.localizedDescription; FDMLog(@"engine terminal record commit failed"); }
    return committed;
}

- (void)archive:(NSMutableDictionary *)row {
    if ([self commitTerminalRecord:row]) {
        [self dropLegacyAliasForRow:row];
        [_items removeObject:row];
    }
}

#pragma mark - Delegate lifetime and attempt boundaries

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)received totalBytesExpectedToWrite:(int64_t)total {
    [self sync:^{
        NSMutableDictionary *row = [self itemForTask:task];
        if (!row || [row[@"pausing"] boolValue] || [row[@"state"] integerValue] == FDMStateCompleted) return;
        row[@"received"] = @(MAX(0, received));
        row[@"total"] = @(MAX(0, total));
        NSString *key = row[@"key"];
        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        NSArray *last = self->_samples[key];
        if (last && now - [last[1] doubleValue] >= 0.4) {
            row[@"speed"] = @(MAX(0, received - [last[0] longLongValue]) / (now - [last[1] doubleValue]));
            self->_samples[key] = @[@(received), @(now)];
        }
        if (now - self->_lastSave > 1.5) { [self persist:nil]; FDMNotifyRecordsChanged(); }
    }];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)location {
    // Synchronous ownership is essential: NSURLSession's temporary file expires when this delegate returns.
    [self sync:^{
        NSMutableDictionary *row = [self itemForTask:task];
        if (!row || [row[@"state"] integerValue] == FDMStateCompleted) return;
        NSHTTPURLResponse *response = [task.response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)task.response : nil;
        if (!response || response.statusCode < 200 || response.statusCode >= 300) {
            row[@"state"] = @(FDMStateFailed);
            row[@"error"] = response ? [NSString stringWithFormat:@"HTTP %ld：服务器未提供成功下载响应", (long)response.statusCode] : @"响应不是可验证的 HTTP 文件下载";
            [self persist:nil];
            return;
        }
        NSString *directory = FDMDirectory([@"FocusDM/downloads" stringByAppendingPathComponent:FDMLegacyHash(row[@"key"])]);
        NSString *name = FDMSafeFilename(response.suggestedFilename ?: row[@"name"]);
        NSString *destination = [directory stringByAppendingPathComponent:name];
        if ([[NSFileManager defaultManager] fileExistsAtPath:destination]) {
            NSString *base = name.stringByDeletingPathExtension;
            NSString *suffix = name.pathExtension;
            NSString *unique = [NSString stringWithFormat:@"%@-%@%@%@", base, NSUUID.UUID.UUIDString, suffix.length ? @"." : @"", suffix];
            destination = [directory stringByAppendingPathComponent:unique];
        }
        NSError *error = nil;
        if (!FDMRelativeDocumentPath(destination) || [[NSFileManager defaultManager] fileExistsAtPath:destination]) error = FDMError(@"无法创建唯一保存路径；已有文件未覆盖");
        else if (![[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:destination] error:&error]) {}
        if (error) { row[@"state"] = @(FDMStateFailed); row[@"error"] = error.localizedDescription; }
        else {
            row[@"state"] = @(FDMStateCompleted);
            row[@"pausing"] = @NO;
            row[@"pauseIntent"] = @NO;
            [row removeObjectForKey:@"resumeRequested"];
            row[@"path"] = destination;
            row[@"relativePath"] = FDMRelativeDocumentPath(destination);
            NSDictionary *identity = FDMFileIdentity(destination);
            if (identity) row[@"fileIdentity"] = identity;
            row[@"size"] = identity[@"size"] ?: @(task.countOfBytesReceived);
            row[@"received"] = row[@"size"];
            row[@"completedAt"] = @(NSDate.date.timeIntervalSince1970);
            row[@"completionEvidence"] = @"http-success-and-file-moved";
            row[@"speed"] = @0;
            [row removeObjectForKey:@"error"];
            [self commitTerminalRecord:row];
        }
        [self persist:nil];
        FDMNotifyRecordsChanged();
    }];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    [self sync:^{
        NSMutableDictionary *row = [self itemForTask:task];
        if (!row) return;
        NSString *key = row[@"key"];
        NSString *token = task.taskDescription;
        NSMutableDictionary *pause = self->_pauses[token];
        if (pause) {
            pause[@"completeSeen"] = @YES;
            NSData *data = error.userInfo[NSURLSessionDownloadTaskResumeData];
            if ([self isValidResume:data] && ![pause[@"resume"] length]) {
                pause[@"resume"] = data;
                [self saveResume:data item:row];
                [self persist:nil];
            }
            [self settlePause:token];
            return;
        }
        NSURLSessionTask *current = self->_tasks[key];
        if (current.taskIdentifier == task.taskIdentifier) [self->_tasks removeObjectForKey:key];
        [self->_samples removeObjectForKey:key];
        if ([row[@"pauseIntent"] boolValue] && [row[@"state"] integerValue] != FDMStateCompleted) {
            NSData *data = error.userInfo[NSURLSessionDownloadTaskResumeData];
            if ([data isKindOfClass:NSData.class] && data.length) [self saveResume:data item:row];
            row[@"state"] = @(FDMStatePaused);
            row[@"pausing"] = @NO;
            row[@"speed"] = @0;
            [self persist:nil];
            FDMNotifyRecordsChanged();
            [self finishBackgroundIfReady];
            return;
        }
        if ([row[@"state"] integerValue] != FDMStateCompleted) {
            NSData *data = error.userInfo[NSURLSessionDownloadTaskResumeData];
            if ([data isKindOfClass:NSData.class] && data.length) [self saveResume:data item:row];
            if ([row[@"usedResume"] boolValue] && error && ![self resumeData:row].length) {
                row[@"resumeRejected"] = @YES;
                row[@"error"] = [NSString stringWithFormat:@"续传未完成：%@；没有新的续传数据，请重新下载", error.localizedDescription ?: @"系统下载失败"];
            } else if (!row[@"error"]) row[@"error"] = error.localizedDescription ?: @"下载未完成文件保存，请重试";
            row[@"state"] = @([self resumeData:row].length ? FDMStateInterrupted : FDMStateFailed);
            row[@"speed"] = @0;
        }
        if ([row[@"state"] integerValue] == FDMStateCompleted || [row[@"state"] integerValue] == FDMStateFailed) [self archive:row];
        [self persist:nil];
        FDMNotifyRecordsChanged();
        [self finishBackgroundIfReady];
    }];
}

- (void)setBackgroundCompletion:(void (^)(void))completion {
    dispatch_async(_queue, ^{
        if (self->_backgroundCompletion) {
            if (!self->_additionalBackgroundCompletions) self->_additionalBackgroundCompletions = [NSMutableArray array];
            [self->_additionalBackgroundCompletions addObject:[completion copy]];
            return;
        }
        if (self->_backgroundBatchConsumed) self->_eventsFinished = NO;
        self->_backgroundBatchConsumed = NO;
        self->_backgroundCompletion = [completion copy];
        [self finishBackgroundIfReady];
    });
}

- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
    [self sync:^{
        if (self->_backgroundBatchConsumed && !self->_backgroundCompletion) return;
        self->_eventsFinished = YES;
        [self finishBackgroundIfReady];
    }];
}

- (void)finishBackgroundIfReady {
    if (!_eventsFinished || _restoring || _pauses.count || !_backgroundCompletion) return;
    NSError *error = nil;
    if (![self persist:&error]) {
        FDMLog(@"background finish waiting for persistence: %@", error.localizedDescription);
        static const NSUInteger retryLimit = 3;
        if (_backgroundSaveRetries < retryLimit) {
            _backgroundSaveRetries++;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), _queue, ^{ [self finishBackgroundIfReady]; });
        }
        return;
    }
    _backgroundSaveRetries = 0;
    void (^completion)(void) = _backgroundCompletion;
    NSArray *additional = [_additionalBackgroundCompletions copy];
    [_additionalBackgroundCompletions removeAllObjects];
    _backgroundCompletion = nil;
    _eventsFinished = NO;
    _backgroundBatchConsumed = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        completion();
        for (id block in additional) { void (^other)(void) = block; other(); }
    });
}
@end
