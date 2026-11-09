#import "FDMEngine.h"
#import "FDMStore.h"
#import "FDMIntent.h"
#import "FDMVault.h"
#import "FDMJSON.h"
#import "FDMPolicy.h"

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
    NSMutableSet<NSString *> *_privateIDs;
    NSMutableDictionary<NSString *, NSNumber *> *_intentTimes;
    // Request context for queued intents. Never persisted: cookies and auth headers die with the
    // process, and a restored row without its request is reported as needsContext.
    NSMutableDictionary<NSString *, NSURLRequest *> *_requests;
    NSMutableDictionary<NSString *, NSURLSession *> *_credentialedSessions;
    NSMutableDictionary<NSString *, NSData *> *_memoryResume;
    NSMutableDictionary<NSString *, NSMutableDictionary *> *_webKitBindings;
    NSMutableDictionary<NSString *, NSString *> *_intentKeys;
    NSString *_path;
    BOOL _restoring;
    BOOL _writable;
    BOOL _eventsFinished;
    BOOL _backgroundBatchConsumed;
    NSTimeInterval _lastSave;
    NSUInteger _backgroundSaveRetries;
    NSUInteger _concurrencyLimit;
    BOOL _batchEnqueuing;
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
    _privateIDs = [NSMutableSet set];
    _intentTimes = [NSMutableDictionary dictionary];
    _requests = [NSMutableDictionary dictionary];
    _credentialedSessions = [NSMutableDictionary dictionary];
    _memoryResume = [NSMutableDictionary dictionary];
    _webKitBindings = [NSMutableDictionary dictionary];
    _intentKeys = [NSMutableDictionary dictionary];
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
        configuration.URLCredentialStorage = nil;
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
    if (!row[@"transport"]) row[@"transport"] = @(FDMTransportAnonymousBackground);
    if (!row[@"method"]) row[@"method"] = @"GET";
    if (!row[@"replayable"]) row[@"replayable"] = @([row[@"method"] isEqual:@"GET"]);
    if (!row[@"schedulerStatus"]) {
        NSInteger state = [row[@"state"] integerValue];
        row[@"schedulerStatus"] = @(state == FDMStateDownloading ? FDMSchedulerRunning :
            (state == FDMStatePaused ? FDMSchedulerUserPaused : FDMSchedulerNeedsContext));
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
    NSMutableArray *persistent = [NSMutableArray array];
    for (NSDictionary *row in _items) if (![row[@"privateContext"] boolValue]) [persistent addObject:row];
    BOOL ok = FDMWriteJSON(persistent, _path, error);
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

- (NSString *)resumeObjectID:(NSDictionary *)item {
    return [NSString stringWithFormat:@"resume-%@-%@-%@", item[@"key"], item[@"generation"] ?: @0, item[@"transport"] ?: @0];
}
- (NSData *)resumeData:(NSDictionary *)item {
    if ([item[@"resumeRejected"] boolValue] || [item[@"state"] integerValue] == FDMStateCompleted) return nil;
    if ([item[@"transport"] integerValue] == FDMTransportWebKitDownload) {
        // WK resume is accepted only while the originating WebView remains alive in its binding.
        NSDictionary *binding = _webKitBindings[item[@"key"]];
        if ([binding[@"contextInvalid"] boolValue] || [binding[@"resumeExpiresAt"] doubleValue] < NSDate.date.timeIntervalSince1970) return nil;
        return binding[@"resumeData"];
    }
    NSData *memory = _memoryResume[[self resumeObjectID:item]];
    if (memory.length) return memory;
    NSString *vault = FDMString(item[@"resumeVaultID"]);
    if (vault.length) {
        NSData *bytes = FDMVaultGet(vault, NULL);
        if (!bytes.length) return nil;
        id envelope = [NSPropertyListSerialization propertyListWithData:bytes
            options:NSPropertyListImmutable format:NULL error:NULL];
        if (![envelope isKindOfClass:NSDictionary.class] || ![envelope[@"taskID"] isEqual:item[@"key"]] ||
            ![envelope[@"attempt"] isEqual:item[@"generation"]] ||
            [envelope[@"transport"] integerValue] != [item[@"transport"] integerValue]) return nil;
        return [self isValidResume:envelope[@"data"]] ? envelope[@"data"] : nil;
    }
    // Read old v19 candidates in-place. Never move, delete or rewrite legacy resume data.
    NSDictionary *normalized = [item[@"schema"] isEqual:@2] ? item : [self normalizedRecord:item];
    NSString *relative = FDMString(normalized[@"resumeRelativePath"]) ?: FDMString(normalized[@"legacyResumeRelativePath"]);
    NSString *path = relative.length ? FDMResolveDocumentPath(@{@"relativePath": relative}) : nil;
    NSData *data = path.length ? [NSData dataWithContentsOfFile:path] : nil;
    return [self isValidResume:data] ? data : nil;
}
- (BOOL)saveResume:(NSData *)data item:(NSMutableDictionary *)item {
    if (![self isValidResume:data] || [_deleted containsObject:item[@"key"]] || [item[@"state"] integerValue] == FDMStateCompleted ||
        [item[@"transport"] integerValue] == FDMTransportWebKitDownload) return NO;
    NSString *objectID = [self resumeObjectID:item];
    if ([item[@"privateContext"] boolValue]) _memoryResume[objectID] = [data copy];
    else {
        NSDictionary *envelope = @{@"schema": @1, @"taskID": item[@"key"], @"attempt": item[@"generation"] ?: @0,
            @"transport": item[@"transport"] ?: @0, @"data": data};
        NSData *bytes = [NSPropertyListSerialization dataWithPropertyList:envelope
            format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
        NSError *error = nil;
        if (!FDMVaultPut(objectID, bytes, NSDate.date.timeIntervalSince1970 + 24 * 3600, &error)) {
            item[@"actionError"] = @"设备本地续传数据未能安全保存；请解锁后重试或重新发起";
            return NO;
        }
        item[@"resumeVaultID"] = objectID;
#ifdef FDM_TESTING
        // Existing regression inspects an explicit test-only plaintext candidate in its new root.
        // This branch is never compiled into the dylib and is not a platform-security claim.
        NSString *relative = [NSString stringWithFormat:@"FocusDM/resume/%@-%@.resume", FDMLegacyHash(item[@"key"]), item[@"generation"]];
        NSString *path = [FDMDirectory(@"FocusDM/resume") stringByAppendingPathComponent:relative.lastPathComponent];
        if (![data writeToFile:path options:NSDataWritingAtomic error:NULL]) return NO;
        item[@"resumeRelativePath"] = relative;
#endif
    }
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
    if ([row[@"transport"] integerValue] == FDMTransportWebKitDownload) return NO;
    return !row[@"replayable"] || [row[@"replayable"] boolValue];
}
- (NSUInteger)runningReplayableCount { return _tasks.count; }

// Starts queued GETs up to the limit. Only rows that never started are eligible, so a restored or
// finished attempt is never duplicated by a queue pump.
- (void)pumpScheduler {
    if (_restoring || _batchEnqueuing) return;
    NSUInteger running = [self runningReplayableCount];
    BOOL changed = NO;
    for (NSMutableDictionary *row in [[_items copy] reverseObjectEnumerator]) {
        if (running >= _concurrencyLimit) break;
        if ([_deleted containsObject:row[@"key"]]) continue;
        if ([row[@"schedulerStatus"] integerValue] != FDMSchedulerWaiting) continue;
        if ([row[@"state"] integerValue] != FDMStatePaused) continue;
        NSURLRequest *request = _requests[row[@"key"]];
        NSError *error = nil;
        if (![self startItem:row resume:[row[@"scheduledResume"] boolValue] request:request error:&error]) {
            row[@"actionError"] = error.localizedDescription;
            row[@"schedulerStatus"] = @(FDMSchedulerNeedsContext);
            row[@"waitReason"] = error.localizedDescription;
            changed = YES;
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
        if ([row[@"schedulerStatus"] integerValue] == FDMSchedulerWaiting &&
            [row[@"transport"] integerValue] != FDMTransportAnonymousBackground && !_requests[key]) {
            row[@"schedulerStatus"] = @(FDMSchedulerNeedsContext);
            row[@"waitReason"] = @"来源会话已关闭，请重新发起下载";
        }
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
    return [self enqueueURL:url name:name error:error];
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
    if ([row[@"transport"] integerValue] == FDMTransportWebKitDownload) {
        if (error) *error = FDMError(@"网页原请求需要通过原WebView继续，不能改为重新请求"); return NO;
    }
    if (!request) request = _requests[row[@"key"]];
    if (!request && FDMString(row[@"requestVaultID"]).length) {
        NSData *recipe = FDMVaultGet(row[@"requestVaultID"], NULL);
        if (recipe.length) {
            NSDictionary *object = [NSPropertyListSerialization propertyListWithData:recipe options:NSPropertyListImmutable format:NULL error:NULL];
            NSURL *savedURL = FDMValidatedURL(FDMString(object[@"url"]), NULL);
            if (savedURL) {
                NSMutableURLRequest *restored = [NSMutableURLRequest requestWithURL:savedURL];
                restored.HTTPMethod = @"GET";
                if ([object[@"headers"] isKindOfClass:NSDictionary.class]) restored.allHTTPHeaderFields = object[@"headers"];
                request = restored;
            }
        }
    }
    // Legacy v19 rows contain their real anonymous URL; keep the old candidate semantics.
    if (!request && !row[@"publicSchema"]) {
        NSURL *legacy = FDMValidatedURL(row[@"url"], NULL);
        if (legacy) request = [NSURLRequest requestWithURL:legacy];
    }
    NSData *data = resume ? [self resumeData:row] : nil;
    if (resume && !data.length) { if (error) *error = FDMError(@"没有有效的续传数据，请选择重新下载"); return NO; }
    if (!request && !data.length) { if (error) *error = FDMError(@"原请求上下文已失效；请返回来源页重新发起"); return NO; }
    FDMTransportKind route = row[@"transport"] ? [row[@"transport"] integerValue] : FDMTransportAnonymousBackground;
    NSURLSession *session = _session;
    if (route == FDMTransportCredentialedSession) {
        session = _credentialedSessions[row[@"key"]];
        if (!session) {
            NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
            configuration.HTTPShouldSetCookies = NO; configuration.HTTPCookieStorage = nil;
            configuration.URLCredentialStorage = nil; configuration.URLCache = nil;
            session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:_delegates];
            _credentialedSessions[row[@"key"]] = session;
        }
    }
    NSMutableDictionary *previous = [row mutableCopy];
    NSURLSessionDownloadTask *task = data ? [session downloadTaskWithResumeData:data] : [session downloadTaskWithRequest:request];
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
    [row removeObjectForKey:@"scheduledResume"];
    [row removeObjectForKey:@"error"];
    [row removeObjectForKey:@"actionError"];
    [row removeObjectForKey:@"resumeRequested"];
    if (!resume) { row[@"received"] = @0; row[@"total"] = @0; }
    [row removeObjectForKey:@"resumeVaultID"];
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
        [_credentialedSessions[key] invalidateAndCancel];
        [_credentialedSessions removeObjectForKey:key];
        [row removeAllObjects];
        [row addEntriesFromDictionary:previous];
        return NO;
    }
    [FDMStore.shared dropKey:row[@"key"] error:nil];
    [self dropLegacyAliasForRow:row];
    [task resume];
    FDMLog(@"engine start id=%@ attempt=%@ resumed=%d transport=%@", key, row[@"generation"], (int)resume,
           FDMTransportName([row[@"transport"] integerValue]));
    return YES;
}

#pragma mark - credentialed redirect boundary

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completionHandler {
    __block NSError *refusal = nil;
    [self sync:^{
        NSMutableDictionary *row = [self itemForTask:task];
        if (!row || [_deleted containsObject:row[@"key"]]) refusal = FDMError(@"下载已失效");
        else if ([row[@"transport"] integerValue] == FDMTransportCredentialedSession)
            refusal = FDMRedirectRefusal(task.originalRequest, request);
        if (refusal) row[@"error"] = refusal.localizedDescription;
    }];
    // Background sessions never call this method; only default/ephemeral can enforce it.
    completionHandler(refusal ? nil : request);
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
        return NO;
    }
    NSDictionary *identity = FDMFileIdentity(destination);
    if (!identity) {
        row[@"state"] = @(FDMStateFailed); row[@"error"] = @"文件成功接管但regular-file身份无法确认";
        [self commitTerminalRecord:row]; return NO;
    }
    row[@"state"] = @(FDMStateCompleted);
    row[@"schedulerStatus"] = @(FDMSchedulerRunning);
    row[@"pausing"] = @NO;
    row[@"pauseIntent"] = @NO;
    [row removeObjectForKey:@"resumeRequested"];
    row[@"path"] = destination;
    row[@"name"] = name;
    row[@"relativePath"] = FDMRelativeDocumentPath(destination);
    if (identity) row[@"fileIdentity"] = identity;
    row[@"size"] = identity[@"size"] ?: (row[@"received"] ?: @0);
    row[@"received"] = row[@"size"];
    row[@"completedAt"] = @(NSDate.date.timeIntervalSince1970);
    row[@"completionEvidence"] = evidence;
    row[@"speed"] = @0;
    [row removeObjectForKey:@"error"];
    [self commitTerminalRecord:row];
    return YES;
}

#pragma mark - WebKit downloads

- (NSString *)registerWebKitDownload:(id)download intent:(FDMDownloadIntent *)intent tabID:(NSString *)tabID {
    if (!download) return nil;
    NSURLRequest *request = FDMValue(download, @"originalRequest");
    __block NSString *key = nil;
    [self sync:^{
        // WK original navigation is already in flight; a GET queue restore barrier must not stall it.
        if (!_writable) return;
        if (intent && _intentKeys[intent.intentID]) { key = _intentKeys[intent.intentID]; return; }
        key = NSUUID.UUID.UUIDString;
        NSMutableDictionary *row = [@{@"schema": @2, @"publicSchema": @1, @"key": key,
            @"url": FDMDownloadPublicURL(request.URL), @"name": FDMSafeFilename(intent.suggestedFilename ?: request.URL.lastPathComponent),
            @"generation": @1, @"state": @(FDMStateDownloading), @"schedulerStatus": @(FDMSchedulerRunning),
            @"transport": @(FDMTransportWebKitDownload), @"replayable": @NO,
            @"method": (request.HTTPMethod ?: @"GET").uppercaseString, @"source": @0,
            @"received": @0, @"total": @0, @"speed": @0, @"time": @(NSDate.date.timeIntervalSince1970),
            @"sourceOrigin": intent.sourceOrigin ?: @"", @"targetOrigin": FDMOriginForURL(request.URL) ?: @"",
            @"tabID": tabID ?: intent.tabID ?: @"", @"privateContext": @(!intent.persistentContext)} mutableCopy];
        if (intent) row[@"intentID"] = intent.intentID;
        if ([row[@"privateContext"] boolValue]) [_privateIDs addObject:key];
        [_items insertObject:row atIndex:0];
        if (![self persist:NULL]) { [_items removeObject:row]; key = nil; return; }
        if (intent) [self rememberIntent:intent.intentID key:key];
    }];
    if (key) FDMNotifyRecordsChanged();
    return key;
}
- (void)bindWebKitKey:(NSString *)key transportIdentity:(NSString *)identity
    cancel:(void (^)(void (^)(NSData *)))cancel resume:(void (^)(NSData *, NSString *, void (^)(BOOL)))resume {
    [self sync:^{
        NSMutableDictionary *row = [self item:key];
        if (!row || [_deleted containsObject:key]) return;
        NSMutableDictionary *old = _webKitBindings[key];
        NSMutableDictionary *binding = [@{@"identity": identity, @"cancel": [cancel copy], @"resume": [resume copy]} mutableCopy];
        if (old[@"contextInvalid"]) binding[@"contextInvalid"] = @YES;
        _webKitBindings[key] = binding;
        row[@"transportIdentity"] = identity;
    }];
}
- (NSMutableDictionary *)webKitItem:(NSString *)key identity:(NSString *)identity {
    NSMutableDictionary *row = [self item:key];
    if (!row || [_deleted containsObject:key] || [row[@"transport"] integerValue] != FDMTransportWebKitDownload ||
        ![row[@"transportIdentity"] isEqual:identity]) return nil;
    return row;
}
- (NSString *)destinationForWebKitDownloadKey:(NSString *)key transportIdentity:(NSString *)identity
    suggestedFilename:(NSString *)filename response:(NSURLResponse *)response {
    __block NSString *destination = nil;
    [self sync:^{
        NSMutableDictionary *row = [self webKitItem:key identity:identity]; if (!row) return;
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (id)response : nil;
        if (http && (http.statusCode < 200 || http.statusCode >= 300)) {
            row[@"error"] = [NSString stringWithFormat:@"HTTP %ld：不是成功下载响应", (long)http.statusCode]; return;
        }
        NSString *directory = FDMDirectory([@"FocusDM/downloads" stringByAppendingPathComponent:FDMLegacyHash(key)]);
        NSString *name = FDMSafeFilename(filename.length ? filename : (response.suggestedFilename ?: row[@"name"]));
        // Attempt-specific exclusive pathname; no file or existing sibling is overwritten.
        NSString *candidate = [directory stringByAppendingPathComponent:name];
        if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
            NSString *ext = name.pathExtension;
            candidate = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@%@%@",
                name.stringByDeletingPathExtension, NSUUID.UUID.UUIDString, ext.length ? @"." : @"", ext]];
        }
        if (!FDMRelativeDocumentPath(candidate) || [[NSFileManager defaultManager] fileExistsAtPath:candidate]) return;
        row[@"path"] = candidate; row[@"relativePath"] = FDMRelativeDocumentPath(candidate); row[@"name"] = name;
        row[@"responseAccepted"] = @YES;
        row[@"responseHTTP"] = @(http != nil);
        row[@"total"] = @(MAX(0, response.expectedContentLength));
        if (![self persist:NULL]) return;
        destination = candidate;
    }];
    return destination;
}
- (void)applyWebKitProgressKey:(NSString *)key transportIdentity:(NSString *)identity received:(long long)received total:(long long)total {
    [self sync:^{ NSMutableDictionary *row = [self webKitItem:key identity:identity];
        if (!row || [row[@"state"] integerValue] != FDMStateDownloading || [row[@"pausing"] boolValue]) return;
        row[@"received"] = @(MAX(0, received)); row[@"total"] = @(MAX(0, total));
        FDMNotifyRecordsChanged(); }];
}
- (void)webKitDownloadDidFinishKey:(NSString *)key transportIdentity:(NSString *)identity {
    [self sync:^{
        NSMutableDictionary *row = [self webKitItem:key identity:identity];
        if (!row) { [_webKitBindings removeObjectForKey:key]; return; }
        NSDictionary *file = FDMFileIdentity(FDMResolveDocumentPath(row));
        if (!file || ![row[@"responseAccepted"] boolValue]) {
            row[@"state"] = @(FDMStateFailed); row[@"schedulerStatus"] = @(FDMSchedulerNeedsContext);
            row[@"error"] = @"网页下载已结束，但响应或保存文件无法确认";
        } else {
            row[@"state"] = @(FDMStateCompleted); row[@"pausing"] = @NO; row[@"pauseIntent"] = @NO;
            row[@"fileIdentity"] = file; row[@"size"] = file[@"size"]; row[@"received"] = file[@"size"];
            row[@"completedAt"] = @(NSDate.date.timeIntervalSince1970);
            row[@"completionEvidence"] = @"webkit-finish-and-file-confirmed";
            [row removeObjectForKey:@"error"]; [row removeObjectForKey:@"resumeRequested"];
        }
        row[@"speed"] = @0;
        [_webKitBindings removeObjectForKey:key];
        [self archive:row]; [self persist:NULL]; FDMNotifyRecordsChanged();
    }];
}
- (void)settleWebKitPause:(NSString *)key identity:(NSString *)identity {
    NSMutableDictionary *row = [self webKitItem:key identity:identity];
    NSMutableDictionary *binding = _webKitBindings[key];
    if (!row || ![binding[@"cancelSeen"] boolValue]) return;
    // WK cancel completion is the public convergence signal; a didFail callback is not guaranteed.
    row[@"state"] = @(FDMStatePaused); row[@"schedulerStatus"] = @(FDMSchedulerUserPaused);
    row[@"pausing"] = @NO; row[@"speed"] = @0;
    row[@"waitReason"] = binding[@"resumeData"] && ![binding[@"contextInvalid"] boolValue]
        ? @"可尝试在原标签页断点继续；应用退出后需重新发起" : @"原页面或续传数据不可用；请重新发起";
    BOOL requested = [row[@"resumeRequested"] boolValue]; [row removeObjectForKey:@"resumeRequested"];
    [self persist:NULL]; FDMNotifyRecordsChanged();
    if (requested) [self resumeWebKitItem:row];
}
- (void)webKitDownloadKey:(NSString *)key transportIdentity:(NSString *)identity failedWithMessage:(NSString *)message resumeData:(NSData *)data {
    [self sync:^{
        NSMutableDictionary *row = [self webKitItem:key identity:identity];
        NSMutableDictionary *binding = _webKitBindings[key];
        if (!row) { if ([_deleted containsObject:key]) [_webKitBindings removeObjectForKey:key]; return; }
        if ([row[@"state"] integerValue] == FDMStateCompleted) return;
        if (data.length && ![binding[@"contextInvalid"] boolValue]) {
            binding[@"resumeData"] = [data copy]; binding[@"resumeExpiresAt"] = @(NSDate.date.timeIntervalSince1970 + 24 * 3600);
        }
        if ([row[@"pauseIntent"] boolValue]) { binding[@"failureSeen"] = @YES; [self settleWebKitPause:key identity:identity]; return; }
        row[@"error"] = message.length ? message : @"网页下载失败"; row[@"speed"] = @0;
        row[@"state"] = @(binding[@"resumeData"] ? FDMStateInterrupted : FDMStateFailed);
        row[@"schedulerStatus"] = @(FDMSchedulerNeedsContext);
        if ([row[@"state"] integerValue] == FDMStateFailed) [self archive:row];
        [self persist:NULL]; FDMNotifyRecordsChanged();
    }];
}
- (void)pauseWebKitItem:(NSMutableDictionary *)row {
    if (!row || [row[@"state"] integerValue] != FDMStateDownloading || [row[@"pausing"] boolValue]) return;
    NSString *key = row[@"key"]; NSMutableDictionary *binding = _webKitBindings[key];
    if (!binding[@"cancel"]) { row[@"actionError"] = @"原网页下载对象已经失效"; return; }
    row[@"pauseIntent"] = @YES; row[@"pausing"] = @YES;
    if (![self persist:NULL]) { row[@"pauseIntent"] = @NO; row[@"pausing"] = @NO; return; }
    NSString *identity = binding[@"identity"];
    void (^cancel)(void (^)(NSData *)) = binding[@"cancel"];
    cancel(^(NSData *data) { dispatch_async(_queue, ^{
        NSMutableDictionary *current = [self webKitItem:key identity:identity]; if (!current) return;
        NSMutableDictionary *active = _webKitBindings[key]; active[@"cancelSeen"] = @YES;
        if (data.length && ![active[@"contextInvalid"] boolValue]) {
            active[@"resumeData"] = [data copy]; active[@"resumeExpiresAt"] = @(NSDate.date.timeIntervalSince1970 + 24 * 3600);
        }
        [self settleWebKitPause:key identity:identity];
    }); });
}
- (void)resumeWebKitItem:(NSMutableDictionary *)row {
    NSString *key = row[@"key"]; NSMutableDictionary *binding = _webKitBindings[key];
    NSData *data = [self resumeData:row];
    if (!data.length || !binding[@"resume"] || [binding[@"contextInvalid"] boolValue]) {
        row[@"actionError"] = @"原WebView已关闭或续传数据不可用；请重新发起"; FDMNotifyRecordsChanged(); return;
    }
    NSString *identity = NSUUID.UUID.UUIDString;
    row[@"generation"] = @([row[@"generation"] unsignedLongLongValue] + 1);
    row[@"transportIdentity"] = identity; binding[@"identity"] = identity;
    row[@"state"] = @(FDMStateDownloading); row[@"schedulerStatus"] = @(FDMSchedulerRunning);
    row[@"pauseIntent"] = @NO; row[@"pausing"] = @NO;
    [row removeObjectForKey:@"error"]; [row removeObjectForKey:@"actionError"];
    [binding removeObjectForKey:@"resumeData"]; [binding removeObjectForKey:@"cancelSeen"];
    if (![self persist:NULL]) { row[@"state"] = @(FDMStatePaused); binding[@"resumeData"] = data; return; }
    void (^resume)(NSData *, NSString *, void (^)(BOOL)) = binding[@"resume"];
    resume(data, identity, ^(BOOL success) { if (!success) [self webKitDownloadKey:key transportIdentity:identity failedWithMessage:@"原页面无法继续此下载" resumeData:nil]; });
    FDMNotifyRecordsChanged();
}
- (void)invalidateWebKitContextForTabID:(NSString *)tabID {
    dispatch_async(_queue, ^{ for (NSMutableDictionary *row in _items) {
        if (![row[@"tabID"] isEqual:tabID] || [row[@"transport"] integerValue] != FDMTransportWebKitDownload) continue;
        NSMutableDictionary *binding = _webKitBindings[row[@"key"]]; binding[@"contextInvalid"] = @YES;
        [binding removeObjectForKey:@"resumeData"];
        if ([row[@"state"] integerValue] != FDMStateDownloading) [_webKitBindings removeObjectForKey:row[@"key"]];
        if ([row[@"privateContext"] boolValue] && binding[@"cancel"]) { void (^cancel)(void (^)(NSData *)) = binding[@"cancel"]; cancel(^(NSData *data) {}); }
    } });
}

#pragma mark - intent entry points

- (NSString *)enqueueURL:(NSString *)url name:(NSString *)name error:(NSError **)error {
    NSURL *address = FDMValidatedURL(url, error);
    if (!address) return nil;
    NSURLRequest *request = [NSURLRequest requestWithURL:address];
    FDMTransportKind route = FDMRequestCanUseAnonymousBackground(request) ? FDMTransportAnonymousBackground : FDMTransportCredentialedSession;
    FDMDownloadIntent *intent = [[FDMDownloadIntent alloc] initWithRequest:request tabID:@"manual" generation:0
        sourceOrigin:FDMOriginForURL(address) transport:route dataStore:nil userInitiated:YES policyRevision:0];
    return [self enqueueIntent:intent request:request name:name error:error];
}
- (void)rememberIntent:(NSString *)intentID key:(NSString *)key {
    if (!intentID.length) return;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    _intentKeys[intentID] = key; _intentTimes[intentID] = @(now);
    for (NSString *old in [_intentTimes.allKeys copy]) {
        if (now - [_intentTimes[old] doubleValue] > 1800) { [_intentKeys removeObjectForKey:old]; [_intentTimes removeObjectForKey:old]; }
    }
    if (_intentTimes.count > 4096) {
        NSArray *ordered = [_intentTimes.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) { return [_intentTimes[a] compare:_intentTimes[b]]; }];
        for (NSString *old in ordered) {
            if ([self item:_intentKeys[old]]) continue;
            [_intentKeys removeObjectForKey:old]; [_intentTimes removeObjectForKey:old];
            if (_intentTimes.count <= 4096) break;
        }
    }
}
- (NSString *)enqueueIntent:(FDMDownloadIntent *)intent request:(NSURLRequest *)request name:(NSString *)name error:(NSError **)error {
    if (!intent || !request || !intent.replayable || intent.transport == FDMTransportWebKitDownload ||
        NSDate.date.timeIntervalSince1970 - intent.captureTime > 1800) {
        if (error) *error = FDMError(@"该下载必须保留原导航，不能改为重新请求"); return nil;
    }
    if (![intent.method isEqual:(request.HTTPMethod ?: @"GET").uppercaseString] ||
        ![intent.targetOrigin isEqual:FDMOriginForURL(request.URL)]) {
        if (error) *error = FDMError(@"下载意图和请求身份不匹配"); return nil;
    }
    __block NSString *key = nil; __block NSError *failure = nil;
    [self sync:^{
        if (_restoring || !_writable) { failure = FDMError(@"下载记录正在恢复或不可写，请稍后重试"); return; }
        NSString *existing = _intentKeys[intent.intentID];
        if (existing) { key = existing; return; }
        if (_items.count >= FDMQueueLimit) { failure = FDMError(@"任务队列上限为500，请先处理已有任务"); return; }
        key = NSUUID.UUID.UUIDString;
        NSString *safeName = name.length ? name : (intent.suggestedFilename ?: request.URL.lastPathComponent);
        NSMutableDictionary *row = [@{@"schema": @2, @"publicSchema": @1, @"key": key,
            @"url": intent.url, @"name": FDMSafeFilename(safeName), @"generation": @0,
            @"state": @(FDMStatePaused), @"schedulerStatus": @(FDMSchedulerWaiting),
            @"transport": @(!intent.persistentContext ? FDMTransportCredentialedSession : intent.transport), @"replayable": @YES, @"intentID": intent.intentID,
            @"method": intent.method, @"sourceOrigin": intent.sourceOrigin ?: @"", @"targetOrigin": intent.targetOrigin ?: @"",
            @"privateContext": @(!intent.persistentContext), @"source": @0, @"received": @0, @"total": @0,
            @"speed": @0, @"time": @(NSDate.date.timeIntervalSince1970)} mutableCopy];
        _requests[key] = [request copy];
        if (intent.transport == FDMTransportAnonymousBackground && intent.persistentContext) {
            NSString *objectID = [@"request-" stringByAppendingString:key];
            NSData *recipe = [NSPropertyListSerialization dataWithPropertyList:@{@"schema": @1,
                @"url": request.URL.absoluteString, @"headers": request.allHTTPHeaderFields ?: @{}}
                format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
            if (!FDMVaultPut(objectID, recipe, NSDate.date.timeIntervalSince1970 + 24 * 3600, &failure)) { [_requests removeObjectForKey:key]; key = nil; return; }
            row[@"requestVaultID"] = objectID;
        }
        if ([row[@"privateContext"] boolValue]) [_privateIDs addObject:key];
        [_items insertObject:row atIndex:0];
        if (!_batchEnqueuing && ![self persist:&failure]) { [_items removeObject:row]; [_requests removeObjectForKey:key]; key = nil; return; }
        [self rememberIntent:intent.intentID key:key];
        [self pumpScheduler];
    }];
    if (failure && error) *error = failure;
    if (key) FDMNotifyRecordsChanged();
    return key;
}
- (BOOL)enqueueURLs:(NSArray<NSString *> *)urls error:(NSError **)error {
    if (![urls isKindOfClass:NSArray.class] || !urls.count || urls.count > FDMBatchPreviewLimit) {
        if (error) *error = FDMError(@"一次批量必须包含1至100个直链"); return NO;
    }
    for (id url in urls) if (![url isKindOfClass:NSString.class] || !FDMValidatedURL(url, error)) return NO;
    __block BOOL ok = YES; __block NSError *failure = nil;
    [self sync:^{
        if (_restoring || !_writable || _items.count + urls.count > FDMQueueLimit) {
            failure = FDMError(@"正在恢复任务、存储不可写或队列超出500上限，未加入任何任务"); ok = NO; return;
        }
        NSArray *before = [_items copy]; NSDictionary *beforeRequests = [_requests copy]; NSDictionary *beforeIntents = [_intentKeys copy];
        _batchEnqueuing = YES;
        for (NSString *url in urls) if (![self enqueueURL:url name:nil error:&failure]) { ok = NO; break; }
        _batchEnqueuing = NO;
        if (ok && ![self persist:&failure]) ok = NO;
        if (!ok) {
            _items = [before mutableCopy]; _requests = [beforeRequests mutableCopy]; _intentKeys = [beforeIntents mutableCopy];
            [self persist:NULL];
        } else [self pumpScheduler];
    }];
    if (!ok && error) *error = failure; return ok;
}
- (NSString *)startIntent:(FDMDownloadIntent *)intent request:(NSURLRequest *)request error:(NSError **)error {
    return [self enqueueIntent:intent request:request name:nil error:error];
}


- (void)beginPause:(NSString *)key {
    NSMutableDictionary *row = [self item:key];
    key = row[@"key"] ?: key;
    if ([row[@"transport"] integerValue] == FDMTransportWebKitDownload) {
        [self pauseWebKitItem:row]; return;
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
    if ([row[@"state"] integerValue] != FDMStateCompleted) row[@"schedulerStatus"] = @(FDMSchedulerUserPaused);
    if (requested && [row[@"state"] integerValue] != FDMStateCompleted) {
        if ([self resumeData:row].length) {
            row[@"state"] = @(FDMStatePaused); row[@"schedulerStatus"] = @(FDMSchedulerWaiting); row[@"scheduledResume"] = @YES;
        } else row[@"actionError"] = @"没有有效的续传数据，请选择重新下载";
    }
    if ([row[@"state"] integerValue] == FDMStateCompleted) [self archive:row];
    [self persist:nil];
    FDMNotifyRecordsChanged();
    [self markSlotFreed];
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
        if (_restoring) return;
        NSMutableDictionary *row = [self restoreArchivedItem:key]; if (!row) return;
        if ([row[@"pausing"] boolValue]) { row[@"resumeRequested"] = @YES; [self persist:nil]; return; }
        if (_tasks[row[@"key"]]) return;
        if ([row[@"transport"] integerValue] == FDMTransportWebKitDownload) {
            [self resumeWebKitItem:row]; return;
        }
        if (![self resumeData:row].length) row[@"actionError"] = @"没有有效的续传数据，请选择重新下载";
        else { row[@"state"] = @(FDMStatePaused); row[@"schedulerStatus"] = @(FDMSchedulerWaiting); row[@"scheduledResume"] = @YES; }
        [self persist:nil]; [self pumpScheduler]; FDMNotifyRecordsChanged();
    });
}
- (void)restartKey:(NSString *)key {
    dispatch_async(_queue, ^{
        if (_restoring) return;
        NSMutableDictionary *row = [self restoreArchivedItem:key];
        if (!row || _tasks[row[@"key"]] || [row[@"pausing"] boolValue]) return;
        if (![self isReplayableRow:row]) { row[@"actionError"] = @"原导航无法重放；请回到来源页重新发起"; }
        else { row[@"state"] = @(FDMStatePaused); row[@"schedulerStatus"] = @(FDMSchedulerWaiting); row[@"scheduledResume"] = @NO; }
        [self persist:nil]; [self pumpScheduler]; FDMNotifyRecordsChanged();
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
            NSMutableSet *durableDeleted = [self->_deleted mutableCopy];
            for (NSDictionary *privateRow in self->_items) if ([privateRow[@"privateContext"] boolValue]) [durableDeleted removeObject:privateRow[@"key"]];
            if (![row[@"privateContext"] boolValue]) [durableDeleted unionSet:next];
            [durableDeleted minusSet:_privateIDs];
            if (![row[@"privateContext"] boolValue] && !FDMWriteJSON(durableDeleted.allObjects, [self deletionPath], &journalError)) {
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
                NSMutableDictionary *webKit = self->_webKitBindings[canonical];
                if (webKit[@"cancel"]) {
                    void (^cancel)(void (^)(NSData *)) = webKit[@"cancel"];
                    cancel(^(NSData *data) {});
                }
                [self->_requests removeObjectForKey:canonical];
                [self->_memoryResume removeObjectForKey:[self resumeObjectID:row ?: record]];
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
    if ([row[@"privateContext"] boolValue]) return YES;
    NSMutableDictionary *record = [row mutableCopy];
    NSURL *rawURL = [NSURL URLWithString:FDMString(record[@"url"]) ?: @""];
    if (rawURL.host.length) record[@"url"] = FDMDownloadPublicURL(rawURL);
    record[@"publicSchema"] = @1;
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
    if ([row[@"privateContext"] boolValue]) {
        [_memoryResume removeObjectForKey:[self resumeObjectID:row]];
        if ([row[@"state"] integerValue] == FDMStateCompleted) [_requests removeObjectForKey:row[@"key"]];
        FDMNotifyRecordsChanged(); return;
    }
    if ([self commitTerminalRecord:row]) {
        [self dropLegacyAliasForRow:row];
        if ([row[@"state"] integerValue] == FDMStateCompleted) [_requests removeObjectForKey:row[@"key"]];
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
        NSString *mime = response.MIMEType.lowercaseString;
        NSString *extension = [row[@"name"] pathExtension].lowercaseString;
        if (([mime isEqual:@"text/html"] || [mime isEqual:@"application/xhtml+xml"]) &&
            ![@[@"html", @"htm", @"xhtml"] containsObject:extension]) {
            row[@"state"] = @(FDMStateFailed); row[@"error"] = @"收到登录或网页响应，而不是所请求的文件；请返回网页重新发起";
            [self persist:NULL]; return;
        }
        [self acceptDownloadedFile:location row:row response:response evidence:@"http-success-and-file-moved"];
        [self persist:nil];
        FDMNotifyRecordsChanged();
    }];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    [self sync:^{
        NSMutableDictionary *row = [self itemForTask:task];
        if (!row) {
            for (NSString *key in [_tasks.allKeys copy]) {
                NSURLSessionTask *bound = _tasks[key];
                if (bound.taskIdentifier == task.taskIdentifier && [bound.taskDescription isEqual:task.taskDescription]) {
                    [_tasks removeObjectForKey:key]; [_credentialedSessions[key] finishTasksAndInvalidate];
                    [_credentialedSessions removeObjectForKey:key];
                }
            }
            [self markSlotFreed]; return;
        }
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
        [self->_credentialedSessions[key] finishTasksAndInvalidate];
        [self->_credentialedSessions removeObjectForKey:key];
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
