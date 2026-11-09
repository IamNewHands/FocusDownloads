// Post-implementation Foundation regressions for the real FDMEngine owner.
// No NSURLSession is created: fake transport objects only deliver explicit events.
// Compile with -DFDM_TESTING=1, FDMCommon.m, FDMStore.m and FDMEngine.m.
// The parent runner calls FDMRunEngineRegression() on the main thread, before
// any other suite initializes FDMStore.shared. Fixtures use a new temporary root.
#import <Foundation/Foundation.h>
#import "FDMEngine.h"
#import "FDMStore.h"
#import "FDMIntent.h"
#import <stdio.h>
#import <stdlib.h>

#ifndef FDM_TESTING
#error engine_regression.m requires FDM_TESTING
#endif

static NSString *FDMERoot;
static NSString *FDMECase;
static NSUInteger FDMECases;

static void FDMECheck(BOOL condition, NSString *message) {
    if (condition) return;
    fprintf(stderr, "ENGINE REGRESSION FAILED [%s]: %s\n", FDMECase.UTF8String ?: "setup", message.UTF8String);
    abort();
}

@interface FDMEFakeTask : NSObject
@property (nonatomic, copy) NSString *taskDescription;
@property (nonatomic) NSUInteger taskIdentifier;
@property (nonatomic) NSURLSessionTaskState state;
@property (nonatomic, strong) NSURLResponse *response;
@property (nonatomic) int64_t countOfBytesReceived;
@property (nonatomic, strong) NSURL *requestedURL;
@property (nonatomic, copy) NSURLRequest *requestedRequest;
@property (nonatomic, copy) NSData *resumeDataUsed;
@property (nonatomic, copy) void (^pauseCompletion)(NSData *);
@property (nonatomic) NSUInteger resumeCalls;
@property (nonatomic) NSUInteger cancelCalls;
@property (nonatomic) NSUInteger pauseCalls;
- (void)resume;
- (void)cancel;
- (void)cancelByProducingResumeData:(void (^)(NSData *))completion;
- (void)deliverPauseData:(NSData *)data;
@end

@implementation FDMEFakeTask
- (instancetype)init {
    if ((self = [super init])) _state = NSURLSessionTaskStateSuspended;
    return self;
}
- (BOOL)isKindOfClass:(Class)cls {
    return cls == NSURLSessionDownloadTask.class || cls == NSURLSessionTask.class || [super isKindOfClass:cls];
}
- (void)resume { self.resumeCalls++; self.state = NSURLSessionTaskStateRunning; }
- (void)cancel { self.cancelCalls++; self.state = NSURLSessionTaskStateCanceling; }
- (void)cancelByProducingResumeData:(void (^)(NSData *))completion {
    FDMECheck(!self.pauseCompletion, @"a task must not receive two outstanding pause requests");
    self.pauseCalls++;
    self.state = NSURLSessionTaskStateCanceling;
    self.pauseCompletion = completion;
}
- (void)deliverPauseData:(NSData *)data {
    void (^callback)(NSData *) = self.pauseCompletion;
    self.pauseCompletion = nil;
    FDMECheck(callback != nil, @"expected a captured pause completion");
    callback(data);
}
@end

@interface FDMEFakeSession : NSObject
@property (nonatomic, weak) id<NSURLSessionDownloadDelegate> delegate;
@property (nonatomic, strong) NSOperationQueue *delegateQueue;
@property (nonatomic, copy) NSArray<FDMEFakeTask *> *enumerationSnapshot;
@property (nonatomic, copy) void (^enumerationCompletion)(NSArray<__kindof NSURLSessionTask *> *);
@property (nonatomic, strong) NSMutableArray<FDMEFakeTask *> *created;
@property (nonatomic) NSUInteger nextIdentifier;
- (void)getAllTasksWithCompletionHandler:(void (^)(NSArray<__kindof NSURLSessionTask *> *))completion;
- (NSURLSessionDownloadTask *)downloadTaskWithURL:(NSURL *)url;
- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request;
- (NSURLSessionDownloadTask *)downloadTaskWithResumeData:(NSData *)data;
- (void)replyEnumeration;
- (void)completeTask:(FDMEFakeTask *)task error:(NSError *)error;
- (void)finishTask:(FDMEFakeTask *)task status:(NSInteger)status temporaryURL:(NSURL *)url;
- (void)writeTask:(FDMEFakeTask *)task received:(int64_t)received total:(int64_t)total;
- (void)abandonForSimulatedExit;
@end

@implementation FDMEFakeSession
- (instancetype)init {
    if ((self = [super init])) {
        _created = [NSMutableArray array];
        _enumerationSnapshot = @[];
        _nextIdentifier = 1000;
    }
    return self;
}
- (void)getAllTasksWithCompletionHandler:(void (^)(NSArray<__kindof NSURLSessionTask *> *))completion {
    FDMECheck(!self.enumerationCompletion, @"enumeration must be replied exactly once");
    self.enumerationCompletion = completion;
}
- (FDMEFakeTask *)makeTask {
    FDMEFakeTask *task = [[FDMEFakeTask alloc] init];
    task.taskIdentifier = ++self.nextIdentifier;
    [self.created addObject:task];
    return task;
}
- (NSURLSessionDownloadTask *)downloadTaskWithURL:(NSURL *)url {
    return [self downloadTaskWithRequest:[NSURLRequest requestWithURL:url]];
}
- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request {
    FDMEFakeTask *task = [self makeTask];
    task.requestedURL = request.URL;
    task.requestedRequest = [request copy];
    return (NSURLSessionDownloadTask *)(id)task;
}
- (NSURLSessionDownloadTask *)downloadTaskWithResumeData:(NSData *)data {
    FDMECheck(data.length > 0, @"the resume API must receive bytes");
    FDMEFakeTask *task = [self makeTask];
    task.resumeDataUsed = data;
    return (NSURLSessionDownloadTask *)(id)task;
}
- (void)replyEnumeration {
    void (^callback)(NSArray<__kindof NSURLSessionTask *> *) = self.enumerationCompletion;
    self.enumerationCompletion = nil;
    FDMECheck(callback != nil, @"expected a delayed system enumeration");
    for (FDMEFakeTask *task in self.enumerationSnapshot) self.nextIdentifier = MAX(self.nextIdentifier, task.taskIdentifier);
    callback((NSArray<__kindof NSURLSessionTask *> *)(id)self.enumerationSnapshot);
}
- (void)completeTask:(FDMEFakeTask *)task error:(NSError *)error {
    FDMECheck(self.delegate != nil, @"simulated exited sessions cannot deliver new events");
    task.state = NSURLSessionTaskStateCompleted;
    [self.delegate URLSession:(NSURLSession *)(id)self task:(NSURLSessionTask *)(id)task didCompleteWithError:error];
}
- (void)finishTask:(FDMEFakeTask *)task status:(NSInteger)status temporaryURL:(NSURL *)url {
    FDMECheck(self.delegate != nil, @"a finish event needs a live owner");
    task.response = [[NSHTTPURLResponse alloc] initWithURL:task.requestedURL ?: [NSURL URLWithString:@"https://fixture.invalid/payload.bin"]
        statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Disposition": @"attachment; filename=\"payload.bin\""}];
    NSData *bytes = [NSData dataWithContentsOfURL:url];
    FDMECheck(bytes != nil, @"the temporary download fixture must exist");
    task.countOfBytesReceived = (int64_t)bytes.length;
    [self.delegate URLSession:(NSURLSession *)(id)self downloadTask:(NSURLSessionDownloadTask *)(id)task didFinishDownloadingToURL:url];
}
- (void)writeTask:(FDMEFakeTask *)task received:(int64_t)received total:(int64_t)total {
    task.countOfBytesReceived = received;
    [self.delegate URLSession:(NSURLSession *)(id)self downloadTask:(NSURLSessionDownloadTask *)(id)task
        didWriteData:received totalBytesWritten:received totalBytesExpectedToWrite:total];
}
- (void)abandonForSimulatedExit {
    // Drop in-process closures without invoking them; the recreated owner only
    // receives the system task snapshot and disk state, just as after an exit.
    for (FDMEFakeTask *task in self.created) task.pauseCompletion = nil;
    for (FDMEFakeTask *task in self.enumerationSnapshot) task.pauseCompletion = nil;
    self.enumerationCompletion = nil;
    self.delegate = nil;
}
@end

static FDMEngine *FDMENewEngine(FDMEFakeSession *session, BOOL reply) {
    FDMEngine *engine = [[FDMEngine alloc] initForTestingWithSessionFactory:^NSURLSession *(id<NSURLSessionDelegate> delegate, NSOperationQueue *queue) {
        session.delegate = (id<NSURLSessionDownloadDelegate>)delegate;
        session.delegateQueue = queue;
        return (NSURLSession *)(id)session;
    }];
    FDMECheck(engine.restoring, @"new owners start behind the restoration barrier");
    if (reply) { [session replyEnumeration]; [engine drainForTesting]; FDMECheck(!engine.restoring, @"restoration must settle after enumeration"); }
    return engine;
}

static void FDMEFlushMain(void) {
    FDMECheck(NSThread.isMainThread, @"the regression runner must run on main");
    __block BOOL marker = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ marker = YES; });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (!marker && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    FDMECheck(marker, @"bounded main queue flush timed out");
}

static NSString *FDMEDataPath(NSString *name) { return [FDMDirectory(@"FocusDM") stringByAppendingPathComponent:name]; }

static void FDMEWriteJSON(id data, NSString *name) {
    NSError *error = nil;
    FDMECheck(FDMWriteJSON(data, FDMEDataPath(name), &error), [NSString stringWithFormat:@"fixture JSON write failed: %@", error]);
}

static void FDMEBeginCase(NSString *name) {
    FDMECase = name;
    FDMECheck([FDMDocumentsPath() isEqual:FDMERoot], @"test documents must remain inside this suite's new root");
    FDMStore *store = FDMStore.shared;
    NSString *storePath = FDMString(FDMValue(store, @"path"));
    FDMECheck([storePath isEqual:FDMEDataPath(@"history.json")], @"FDMStore.shared was initialized before this suite; refusing to touch its records");
    for (NSDictionary *record in store.records) {
        NSError *error = nil;
        FDMECheck([store dropKey:record[@"key"] error:&error], [NSString stringWithFormat:@"fixture history reset failed: %@", error]);
    }
    // Only these two files in the freshly allocated suite root are reset.
    // Final/resume fixtures are deliberately retained, including older attempts.
    FDMEWriteJSON(@[], @"tasks.json");
    FDMEWriteJSON(@[], @"deleted-task-ids.json");
}

static NSString *FDMEURL(void) { return [NSString stringWithFormat:@"https://fixture.invalid/%@/payload.bin", FDMECase]; }

static NSData *FDMEResume(NSString *marker) {
    NSError *error = nil;
    NSDictionary *plist = @{@"NSURLSessionResumeInfoVersion": @2, @"NSURLSessionResumeInfoURL": FDMEURL(),
        @"NSURLSessionResumeBytesReceived": @4096, @"regression-marker": marker};
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    FDMECheck(data != nil, [NSString stringWithFormat:@"resume fixture encoding failed: %@", error]);
    // This is a deterministic transport fixture, not proof Apple accepts these bytes.
    return data;
}

static NSError *FDMECancelled(NSData *data) {
    return [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled
        userInfo:data.length ? @{NSURLSessionDownloadTaskResumeData: data} : @{}];
}

static NSDictionary *FDMEItem(FDMEngine *engine, NSString *key) {
    for (NSDictionary *item in engine.items) if ([item[@"key"] isEqual:key] || [item[@"legacyKey"] isEqual:key]) return item;
    return nil;
}

static NSDictionary *FDMEDiskItem(NSString *key) {
    id root = FDMReadJSON(FDMEDataPath(@"tasks.json"), nil);
    FDMECheck([root isKindOfClass:NSArray.class], @"tasks fixture remains an array");
    for (NSDictionary *row in root) if ([row[@"key"] isEqual:key] || [row[@"legacyKey"] isEqual:key]) return row;
    return nil;
}

static NSString *FDMEResumePath(NSDictionary *record) {
    NSString *relative = FDMString(record[@"resumeRelativePath"]) ?: FDMString(record[@"legacyResumeRelativePath"]);
    return relative.length ? FDMResolveDocumentPath(@{@"relativePath": relative}) : nil;
}

static NSString *FDMEStart(FDMEngine *engine) {
    NSError *error = nil;
    NSString *key = [engine startURL:FDMEURL() name:@"payload.bin" error:&error];
    FDMECheck(key.length > 0 && !error, [NSString stringWithFormat:@"start failed: %@", error]);
    return key;
}

static NSURL *FDMETemporary(NSData *data) {
    NSString *path = [FDMDirectory(@"incoming-fixtures") stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".tmp"]];
    NSError *error = nil;
    FDMECheck([data writeToFile:path options:NSDataWritingAtomic error:&error], [NSString stringWithFormat:@"temporary fixture failed: %@", error]);
    return [NSURL fileURLWithPath:path];
}

static FDMEFakeTask *FDMECloneTask(FDMEFakeTask *source, NSURLSessionTaskState state) {
    FDMEFakeTask *task = [[FDMEFakeTask alloc] init];
    task.taskIdentifier = source.taskIdentifier;
    task.taskDescription = source.taskDescription;
    task.requestedURL = source.requestedURL;
    task.state = state;
    return task;
}

static void FDMECompletedFlags(NSDictionary *row) {
    FDMECheck(row && [row[@"state"] integerValue] == FDMStateCompleted, @"expected a successfully completed record");
    FDMECheck(![row[@"pausing"] boolValue] && ![row[@"pauseIntent"] boolValue] && !row[@"resumeRequested"],
        @"Completed must clear pausing, pause intent and queued resume; UI cannot remain in a pending pause state");
}

static void FDMEPauseFully(FDMEngine *engine, FDMEFakeSession *session, FDMEFakeTask *task, NSString *key, NSData *data) {
    [engine pauseKey:key]; [engine drainForTesting];
    [task deliverPauseData:data]; [engine drainForTesting];
    [session completeTask:task error:FDMECancelled(data)]; [engine drainForTesting];
    NSDictionary *row = FDMEItem(engine, key);
    FDMECheck([row[@"state"] integerValue] == FDMStatePaused && ![row[@"pausing"] boolValue], @"both pause callbacks must settle Paused");
}

static void FDMETestDistinctIDs(void) {
    FDMEBeginCase(@"distinct-ids");
    FDMEFakeSession *session = [[FDMEFakeSession alloc] init];
    FDMEngine *engine = FDMENewEngine(session, NO);
    NSError *error = nil;
    FDMECheck([engine startURL:FDMEURL() name:nil error:&error] == nil && error != nil && session.created.count == 0, @"Restoring must prevent duplicate starts");
    [session replyEnumeration]; [engine drainForTesting];
    NSString *a = FDMEStart(engine), *b = FDMEStart(engine);
    FDMECheck(![a isEqual:b] && session.created.count == 2, @"two downloads of the same URL need distinct logical IDs");
    FDMECheck([[NSUUID alloc] initWithUUIDString:a] != nil && [[NSUUID alloc] initWithUUIDString:b] != nil, @"new identities must be UUIDs");
    FDMECheck(![session.created[0].taskDescription isEqual:session.created[1].taskDescription], @"system task tokens must distinguish logical IDs");
    FDMECheck([FDMEDiskItem(a)[@"generation"] integerValue] == 1, @"first attempt identity must be durable before resume");
    FDMECases++;
}

static void FDMETestPauseOrder(BOOL cancelFirst) {
    FDMEBeginCase(cancelFirst ? @"pause-cancel-first" : @"pause-complete-first");
    FDMEFakeSession *session = [[FDMEFakeSession alloc] init];
    FDMEngine *engine = FDMENewEngine(session, YES);
    NSString *key = FDMEStart(engine);
    FDMEFakeTask *old = session.created.lastObject;
    NSData *data = FDMEResume(@"pause-order");
    [engine pauseKey:key]; [engine drainForTesting];
    if (cancelFirst) [old deliverPauseData:data];
    else [session completeTask:old error:FDMECancelled(data)];
    [engine drainForTesting];
    NSDictionary *partial = FDMEDiskItem(key);
    FDMECheck([partial[@"pausing"] boolValue], @"one callback must not settle the two-callback transaction");
    FDMECheck([[NSData dataWithContentsOfFile:FDMEResumePath(partial)] isEqual:data], @"the first observed resume candidate must already be on disk");
    [engine resumeKey:key]; [engine drainForTesting];
    FDMECheck(session.created.count == 1 && [FDMEItem(engine, key)[@"resumeRequested"] boolValue], @"continue during Pausing must queue once, not start early");
    if (cancelFirst) [session completeTask:old error:FDMECancelled(data)];
    else [old deliverPauseData:data];
    [engine drainForTesting];
    FDMEFakeTask *current = session.created.lastObject;
    FDMECheck(session.created.count == 2 && [current.resumeDataUsed isEqual:data], @"queued continue must use the saved candidate after both callbacks");
    FDMECheck([FDMEItem(engine, key)[@"generation"] integerValue] == 2 && current.resumeCalls == 1, @"continue preserves logical ID and increments only the actual attempt");
    FDMECheck(![engine canResumeKey:key], @"a running new attempt cannot inherit old resume capability");
    FDMECases++;
}

static void FDMETestPauseWithoutData(void) {
    FDMEBeginCase(@"pause-without-data");
    FDMEFakeSession *session = [[FDMEFakeSession alloc] init];
    FDMEngine *engine = FDMENewEngine(session, YES);
    NSString *key = FDMEStart(engine);
    FDMEPauseFully(engine, session, session.created.lastObject, key, nil);
    FDMECheck(![engine canResumeKey:key], @"Paused without data must not advertise resumability");
    [engine resumeKey:key]; [engine drainForTesting];
    FDMECheck(session.created.count == 1 && FDMString(FDMEItem(engine, key)[@"actionError"]).length > 0, @"continue without data must explain the need to restart");
    [engine restartKey:key]; [engine drainForTesting];
    FDMECheck(session.created.count == 2 && !session.created.lastObject.resumeDataUsed, @"explicit restart creates a full download");
    FDMECases++;
}

static void FDMETestExitAfterFirstPauseData(BOOL cancelFirst) {
    FDMEBeginCase(cancelFirst ? @"exit-after-cancel-data" : @"exit-after-complete-data");
    FDMEFakeSession *oldSession = [[FDMEFakeSession alloc] init];
    FDMEngine *oldEngine = FDMENewEngine(oldSession, YES);
    NSString *key = FDMEStart(oldEngine);
    FDMEFakeTask *oldTask = oldSession.created.lastObject;
    NSData *data = FDMEResume(@"durable-before-second-callback");
    [oldEngine pauseKey:key]; [oldEngine drainForTesting];
    if (cancelFirst) [oldTask deliverPauseData:data];
    else [oldSession completeTask:oldTask error:FDMECancelled(data)];
    [oldEngine drainForTesting];
    NSString *savedPath = FDMEResumePath(FDMEDiskItem(key));
    FDMECheck([[NSData dataWithContentsOfFile:savedPath] isEqual:data], @"partial pause data must survive exit");
    FDMEFakeTask *systemTask = FDMECloneTask(oldTask, NSURLSessionTaskStateCanceling);
    [oldSession abandonForSimulatedExit]; oldEngine = nil;
    FDMEFakeSession *session = [[FDMEFakeSession alloc] init];
    session.enumerationSnapshot = cancelFirst ? @[systemTask] : @[];
    FDMEngine *engine = FDMENewEngine(session, YES);
    if (cancelFirst) [session completeTask:systemTask error:FDMECancelled(nil)];
    [engine drainForTesting];
    NSDictionary *row = FDMEItem(engine, key);
    FDMECheck([row[@"state"] integerValue] == FDMStatePaused && ![row[@"pausing"] boolValue], @"recovered pause intent must settle without the lost in-process closure");
    FDMECheck([engine canResumeKey:key] && [[NSData dataWithContentsOfFile:savedPath] isEqual:data], @"recovered pause must retain its saved candidate");
    [engine resumeKey:key]; [engine drainForTesting];
    FDMECheck(session.created.count == 1 && [session.created.lastObject.resumeDataUsed isEqual:data], @"recovered continue must bind the saved logical attempt");
    FDMECases++;
}

static void FDMETestRecoveredPausingNoData(void) {
    FDMEBeginCase(@"recovered-pausing-no-data");
    NSString *key = NSUUID.UUID.UUIDString;
    FDMEWriteJSON(@[@{@"schema": @2, @"key": key, @"url": FDMEURL(), @"name": @"payload.bin", @"generation": @3,
        @"taskIdentifier": @41, @"state": @(FDMStateDownloading), @"pauseIntent": @YES, @"pausing": @YES}], @"tasks.json");
    FDMEFakeSession *session = [[FDMEFakeSession alloc] init];
    FDMEngine *engine = FDMENewEngine(session, YES);
    NSDictionary *row = FDMEItem(engine, key);
    FDMECheck([row[@"state"] integerValue] == FDMStatePaused && ![row[@"pausing"] boolValue] && ![engine canResumeKey:key], @"no-system-task restoration cannot wait forever in Pausing");
    [engine restartKey:key]; [engine drainForTesting];
    FDMECheck(session.created.count == 1 && !session.created.lastObject.resumeDataUsed, @"recovered data-less pause can only restart explicitly");
    FDMECases++;
}

static void FDMETestStaleEnumeration(void) {
    FDMEBeginCase(@"stale-completed-enumeration");
    NSString *key = NSUUID.UUID.UUIDString;
    FDMEFakeTask *task = [[FDMEFakeTask alloc] init];
    task.taskIdentifier = 77; task.taskDescription = [NSString stringWithFormat:@"fdm2:%@:1", key]; task.state = NSURLSessionTaskStateRunning;
    FDMEWriteJSON(@[@{@"schema": @2, @"key": key, @"url": FDMEURL(), @"generation": @1, @"taskIdentifier": @77,
        @"state": @(FDMStateDownloading)}], @"tasks.json");
    FDMEFakeSession *session = [[FDMEFakeSession alloc] init]; session.enumerationSnapshot = @[task];
    FDMEngine *engine = FDMENewEngine(session, NO);
    [session completeTask:task error:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNetworkConnectionLost
        userInfo:@{NSURLSessionDownloadTaskResumeData: FDMEResume(@"enumeration-finished-late")}]];
    [session replyEnumeration]; [engine drainForTesting];
    [engine resumeKey:key]; [engine drainForTesting];
    FDMECheck(session.created.count == 1 && session.created.lastObject.resumeDataUsed.length > 0, @"completed enumeration snapshots cannot rebind a dead task and block continue");
    FDMECases++;
}

static void FDMETestCompletedSurvivesRecoveredPause(BOOL cancelFirst) {
    FDMEBeginCase(cancelFirst ? @"completed-pause-cancel-first" : @"completed-pause-complete-first");
    FDMEFakeSession *oldSession = [[FDMEFakeSession alloc] init];
    FDMEngine *oldEngine = FDMENewEngine(oldSession, YES);
    NSString *key = FDMEStart(oldEngine);
    FDMEFakeTask *oldTask = oldSession.created.lastObject;
    [oldEngine pauseKey:key]; [oldEngine drainForTesting];
    [oldEngine resumeKey:key]; [oldEngine drainForTesting];
    FDMECheck([FDMEItem(oldEngine, key)[@"resumeRequested"] boolValue], @"seed a queued continue before completion wins");
    NSData *payload = [@"completed-while-cancellation-was-pending" dataUsingEncoding:NSUTF8StringEncoding];
    NSURL *temporary = FDMETemporary(payload);
    [oldSession finishTask:oldTask status:200 temporaryURL:temporary];
    NSDictionary *saved = FDMEDiskItem(key);
    FDMECompletedFlags(saved);
    FDMECheck(![[NSFileManager defaultManager] fileExistsAtPath:temporary.path], @"finish must synchronously move the temporary file");
    NSString *destination = FDMResolveDocumentPath(saved);
    NSData *resume = FDMEResume(@"late-pause-after-success");
    if (cancelFirst) [oldTask deliverPauseData:resume];
    else [oldSession completeTask:oldTask error:FDMECancelled(resume)];
    [oldEngine drainForTesting]; FDMECompletedFlags(FDMEItem(oldEngine, key));
    if (cancelFirst) [oldSession completeTask:oldTask error:FDMECancelled(resume)];
    else [oldTask deliverPauseData:resume];
    [oldEngine drainForTesting];
    FDMECompletedFlags([FDMStore.shared recordForKey:key]);
    FDMECheck(oldSession.created.count == 1, @"completion must discard queued continue rather than create a new attempt");
    FDMEFakeTask *systemTask = FDMECloneTask(oldTask, NSURLSessionTaskStateRunning);
    [oldSession abandonForSimulatedExit]; oldEngine = nil;
    FDMEWriteJSON(@[saved], @"tasks.json");
    FDMEFakeSession *session = [[FDMEFakeSession alloc] init]; session.enumerationSnapshot = @[systemTask];
    FDMEngine *engine = FDMENewEngine(session, YES);
    [session completeTask:systemTask error:FDMECancelled(nil)]; [engine drainForTesting];
    NSDictionary *record = [FDMStore.shared recordForKey:key];
    FDMECompletedFlags(record);
    FDMECheck(record[@"fileIdentity"] != nil, @"recovered completion keeps file identity");
    FDMECheck([[NSData dataWithContentsOfFile:destination] isEqual:payload] && FDMEItem(engine, key) == nil, @"completed file must be preserved and archived once");
    FDMECases++;
}

static void FDMETestOldAttemptCannotMutate(void) {
    FDMEBeginCase(@"old-attempt-rejected");
    FDMEFakeSession *session = [[FDMEFakeSession alloc] init];
    FDMEngine *engine = FDMENewEngine(session, YES);
    NSString *key = FDMEStart(engine);
    FDMEFakeTask *old = session.created.lastObject;
    NSData *first = FDMEResume(@"first-generation");
    FDMEPauseFully(engine, session, old, key, first);
    NSString *oldPath = FDMEResumePath(FDMEDiskItem(key));
    [engine resumeKey:key]; [engine drainForTesting];
    NSDictionary *before = FDMEItem(engine, key);
    [session writeTask:old received:999999 total:999999];
    [session completeTask:old error:FDMECancelled(FDMEResume(@"stale-overwrite"))];
    NSURL *temporary = FDMETemporary([@"stale-file" dataUsingEncoding:NSUTF8StringEncoding]);
    [session finishTask:old status:200 temporaryURL:temporary]; [engine drainForTesting];
    FDMECheck([FDMEItem(engine, key) isEqual:before] && ![engine canResumeKey:key], @"old progress/finish/error cannot mutate current generation");
    FDMECheck([[NSData dataWithContentsOfFile:oldPath] isEqual:first] && [[NSFileManager defaultManager] fileExistsAtPath:temporary.path], @"old callback must be rejected before resume write or file move");
    FDMEPauseFully(engine, session, session.created.lastObject, key, FDMEResume(@"current-generation"));
    FDMECheck([engine canResumeKey:key], @"old error must not remove the new system task mapping");
    FDMECases++;
}

static void FDMETestRestartClearsResume(void) {
    FDMEBeginCase(@"full-restart-clears-capability");
    FDMEFakeSession *session = [[FDMEFakeSession alloc] init];
    FDMEngine *engine = FDMENewEngine(session, YES);
    NSString *key = FDMEStart(engine);
    NSData *data = FDMEResume(@"old-checkpoint");
    FDMEPauseFully(engine, session, session.created.lastObject, key, data);
    NSString *oldPath = FDMEResumePath(FDMEDiskItem(key));
    [engine restartKey:key]; [engine drainForTesting];
    FDMEFakeTask *current = session.created.lastObject;
    FDMECheck(session.created.count == 2 && !current.resumeDataUsed && ![engine canResumeKey:key], @"restart is a full attempt with no inherited resume capability");
    [session completeTask:current error:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNetworkConnectionLost userInfo:nil]];
    NSDictionary *record = [FDMStore.shared recordForKey:key];
    FDMECheck([record[@"state"] integerValue] == FDMStateFailed && ![engine canResumeKey:key], @"failure of the new full attempt cannot advertise the old checkpoint");
    FDMECheck([[NSData dataWithContentsOfFile:oldPath] isEqual:data], @"clearing capability does not delete an older resume file");
    FDMECases++;
}

static void FDMETestRecordDeletionAndJournalReplay(void) {
    FDMEBeginCase(@"record-delete-and-journal-replay");
    NSString *key = NSUUID.UUID.UUIDString;
    NSData *payload = [@"keep-final-file" dataUsingEncoding:NSUTF8StringEncoding], *resume = FDMEResume(@"keep-resume-file");
    NSString *finalPath = [FDMDirectory(@"owned-fixtures") stringByAppendingPathComponent:@"final.bin"];
    FDMECheck([payload writeToFile:finalPath atomically:YES], @"final fixture write");
    NSString *relative = [NSString stringWithFormat:@"FocusDM/resume/%@-1.resume", FDMLegacyHash(key)];
    FDMDirectory(@"FocusDM/resume");
    NSString *resumePath = FDMResolveDocumentPath(@{@"relativePath": relative});
    FDMECheck([resume writeToFile:resumePath atomically:YES], @"resume fixture write");
    NSDictionary *fixture = @{@"schema": @2, @"key": key, @"url": FDMEURL(), @"generation": @1, @"taskIdentifier": @88,
        @"state": @(FDMStateDownloading), @"path": finalPath, @"relativePath": FDMRelativeDocumentPath(finalPath),
        @"fileIdentity": FDMFileIdentity(finalPath), @"resumeRelativePath": relative};
    FDMEWriteJSON(@[fixture], @"tasks.json");
    FDMEFakeTask *task = [[FDMEFakeTask alloc] init]; task.taskIdentifier = 88;
    task.taskDescription = [NSString stringWithFormat:@"fdm2:%@:1", key]; task.state = NSURLSessionTaskStateRunning;
    FDMEFakeSession *oldSession = [[FDMEFakeSession alloc] init]; oldSession.enumerationSnapshot = @[task];
    FDMEngine *oldEngine = FDMENewEngine(oldSession, YES);
    __block BOOL delivered = NO; __block NSError *failure;
    [oldEngine removeKey:key deleteFile:NO completion:^(NSError *error) { failure = error; delivered = YES; }];
    [oldEngine drainForTesting]; FDMEFlushMain();
    FDMECheck(delivered && !failure && task.cancelCalls == 1 && [oldEngine isRemovedKey:key], @"record-only deletion must commit suppression and stop the task");
    [oldSession writeTask:task received:100 total:100];
    [oldSession completeTask:task error:FDMECancelled(FDMEResume(@"deleted-callback"))];
    [oldEngine drainForTesting];
    FDMECheck(FDMEItem(oldEngine, key) == nil && [FDMStore.shared recordForKey:key] == nil, @"late events cannot revive a removed record");
    FDMECheck([[NSData dataWithContentsOfFile:finalPath] isEqual:payload] && [[NSData dataWithContentsOfFile:resumePath] isEqual:resume], @"record-only deletion must preserve final and resume bytes");
    FDMEFakeTask *systemTask = FDMECloneTask(task, NSURLSessionTaskStateRunning);
    [oldSession abandonForSimulatedExit]; oldEngine = nil;
    // Simulate exit after durable journal commit but before tasks/history cleanup.
    FDMEWriteJSON(@[fixture], @"tasks.json");
    NSError *error = nil; FDMECheck([FDMStore.shared upsertRecord:fixture error:&error], @"seed this suite's pending history cleanup");
    FDMEFakeSession *session = [[FDMEFakeSession alloc] init]; session.enumerationSnapshot = @[systemTask];
    FDMEngine *engine = FDMENewEngine(session, YES);
    FDMECheck(systemTask.cancelCalls == 1 && engine.items.count == 0 && [FDMStore.shared recordForKey:key] == nil, @"restoration must replay committed task cancellation and history cleanup");
    FDMECheck([[NSData dataWithContentsOfFile:finalPath] isEqual:payload] && [[NSData dataWithContentsOfFile:resumePath] isEqual:resume], @"journal replay cannot delete retained local files");
    FDMECases++;
}

static void FDMETestHTTPAndUniqueDestination(void) {
    FDMEBeginCase(@"http-and-non-overwrite");
    FDMEFakeSession *session = [[FDMEFakeSession alloc] init];
    FDMEngine *engine = FDMENewEngine(session, YES);
    NSString *failedKey = FDMEStart(engine); FDMEFakeTask *failed = session.created.lastObject;
    [session finishTask:failed status:404 temporaryURL:FDMETemporary([@"<html>not a download</html>" dataUsingEncoding:NSUTF8StringEncoding])];
    [session completeTask:failed error:nil];
    NSDictionary *failure = [FDMStore.shared recordForKey:failedKey];
    FDMECheck([failure[@"state"] integerValue] == FDMStateFailed && [FDMString(failure[@"error"]) containsString:@"404"] && !failure[@"completionEvidence"], @"HTTP 404 with no transport error must archive Failed");
    NSString *key = FDMEStart(engine); FDMEFakeTask *task = session.created.lastObject;
    NSString *directory = FDMDirectory([@"FocusDM/downloads" stringByAppendingPathComponent:FDMLegacyHash(key)]);
    NSString *occupied = [directory stringByAppendingPathComponent:@"payload.bin"];
    NSData *original = [@"existing-unrelated-file" dataUsingEncoding:NSUTF8StringEncoding];
    FDMECheck([original writeToFile:occupied atomically:YES], @"seed collision fixture");
    NSData *payload = [@"new-successful-download" dataUsingEncoding:NSUTF8StringEncoding];
    NSURL *temporary = FDMETemporary(payload);
    [session finishTask:task status:200 temporaryURL:temporary];
    FDMECheck(![[NSFileManager defaultManager] fileExistsAtPath:temporary.path], @"temporary file must move before delegate returns");
    [session completeTask:task error:nil];
    NSDictionary *record = [FDMStore.shared recordForKey:key];
    NSString *path = FDMResolveDocumentPath(record);
    FDMECheck([record[@"state"] integerValue] == FDMStateCompleted && [record[@"completionEvidence"] isEqual:@"http-success-and-file-moved"], @"success must have response-and-file completion evidence");
    FDMECheck(![path isEqual:occupied] && [[NSData dataWithContentsOfFile:occupied] isEqual:original], @"save must not replace the existing destination");
    FDMECheck([[NSData dataWithContentsOfFile:path] isEqual:payload] && [record[@"fileIdentity"] isEqual:FDMFileIdentity(path)], @"completed history must point at the newly moved owned file");
    FDMECompletedFlags(record);
    NSUInteger beforeStaleActions = session.created.count;
    [engine resumeKey:key]; [engine restartKey:key]; [engine drainForTesting];
    FDMECheck(session.created.count == beforeStaleActions && FDMEItem(engine, key) == nil && [[FDMStore.shared recordForKey:key] isEqual:record], @"stale resume/restart actions cannot reopen a Completed record");
    NSString *independent = FDMEStart(engine);
    FDMECheck(![independent isEqual:key] && session.created.count == beforeStaleActions + 1 && [[FDMStore.shared recordForKey:key] isEqual:record], @"new download of the same URL must create another UUID without replacing completed history");
    FDMECheck([[NSData dataWithContentsOfFile:path] isEqual:payload], @"stale or new actions preserve the original completed file");
    FDMECases++;
}

static void FDMETestBackgroundOrder(BOOL finishFirst) {
    FDMEBeginCase(finishFirst ? @"background-events-first" : @"background-handler-first");
    FDMEFakeSession *session = [[FDMEFakeSession alloc] init];
    FDMEngine *engine = FDMENewEngine(session, NO);
    __block NSUInteger calls = 0; __block BOOL mainThread = NO;
    void (^completion)(void) = ^{ calls++; mainThread = NSThread.isMainThread; };
    if (finishFirst) [engine URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)(id)session];
    [engine setBackgroundCompletion:completion]; [engine drainForTesting];
    if (!finishFirst) [engine URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)(id)session];
    FDMEFlushMain(); FDMECheck(calls == 0, @"background handoff must wait for restoration");
    [session replyEnumeration]; [engine drainForTesting]; FDMEFlushMain();
    FDMECheck(calls == 1 && mainThread, @"both handler/event orders must hand off once on main");
    [engine URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)(id)session];
    [engine drainForTesting]; FDMEFlushMain();
    FDMECheck(calls == 1, @"extra finish events cannot call the consumed completion again");
    FDMECases++;
}

static void FDMETestBackgroundPauseBarrier(void) {
    FDMEBeginCase(@"background-pause-barrier");
    FDMEFakeSession *session = [[FDMEFakeSession alloc] init]; FDMEngine *engine = FDMENewEngine(session, YES);
    NSString *key = FDMEStart(engine); FDMEFakeTask *task = session.created.lastObject; NSData *data = FDMEResume(@"pause-before-handoff");
    [engine pauseKey:key]; [engine drainForTesting]; [task deliverPauseData:data]; [engine drainForTesting];
    __block NSUInteger calls = 0;
    [engine setBackgroundCompletion:^{ FDMECheck(NSThread.isMainThread, @"background handoff runs on main"); calls++; }];
    [engine drainForTesting]; [engine URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)(id)session]; FDMEFlushMain();
    FDMECheck(calls == 0, @"handoff cannot bypass the pending pause transaction");
    [session completeTask:task error:FDMECancelled(data)]; [engine drainForTesting]; FDMEFlushMain();
    FDMECheck(calls == 1 && [engine canResumeKey:key], @"pause settlement and durable resume must precede background handoff");
    FDMECases++;
}

static void FDMETestLegacyCompatibility(BOOL historyOnly) {
    FDMEBeginCase(historyOnly ? @"legacy-history-only" : @"legacy-task-and-history");
    NSString *url = FDMEURL(); NSData *data = FDMEResume(@"legacy-data");
    NSString *relative = [NSString stringWithFormat:@"FocusDM/resume/%@.resume", FDMLegacyHash(url)]; FDMDirectory(@"FocusDM/resume");
    NSString *legacyPath = FDMResolveDocumentPath(@{@"relativePath": relative});
    FDMECheck([data writeToFile:legacyPath atomically:YES], @"legacy resume fixture");
    NSDictionary *legacy = @{@"key": url, @"url": url, @"name": @"payload.bin", @"state": @(FDMStatePaused), @"received": @4096, @"total": @8192};
    if (!historyOnly) FDMEWriteJSON(@[legacy], @"tasks.json");
    NSError *error = nil; FDMECheck([FDMStore.shared upsertRecord:legacy error:&error], @"legacy history fixture");
    FDMEFakeSession *oldSession = [[FDMEFakeSession alloc] init]; FDMEngine *oldEngine = FDMENewEngine(oldSession, YES);
    NSString *actionKey = historyOnly ? url : FDMString(oldEngine.items.firstObject[@"key"]);
    FDMECheck(actionKey.length > 0 && [oldEngine canResumeKey:actionKey], @"legacy records expose their candidate through both canonical and old history keys");
    [oldEngine resumeKey:actionKey]; [oldEngine drainForTesting];
    FDMECheck(oldSession.created.count == 1 && [oldSession.created.lastObject.resumeDataUsed isEqual:data], @"legacy continue must use old bytes, not silently restart");
    NSDictionary *row = oldEngine.items.firstObject; NSString *key = row[@"key"];
    FDMECheck([row[@"schema"] isEqual:@2] && [row[@"legacyKey"] isEqual:url] && ![key isEqual:url], @"loaded and archived legacy paths must share canonical migration");
    FDMECheck([FDMStore.shared recordForKey:url] == nil, @"legacy historical alias must not remain a duplicate after continue");
    FDMEFakeTask *systemTask = FDMECloneTask(oldSession.created.lastObject, NSURLSessionTaskStateRunning);
    [oldSession abandonForSimulatedExit]; oldEngine = nil;
    FDMEFakeSession *session = [[FDMEFakeSession alloc] init]; session.enumerationSnapshot = @[systemTask];
    FDMEngine *engine = FDMENewEngine(session, YES);
    FDMECheck([FDMEItem(engine, key)[@"generation"] integerValue] == 1 && session.created.count == 0, @"cold restore must bind the migrated attempt, not generate a new identity");
    [engine pauseKey:key]; [engine drainForTesting];
    FDMECheck(systemTask.pauseCalls == 1, @"restored task map must actually control the existing system task");
    [systemTask deliverPauseData:data]; [engine drainForTesting]; [session completeTask:systemTask error:FDMECancelled(data)];
    [engine resumeKey:key]; [engine drainForTesting];
    FDMEFakeTask *completedTask = session.created.lastObject;
    [session finishTask:completedTask status:200 temporaryURL:FDMETemporary([@"legacy-completed" dataUsingEncoding:NSUTF8StringEncoding])];
    [session completeTask:completedTask error:nil];
    FDMECheck([FDMStore.shared recordForKey:url] == nil, @"canonical completion must not restore the old historical alias");
    FDMECompletedFlags([FDMStore.shared recordForKey:key]);
    FDMECheck([[NSData dataWithContentsOfFile:legacyPath] isEqual:data], @"legacy compatibility never moves or deletes the old resume file");
    if (!historyOnly) {
        NSMutableDictionary *oldCompleted = [[FDMStore.shared recordForKey:key] mutableCopy];
        oldCompleted[@"key"] = url; [oldCompleted removeObjectForKey:@"schema"];
        [session abandonForSimulatedExit]; engine = nil;
        FDMEBeginCase(@"legacy-completed-deletion-boundary");
        FDMECheck([FDMStore.shared upsertRecord:oldCompleted error:&error], @"seed independent completed legacy history");
        FDMEWriteJSON(@[@{@"schema": @2, @"key": key, @"legacyKey": url, @"url": url, @"generation": @0, @"state": @(FDMStatePaused)}], @"tasks.json");
        session = [[FDMEFakeSession alloc] init]; engine = FDMENewEngine(session, YES);
        __block BOOL removed = NO; __block NSError *failure;
        [engine removeKey:key deleteFile:NO completion:^(NSError *error) { failure = error; removed = YES; }];
        [engine drainForTesting]; FDMEFlushMain();
        FDMECheck(removed && !failure && [engine isRemovedKey:key] && engine.items.count == 0, @"remove only the canonical paused owner");
        FDMECheck(![engine isRemovedKey:url] && [[FDMStore.shared recordForKey:url] isEqual:oldCompleted], @"completed legacy history is not a removable alias");
        FDMECheck(![(NSArray *)FDMReadJSON(FDMEDataPath(@"deleted-task-ids.json"), nil) containsObject:url], @"deletion journal must not suppress the independent completed legacy key");
        FDMECheck([[NSData dataWithContentsOfFile:FDMResolveDocumentPath(oldCompleted)] isEqual:[@"legacy-completed" dataUsingEncoding:NSUTF8StringEncoding]], @"record-only deletion retains the earlier completed file");
        FDMECases++;
    }
    FDMECases++;
}

static void FDMETestInvalidResumeCannotReplace(BOOL validCancelFirst) {
    FDMEBeginCase(validCancelFirst ? @"invalid-complete-resume" : @"invalid-cancel-resume");
    FDMEFakeSession *session = [[FDMEFakeSession alloc] init];
    FDMEngine *engine = FDMENewEngine(session, YES);
    NSString *key = FDMEStart(engine); FDMEFakeTask *task = session.created.lastObject;
    NSData *valid = FDMEResume(@"valid-candidate-survives");
    NSData *invalid = [@"not-a-resume-property-list" dataUsingEncoding:NSUTF8StringEncoding];
    [engine pauseKey:key]; [engine drainForTesting];
    if (validCancelFirst) [task deliverPauseData:valid];
    else [session completeTask:task error:FDMECancelled(valid)];
    [engine drainForTesting];
    NSString *path = FDMEResumePath(FDMEDiskItem(key));
    if (validCancelFirst) [session completeTask:task error:FDMECancelled(invalid)];
    else [task deliverPauseData:invalid];
    [engine drainForTesting];
    FDMECheck([engine canResumeKey:key] && [[NSData dataWithContentsOfFile:path] isEqual:valid], @"a later invalid candidate cannot overwrite a saved valid resume file");
    FDMECases++;
}

static NSDictionary *FDMEBlockTasksWrites(void) {
    // Move only this suite's freshly created fixture. No pre-existing path is
    // removed; the temporary directory occupying tasks.json is also moved away.
    NSString *path = FDMEDataPath(@"tasks.json");
    NSString *saved = FDMEDataPath([@"saved-tasks-" stringByAppendingString:NSUUID.UUID.UUIDString]);
    FDMECheck([FDMRelativeDocumentPath(path) isEqual:@"FocusDM/tasks.json"], @"write-failure injection is restricted to the suite tasks fixture");
    NSError *error = nil;
    FDMECheck([[NSFileManager defaultManager] moveItemAtPath:path toPath:saved error:&error], @"retain tasks fixture before failure injection");
    FDMECheck([[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:NO attributes:nil error:&error], @"a directory at tasks.json must reject file writes");
    return @{@"path": path, @"saved": saved};
}

static void FDMEUnblockTasksWrites(NSDictionary *fixture) {
    NSString *path = fixture[@"path"], *saved = fixture[@"saved"];
    FDMECheck([FDMRelativeDocumentPath(path) isEqual:@"FocusDM/tasks.json"] && FDMRelativeDocumentPath(saved).length > 0, @"restore only fixture-owned paths");
    NSString *retainedDirectory = FDMEDataPath([@"retained-write-blocker-" stringByAppendingString:NSUUID.UUID.UUIDString]);
    NSError *error = nil;
    FDMECheck([[NSFileManager defaultManager] moveItemAtPath:path toPath:retainedDirectory error:&error], @"retain write-blocker directory without deleting it");
    FDMECheck([[NSFileManager defaultManager] moveItemAtPath:saved toPath:path error:&error], @"restore the saved tasks fixture");
}

static void FDMETestStartPersistenceRollback(void) {
    FDMEBeginCase(@"attempt-persist-rollback");
    FDMEFakeSession *session = [[FDMEFakeSession alloc] init]; FDMEngine *engine = FDMENewEngine(session, YES);
    NSString *key = FDMEStart(engine); NSData *data = FDMEResume(@"rollback-candidate");
    FDMEPauseFully(engine, session, session.created.lastObject, key, data);
    NSDictionary *before = FDMEItem(engine, key);
    NSDictionary *blocker = FDMEBlockTasksWrites();
    [engine resumeKey:key]; [engine drainForTesting];
    FDMEFakeTask *cancelledAttempt = session.created.lastObject;
    NSDictionary *after = FDMEItem(engine, key);
    FDMECheck(session.created.count == 2 && cancelledAttempt.resumeCalls == 0 && cancelledAttempt.cancelCalls == 1, @"an uncommitted system attempt must be cancelled before it runs");
    FDMECheck([after[@"generation"] isEqual:before[@"generation"]] && [after[@"state"] integerValue] == FDMStatePaused && [engine canResumeKey:key], @"failed persistence must restore the old attempt and resume capability");
    [session completeTask:cancelledAttempt error:FDMECancelled(FDMEResume(@"uncommitted-attempt"))];
    [engine drainForTesting];
    FDMECheck([FDMEItem(engine, key)[@"generation"] isEqual:before[@"generation"]] && [engine canResumeKey:key], @"a failed, uncommitted attempt cannot write back through its cancellation callback");
    FDMEUnblockTasksWrites(blocker);
    [engine resumeKey:key]; [engine drainForTesting];
    FDMECheck(session.created.count == 3 && [session.created.lastObject.resumeDataUsed isEqual:data], @"retry after storage recovery must still use the retained candidate");
    FDMECases++;
}

static void FDMETestBackgroundPersistenceRecovery(void) {
    FDMEBeginCase(@"background-persist-recovery");
    FDMEFakeSession *session = [[FDMEFakeSession alloc] init]; FDMEngine *engine = FDMENewEngine(session, YES);
    NSDictionary *blocker = FDMEBlockTasksWrites();
    __block NSUInteger calls = 0;
    [engine setBackgroundCompletion:^{ FDMECheck(NSThread.isMainThread, @"recovered handoff runs on main"); calls++; }];
    [engine drainForTesting];
    [engine URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)(id)session];
    FDMEFlushMain();
    FDMECheck(calls == 0, @"a failed durable write cannot prematurely release the background completion");
    FDMEUnblockTasksWrites(blocker);
    FDMEStart(engine); [engine drainForTesting]; FDMEFlushMain();
    FDMECheck(calls == 1, @"later successful persistence must unblock background handoff even without another finish event");
    [engine drainForTesting];
    FDMECases++;
}

static void FDMETestDurableHistoryAndStaleTasks(BOOL newerAttempt) {
    FDMEBeginCase(newerAttempt ? @"old-history-new-live-attempt" : @"durable-history-stale-tasks");
    FDMEFakeSession *oldSession = [[FDMEFakeSession alloc] init];
    FDMEngine *oldEngine = FDMENewEngine(oldSession, YES);
    NSString *key = FDMEStart(oldEngine); FDMEFakeTask *oldTask = oldSession.created.lastObject;
    [oldEngine pauseKey:key]; [oldEngine drainForTesting];
    [oldEngine resumeKey:key]; [oldEngine drainForTesting];
    NSDictionary *before = FDMEDiskItem(key);
    FDMECheck([before[@"pausing"] boolValue] && [before[@"pauseIntent"] boolValue] && [before[@"resumeRequested"] boolValue], @"seed real pending pause flags before blocking task-state writes");
    NSDictionary *blocker = FDMEBlockTasksWrites();
    NSData *payload = [@"durable-final-despite-tasks-write-failure" dataUsingEncoding:NSUTF8StringEncoding];
    NSURL *temporary = FDMETemporary(payload);
    [oldSession finishTask:oldTask status:200 temporaryURL:temporary];
    FDMECompletedFlags(FDMEItem(oldEngine, key));
    [oldSession completeTask:oldTask error:nil]; [oldEngine drainForTesting];
    [oldTask deliverPauseData:FDMEResume(@"late-cancel-after-durable-success")]; [oldEngine drainForTesting];
    NSDictionary *completed = [FDMStore.shared recordForKey:key];
    FDMECompletedFlags(completed);
    NSString *destination = FDMResolveDocumentPath(completed);
    NSDictionary *identity = completed[@"fileIdentity"];
    FDMECheck(completed && [completed[@"state"] integerValue] == FDMStateCompleted && FDMEItem(oldEngine, key) == nil,
        @"history archive must succeed even while the separate tasks file cannot be written");
    FDMECheck([completed[@"key"] isEqual:key] && [completed[@"generation"] isEqual:before[@"generation"]]
        && [completed[@"taskIdentifier"] isEqual:before[@"taskIdentifier"]] && [identity isEqual:FDMFileIdentity(destination)],
        @"durable terminal evidence must retain exact logical ID, attempt, system task and file identity");
    FDMECheck(![[NSFileManager defaultManager] fileExistsAtPath:temporary.path]
        && [[NSData dataWithContentsOfFile:destination] isEqual:payload], @"successful move must survive the failed task-state write");
    NSArray *durableHistory = FDMReadJSON(FDMEDataPath(@"history.json"), nil);
    FDMECheck([durableHistory isKindOfClass:NSArray.class] && [durableHistory containsObject:completed],
        @"the winning completion must exist on disk, not only in FDMStore memory");
    [oldSession abandonForSimulatedExit]; oldEngine = nil;
    FDMEUnblockTasksWrites(blocker);
    FDMECheck([FDMEDiskItem(key) isEqual:before] && [before[@"state"] integerValue] == FDMStateDownloading,
        @"restoration fixture must keep the old Downloading row, not accidentally flush completion into tasks.json");
    FDMEFakeSession *session = [[FDMEFakeSession alloc] init];
    FDMEFakeTask *live = nil;
    if (newerAttempt) {
        // A later committed attempt has a live system task; older terminal
        // history is not authority for this attempt merely because UUID matches.
        live = FDMECloneTask(oldTask, NSURLSessionTaskStateRunning);
        live.taskIdentifier = oldTask.taskIdentifier + 100;
        NSNumber *generation = @([before[@"generation"] unsignedIntegerValue] + 1);
        live.taskDescription = [NSString stringWithFormat:@"fdm2:%@:%@", key, generation];
        NSMutableDictionary *newer = [before mutableCopy];
        newer[@"generation"] = generation; newer[@"taskIdentifier"] = @(live.taskIdentifier);
        newer[@"pausing"] = @NO; newer[@"pauseIntent"] = @NO; [newer removeObjectForKey:@"resumeRequested"];
        FDMEWriteJSON(@[newer], @"tasks.json");
        session.enumerationSnapshot = @[live];
    }
    FDMEngine *engine = FDMENewEngine(session, YES);
    if (newerAttempt) {
        NSDictionary *current = FDMEItem(engine, key);
        FDMECheck(current && [current[@"state"] integerValue] == FDMStateDownloading
            && [current[@"generation"] unsignedIntegerValue] == [before[@"generation"] unsignedIntegerValue] + 1
            && [current[@"taskIdentifier"] unsignedIntegerValue] == live.taskIdentifier && !current[@"completionEvidence"],
            @"older terminal history cannot complete or remove a newer live attempt");
        FDMEPauseFully(engine, session, live, key, FDMEResume(@"newer-live-attempt"));
        FDMECheck(live.pauseCalls == 1, @"restored newer attempt must control its actual existing system task");
    } else {
        FDMECheck(FDMEItem(engine, key) == nil && ![engine canResumeKey:key] && session.created.count == 0,
            @"same-attempt durable completion must suppress the stale interrupted task without creating a replacement");
    }
    NSDictionary *restored = [FDMStore.shared recordForKey:key];
    FDMECompletedFlags(restored);
    FDMECheck([restored[@"state"] integerValue] == FDMStateCompleted && [restored[@"generation"] isEqual:completed[@"generation"]]
        && [restored[@"fileIdentity"] isEqual:identity] && [[NSData dataWithContentsOfFile:destination] isEqual:payload],
        @"reconciliation must preserve exact durable completion and original final file");
    FDMECases++;
}

static void FDMETestSchedulerAndAtomicBatch(void) {
    FDMEBeginCase(@"scheduler-concurrency-batch");
    FDMEFakeSession *session = [FDMEFakeSession new]; FDMEngine *engine = FDMENewEngine(session, YES);
    engine.concurrencyLimit = 1; [engine drainForTesting];
    NSError *error = nil;
    NSString *first = FDMEStart(engine);
    NSArray *urls = @[@"https://fixture.invalid/batch-1", @"https://fixture.invalid/batch-2"];
    FDMECheck([engine enqueueURLs:urls error:&error], @"batch waiting rows accepted");
    FDMECheck(session.created.count == 1 && engine.items.count == 3, @"real transport creation respects one-slot queue");
    FDMEFakeTask *old = session.created.firstObject;
    [engine pauseKey:first]; [engine drainForTesting];
    [old deliverPauseData:FDMEResume(@"scheduler-partial")]; [engine drainForTesting];
    FDMECheck(session.created.count == 1, @"cancel resume callback alone cannot free slot");
    [session completeTask:old error:FDMECancelled(nil)]; [engine drainForTesting];
    FDMECheck(session.created.count == 2 && [session.created.lastObject.requestedURL.absoluteString isEqual:urls[0]], @"slot release schedules FIFO GET exactly once");
    NSUInteger before = engine.items.count, created = session.created.count;
    FDMECheck(![engine enqueueURLs:@[@"https://fixture.invalid/good", @"file:///not-web"] error:&error], @"invalid batch rejected before side effects");
    FDMECheck(engine.items.count == before && session.created.count == created, @"bad batch has zero task mutation");
    NSMutableArray *large = [NSMutableArray array];
    for (NSUInteger i=0;i<101;i++) [large addObject:urls[0]];
    FDMECheck(![engine enqueueURLs:large error:&error], @"batch over preview cap rejected");
    FDMECases++;
}

@interface FDMEPrivateStore : NSObject
- (BOOL)isPersistent;
@end
@implementation FDMEPrivateStore
- (BOOL)isPersistent { return NO; }
@end
static void FDMETestPrivateIntentAndOriginalPOST(void) {
    FDMEBeginCase(@"private-and-original-post");
    FDMEFakeSession *session=[FDMEFakeSession new]; FDMEngine *engine=FDMENewEngine(session, YES);
    NSMutableURLRequest *post=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://fixture.invalid/post?ticket=sensitive"]];
    post.HTTPMethod=@"POST"; post.HTTPBody=[@"secret-body" dataUsingEncoding:NSUTF8StringEncoding];
    FDMDownloadIntent *intent=[[FDMDownloadIntent alloc] initWithRequest:post tabID:@"private-tab" generation:4
        sourceOrigin:@"https://fixture.invalid" transport:FDMTransportWebKitDownload dataStore:[FDMEPrivateStore new] userInitiated:YES policyRevision:0];
    NSObject *download=[NSObject new];
    // This fixture tests the single state owner only; real WKDownload POST exactly-once is the simulator test.
    NSString *key=[engine registerWebKitDownload:download intent:intent tabID:@"private-tab"];
    FDMECheck(key && engine.items.count == 1 && session.created.count == 0, @"WebKit POST adopt never creates NSURLSession GET");
    NSData *tasks=[NSData dataWithContentsOfFile:FDMEDataPath(@"tasks.json")];
    NSString *text=[[NSString alloc] initWithData:tasks encoding:NSUTF8StringEncoding];
    FDMECheck(![text containsString:key] && ![text containsString:@"sensitive"], @"private row and request secrets never persist");
    __block NSError *failure=nil;
    [engine removeKey:key deleteFile:NO completion:^(NSError *error) { failure=error; }]; [engine drainForTesting]; FDMEFlushMain();
    FDMECheck(!failure && ![[NSString stringWithContentsOfFile:FDMEDataPath(@"deleted-task-ids.json") encoding:NSUTF8StringEncoding error:NULL] containsString:key], @"private deletion leaves no durable tombstone");
    FDMECases++;
}

void FDMRunEngineRegression(void) {
    @autoreleasepool {
        FDMECheck(NSThread.isMainThread, @"call the regression entry on main");
        FDMERoot = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"focusdm-engine-regression-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSError *error = nil;
        FDMECheck(![[NSFileManager defaultManager] fileExistsAtPath:FDMERoot], @"never reuse an existing fixture directory");
        FDMECheck([[NSFileManager defaultManager] createDirectoryAtPath:FDMERoot withIntermediateDirectories:YES attributes:nil error:&error], @"new temporary fixture directory must be writable");
        FDMECheck(setenv("FDM_TEST_DOCUMENTS", FDMERoot.fileSystemRepresentation, 1) == 0, @"fixture environment setup failed");
        FDMECheck([FDMDocumentsPath() isEqual:FDMERoot], @"FDM_TESTING must route all owner files into the new fixture root");
        FDMECases = 0;
        FDMETestDistinctIDs();
        FDMETestSchedulerAndAtomicBatch();
        FDMETestPrivateIntentAndOriginalPOST();
        FDMETestPauseOrder(YES); FDMETestPauseOrder(NO);
        FDMETestPauseWithoutData();
        FDMETestExitAfterFirstPauseData(YES); FDMETestExitAfterFirstPauseData(NO);
        FDMETestRecoveredPausingNoData();
        FDMETestStaleEnumeration();
        FDMETestCompletedSurvivesRecoveredPause(YES); FDMETestCompletedSurvivesRecoveredPause(NO);
        FDMETestOldAttemptCannotMutate();
        FDMETestRestartClearsResume();
        FDMETestRecordDeletionAndJournalReplay();
        FDMETestHTTPAndUniqueDestination();
        FDMETestBackgroundOrder(YES); FDMETestBackgroundOrder(NO);
        FDMETestBackgroundPauseBarrier();
        FDMETestLegacyCompatibility(NO); FDMETestLegacyCompatibility(YES);
        FDMETestInvalidResumeCannotReplace(YES); FDMETestInvalidResumeCannotReplace(NO);
        FDMETestStartPersistenceRollback();
        FDMETestBackgroundPersistenceRecovery();
        FDMETestDurableHistoryAndStaleTasks(NO); FDMETestDurableHistoryAndStaleTasks(YES);
        FDMEFlushMain();
        printf("FDMEngine regression: %lu scenarios passed; fixture root=%s\n", (unsigned long)FDMECases, FDMERoot.fileSystemRepresentation);
        // Keep the allocated root and environment for the parent runner's other
        // suites; do not remove existing or newly created user-like fixtures.
    }
}
