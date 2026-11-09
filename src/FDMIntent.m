#import "FDMIntent.h"
#import "FDMPolicy.h"

#if __has_include(<UIKit/UIKit.h>)
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#define FDM_HAS_UIKIT 1
#else
// Foundation-only regression builds exercise the registry and redirect policy without UIKit.
#define FDM_HAS_UIKIT 0
#endif

#pragma mark - intent

@interface FDMDownloadIntent ()
@property (nonatomic, copy) NSString *intentID;
@property (nonatomic, copy) NSString *tabID;
@property (nonatomic) unsigned long long navigationGeneration;
@property (nonatomic, copy, nullable) NSString *sourceOrigin;
@property (nonatomic, copy, nullable) NSString *targetOrigin;
@property (nonatomic, copy) NSString *method;
@property (nonatomic) BOOL replayable;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy, nullable) NSString *suggestedFilename;
@property (nonatomic, copy, nullable) NSString *mime;
@property (nonatomic) long long expectedLength;
@property (nonatomic) BOOL userInitiated;
@property (nonatomic) NSTimeInterval captureTime;
@property (nonatomic) unsigned long long policyRevision;
@property (nonatomic) FDMTransportKind transport;
@property (nonatomic, copy, nullable) NSString *transportRefusal;
@end

@implementation FDMDownloadIntent
- (NSString *)description {
    return [NSString stringWithFormat:@"<intent %@ tab=%@ gen=%llu %@ %@ transport=%@>",
            self.intentID, self.tabID, self.navigationGeneration, self.method,
            FDMRedactedURL(self.url), FDMTransportName(self.transport)];
}
@end

#pragma mark - redirect policy

NSError *FDMRedirectRefusal(NSURLRequest *original, NSURLRequest *redirect) {
    if (!original || !redirect) return nil;
    NSString *from = FDMOriginForURL(original.URL);
    NSString *to = FDMOriginForURL(redirect.URL);
    if (!from || !to) return [NSError errorWithDomain:@"FocusDM.Transport" code:2
                                            userInfo:@{NSLocalizedDescriptionKey: @"重定向目标不是有效的 http/https 地址，已停止下载"}];
    if ([from isEqual:to]) return nil;
    // A credentialed cross-origin hop must not inherit the previous site's authority.
    BOOL carriesSecret = original.URL.user.length || original.URL.password.length;
    for (NSString *name in original.allHTTPHeaderFields) if (FDMIsSecretHeader(name)) carriesSecret = YES;
    NSURLComponents *fromParts = [NSURLComponents componentsWithString:from];
    NSURLComponents *toParts = [NSURLComponents componentsWithString:to];
    if ([fromParts.scheme isEqual:@"https"] && [toParts.scheme isEqual:@"http"]) {
        return [NSError errorWithDomain:@"FocusDM.Transport" code:3
                                userInfo:@{NSLocalizedDescriptionKey: @"下载被重定向到不安全的 HTTP 地址，已停止以保护登录信息"}];
    }
    if (carriesSecret) {
        return [NSError errorWithDomain:@"FocusDM.Transport" code:4
                                userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"下载被重定向到其他站点（%@），已停止以免泄露登录信息", to]}];
    }
    return nil;
}

#pragma mark - registry

typedef struct {
    __unsafe_unretained NSString *url;
    __unsafe_unretained NSString *tabID;
} FDMIntentKey;

static const void *FDMIntentRegistryQueueKey = &FDMIntentRegistryQueueKey;

@implementation FDMIntentRegistry {
    dispatch_queue_t _queue;
    NSMutableDictionary<NSString *, NSMutableDictionary *> *_records;
    NSMutableArray<NSString *> *_order;
    NSMapTable<id, NSString *> *_tabByDataStore;
}

+ (instancetype)shared {
    static FDMIntentRegistry *registry;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ registry = [[self alloc] init]; });
    return registry;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("FocusDM.intent-registry", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_queue, FDMIntentRegistryQueueKey, (__bridge void *)self, NULL);
        _records = [NSMutableDictionary dictionary];
        _order = [NSMutableArray array];
        _tabByDataStore = [NSMapTable strongToStrongObjectsMapTable];
#if FDM_HAS_UIKIT
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidEnterBackground:)
                                                     name:UIApplicationDidEnterBackgroundNotification object:nil];
#endif
    }
    return self;
}

- (void)applicationDidEnterBackground:(NSNotification *)note {
    // Request context is process-local by design: an in-flight anonymous GET keeps running in its
    // own session, but cookies/headers for not-yet-started intents must not outlive the process.
    [self pruneExpired:YES];
}

- (void)sync:(dispatch_block_t)block {
    if (dispatch_get_specific(FDMIntentRegistryQueueKey) == (__bridge void *)self) block();
    else dispatch_sync(_queue, block);
}

- (void)pruneExpired:(BOOL)aggressive {
    // Called on _queue. 30 minutes is long enough for a slow filename probe, short enough that a
    // stale credential is not reused for a later unrelated download.
    NSTimeInterval limit = aggressive ? 60 : 1800;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSMutableArray *dead = [NSMutableArray array];
    for (NSString *intentID in _order) {
        NSDictionary *record = _records[intentID];
        if (!record || now - [record[@"time"] doubleValue] > limit) [dead addObject:intentID];
    }
    for (NSString *intentID in dead) [_records removeObjectForKey:intentID];
    if (dead.count) [_order removeObjectsInArray:dead];
}

- (void)registerRequest:(NSURLRequest *)request
                  tabID:(NSString *)tabID
     navigationGeneration:(unsigned long long)generation
             sourceOrigin:(NSString *)sourceOrigin
        suggestedFilename:(NSString *)filename
                dataStore:(id)dataStore
            userInitiated:(BOOL)userInitiated {
    if (!request.URL || !tabID.length) return;
    NSMutableURLRequest *copy = [request mutableCopy];
    NSString *intentID = NSUUID.UUID.UUIDString;
    NSString *method = (request.HTTPMethod ?: @"GET").uppercaseString;
    BOOL replayable = [method isEqual:@"GET"] && !request.HTTPBody && request.HTTPBodyStream == nil;
    NSString *targetOrigin = FDMOriginForURL(request.URL);
    FDMDownloadIntent *intent = [[FDMDownloadIntent alloc] init];
    intent.intentID = intentID;
    intent.tabID = tabID;
    intent.navigationGeneration = generation;
    intent.sourceOrigin = FDMNormalizedOrigin(sourceOrigin);
    intent.targetOrigin = targetOrigin;
    intent.method = method;
    intent.replayable = replayable;
    intent.url = copy.URL.absoluteString;
    intent.suggestedFilename = filename;
    intent.mime = request.allHTTPHeaderFields[@"Accept"];
    intent.expectedLength = -1;
    intent.userInitiated = userInitiated;
    intent.captureTime = NSDate.date.timeIntervalSince1970;
    intent.policyRevision = FDMSitePolicyStore.shared.revision;
    BOOL secretHeader = NO;
    for (NSString *name in request.allHTTPHeaderFields) if (FDMIsSecretHeader(name)) secretHeader = YES;
    BOOL hasCookies = [self request:request carriesCookiesForDataStore:dataStore];
    BOOL sameOrigin = intent.sourceOrigin && [intent.sourceOrigin isEqual:targetOrigin];
    if (!replayable) {
        intent.transport = FDMTransportWebKitDownload;
        intent.transportRefusal = @"POST 或带请求体的下载必须保留原浏览器请求，改由 WebKit 通道处理";
    } else if (secretHeader || hasCookies || !sameOrigin) {
        intent.transport = FDMTransportCredentialedSession;
        intent.transportRefusal = nil;
    } else {
        intent.transport = FDMTransportAnonymousBackground;
        intent.transportRefusal = nil;
    }
    NSMutableDictionary *record = [@{@"intent": intent, @"request": copy, @"time": @(intent.captureTime),
                                     @"tabID": tabID, @"generation": @(generation)} mutableCopy];
    if (dataStore) record[@"dataStore"] = dataStore;
    [self sync:^{
        [self pruneExpired:NO];
        self->_records[intentID] = record;
        [self->_order addObject:intentID];
        // Bounded: only the most recent intents can still be claimed by a download response.
        while (self->_order.count > 64) {
            NSString *oldest = self->_order.firstObject;
            [self->_order removeObjectAtIndex:0];
            [self->_records removeObjectForKey:oldest];
        }
    }];
}

- (BOOL)request:(NSURLRequest *)request carriesCookiesForDataStore:(id)dataStore {
    // A Cookie header the page itself set means the request is credentialed regardless of the store.
    for (NSString *name in request.allHTTPHeaderFields) if ([name.lowercaseString isEqual:@"cookie"]) return YES;
    return dataStore != nil;
}

- (FDMDownloadIntent *)takeIntentMatchingURL:(NSURL *)url {
    if (!url) return nil;
    __block FDMDownloadIntent *match = nil;
    NSString *absolute = url.absoluteString;
    [self sync:^{
        for (NSString *intentID in self->_order.reverseObjectEnumerator) {
            NSDictionary *record = self->_records[intentID];
            FDMDownloadIntent *intent = record[@"intent"];
            if (!intent) continue;
            if (![intent.url isEqual:absolute]) continue;
            match = intent;
            break;
        }
    }];
    return match;
}

- (NSURLRequest *)requestForIntent:(NSString *)intentID {
    if (!intentID.length) return nil;
    __block NSURLRequest *request;
    [self sync:^{
        NSDictionary *record = self->_records[intentID];
        NSURLRequest *stored = record[@"request"];
        request = [stored copy];
    }];
    return request;
}

- (void)cookiesForIntent:(NSString *)intentID completion:(void (^)(NSArray<NSHTTPCookie *> *))completion {
    if (!completion) return;
#if FDM_HAS_UIKIT
    __block id dataStore;
    [self sync:^{ dataStore = self->_records[intentID][@"dataStore"]; }];
    WKHTTPCookieStore *store = nil;
    if ([dataStore isKindOfClass:WKWebsiteDataStore.class]) store = ((WKWebsiteDataStore *)dataStore).httpCookieStore;
    if (!store) { completion(@[]); return; }
    [store getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        NSURLRequest *request = [self requestForIntent:intentID];
        NSURL *url = request.URL;
        NSMutableArray *accepted = [NSMutableArray array];
        for (NSHTTPCookie *cookie in cookies) if ([self cookie:cookie appliesToURL:url]) [accepted addObject:cookie];
        completion([accepted copy]);
    }];
#else
    completion(@[]);
#endif
}

- (BOOL)cookie:(NSHTTPCookie *)cookie appliesToURL:(NSURL *)url {
    if (!cookie || !url.host.length) return NO;
    NSString *host = url.host.lowercaseString;
    NSString *domain = cookie.domain.lowercaseString;
    if (!domain.length) return NO;
    if ([cookie.domain hasPrefix:@"."]) {
        // RFC6265 domain match: the host must be the domain or a subdomain of it.
        NSString *bare = [domain substringFromIndex:1];
        if (!([host isEqual:bare] || [host hasSuffix:[@"." stringByAppendingString:bare]])) return NO;
    } else if (![host isEqual:domain]) {
        return NO;
    }
    NSString *path = cookie.path.length ? cookie.path : @"/";
    if (![url.path hasPrefix:path]) return NO;
    if (cookie.isSecure && ![url.scheme.lowercaseString isEqual:@"https"]) return NO;
    if (cookie.expiresDate && [cookie.expiresDate timeIntervalSinceNow] < 0) return NO;
    return YES;
}

- (void)invalidateTab:(NSString *)tabID {
    if (!tabID.length) return;
    [self sync:^{
        NSMutableArray *dead = [NSMutableArray array];
        for (NSString *intentID in self->_order) {
            if ([self->_records[intentID][@"tabID"] isEqual:tabID]) [dead addObject:intentID];
        }
        for (NSString *intentID in dead) [self->_records removeObjectForKey:intentID];
        if (dead.count) [self->_order removeObjectsInArray:dead];
    }];
}

- (void)invalidateAll {
    [self sync:^{
        [self->_records removeAllObjects];
        [self->_order removeAllObjects];
    }];
}

- (NSUInteger)count {
    __block NSUInteger value = 0;
    [self sync:^{ value = self->_records.count; }];
    return value;
}
@end

#pragma mark - credentialed transport

@interface FDMCredentialedTransport () <NSURLSessionDataDelegate, NSURLSessionTaskDelegate>
@end

@implementation FDMCredentialedTransport {
    FDMDownloadIntent *_intent;
    NSURLRequest *_request;
    dispatch_queue_t _queue;
    NSURLSession *_session;
    NSURLSessionDataTask *_task;
    NSMutableData *_body;
    void (^_progress)(int64_t, int64_t);
    void (^_completion)(NSURL *, NSHTTPURLResponse *, NSError *);
    BOOL _finished;
    NSURL *_temporaryFile;
}

- (instancetype)initWithIntent:(FDMDownloadIntent *)intent request:(NSURLRequest *)request queue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _intent = intent;
        _request = [request copy];
        _queue = queue;
        _body = [NSMutableData data];
    }
    return self;
}

- (void)startWithProgress:(void (^)(int64_t, int64_t))progress
               completion:(void (^)(NSURL *, NSHTTPURLResponse *, NSError *))completion {
    _progress = [progress copy];
    _completion = [completion copy];
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    // A per-intent ephemeral store keeps this download's cookies away from every other download.
    configuration.HTTPCookieStorage = nil;
    configuration.URLCache = nil;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    configuration.timeoutIntervalForRequest = 60;
    configuration.timeoutIntervalForResource = 3600;
    NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
    delegateQueue.maxConcurrentOperationCount = 1;
    _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:delegateQueue];
    _task = [_session dataTaskWithRequest:_request];
    [_task resume];
    FDMLog(@"transport start kind=%@ method=%@ origin=%@ headers=%@",
           FDMTransportName(_intent ? _intent.transport : FDMTransportCredentialedSession),
           _request.HTTPMethod ?: @"GET", FDMOriginForURL(_request.URL),
           FDMRedactedHeaderNames(_request.allHTTPHeaderFields));
}

- (void)cancel {
    [_task cancel];
}

- (void)finishWithError:(NSError *)error {
    if (_finished) return;
    _finished = YES;
    void (^completion)(NSURL *, NSHTTPURLResponse *, NSError *) = _completion;
    _completion = nil;
    _progress = nil;
    NSHTTPURLResponse *response = [_task.response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)_task.response : nil;
    NSURL *location = _temporaryFile;
    [_session finishTasksAndInvalidate];
    if (completion) completion(location, response, error);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
        willPerformHTTPRedirection:(NSHTTPURLResponse *)response
                        newRequest:(NSURLRequest *)request
                 completionHandler:(void (^)(NSURLRequest *))completionHandler {
    NSError *refusal = FDMRedirectRefusal(_request, request);
    if (refusal) {
        FDMLog(@"transport redirect refused: %@", refusal.localizedDescription);
        // nil cancels the redirect; the 3xx body arrives as a response and is then failed below.
        completionHandler(nil);
        dispatch_async(_queue, ^{
            [self cancel];
            [self finishWithError:refusal];
        });
        return;
    }
    completionHandler(request);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
    if (status < 200 || status >= 300) {
        completionHandler(NSURLSessionResponseCancel);
        NSError *error = [NSError errorWithDomain:@"FocusDM.Transport" code:status
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld：服务器未提供成功下载响应", (long)status]}];
        dispatch_async(_queue, ^{ [self finishWithError:error]; });
        return;
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    [_body appendData:data];
    int64_t received = (int64_t)_body.length;
    int64_t total = task.countOfBytesExpectedToReceive > 0 ? task.countOfBytesExpectedToReceive : -1;
    void (^progress)(int64_t, int64_t) = _progress;
    if (progress) dispatch_async(_queue, ^{ progress(received, total); });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (_finished) return;
    if (error) { dispatch_async(_queue, ^{ [self finishWithError:error]; }); return; }
    // The response body is held in memory by this transport; hand it to a task-owned file so the
    // caller can move it exactly like an NSURLSession download temporary file.
    NSString *directory = NSTemporaryDirectory();
    NSString *name = [NSString stringWithFormat:@"focusdm-intent-%@.part", _intent.intentID ?: NSUUID.UUID.UUIDString];
    NSString *path = [directory stringByAppendingPathComponent:name];
    NSError *writeError = nil;
    if (![_body writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
        dispatch_async(_queue, ^{ [self finishWithError:writeError]; });
        return;
    }
    _temporaryFile = [NSURL fileURLWithPath:path];
    dispatch_async(_queue, ^{ [self finishWithError:nil]; });
}
@end
