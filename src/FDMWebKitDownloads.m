#import "FDMWebKitDownloads.h"
#import "FDMEngine.h"
#import "FDMIntent.h"
#import "FDMPolicy.h"

// WKDownload is iOS 14.5+; on older systems this file degrades to a capability report.
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 140500
#import <WebKit/WebKit.h>
#define FDM_HAS_WKDOWNLOAD 1
#else
#define FDM_HAS_WKDOWNLOAD 0
#endif

#if FDM_HAS_WKDOWNLOAD
// WKDownloadDelegate is only available on iOS 14.5+, while the library targets iOS 14.0. Declaring
// conformance would be an availability error, so the delegate methods are plain instance methods and
// the delegate is assigned through `id`. WebKit only calls them on systems where they exist.
@interface FDMWebKitDownloads ()
@end
#else
@interface FDMWebKitDownloads ()
@end
#endif

@implementation FDMWebKitDownloads {
    NSMapTable<id, NSString *> *_keysByDownload;
    NSMutableDictionary<NSString *, id> *_downloadsByKey;
}

+ (instancetype)shared {
    static FDMWebKitDownloads *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[self alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _keysByDownload = [NSMapTable strongToStrongObjectsMapTable];
        _downloadsByKey = [NSMutableDictionary dictionary];
    }
    return self;
}

- (BOOL)supported {
#if FDM_HAS_WKDOWNLOAD
    if (@available(iOS 14.5, *)) return YES;
#endif
    return NO;
}

- (void)adoptDownload:(id)download intent:(id)intent tabID:(NSString *)tabID {
#if FDM_HAS_WKDOWNLOAD
    if (@available(iOS 14.5, *)) {
        if (![download isKindOfClass:WKDownload.class]) return;
        WKDownload *owned = (WKDownload *)download;
        // A WebKit download cannot be re-requested: its request context (POST body, one-time ticket,
        // cookies) only exists inside WebKit. The engine row therefore records the WebKit transport
        // and never offers an anonymous retry.
        NSString *key = [FDMEngine.shared registerWebKitDownload:owned intent:intent tabID:tabID];
        if (!key.length) return;
        @synchronized (self) {
            _downloadsByKey[key] = owned;
            [_keysByDownload setObject:key forKey:owned];
        }
        owned.delegate = (id)self;
        FDMLog(@"webkit download adopted id=%@ origin=%@ method=%@",
               key, FDMOriginForURL(owned.originalRequest.URL), owned.originalRequest.HTTPMethod ?: @"GET");
        // WKDownload exposes NSProgress; observe it rather than inventing a synthetic percentage.
        [owned.progress addObserver:self forKeyPath:@"completedUnitCount" options:NSKeyValueObservingOptionNew context:(__bridge void *)owned];
        [owned.progress addObserver:self forKeyPath:@"totalUnitCount" options:NSKeyValueObservingOptionNew context:(__bridge void *)owned];
    }
#endif
}

- (void)cancelKey:(NSString *)key {
    id download = nil;
    @synchronized (self) { download = _downloadsByKey[key]; }
#if FDM_HAS_WKDOWNLOAD
    if (@available(iOS 14.5, *)) {
        if ([download isKindOfClass:WKDownload.class]) [(WKDownload *)download cancel:^(NSData *resumeData) {}];
    }
#endif
    (void)download;
}

#if FDM_HAS_WKDOWNLOAD

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    WKDownload *download = (__bridge WKDownload *)context;
    NSString *key = [self keyForDownload:download];
    if (!key.length) return;
    NSProgress *progress = download.progress;
    [FDMEngine.shared applyWebKitProgressKey:key received:progress.completedUnitCount total:progress.totalUnitCount];
}

- (void)download:(WKDownload *)download
    decideDestinationUsingResponse:(NSURLResponse *)response
    suggestedFilename:(NSString *)suggestedFilename
    completionHandler:(void (^)(NSURL * _Nullable))completionHandler {
    NSString *key = [self keyForDownload:download];
    NSString *destination = key.length ? [FDMEngine.shared destinationForWebKitDownloadKey:key
                                                                        suggestedFilename:suggestedFilename
                                                                                 response:response] : nil;
    if (!destination.length) {
        // Declining the destination cancels the download; the engine records the honest reason.
        if (key.length) [FDMEngine.shared webKitDownloadKey:key failedWithMessage:@"无法为网页下载创建保存位置" deleted:NO];
        completionHandler(nil);
        return;
    }
    completionHandler([NSURL fileURLWithPath:destination]);
}

- (void)download:(WKDownload *)download didFailWithError:(NSError *)error resumeData:(NSData *)resumeData {
    NSString *key = [self keyForDownload:download];
    // WK resumeData is only usable by WKWebView.resumeDownload; it is never mixed with URLSession data
    // and never persisted here, because the request context that produced it is gone.
    if (key.length) [FDMEngine.shared webKitDownloadKey:key failedWithMessage:error.localizedDescription ?: @"网页下载失败" deleted:NO];
    [self forget:download];
}

- (void)downloadDidFinish:(WKDownload *)download {
    NSString *key = [self keyForDownload:download];
    if (key.length) [FDMEngine.shared webKitDownloadDidFinishKey:key];
    [self forget:download];
}

- (void)download:(WKDownload *)download
    didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
    completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable))completionHandler {
    // Never silently trust a server certificate: hand the decision back to the system default.
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}

- (void)download:(WKDownload *)download
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response
    newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(WKDownloadRedirectPolicy))completionHandler API_AVAILABLE(ios(15.0)) {
    // WKDownload can only allow or cancel here; it cannot rewrite the request.
    NSError *refusal = FDMRedirectRefusal(download.originalRequest, request);
    if (refusal) {
        FDMLog(@"webkit redirect refused: %@", refusal.localizedDescription);
        completionHandler(WKDownloadRedirectPolicyCancel);
        return;
    }
    completionHandler(WKDownloadRedirectPolicyAllow);
}

- (NSString *)keyForDownload:(WKDownload *)download {
    @synchronized (self) { return [_keysByDownload objectForKey:download]; }
}

- (void)forget:(WKDownload *)download {
    @try {
        [download.progress removeObserver:self forKeyPath:@"completedUnitCount" context:(__bridge void *)download];
        [download.progress removeObserver:self forKeyPath:@"totalUnitCount" context:(__bridge void *)download];
    } @catch (NSException *exception) { FDMLog(@"webkit progress observer cleanup skipped"); }
    @synchronized (self) {
        NSString *key = [_keysByDownload objectForKey:download];
        if (key) [_downloadsByKey removeObjectForKey:key];
        [_keysByDownload removeObjectForKey:download];
    }
}

#else

- (void)download:(id)download decideDestinationUsingResponse:(id)response suggestedFilename:(NSString *)name completionHandler:(void (^)(id))completionHandler {}
- (void)download:(id)download didFailWithError:(id)error resumeData:(id)resumeData {}
- (void)downloadDidFinish:(id)download {}

#endif
@end
