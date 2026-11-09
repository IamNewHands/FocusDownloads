#import "FDMIntent.h"
#import "FDMPolicy.h"

BOOL FDMRequestCanUseAnonymousBackground(NSURLRequest *request) {
    if (![request isKindOfClass:NSURLRequest.class] || !FDMValidatedURL(request.URL.absoluteString, NULL)) return NO;
    if (![(request.HTTPMethod ?: @"GET").uppercaseString isEqual:@"GET"] || request.HTTPBody || request.HTTPBodyStream) return NO;
    NSURLComponents *parts = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
    // Query/fragment may be a single-use ticket. Never guess which query names are harmless.
    if (parts.query.length || parts.fragment.length) return NO;
    for (NSString *name in request.allHTTPHeaderFields) {
        if (![@[@"accept", @"accept-language", @"user-agent", @"range", @"if-range"] containsObject:name.lowercaseString]) return NO;
    }
    return YES;
}
NSString *FDMDownloadPublicURL(NSURL *url) { return FDMOriginForURL(url) ?: @"网页生成资源"; }
NSError *FDMRedirectRefusal(NSURLRequest *original, NSURLRequest *redirect) {
    NSString *from = FDMOriginForURL(original.URL), *to = FDMOriginForURL(redirect.URL);
    if (!from || !to) return FDMError(@"重定向地址无效，已停止下载");
    if ([from isEqual:to]) return nil;
    // This predicate is for the credentialed/WebKit routes, not the background session. Those routes
    // cannot rewrite WK requests, and even an originalRequest without visible Cookie may carry one.
    return FDMError(@"下载跨站重定向已停止，以保护来源站点的登录信息");
}

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
@property (nonatomic) BOOL persistentContext;
@property (nonatomic, copy, nullable) NSString *transportRefusal;
@end
@implementation FDMDownloadIntent
- (instancetype)initWithRequest:(NSURLRequest *)request tabID:(NSString *)tabID
    generation:(unsigned long long)generation sourceOrigin:(NSString *)sourceOrigin
    transport:(FDMTransportKind)transport dataStore:(id)dataStore
    userInitiated:(BOOL)userInitiated policyRevision:(unsigned long long)policyRevision {
    if ((self = [super init])) {
        _intentID = NSUUID.UUID.UUIDString; _tabID = [tabID copy]; _navigationGeneration = generation;
        _sourceOrigin = FDMNormalizedOrigin(sourceOrigin); _targetOrigin = FDMOriginForURL(request.URL);
        _url = FDMDownloadPublicURL(request.URL); _method = [(request.HTTPMethod ?: @"GET").uppercaseString copy];
        _replayable = [_method isEqual:@"GET"] && !request.HTTPBody && !request.HTTPBodyStream;
        _transport = transport; _userInitiated = userInitiated; _policyRevision = policyRevision;
        _captureTime = NSDate.date.timeIntervalSince1970; _expectedLength = -1;
        // Call the evidenced public isPersistent selector only; no assumed profile/suite fields.
        if (dataStore && [dataStore respondsToSelector:NSSelectorFromString(@"isPersistent")])
            _persistentContext = ((BOOL (*)(id, SEL))objc_msgSend)(dataStore, NSSelectorFromString(@"isPersistent"));
        else _persistentContext = dataStore == nil;
    }
    return self;
}
+ (BOOL)accessInstanceVariablesDirectly { return NO; }
- (NSString *)description { return [NSString stringWithFormat:@"<intent %@ %@ %@>", _intentID, _method, _targetOrigin ?: @"generated"]; }
@end

static const void *FDMRegistryQueueKey = &FDMRegistryQueueKey;
@implementation FDMIntentRegistry {
    dispatch_queue_t _queue;
    NSMutableDictionary<NSString *, NSDictionary *> *_records;
    NSMutableDictionary<NSString *, NSString *> *_currentByTab;
}
+ (instancetype)shared { static id shared; static dispatch_once_t once; dispatch_once(&once, ^{ shared = [self new]; }); return shared; }
- (instancetype)init {
    if ((self = [super init])) { _queue = dispatch_queue_create("FocusDM.intents", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_queue, FDMRegistryQueueKey, (__bridge void *)self, NULL);
        _records = [NSMutableDictionary dictionary]; _currentByTab = [NSMutableDictionary dictionary]; }
    return self;
}
- (void)sync:(dispatch_block_t)block { if (dispatch_get_specific(FDMRegistryQueueKey) == (__bridge void *)self) block(); else dispatch_sync(_queue, block); }
- (FDMDownloadIntent *)registerRequest:(NSURLRequest *)request tabID:(NSString *)tabID
    navigationGeneration:(unsigned long long)generation sourceOrigin:(NSString *)sourceOrigin
    suggestedFilename:(NSString *)filename dataStore:(id)dataStore userInitiated:(BOOL)userInitiated {
    FDMTransportKind route = dataStore ? FDMTransportWebKitDownload :
        (FDMRequestCanUseAnonymousBackground(request) ? FDMTransportAnonymousBackground : FDMTransportCredentialedSession);
    FDMDownloadIntent *intent = [[FDMDownloadIntent alloc] initWithRequest:request tabID:tabID generation:generation
        sourceOrigin:sourceOrigin transport:route dataStore:dataStore userInitiated:userInitiated policyRevision:FDMSitePolicyStore.shared.revision];
    intent.suggestedFilename = filename.length ? FDMSafeFilename(filename) : nil;
    [self sync:^{
        NSString *old = self->_currentByTab[tabID]; if (old) [self->_records removeObjectForKey:old];
        self->_currentByTab[tabID] = intent.intentID;
        self->_records[intent.intentID] = @{@"intent": intent, @"request": [request copy], @"claimed": @NO};
        // Unclaimed navigation records are bounded. This never evicts an adopted engine request.
        if (self->_records.count > 128) {
            NSArray *ids = self->_records.allKeys;
            for (NSString *identifier in ids) {
                if ([identifier isEqual:intent.intentID]) continue;
                FDMDownloadIntent *oldIntent = self->_records[identifier][@"intent"];
                [self->_currentByTab removeObjectForKey:oldIntent.tabID]; [self->_records removeObjectForKey:identifier];
                if (self->_records.count <= 128) break;
            }
        }
    }];
    return intent;
}
- (FDMDownloadIntent *)intentForTabID:(NSString *)tabID generation:(unsigned long long)generation {
    __block FDMDownloadIntent *result;
    [self sync:^{ FDMDownloadIntent *intent = self->_records[self->_currentByTab[tabID]][@"intent"];
        if (intent.navigationGeneration == generation && NSDate.date.timeIntervalSince1970 - intent.captureTime < 1800) result = intent; }];
    return result;
}
- (NSURLRequest *)requestForIntent:(NSString *)intentID {
    __block NSURLRequest *request; [self sync:^{ request = [self->_records[intentID][@"request"] copy]; }]; return request;
}
- (BOOL)claimIntent:(NSString *)intentID tabID:(NSString *)tabID generation:(unsigned long long)generation {
    __block BOOL claimed = NO;
    [self sync:^{ NSDictionary *record = self->_records[intentID]; FDMDownloadIntent *intent = record[@"intent"];
        if (!intent || [record[@"claimed"] boolValue] || ![intent.tabID isEqual:tabID] || intent.navigationGeneration != generation ||
            ![self->_currentByTab[tabID] isEqual:intentID]) return;
        NSMutableDictionary *next = [record mutableCopy]; next[@"claimed"] = @YES; self->_records[intentID] = [next copy]; claimed = YES; }];
    return claimed;
}
- (void)invalidateTab:(NSString *)tabID { if (!tabID.length) return; [self sync:^{ NSString *identifier = self->_currentByTab[tabID];
    if (identifier) [self->_records removeObjectForKey:identifier]; [self->_currentByTab removeObjectForKey:tabID]; }]; }
- (void)invalidateAll { [self sync:^{ [self->_records removeAllObjects]; [self->_currentByTab removeAllObjects]; }]; }
- (NSUInteger)count { __block NSUInteger count; [self sync:^{ count = self->_records.count; }]; return count; }
@end
