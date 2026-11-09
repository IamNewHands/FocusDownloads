#import "FDMWebKitDownloads.h"
#import "FDMEngine.h"
#import "FDMIntent.h"
#import <WebKit/WebKit.h>

// Execution owner only. Engine owns identities, records, resume eligibility and lifecycle.
@interface FDMWKAttempt : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *identity;
@property (nonatomic, strong) NSProgress *progress;
@end
@implementation FDMWKAttempt @end

@interface FDMWebKitDownloads () @end
@implementation FDMWebKitDownloads {
    NSMapTable<id, FDMWKAttempt *> *_attempts;
    NSMutableDictionary<NSString *, id> *_live;
}
+ (instancetype)shared { static id owner; static dispatch_once_t once; dispatch_once(&once, ^{ owner = [self new]; }); return owner; }
- (instancetype)init { if ((self = [super init])) { _attempts = [NSMapTable strongToStrongObjectsMapTable]; _live = [NSMutableDictionary dictionary]; } return self; }
- (BOOL)supported { if (@available(iOS 14.5, macOS 11.3, *)) return YES; return NO; }
- (void)adoptDownload:(id)download intent:(id)intent tabID:(NSString *)tabID {
    NSAssert(NSThread.isMainThread, @"WebKit execution must run on main");
    if (@available(iOS 14.5, macOS 11.3, *)) {
        if (![download isKindOfClass:WKDownload.class] || [_attempts objectForKey:download]) return;
        NSString *key = [FDMEngine.shared registerWebKitDownload:download intent:intent tabID:tabID];
        if (!key) { [(WKDownload *)download cancel:nil]; return; }
        [self bindDownload:download key:key identity:NSUUID.UUID.UUIDString];
    }
}
- (void)bindDownload:(id)object key:(NSString *)key identity:(NSString *)identity {
    if (@available(iOS 14.5, macOS 11.3, *)) {
        WKDownload *download = object;
        FDMWKAttempt *attempt = [FDMWKAttempt new]; attempt.key = key; attempt.identity = identity; attempt.progress = download.progress;
        [_attempts setObject:attempt forKey:download]; _live[key] = download; download.delegate = (id)self;
        __weak WKDownload *weakDownload = download;
        __weak WKWebView *weakWebView = download.webView;
        __weak typeof(self) weakSelf = self;
        [FDMEngine.shared bindWebKitKey:key transportIdentity:identity cancel:^(void (^done)(NSData *)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                WKDownload *current = weakDownload;
                if (!current) { done(nil); return; }
                [current cancel:^(NSData *data) { done(data); [weakSelf forget:current]; }];
            });
        } resume:^(NSData *data, NSString *nextIdentity, void (^done)(BOOL)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                WKWebView *source = weakWebView;
                if (!source) { done(NO); return; }
                [source resumeDownloadFromResumeData:data completionHandler:^(WKDownload *resumed) {
                    if (!resumed) { done(NO); return; }
                    [weakSelf bindDownload:resumed key:key identity:nextIdentity]; done(YES);
                }];
            });
        }];
        [attempt.progress addObserver:self forKeyPath:@"completedUnitCount" options:NSKeyValueObservingOptionNew context:NULL];
        [attempt.progress addObserver:self forKeyPath:@"totalUnitCount" options:NSKeyValueObservingOptionNew context:NULL];
    }
}
- (void)observeValueForKeyPath:(NSString *)path ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    for (id download in _attempts.keyEnumerator) {
        FDMWKAttempt *attempt = [_attempts objectForKey:download];
        if (attempt.progress != object) continue;
        [FDMEngine.shared applyWebKitProgressKey:attempt.key transportIdentity:attempt.identity
            received:attempt.progress.completedUnitCount total:attempt.progress.totalUnitCount]; return;
    }
}
- (void)download:(id)download decideDestinationUsingResponse:(NSURLResponse *)response suggestedFilename:(NSString *)filename
    completionHandler:(void (^)(NSURL *))completionHandler {
    FDMWKAttempt *attempt = [_attempts objectForKey:download];
    NSString *path = attempt ? [FDMEngine.shared destinationForWebKitDownloadKey:attempt.key transportIdentity:attempt.identity
        suggestedFilename:filename response:response] : nil;
    completionHandler(path ? [NSURL fileURLWithPath:path] : nil);
    if (!path && attempt) [FDMEngine.shared webKitDownloadKey:attempt.key transportIdentity:attempt.identity
        failedWithMessage:@"下载响应无效或保存位置不可写" resumeData:nil];
}
- (void)download:(id)download didFailWithError:(NSError *)error resumeData:(NSData *)data {
    FDMWKAttempt *attempt = [_attempts objectForKey:download];
    if (attempt) [FDMEngine.shared webKitDownloadKey:attempt.key transportIdentity:attempt.identity
        failedWithMessage:@"网页下载失败；可用的原页面续传能力请见该任务" resumeData:data];
    [self forget:download];
}
- (void)downloadDidFinish:(id)download {
    FDMWKAttempt *attempt = [_attempts objectForKey:download];
    if (attempt) [FDMEngine.shared webKitDownloadDidFinishKey:attempt.key transportIdentity:attempt.identity];
    [self forget:download];
}
- (void)download:(id)download willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    decisionHandler:(void (^)(NSInteger))decisionHandler {
    // Exact public selector: decisionHandler:, not completionHandler:. Policy is allow/cancel only.
    NSURLRequest *original = FDMValue(download, @"originalRequest");
    decisionHandler(FDMRedirectRefusal(original, request) ? 0 : 1);
}
- (void)download:(id)download didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
    completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}
- (void)cancelKey:(NSString *)key {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (@available(iOS 14.5, macOS 11.3, *)) [(WKDownload *)_live[key] cancel:nil];
    });
}
- (void)forget:(id)download {
    FDMWKAttempt *attempt = [_attempts objectForKey:download]; if (!attempt) return;
    [attempt.progress removeObserver:self forKeyPath:@"completedUnitCount" context:NULL];
    [attempt.progress removeObserver:self forKeyPath:@"totalUnitCount" context:NULL];
    if (_live[attempt.key] == download) [_live removeObjectForKey:attempt.key];
    [_attempts removeObjectForKey:download];
}
@end
