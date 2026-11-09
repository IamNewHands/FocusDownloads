#import "FDMEngine.h"
#import "FDMStore.h"
#import "FDMIntent.h"

// The WebKit transport lives in its own owner and links WebKit. The engine must stay Foundation-only
// so the regression build (and any Foundation-only host) does not pull WebKit in; the cancel call is
// therefore resolved at runtime and is a no-op when the WebKit owner is absent.
static void FDMEngineCancelWebKitDownload(NSString *key) {
    Class webKitOwner = NSClassFromString(@"FDMWebKitDownloads");
    SEL shared = NSSelectorFromString(@"shared");
    SEL cancel = NSSelectorFromString(@"cancelKey:");
    if (!webKitOwner || ![webKitOwner respondsToSelector:shared]) return;
    id owner = ((id (*)(id, SEL))objc_msgSend)((id)webKitOwner, shared);
    if (owner && [owner respondsToSelector:cancel]) ((void (*)(id, SEL, id))objc_msgSend)(owner, cancel, key);
}

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
    // Request context for queued intents. Never persisted: cookies and auth headers die with the
    // process, and a restored row without its request is reported as needsContext.
    NSMutableDictionary<NSString *, NSURLRequest *> *_requests;
    NSMutableDictionary<NSString *, FDMCredentialedTransport *> *_credentialed;
    NSString *_path;
    BOOL _restoring;
    BOOL _writable;
    BOOL _eventsFinished;
    BOOL _backgroundBatchConsumed;
    NSTimeInterval _lastSave;
    NSUInteger _backgroundSaveRetries;
    NSUInteger _concurrencyLimit;
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
    _requests = [NSMutableDictionary dictionary];
    _credentialed = [NSMutableDictionary dictionary];
    _concurrencyLimit = 3;
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
        // The background transport is the anonymous one. It must not silently inherit browser
        // cookies: a credentialed download takes the explicit per-intent transport instead.
        configuration.HTTPShouldSetCookies = NO;
        configuration.HTTPCookieStorage = nil;
        configuration.URLCache = nil;
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

#pragma mark - scheduler

- (NSUInteger)concurrencyLimit {
    __block NSUInteger value;
    [self sync:^{ value = self->_concurrencyLimit; }];
    return value;
}

- (void)setConcurrencyLimit:(NSUInteger)limit {
    NSUInteger clamped = MIN(6, MAX(1, limit));
    dispatch_async(_queue, ^{
        self->_concurrencyLimit = clamped;
        [self pumpScheduler];
    });
}

- (BOOL)isReplayableRow:(NSDictionary *)row {
    return [row[@"replayable"] boolValue] || [row[@"transport"] integerValue] == FDMTransportAnonymousBackground;
}

- (NSUInteger)runningReplayableCount {
    NSUInteger count = 0;
    for (NSMutableDictionary *row in _items) {
        if (![self isReplayableRow:row]) continue;
        if ([row[@"state"] integerValue] == FDMStateDownloading && ![row[@"pausing"] boolValue]) count++;
    }
    return count;
}

// Starts queued GETs up to the limit. Only rows that never started are eligible, so a restored or
// finished attempt is never duplicated by a queue pump.
- (void)pumpScheduler {
    if (_restoring) return;
    NSUInteger running = [self runningReplayableCount];
    BOOL changed = NO;
    for (NSMutableDictionary *row in [_items copy]) {
        if (running >= _concurrencyLimit) break;
        if ([_deleted containsObject:row[@"key"]]) continue;
        if ([row[@"schedulerStatus"] integerValue] != FDMSchedulerWaiting) continue;
        if ([row[@"state"] integerValue] != FDMStatePaused) continue;
        NSURLRequest *request = _requests[row[@"key"]];
        NSError *error = nil;
        if (![self startItem:row resume:NO request:request error:&error]) {
            row[@"actionError"] = error.localizedDescription;
            row[@"schedulerStatus"] = @(FDMSchedulerNeedsContext);
            row[@"waitReason"] = error.localizedDescription;
            continue;
        }
        running++;
        changed = YES;
    }
    if (changed) {
        [self persist:nil];
        FDMNotifyRecordsChanged();
    }
}

- (void)markSlotFreed {
    // A slot is released only once the attempt truly converged; a cancel request alone is not enough.
    [self pumpScheduler];
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
            // Rows written by v19 have no scheduler fields; project them from the legacy state
            // instead of leaving the UI to invent a queue position.
            if (!copy[@"schedulerStatus"]) {
                NSInteger state = [copy[@"state"] integerValue];
                copy[@"schedulerStatus"] = @(state == FDMStateDownloading ? FDMSchedulerRunning :
                    (state == FDMStatePaused ? FDMSchedulerUserPaused : FDMSchedulerNeedsContext));
            }
            if (!copy[@"transport"]) copy[@"transport"] = @(FDMTransportAnonymousBackground);
            if (!copy[@"replayable"]) copy[@"replayable"] = @([copy[@"method"] isEqual:@"POST"] ? NO : YES);
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
            row[@"schedulerStatus"] = @([row[@"pauseIntent"] boolValue] ? FDMSchedulerUserPaused : FDMSchedulerNeedsContext);
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
    // Restored rows are already bound or terminal; only now may the queue start new work.
    [self pumpScheduler];
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
    return [self startItem:row resume:resume request:nil error:error];
}

- (BOOL)startItem:(NSMutableDictionary *)row resume:(BOOL)resume request:(NSURLRequest *)request error:(NSError **)error {
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
    if (!data && request && [row[@"transport"] integerValue] == FDMTransportCredentialedSession) {
        return [self startCredentialedItem:row request:request previous:previous error:error];
    }
    NSURLSessionDownloadTask *task = data ? [_session downloadTaskWithResumeData:data] : [_session downloadTaskWithRequest:(request ?: [NSURLRequest requestWithURL:url])];
    row[@"generation"] = @([row[@"generation"] unsignedIntegerValue] + 1);
    task.taskDescription = [self tokenForItem:row];
    row[@"taskIdentifier"] = @(task.taskIdentifier);
    row[@"state"] = @(FDMStateDownloading);
    row[@"schedulerStatus"] = @(FDMSchedulerRunning);
    [row removeObjectForKey:@"waitReason"];
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
    FDMLog(@"engine start id=%@ attempt=%@ resumed=%d transport=%@", key, row[@"generation"], (int)resume,
           FDMTransportName([row[@"transport"] integerValue]));
    return YES;
}

#pragma mark - credentialed transport

- (BOOL)startCredentialedItem:(NSMutableDictionary *)row request:(NSURLRequest *)request previous:(NSMutableDictionary *)previous error:(NSError **)error {
    NSString *key = row[@"key"];
    FDMCredentialedTransport *transport = [[FDMCredentialedTransport alloc] initWithIntent:nil request:request queue:_queue];
    row[@"generation"] = @([row[@"generation"] unsignedIntegerValue] + 1);
    row[@"state"] = @(FDMStateDownloading);
    row[@"schedulerStatus"] = @(FDMSchedulerRunning);
    [row removeObjectForKey:@"waitReason"];
    row[@"pausing"] = @NO;
    row[@"pauseIntent"] = @NO;
    row[@"speed"] = @0;
    row[@"usedResume"] = @NO;
    row[@"received"] = @0;
    row[@"total"] = @0;
    [row removeObjectForKey:@"error"];
    [row removeObjectForKey:@"actionError"];
    [row removeObjectForKey:@"resumeRelativePath"];
    [row removeObjectForKey:@"canResume"];
    _credentialed[key] = transport;
    if (![self persist:error]) {
        [_credentialed removeObjectForKey:key];
        [row removeAllObjects];
        [row addEntriesFromDictionary:previous];
        return NO;
    }
    __weak typeof(self) weakSelf = self;
    NSUInteger generation = [row[@"generation"] unsignedIntegerValue];
    [transport startWithProgress:^(int64_t received, int64_t total) {
        [weakSelf applyCredentialedProgress:key generation:generation received:received total:total];
    } completion:^(NSURL *location, NSHTTPURLResponse *response, NSError *failure) {
        [weakSelf finishCredentialed:key generation:generation location:location response:response error:failure];
    }];
    FDMLog(@"engine start id=%@ attempt=%@ transport=%@", key, row[@"generation"], FDMTransportName(FDMTransportCredentialedSession));
    return YES;
}

- (void)applyCredentialedProgress:(NSString *)key generation:(NSUInteger)generation received:(int64_t)received total:(int64_t)total {
    [self sync:^{
        NSMutableDictionary *row = [self item:key];
        if (!row || [row[@"generation"] unsignedIntegerValue] != generation) return;
        if ([row[@"pausing"] boolValue] || [row[@"state"] integerValue] == FDMStateCompleted) return;
        row[@"received"] = @(MAX(0, received));
        row[@"total"] = @(MAX(0, total));
    }];
}

- (void)finishCredentialed:(NSString *)key generation:(NSUInteger)generation location:(NSURL *)location response:(NSHTTPURLResponse *)response error:(NSError *)failure {
    [self sync:^{
        // A late callback from an older attempt must never write the new task's state or file.
        NSMutableDictionary *row = [self item:key];
        if (!row || [row[@"generation"] unsignedIntegerValue] != generation) {
            if (location) [[NSFileManager defaultManager] removeItemAtURL:location error:nil];
            return;
        }
        [self->_credentialed removeObjectForKey:key];
        if ([self->_deleted containsObject:key]) {
            if (location) [[NSFileManager defaultManager] removeItemAtURL:location error:nil];
            return;
        }
        if ([row[@"pauseIntent"] boolValue]) {
            // The credentialed transport has no resumable payload; keep the paused row honest.
            row[@"state"] = @(FDMStatePaused);
            row[@"schedulerStatus"] = @(FDMSchedulerUserPaused);
            row[@"pausing"] = @NO;
            row[@"speed"] = @0;
            row[@"waitReason"] = @"此下载不支持断点续传，继续时需要重新发起";
            if (location) [[NSFileManager defaultManager] removeItemAtURL:location error:nil];
            [self persist:nil];
            FDMNotifyRecordsChanged();
            [self markSlotFreed];
            [self finishBackgroundIfReady];
            return;
        }
        if (!failure && location && response.statusCode >= 200 && response.statusCode < 300) {
            [self acceptDownloadedFile:location row:row response:response evidence:@"credentialed-http-file"];
        } else {
            row[@"state"] = @(FDMStateFailed);
            row[@"schedulerStatus"] = @(FDMSchedulerNeedsContext);
            row[@"error"] = failure.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld：服务器未提供成功下载响应", (long)response.statusCode];
            row[@"speed"] = @0;
            if (location) [[NSFileManager defaultManager] removeItemAtURL:location error:nil];
            [self commitTerminalRecord:row];
            [self archive:row];
        }
        [self persist:nil];
        FDMNotifyRecordsChanged();
        [self markSlotFreed];
        [self finishBackgroundIfReady];
    }];
}

// Takes synchronous ownership of a temporary file and commits completion evidence.
- (BOOL)acceptDownloadedFile:(NSURL *)location row:(NSMutableDictionary *)row response:(NSURLResponse *)response evidence:(NSString *)evidence {
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
    if (error) {
        row[@"state"] = @(FDMStateFailed);
        row[@"schedulerStatus"] = @(FDMSchedulerNeedsContext);
        row[@"error"] = error.localizedDescription;
        [self commitTerminalRecord:row];
        [self archive:row];
        return NO;
    }
    NSDictionary *identity = FDMFileIdentity(destination);
    row[@"state"] = @(FDMStateCompleted);
    row[@"schedulerStatus"] = @(FDMSchedulerRunning);
    row[@"pausing"] = @NO;
    row[@"pauseIntent"] = @NO;
    [row removeObjectForKey:@"resumeRequested"];
    row[@"path"] = destination;
    row[@"relativePath"] = FDMRelativeDocumentPath(destination);
    if (identity) row[@"fileIdentity"] = identity;
    row[@"size"] = identity[@"size"] ?: (row[@"received"] ?: @0);
    row[@"received"] = row[@"size"];
    row[@"completedAt"] = @(NSDate.date.timeIntervalSince1970);
    row[@"completionEvidence"] = evidence;
    row[@"speed"] = @0;
    [row removeObjectForKey:@"error"];
    [self commitTerminalRecord:row];
    [self archive:row];
    return YES;
}

#pragma mark - WebKit downloads

- (NSString *)registerWebKitDownload:(id)download intent:(id)intent tabID:(NSString *)tabID {
    if (!download) return nil;
    __block NSString *key;
    __block NSError *failure;
    NSURLRequest *request = FDMValue(download, @"originalRequest");
    if (![request isKindOfClass:NSURLRequest.class]) request = nil;
    [self sync:^{
        if (self->_restoring) { failure = FDMError(@"正在恢复系统下载任务，请稍后操作"); return; }
        if (!self->_writable) { failure = FDMError(@"下载记录文件不可写；网页下载未接管"); return; }
        NSUInteger queued = 0;
        for (NSDictionary *row in self->_items) if ([row[@"schedulerStatus"] integerValue] == FDMSchedulerWaiting) queued++;
        if (queued >= FDMQueueLimit) { failure = FDMError(@"下载任务过多，请先处理现有任务"); return; }
        key = NSUUID.UUID.UUIDString;
        FDMDownloadIntent *downloadIntent = [intent isKindOfClass:FDMDownloadIntent.class] ? intent : nil;
        NSString *name = downloadIntent.suggestedFilename;
        if (!name.length) name = request.URL.lastPathComponent;
        NSMutableDictionary *row = [@{@"schema": @2, @"key": key,
            @"url": request.URL.absoluteString ?: @"",
            @"name": FDMSafeFilename(name), @"generation": @0,
            // A WebKit download is in flight the moment it is adopted: it is not a queued GET.
            @"state": @(FDMStateDownloading), @"schedulerStatus": @(FDMSchedulerRunning),
            @"transport": @(FDMTransportWebKitDownload), @"replayable": @NO,
            @"method": request.HTTPMethod.uppercaseString ?: @"GET",
            @"source": @0, @"received": @0, @"total": @0, @"speed": @0,
            @"time": @(NSDate.date.timeIntervalSince1970)} mutableCopy];
        if (downloadIntent) {
            row[@"intentID"] = downloadIntent.intentID;
            if (downloadIntent.sourceOrigin) row[@"sourceOrigin"] = downloadIntent.sourceOrigin;
            if (downloadIntent.targetOrigin) row[@"targetOrigin"] = downloadIntent.targetOrigin;
        }
        [self->_items insertObject:row atIndex:0];
        if (![self persist:&failure]) {
            [self->_items removeObject:row];
            key = nil;
        }
    }];
    if (failure) FDMLog(@"webkit adoption refused: %@", failure.localizedDescription);
    if (key) FDMNotifyRecordsChanged();
    return key;
}

- (NSString *)destinationForWebKitDownloadKey:(NSString *)key suggestedFilename:(NSString *)filename response:(NSURLResponse *)response {
    if (!key.length) return nil;
    __block NSString *destination;
    [self sync:^{
        NSMutableDictionary *row = [self item:key];
        if (!row || [self->_deleted containsObject:key]) return;
        NSString *name = FDMSafeFilename(filename.length ? filename : (response.suggestedFilename ?: row[@"name"]));
        NSString *directory = FDMDirectory([@"FocusDM/downloads" stringByAppendingPathComponent:FDMLegacyHash(key)]);
        NSString *candidate = [directory stringByAppendingPathComponent:name];
        // WebKit requires a path that does not exist yet; a second attempt gets its own unique name.
        if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
            NSString *base = name.stringByDeletingPathExtension;
            NSString *suffix = name.pathExtension;
            candidate = [directory stringByAppendingPathComponent:
                [NSString stringWithFormat:@"%@-%@%@%@", base, NSUUID.UUID.UUIDString, suffix.length ? @"." : @"", suffix]];
        }
        if (!FDMRelativeDocumentPath(candidate) || [[NSFileManager defaultManager] fileExistsAtPath:candidate]) return;
        row[@"path"] = candidate;
        row[@"relativePath"] = FDMRelativeDocumentPath(candidate);
        [self persist:nil];
        destination = candidate;
    }];
    return destination;
}

- (void)applyWebKitProgressKey:(NSString *)key received:(long long)received total:(long long)total {
    if (!key.length) return;
    [self sync:^{
        NSMutableDictionary *row = [self item:key];
        if (!row || [row[@"state"] integerValue] == FDMStateCompleted) return;
        row[@"received"] = @(MAX(0, received));
        row[@"total"] = @(MAX(0, total));
    }];
}

- (void)webKitDownloadDidFinishKey:(NSString *)key {
    if (!key.length) return;
    __block BOOL unconfirmed = NO;
    [self sync:^{
        NSMutableDictionary *row = [self item:key];
        if (!row || [self->_deleted containsObject:key]) return;
        // Completion needs an actual regular file with a confirmed identity, not just a callback.
        NSString *path = FDMResolveDocumentPath(row);
        NSDictionary *identity = path.length ? FDMFileIdentity(path) : nil;
        if (!identity) { unconfirmed = YES; return; }
        row[@"state"] = @(FDMStateCompleted);
        row[@"pausing"] = @NO;
        row[@"pauseIntent"] = @NO;
        row[@"fileIdentity"] = identity;
        row[@"size"] = identity[@"size"];
        row[@"received"] = identity[@"size"];
        row[@"completedAt"] = @(NSDate.date.timeIntervalSince1970);
        row[@"completionEvidence"] = @"webkit-finish-and-file-confirmed";
        row[@"speed"] = @0;
        [row removeObjectForKey:@"error"];
        [self commitTerminalRecord:row];
        [self archive:row];
        [self persist:nil];
        FDMNotifyRecordsChanged();
        [self finishBackgroundIfReady];
    }];
    if (unconfirmed) [self webKitDownloadKey:key failedWithMessage:@"网页下载已结束，但保存的文件无法确认" deleted:NO];
}

- (void)webKitDownloadKey:(NSString *)key failedWithMessage:(NSString *)message deleted:(BOOL)deleted {
    if (!key.length) return;
    [self sync:^{
        NSMutableDictionary *row = [self item:key];
        if (!row || [self->_deleted containsObject:key]) return;
        if ([row[@"state"] integerValue] == FDMStateCompleted) return;
        row[@"state"] = @(FDMStateFailed);
        // No anonymous retry: the request context only existed inside WebKit.
        row[@"schedulerStatus"] = @(FDMSchedulerNeedsContext);
        row[@"error"] = message.length ? message : @"网页下载失败";
        row[@"speed"] = @0;
        [self commitTerminalRecord:row];
        [self archive:row];
        [self persist:nil];
        FDMNotifyRecordsChanged();
        [self finishBackgroundIfReady];
    }];
    (void)deleted;
}

#pragma mark - intent entry points

- (NSString *)enqueueURL:(NSString *)url name:(NSString *)name error:(NSError **)error {
    NSError *invalid = nil;
    NSURL *address = FDMValidatedURL(url, &invalid);
    if (!address) { if (error) *error = invalid; return nil; }
    __block NSString *key;
    __block NSError *failure;
    [self sync:^{
        if (self->_restoring) { failure = FDMError(@"正在恢复系统下载任务，请稍后操作"); return; }
        NSUInteger queued = 0;
        for (NSDictionary *row in self->_items) if ([row[@"schedulerStatus"] integerValue] == FDMSchedulerWaiting) queued++;
        if (queued >= FDMQueueLimit) { failure = FDMError(@"等待队列已满，请先处理现有任务"); return; }
        key = NSUUID.UUID.UUIDString;
        NSMutableDictionary *row = [@{@"schema": @2, @"key": key, @"url": address.absoluteString,
            @"name": FDMSafeFilename(name.length ? name : address.lastPathComponent), @"generation": @0,
            @"state": @(FDMStatePaused), @"schedulerStatus": @(FDMSchedulerWaiting),
            @"transport": @(FDMTransportAnonymousBackground), @"replayable": @YES,
            @"source": @0, @"received": @0, @"total": @0, @"speed": @0,
            @"time": @(NSDate.date.timeIntervalSince1970)} mutableCopy];
        [self->_items insertObject:row atIndex:0];
        self->_requests[key] = [NSURLRequest requestWithURL:address];
        // Persist the waiting row before any transport exists, so a crash cannot lose the queue slot.
        if (![self persist:&failure]) {
            [self->_items removeObject:row];
            [self->_requests removeObjectForKey:key];
            key = nil;
            return;
        }
        [self pumpScheduler];
    }];
    if (failure && error) *error = failure;
    if (key) FDMNotifyRecordsChanged();
    return key;
}

- (NSString *)startIntent:(id)intent request:(NSURLRequest *)request error:(NSError **)error {
    FDMDownloadIntent *downloadIntent = intent;
    if (!downloadIntent || !request) { if (error) *error = FDMError(@"下载意图无效，请重新发起下载"); return nil; }
    __block NSString *key;
    __block NSError *failure;
    [self sync:^{
        if (self->_restoring) { failure = FDMError(@"正在恢复系统下载任务，请稍后操作"); return; }
        if (downloadIntent.transport == FDMTransportWebKitDownload) {
            failure = FDMError(@"该下载依赖原浏览器请求，不能改为重新请求；请使用页面内的下载入口");
            return;
        }
        key = NSUUID.UUID.UUIDString;
        NSMutableDictionary *row = [@{@"schema": @2, @"key": key, @"url": downloadIntent.url,
            @"name": FDMSafeFilename(downloadIntent.suggestedFilename ?: request.URL.lastPathComponent),
            @"generation": @0, @"state": @(FDMStatePaused),
            @"schedulerStatus": @(FDMSchedulerWaiting),
            @"transport": @(downloadIntent.transport), @"replayable": @(downloadIntent.replayable),
            @"intentID": downloadIntent.intentID, @"method": downloadIntent.method ?: @"GET",
            @"sourceOrigin": downloadIntent.sourceOrigin ?: @"", @"targetOrigin": downloadIntent.targetOrigin ?: @"",
            @"source": @0, @"received": @0, @"total": @0, @"speed": @0,
            @"time": @(NSDate.date.timeIntervalSince1970)} mutableCopy];
        [self->_items insertObject:row atIndex:0];
        self->_requests[key] = request;
        if (![self persist:&failure]) {
            [self->_items removeObject:row];
            [self->_requests removeObjectForKey:key];
            key = nil;
            return;
        }
        [self pumpScheduler];
    }];
    if (failure && error) *error = failure;
    if (key) FDMNotifyRecordsChanged();
    return key;
}

- (void)beginPause:(NSString *)key {
    NSMutableDictionary *row = [self item:key];
    key = row[@"key"] ?: key;
    // A WebKit download has no resumeData the app may persist, so pausing it means cancelling the
    // WebKit object and keeping an honest "paused, needs re-issue" row.
    if ([row[@"transport"] integerValue] == FDMTransportWebKitDownload) {
        if (!row || [row[@"state"] integerValue] == FDMStateCompleted || [row[@"pausing"] boolValue]) return;
        row[@"pauseIntent"] = @YES;
        row[@"pausing"] = @NO;
        row[@"state"] = @(FDMStatePaused);
        row[@"schedulerStatus"] = @(FDMSchedulerUserPaused);
        row[@"speed"] = @0;
        row[@"waitReason"] = @"网页原请求下载不支持断点续传；继续时需要重新发起";
        [self persist:nil];
        FDMEngineCancelWebKitDownload(key);
        FDMNotifyRecordsChanged();
        return;
    }
    NSURLSessionDownloadTask *task = _tasks[key];
    if (!row || [row[@"state"] integerValue] == FDMStateCompleted || [row[@"pausing"] boolValue]) return;
    row[@"pauseIntent"] = @YES;
    if (!task) { row[@"state"] = @(FDMStatePaused); row[@"schedulerStatus"] = @(FDMSchedulerUserPaused); [self persist:nil]; FDMNotifyRecordsChanged(); return; }
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
        if (error) {
            row[@"state"] = @(FDMStateFailed);
            row[@"schedulerStatus"] = @(FDMSchedulerNeedsContext);
            row[@"error"] = error.localizedDescription;
        } else {
            row[@"state"] = @(FDMStateCompleted);
            row[@"schedulerStatus"] = @(FDMSchedulerRunning);
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
            row[@"schedulerStatus"] = @(FDMSchedulerUserPaused);
            row[@"pausing"] = @NO;
            row[@"speed"] = @0;
            [self persist:nil];
            FDMNotifyRecordsChanged();
            [self markSlotFreed];
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
            row[@"schedulerStatus"] = @(FDMSchedulerNeedsContext);
            row[@"speed"] = @0;
        }
        if ([row[@"state"] integerValue] == FDMStateCompleted || [row[@"state"] integerValue] == FDMStateFailed) [self archive:row];
        [self persist:nil];
        FDMNotifyRecordsChanged();
        // The attempt converged here, so the concurrency slot is genuinely free.
        [self markSlotFreed];
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
