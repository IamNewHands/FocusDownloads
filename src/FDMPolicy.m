#import "FDMPolicy.h"
#import "FDMJSON.h"

NSString *const FDMSitePolicyDidChangeNotification = @"FDMSitePolicyDidChange";

NSString *const FDMPolicyContentMode = @"preferredContentMode";
NSString *const FDMPolicyUserAgent = @"customUserAgent";
NSString *const FDMPolicyPageZoom = @"pageZoom";
NSString *const FDMPolicyReader = @"reader";
NSString *const FDMPolicyContentBlocking = @"contentBlocking";
NSString *const FDMPolicyPageJavaScript = @"pageJavaScript";
NSString *const FDMPolicyUserScripts = @"userScripts";
NSString *const FDMPolicyExternalApps = @"externalApps";
NSString *const FDMPolicyCamera = @"camera";
NSString *const FDMPolicyMicrophone = @"microphone";
NSString *const FDMPolicyInherit = @"inherit";

static const unsigned long long FDMPolicyMaxRevision = 9007199254740991ULL;  // 2^53-1
static const NSUInteger FDMPolicyMaxOrigins = 5000;
static const NSUInteger FDMPolicyMaxOriginLength = 512;
static const NSUInteger FDMPolicyMaxUserAgentLength = 1024;

NSArray<NSString *> *FDMPolicyFieldKeys(void) {
    static NSArray *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[FDMPolicyContentMode, FDMPolicyUserAgent, FDMPolicyPageZoom, FDMPolicyReader,
                 FDMPolicyContentBlocking, FDMPolicyPageJavaScript, FDMPolicyUserScripts,
                 FDMPolicyExternalApps, FDMPolicyCamera, FDMPolicyMicrophone];
    });
    return keys;
}

static NSError *FDMPolicyError(NSString *message) {
    return [NSError errorWithDomain:@"FocusDM.Policy" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSDictionary<NSString *, NSArray<NSString *> *> *FDMPolicyEnumerations(void) {
    static NSDictionary *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            FDMPolicyContentMode: @[@"desktop", @"mobile"],
            FDMPolicyReader: @[@"auto", @"off"],
            FDMPolicyContentBlocking: @[@"on", @"off"],
            FDMPolicyPageJavaScript: @[@"on", @"off"],
            FDMPolicyUserScripts: @[@"on", @"off"],
            FDMPolicyExternalApps: @[@"ask", @"allow", @"deny"],
            FDMPolicyCamera: @[@"ask", @"allow", @"deny"],
            FDMPolicyMicrophone: @[@"ask", @"allow", @"deny"],
        };
    });
    return table;
}

#pragma mark - origin

NSString *FDMNormalizedOrigin(NSString *urlOrOrigin) {
    if (![urlOrOrigin isKindOfClass:NSString.class]) return nil;
    NSString *text = [urlOrOrigin stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length || text.length > 2048) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithString:text];
    if (!components) return nil;
    NSString *scheme = components.scheme.lowercaseString;
    if (!([scheme isEqual:@"http"] || [scheme isEqual:@"https"])) return nil;
    if (components.user.length || components.password.length) return nil;
    NSString *host = components.URL.host.lowercaseString;
    if (!host.length) return nil;
    if ([host rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
        [host containsString:@" "] || [host containsString:@"/"] || [host containsString:@"%"] ) return nil;
    if ([host containsString:@":"] && ![host hasPrefix:@"["]) host = [NSString stringWithFormat:@"[%@]", host];
    NSNumber *port = components.port;
    NSInteger effective = port ? port.integerValue : ([scheme isEqual:@"https"] ? 443 : 80);
    if (effective <= 0 || effective > 65535) return nil;
    NSString *normalized = [NSString stringWithFormat:@"%@://%@:%ld", scheme, host, (long)effective];
    if (normalized.length > FDMPolicyMaxOriginLength) return nil;
    return normalized;
}

NSString *FDMOriginForURL(NSURL *url) {
    if (![url isKindOfClass:NSURL.class]) return nil;
    return FDMNormalizedOrigin(url.absoluteString);
}

#pragma mark - validation

static BOOL FDMPolicyValidEnum(id value, NSString *field) {
    NSArray *allowed = FDMPolicyEnumerations()[field];
    return [value isKindOfClass:NSString.class] && [allowed containsObject:value];
}

NSDictionary *FDMSitePolicyValidateEntry(id payload, NSError **error) {
    NSDictionary *input = FDMJSONObjectValue(payload);
    if (!input) { if (error) *error = FDMPolicyError(@"站点设置必须是对象"); return nil; }
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *key in input) {
        if (![FDMPolicyFieldKeys() containsObject:key]) {
            if (error) *error = FDMPolicyError([NSString stringWithFormat:@"未知站点设置字段：%@", key]);
            return nil;
        }
        id value = input[key];
        if ([value isKindOfClass:NSString.class] && [value isEqual:FDMPolicyInherit]) continue;
        if (value == NSNull.null) {
            // Only the UA override has a meaningful "remove" sentinel.
            if (![key isEqual:FDMPolicyUserAgent]) {
                if (error) *error = FDMPolicyError([NSString stringWithFormat:@"%@ 不接受 null", key]);
                return nil;
            }
            result[key] = NSNull.null;
            continue;
        }
        if ([key isEqual:FDMPolicyUserAgent]) {
            NSString *agent = FDMJSONStringValue(value);
            if (!agent.length || agent.length > FDMPolicyMaxUserAgentLength) {
                if (error) *error = FDMPolicyError(@"自定义 UA 必须是 1–1024 字符的字符串");
                return nil;
            }
            if ([agent rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) {
                if (error) *error = FDMPolicyError(@"自定义 UA 不能包含换行");
                return nil;
            }
            result[key] = agent;
            continue;
        }
        if ([key isEqual:FDMPolicyPageZoom]) {
            double zoom = 0;
            if (!FDMJSONFiniteDouble(value, &zoom) || zoom < 0.5 || zoom > 3.0) {
                if (error) *error = FDMPolicyError(@"页面缩放必须是 0.5–3.0 之间的有限数值");
                return nil;
            }
            result[key] = @(zoom);
            continue;
        }
        if (!FDMPolicyValidEnum(value, key)) {
            if (error) *error = FDMPolicyError([NSString stringWithFormat:@"%@ 的取值不在允许范围", key]);
            return nil;
        }
        result[key] = value;
    }
    return [result copy];
}

NSDictionary *FDMSitePolicyEmptyDocument(void) {
    return @{@"schemaVersion": @1, @"revision": @0, @"origins": @{}};
}

NSDictionary *FDMSitePolicyValidateDocument(id payload, NSError **error) {
    NSDictionary *input = FDMJSONObjectValue(payload);
    if (!input) { if (error) *error = FDMPolicyError(@"站点规则文件必须是对象"); return nil; }
    for (NSString *key in input) {
        if (![@[@"schemaVersion", @"revision", @"origins"] containsObject:key]) {
            if (error) *error = FDMPolicyError([NSString stringWithFormat:@"未知顶层字段：%@", key]);
            return nil;
        }
    }
    unsigned long long schema = 0;
    if (!FDMJSONNonNegativeInteger(input[@"schemaVersion"], FDMPolicyMaxRevision, &schema) || schema != 1) {
        if (error) *error = FDMPolicyError(@"schemaVersion 必须是受支持的版本 1");
        return nil;
    }
    unsigned long long revision = 0;
    if (!FDMJSONNonNegativeInteger(input[@"revision"], FDMPolicyMaxRevision, &revision)) {
        if (error) *error = FDMPolicyError(@"revision 必须是非负整数");
        return nil;
    }
    NSDictionary *origins = FDMJSONObjectValue(input[@"origins"]);
    if (!origins) { if (error) *error = FDMPolicyError(@"origins 必须是对象"); return nil; }
    if (origins.count > FDMPolicyMaxOrigins) { if (error) *error = FDMPolicyError(@"站点规则数量超出上限"); return nil; }
    NSMutableDictionary *normalized = [NSMutableDictionary dictionary];
    for (NSString *rawKey in origins) {
        NSURLComponents *parts = [NSURLComponents componentsWithString:rawKey];
        if (!parts || (parts.path.length && ![parts.path isEqual:@"/"]) || parts.query.length || parts.fragment.length) {
            if (error) *error = FDMPolicyError(@"站点规则键必须是origin，不能包含路径、查询或片段"); return nil;
        }
        NSString *origin = FDMNormalizedOrigin(rawKey);
        if (!origin) { if (error) *error = FDMPolicyError([NSString stringWithFormat:@"站点 origin 无效：%@", rawKey]); return nil; }
        if (normalized[origin]) {
            // Two different spellings that normalize to one origin must not silently overwrite.
            if (error) *error = FDMPolicyError([NSString stringWithFormat:@"多个站点键规范化后重复：%@", origin]);
            return nil;
        }
        NSDictionary *entry = FDMSitePolicyValidateEntry(origins[rawKey], error);
        if (!entry) return nil;
        normalized[origin] = entry;
    }
    return @{@"schemaVersion": @1, @"revision": @(revision), @"origins": [normalized copy]};
}

#pragma mark - resolution

NSDictionary *FDMPolicyGlobalBaseline(void) {
    // Focus keeps the global UA in UserAgentManager; nil means "WebKit default".
    id manager = nil;
    Class cls = NSClassFromString(@"UserAgentManager");
    SEL shared = NSSelectorFromString(@"shareInstance");
    if (cls && [cls respondsToSelector:shared]) manager = ((id (*)(id, SEL))objc_msgSend)(cls, shared);
    SEL current = NSSelectorFromString(@"getCurrentUserAgent");
    NSString *agent = nil;
    if (manager && [manager respondsToSelector:current]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(manager, current);
        if ([value isKindOfClass:NSString.class] && [value length]) agent = value;
    }
    id preference = nil;
    Class preferences = NSClassFromString(@"PreferenceManager");
    if ([preferences respondsToSelector:shared]) {
        id owner = ((id (*)(id, SEL))objc_msgSend)(preferences, shared); preference = FDMValue(owner, @"items");
    }
    return @{FDMPolicyUserAgent: agent ?: NSNull.null,
        FDMPolicyReader: [FDMValue(preference, @"enabledReader") boolValue] ? @"auto" : @"off",
        FDMPolicyContentBlocking: [FDMValue(preference, @"enabledAdblock") boolValue] ? @"on" : @"off",
        FDMPolicyPageJavaScript: @"on", FDMPolicyUserScripts: @"on", FDMPolicyExternalApps: @"ask",
        FDMPolicyCamera: @"ask", FDMPolicyMicrophone: @"ask"};
}

NSString *FDMPolicyEffectiveValue(NSDictionary *entry, NSString *field, NSDictionary *global) {
    id value = entry[field];
    if (!value || value == NSNull.null) value = global[field];
    if (!value) return nil;
    if (value == NSNull.null) return nil;
    if ([value isKindOfClass:NSNumber.class]) return [value stringValue];
    return [value isKindOfClass:NSString.class] ? value : nil;
}

NSDictionary *FDMPolicyEffectiveSnapshot(NSDictionary *entry, NSDictionary *global) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *field in FDMPolicyFieldKeys()) {
        id value = entry[field];
        BOOL overridden = value != nil;
        if (!value) value = global[field];
        result[field] = value ?: NSNull.null;
        result[[field stringByAppendingString:@"Overridden"]] = @(overridden);
    }
    return result;
}

NSArray<NSString *> *FDMPolicyOverriddenFields(NSDictionary *entry) {
    NSMutableArray *fields = [NSMutableArray array];
    for (NSString *field in FDMPolicyFieldKeys()) if (entry[field]) [fields addObject:field];
    return fields;
}

#pragma mark - store

@implementation FDMSitePolicyStore {
    dispatch_queue_t _queue;
    NSMutableDictionary *_document;
    NSString *_path;
    BOOL _writable;
    NSDictionary *_recoveryPublishedBefore;
}

+ (instancetype)shared {
    static FDMSitePolicyStore *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ store = [[self alloc] init]; });
    return store;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("FocusDM.site-policy", DISPATCH_QUEUE_SERIAL);
        _path = [FDMDirectory(@"FocusDM") stringByAppendingPathComponent:@"site-policies.json"];
        _document = [FDMSitePolicyEmptyDocument() mutableCopy];
        _writable = YES;
        NSData *data = [NSData dataWithContentsOfFile:_path];
        if (data.length) {
            NSError *error = nil;
            id root = FDMJSONParseData(data, &error);
            NSDictionary *validated = root ? FDMSitePolicyValidateDocument(root, &error) : nil;
            if (validated) _document = [validated mutableCopy];
            else {
                // Never rewrite a file we could not understand: the user's rules stay on disk.
                _writable = NO;
                FDMLog(@"site policy unreadable; original file preserved: %@", error.localizedDescription);
            }
        } else if ([[NSFileManager defaultManager] fileExistsAtPath:_path]) {
            _writable = NO;
            FDMLog(@"site policy empty or unreadable; original file preserved");
        }
    }
    return self;
}

- (BOOL)writable {
    __block BOOL value;
    dispatch_sync(_queue, ^{ value = self->_writable; });
    return value;
}

- (NSDictionary *)snapshot {
    __block NSDictionary *value;
    dispatch_sync(_queue, ^{ value = _recoveryPublishedBefore ?: @{@"schemaVersion": @1,
        @"revision": _document[@"revision"] ?: @0, @"origins": [_document[@"origins"] copy] ?: @{}}; });
    return value;
}
- (NSDictionary *)transactionSnapshot {
    __block NSDictionary *value;
    dispatch_sync(_queue, ^{ value = @{@"schemaVersion": @1, @"revision": _document[@"revision"] ?: @0,
        @"origins": [_document[@"origins"] copy] ?: @{}}; }); return value;
}
- (void)beginRecoveryPublication {
    dispatch_sync(_queue, ^{ if (!_recoveryPublishedBefore) _recoveryPublishedBefore = @{@"schemaVersion": @1,
        @"revision": _document[@"revision"] ?: @0, @"origins": [_document[@"origins"] copy] ?: @{}}; });
}
- (void)finishRecoveryPublication:(BOOL)publish {
    if (!publish) return; // Failed rollback keeps the before snapshot protected until restart/recovery.
    dispatch_sync(_queue, ^{ _recoveryPublishedBefore = nil; });
}

- (unsigned long long)revision {
    __block unsigned long long value = 0;
    dispatch_sync(_queue, ^{ value = [self->_document[@"revision"] unsignedLongLongValue]; });
    return value;
}

- (NSDictionary *)entryForOrigin:(NSString *)origin {
    if (!origin.length) return nil;
    __block NSDictionary *value;
    dispatch_sync(_queue, ^{ value = (self->_recoveryPublishedBefore ?: self->_document)[@"origins"][origin]; });
    return value;
}

- (BOOL)persist:(NSDictionary *)document error:(NSError **)error {
    if (!_writable) {
        if (error) *error = FDMPolicyError(@"站点规则文件格式未知或损坏；原文件保留，暂不写入");
        return NO;
    }
    NSError *encode = nil;
    NSData *data = FDMJSONCanonicalData(document, &encode);
    if (!data) { if (error) *error = encode; return NO; }
    return [data writeToFile:_path options:NSDataWritingAtomic error:error];
}

- (BOOL)commitDocument:(NSDictionary *)document error:(NSError **)error {
    NSDictionary *validated = FDMSitePolicyValidateDocument(document, error);
    if (!validated) return NO;
    if (![self persist:validated error:error]) return NO;
    _document = [validated mutableCopy];
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:FDMSitePolicyDidChangeNotification object:nil];
    });
    return YES;
}

- (BOOL)setEntry:(NSDictionary *)entry origin:(NSString *)origin error:(NSError **)error {
    NSString *normalized = FDMNormalizedOrigin(origin);
    if (!normalized) { if (error) *error = FDMPolicyError(@"站点 origin 无效"); return NO; }
    NSDictionary *validatedEntry = entry ? FDMSitePolicyValidateEntry(entry, error) : nil;
    if (entry && !validatedEntry) return NO;
    __block BOOL ok = NO;
    __block NSError *failure;
    dispatch_sync(_queue, ^{
        NSMutableDictionary *origins = [self->_document[@"origins"] mutableCopy] ?: [NSMutableDictionary dictionary];
        if (validatedEntry) origins[normalized] = validatedEntry;
        else [origins removeObjectForKey:normalized];
        if (origins.count > FDMPolicyMaxOrigins) { failure = FDMPolicyError(@"站点规则数量超出上限"); return; }
        unsigned long long next = [self->_document[@"revision"] unsignedLongLongValue] + 1;
        ok = [self commitDocument:@{@"schemaVersion": @1, @"revision": @(next), @"origins": origins} error:&failure];
    });
    if (!ok && error) *error = failure;
    return ok;
}

- (BOOL)resetOrigin:(NSString *)origin error:(NSError **)error {
    return [self setEntry:nil origin:origin error:error];
}

- (BOOL)replaceDocument:(NSDictionary *)validatedDocument expectedRevision:(unsigned long long)expected error:(NSError **)error {
    NSDictionary *validated = FDMSitePolicyValidateDocument(validatedDocument, error);
    if (!validated) return NO;
    __block BOOL ok = NO;
    __block NSError *failure;
    dispatch_sync(_queue, ^{
        if ([self->_document[@"revision"] unsignedLongLongValue] != expected) {
            failure = FDMPolicyError(@"站点规则已被修改，请重新预览后再导入");
            return;
        }
        NSMutableDictionary *next = [validated mutableCopy];
        next[@"revision"] = @(expected + 1);
        ok = [self commitDocument:next error:&failure];
    });
    if (!ok && error) *error = failure;
    return ok;
}
- (BOOL)restoreDocument:(NSDictionary *)document publish:(BOOL)publish error:(NSError **)error {
    NSDictionary *validated = FDMSitePolicyValidateDocument(document, error);
    if (!validated) return NO;
    __block BOOL ok = NO; __block NSError *failure = nil;
    dispatch_sync(_queue, ^{
        if (![self persist:validated error:&failure]) return;
        _document = [validated mutableCopy]; ok = YES;
    });
    if (!ok && error) *error = failure;
    if (ok && publish) dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:FDMSitePolicyDidChangeNotification object:nil];
    });
    return ok;
}
@end

#pragma mark - temporary enhancement

@implementation FDMTemporaryEnhancementOff {
    NSMapTable<id, NSNumber *> *_states;
    dispatch_queue_t _queue;
}

+ (instancetype)shared {
    static FDMTemporaryEnhancementOff *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[self alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _states = [NSMapTable weakToStrongObjectsMapTable];
        _queue = dispatch_queue_create("FocusDM.temporary-off", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)setOff:(BOOL)off forObject:(id)object {
    if (!object) return;
    dispatch_async(_queue, ^{
        if (off) [self->_states setObject:@YES forKey:object];
        else [self->_states removeObjectForKey:object];
    });
}

- (BOOL)isOffForObject:(id)object {
    if (!object) return NO;
    __block BOOL value = NO;
    dispatch_sync(_queue, ^{ value = [self->_states objectForKey:object] != nil; });
    return value;
}

- (void)clearForObject:(id)object {
    if (!object) return;
    dispatch_sync(_queue, ^{
        [self->_states removeObjectForKey:object];
    });
}
@end
