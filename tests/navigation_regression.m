// Navigation / download regression against a real WKWebView and a loopback HTTP server.
//
// This drives the real src/FDMNavigation, src/FDMEngine and src/FDMWebKitDownloads through
// WebKit's own delegate callbacks. Fake host classes only supply the *original* methods the
// hooks wrap, exactly as Focus does; the code under test is the shipped source.
//
// It proves simulator behaviour, not device acceptance of the Focus app.
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <Foundation/Foundation.h>
#import "FDMCommon.h"
#import "FDMPolicy.h"
#import "FDMIntent.h"
#import "FDMEngine.h"
#import "FDMStore.h"
#import "FDMNavigation.h"
#import "FDMWebKitDownloads.h"
#import "FDMPageImages.h"
#import "FDMNativePages.h"
#import "FDMBackup.h"
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *FDMTOrigin;
static NSUInteger FDMScriptLoaderCalls;
static NSUInteger FDMScriptLoaderCompletions;
static WKWebpagePreferences *FDMCapturedPreferences;
static NSInteger FDMCapturedContentMode = -1;
static NSInteger FDMCapturedAllowsJS = -1;
static NSMutableArray *FDMNavigationErrors;
static NSMutableArray *FDMNavigationActions;

static void FDMNavCheck(BOOL condition, NSString *message) {
    if (!condition) [NSException raise:@"FDMNavigationRegression" format:@"%@", message];
}

static void FDMNavFlush(NSTimeInterval seconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
}

static BOOL FDMNavWait(NSTimeInterval timeout, BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (deadline.timeIntervalSinceNow > 0) {
        if (condition()) return YES;
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
    return condition();
}

static NSString *FDMNavURL(NSString *path) {
    return [FDMTOrigin stringByAppendingString:path];
}

#pragma mark - fake host classes

// The host's aggregating navigation delegate. Its original implementations are what the hooks wrap.
@interface WebViewNavDelegate : NSObject <WKNavigationDelegate>
@end
@implementation WebViewNavDelegate
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action
    preferences:(WKWebpagePreferences *)preferences
    decisionHandler:(void (^)(WKNavigationActionPolicy, WKWebpagePreferences *))decisionHandler {
    [FDMNavigationActions addObject:[NSString stringWithFormat:@"%@ %@", action.request.HTTPMethod, action.request.URL]];
    if (action.targetFrame.isMainFrame || !action.targetFrame) {
        FDMCapturedPreferences = preferences;
        // The hook mutates this same preferences object before forwarding the decision, so the
        // applied values are read after the handler returns, not before.
        decisionHandler(WKNavigationActionPolicyAllow, preferences);
        FDMCapturedContentMode = preferences.preferredContentMode;
        FDMCapturedAllowsJS = preferences.allowsContentJavaScript ? 1 : 0;
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow, preferences);
}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)response
    decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
    decisionHandler(WKNavigationResponsePolicyAllow);
}
- (void)webView:(WKWebView *)webView didReceiveServerRedirectForProvisionalNavigation:(WKNavigation *)navigation {}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [FDMNavigationErrors addObject:[NSString stringWithFormat:@"%@:%ld %@", error.domain, (long)error.code, error.localizedDescription]];
}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [FDMNavigationErrors addObject:[NSString stringWithFormat:@"%@:%ld %@", error.domain, (long)error.code, error.localizedDescription]];
}
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView { [FDMNavigationErrors addObject:@"WebContent process terminated"]; }

@end

// The browser controller: media permission is added as a new method by the hook installer.
@interface BrowserViewController : UIViewController
@end
@implementation BrowserViewController
- (void)tab:(id)tab didCreateWebView:(WKWebView *)webView {}
- (void)tab:(id)tab didDeleteWebView:(WKWebView *)webView {}
- (void)_addUserScript:(id)script {}
@end

@interface Tab : NSObject
@property (nonatomic, strong) WKWebView *webView;
@end
@implementation Tab
- (void)updateUserAgentWithURL:(id)url {}
@end

// A real WKWebView subclass so pageZoom/rule-list hooks run against real WebKit state.
@interface PandaWebView : WKWebView
@end
@implementation PandaWebView
- (void)applyWebScaleForCurrentURL {}
- (void)updateRuleListIfNeedWithUrl:(id)url {}
- (void)readerDetectorNotification:(NSNotification *)note {}
@end

// The mandatory script engine. Its loader must keep running even when page JavaScript is off:
// it installs the application's own bridge, which is not a user script.
@interface SystemScriptManager : NSObject
+ (instancetype)shareInstance;
@end
@implementation SystemScriptManager
+ (instancetype)shareInstance { static id shared; static dispatch_once_t once; dispatch_once(&once, ^{ shared = [self new]; }); return shared; }
- (void)loadJsEngine:(WKWebView *)webView completion:(void (^)(void))completion {
    FDMScriptLoaderCalls++;
    if (completion) { FDMScriptLoaderCompletions++; completion(); }
}
- (void)injectUserSciptsToWebView:(WKWebView *)webView completion:(void (^)(void))completion { if (completion) completion(); }
@end

@interface DatabaseUnit : NSObject
@end
@implementation DatabaseUnit
- (void)setCompleteBlock:(id)block {}
@end

@interface PreferenceItemModel : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *imageName;
@property (nonatomic) NSInteger itemType;
@property (nonatomic) BOOL shouldAffectByHomeURL;
@end
@implementation PreferenceItemModel
@end

@interface PreferenceContentView : UIView
@property (nonatomic, strong) NSMutableArray *model;
@property (nonatomic, strong) UICollectionView *collectionView;
@end
@implementation PreferenceContentView
- (void)updateWithModel {}
@end

// WKSecurityOrigin has no public initializer; the hook only reads host/protocol/port.
@interface FDMFakeOrigin : NSObject
@property (nonatomic, copy) NSString *fakeHost;
@property (nonatomic, copy) NSString *fakeProtocol;
@property (nonatomic) NSInteger fakePort;
@end
@implementation FDMFakeOrigin
- (NSString *)host { return self.fakeHost; }
- (NSString *)protocol { return self.fakeProtocol; }
- (NSInteger)port { return self.fakePort; }
@end

@interface FDMFakeFrame : NSObject
@property (nonatomic, strong) NSURLRequest *fakeRequest;
@property (nonatomic) BOOL fakeMainFrame;
@end
@implementation FDMFakeFrame
- (NSURLRequest *)request { return self.fakeRequest; }
- (BOOL)isMainFrame { return self.fakeMainFrame; }
@end

#pragma mark - helpers

static NSArray<NSDictionary *> *FDMFetchServerLog(void) {
    NSURL *url = [NSURL URLWithString:FDMNavURL(@"/__log")];
    __block NSData *payload = nil;
    __block BOOL finished = NO;
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithURL:url
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            payload = data; finished = YES;
        }];
    [task resume];
    FDMNavWait(15, ^BOOL { return finished; });
    FDMNavCheck(finished && payload.length > 0, @"loopback log endpoint is unreachable from the simulator");
    id parsed = [NSJSONSerialization JSONObjectWithData:payload options:0 error:nil];
    return [parsed isKindOfClass:NSArray.class] ? parsed : @[];
}

static NSArray<NSDictionary *> *FDMEntriesFor(NSArray<NSDictionary *> *log, NSString *path, NSString *method) {
    NSMutableArray *matches = [NSMutableArray array];
    for (NSDictionary *entry in log) {
        if (![entry[@"path"] isEqual:path]) continue;
        if (method && ![entry[@"method"] isEqual:method]) continue;
        [matches addObject:entry];
    }
    return matches;
}

static NSMutableURLRequest *FDMPostRequest(NSString *path, NSString *body) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:FDMNavURL(path)]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    return request;
}

static PandaWebView *FDMNewWebView(void) {
    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    configuration.websiteDataStore = WKWebsiteDataStore.defaultDataStore;
    PandaWebView *webView = [[PandaWebView alloc] initWithFrame:CGRectMake(0, 0, 320, 480) configuration:configuration];
    WebViewNavDelegate *delegate = [WebViewNavDelegate new];
    webView.navigationDelegate = delegate;
    objc_setAssociatedObject(webView, @selector(FDMNavigationTabID), delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIWindow *window = UIApplication.sharedApplication.windows.firstObject;
    [window.rootViewController.view addSubview:webView];
    return webView;
}

// A row belonging to this WebView's tab, or nil.
static NSDictionary *FDMRowForWebView(WKWebView *webView) {
    NSString *tabID = FDMNavigationTabID(webView);
    NSArray *rows = [FDMEngine.shared.items arrayByAddingObjectsFromArray:FDMStore.shared.records];
    for (NSDictionary *row in rows) {
        if ([row[@"tabID"] isEqual:tabID]) return row;
    }
    return nil;
}

static void FDMSetCookie(WKWebView *webView, NSString *value) {
    NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:@{
        NSHTTPCookieName: @"fdm_nav",
        NSHTTPCookieValue: value,
        NSHTTPCookieDomain: @"localhost",
        NSHTTPCookiePath: @"/",
        NSHTTPCookieVersion: @"0",
    }];
    __block BOOL done = NO;
    [webView.configuration.websiteDataStore.httpCookieStore setCookie:cookie completionHandler:^{ done = YES; }];
    FDMNavCheck(FDMNavWait(10, ^BOOL { return done; }), @"WebKit cookie store never became ready");
}

static void FDMSetPolicy(NSString *origin, NSDictionary *entry) {
    NSError *error = nil;
    if (![FDMSitePolicyStore.shared setEntry:entry origin:origin error:&error]) {
        [NSException raise:@"FDMNavigationRegression" format:@"policy write failed: %@", error.localizedDescription];
    }
}

#pragma mark - 1. POST download: real WKDownload, exactly one request, cookie preserved

static void FDMTestPostDownloadOnce(void) {
    NSArray *before = FDMFetchServerLog();
    NSUInteger postsBefore = FDMEntriesFor(before, @"/post-download", @"POST").count;

    PandaWebView *webView = FDMNewWebView();
    FDMSetCookie(webView, @"1");
    FDMScriptLoaderCalls = 0;
    FDMScriptLoaderCompletions = 0;

    NSMutableURLRequest *request = FDMPostRequest(@"/post-download", @"payload=form-body-marker&token=single-use-ticket");
    [webView loadRequest:request];

    BOOL completed = FDMNavWait(60, ^BOOL {
        NSDictionary *row = FDMRowForWebView(webView);
        return row != nil && [row[@"state"] integerValue] == FDMStateCompleted;
    });
    NSDictionary *row = FDMRowForWebView(webView);
    FDMNavCheck(row != nil, [NSString stringWithFormat:@"POST download created no task row; actions=%@ errors=%@", FDMNavigationActions, FDMNavigationErrors]);
    FDMNavCheck([row[@"transport"] integerValue] == FDMTransportWebKitDownload,
                @"POST download must use the WebKit transport, not a re-request");
    FDMNavCheck([row[@"method"] isEqual:@"POST"], @"task must record the original POST method");
    FDMNavCheck([row[@"replayable"] boolValue] == NO, @"POST download must not be marked replayable");
    FDMNavCheck(completed, [NSString stringWithFormat:@"POST download did not complete: %@", row[@"error"]]);
    FDMNavCheck([row[@"completionEvidence"] isEqual:@"webkit-finish-and-file-confirmed"],
                @"completion must be backed by a confirmed file, not a callback alone");

    // The saved file must be the real server payload.
    NSString *path = FDMResolveDocumentPath(row);
    NSData *saved = path.length ? [NSData dataWithContentsOfFile:path] : nil;
    FDMNavCheck(saved.length > 0, @"download finished without a readable file on disk");
    FDMNavCheck([[[NSString alloc] initWithData:saved encoding:NSUTF8StringEncoding]
                 containsString:@"FOCUSDM-NAVIGATION-FIXTURE-PAYLOAD"], @"saved file is not the served payload");

    // Server-side proof: the POST arrived once, with its body and the browser's cookie.
    NSArray *after = FDMFetchServerLog();
    NSArray *posts = FDMEntriesFor(after, @"/post-download", @"POST");
    FDMNavCheck(posts.count == postsBefore + 1,
                [NSString stringWithFormat:@"expected exactly one POST, server saw %lu", (unsigned long)(posts.count - postsBefore)]);
    NSDictionary *served = posts.lastObject;
    FDMNavCheck([served[@"body"] containsString:@"form-body-marker"], @"POST body was not delivered intact");
    FDMNavCheck([served[@"cookie"] containsString:@"fdm_nav=1"],
                [NSString stringWithFormat:@"cookie from the WebView data store was not sent: %@", served[@"cookie"]]);
    NSArray *replayed = FDMEntriesFor(after, @"/post-download", @"GET");
    FDMNavCheck(replayed.count == 0, @"download was re-requested as a GET instead of using the original POST");
}

#pragma mark - 2. same URL, different user intent, different task

static void FDMTestSameURLDistinctTasks(void) {
    NSArray *before = FDMFetchServerLog();
    NSUInteger postsBefore = FDMEntriesFor(before, @"/post-download", @"POST").count;

    PandaWebView *first = FDMNewWebView();
    [first loadRequest:FDMPostRequest(@"/post-download", @"payload=first-intent")];
    FDMNavWait(60, ^BOOL {
        NSDictionary *row = FDMRowForWebView(first);
        return row != nil && [row[@"state"] integerValue] == FDMStateCompleted;
    });
    NSDictionary *firstRow = FDMRowForWebView(first);
    FDMNavCheck(firstRow != nil, @"first intent produced no task");

    PandaWebView *second = FDMNewWebView();
    [second loadRequest:FDMPostRequest(@"/post-download", @"payload=second-intent")];
    FDMNavWait(60, ^BOOL {
        NSDictionary *row = FDMRowForWebView(second);
        return row != nil && [row[@"state"] integerValue] == FDMStateCompleted;
    });
    NSDictionary *secondRow = FDMRowForWebView(second);
    FDMNavCheck(secondRow != nil, @"second intent produced no task");
    FDMNavCheck(![firstRow[@"key"] isEqual:secondRow[@"key"]],
                @"the same URL must not reuse the first task's identity");
    FDMNavCheck(![FDMNavigationTabID(first) isEqual:FDMNavigationTabID(second)],
                @"distinct WebViews must have distinct tab identities");

    NSArray *after = FDMFetchServerLog();
    NSUInteger posts = FDMEntriesFor(after, @"/post-download", @"POST").count;
    FDMNavCheck(posts == postsBefore + 2,
                [NSString stringWithFormat:@"two intents must send two POSTs, server saw %lu", (unsigned long)(posts - postsBefore)]);
}

#pragma mark - 3. site preferences: content mode and page JavaScript

static void FDMTestSitePreferences(void) {
    NSString *origin = FDMNormalizedOrigin(FDMTOrigin);
    FDMNavCheck(origin.length > 0, @"fixture origin did not normalize");

    FDMSetPolicy(origin, @{FDMPolicyContentMode: @"desktop", FDMPolicyPageJavaScript: @"on"});
    PandaWebView *webView = FDMNewWebView();
    [webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:FDMNavURL(@"/plain.html")]]];
    FDMNavWait(40, ^BOOL { return webView.URL != nil; });
    FDMNavFlush(1.0);
    FDMNavCheck(FDMCapturedPreferences != nil, @"navigation preferences were never delivered to the host");
    FDMNavCheck(FDMCapturedContentMode == WKContentModeDesktop,
                [NSString stringWithFormat:@"desktop override not applied, saw %ld", (long)FDMCapturedContentMode]);
    __block NSString *title = nil;
    [webView evaluateJavaScript:@"document.title" completionHandler:^(id result, NSError *error) { title = result; }];
    FDMNavWait(20, ^BOOL { return title != nil; });
    FDMNavCheck([title isEqual:@"page-script-ran"], @"page JavaScript should run when the site allows it");

    // Now turn page JavaScript off for the same origin.
    FDMSetPolicy(origin, @{FDMPolicyContentMode: @"mobile", FDMPolicyPageJavaScript: @"off"});
    FDMScriptLoaderCalls = 0;
    FDMScriptLoaderCompletions = 0;
    PandaWebView *limited = FDMNewWebView();
    FDMCapturedPreferences = nil;
    FDMCapturedContentMode = -1;
    [limited loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:FDMNavURL(@"/plain.html")]]];
    FDMNavWait(40, ^BOOL { return limited.URL != nil; });
    FDMNavFlush(1.5);
    FDMNavCheck(FDMCapturedContentMode == WKContentModeMobile,
                [NSString stringWithFormat:@"mobile override not applied, saw %ld", (long)FDMCapturedContentMode]);
    FDMNavCheck(FDMCapturedAllowsJS == 0, @"page JavaScript must be disabled by the site override");
    __block NSString *limitedTitle = nil;
    [limited evaluateJavaScript:@"document.title" completionHandler:^(id result, NSError *error) { limitedTitle = result; }];
    FDMNavWait(20, ^BOOL { return limitedTitle != nil; });
    FDMNavCheck(![limitedTitle isEqual:@"page-script-ran"], @"page script ran even though the site disabled JavaScript");

    // The application's own script engine is not a user script and must keep working.
    [[SystemScriptManager shareInstance] loadJsEngine:limited completion:^{}];
    FDMNavCheck(FDMScriptLoaderCalls >= 1, @"mandatory script loader was suppressed by the page-JavaScript override");
    FDMNavCheck(FDMScriptLoaderCompletions >= 1, @"mandatory script loader completion was swallowed");

    [FDMSitePolicyStore.shared resetOrigin:origin error:nil];
}

#pragma mark - 4. media permission decided by the requesting origin

static void FDMTestMediaPermission(void) {
    NSString *topOrigin = FDMNormalizedOrigin(FDMTOrigin);
    NSString *iframeOrigin = FDMNormalizedOrigin([NSString stringWithFormat:@"http://127.0.0.1:%@",
        [NSURLComponents componentsWithString:FDMTOrigin].port.stringValue]);

    BrowserViewController *browser = [BrowserViewController new];
    WKWebView *webView = FDMNewWebView();
    SEL media = NSSelectorFromString(@"webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:");
    FDMNavCheck([browser respondsToSelector:media], @"the media permission handler was not installed on the browser controller");

    // The requesting origin owns the decision: the top site's Allow must not promote an iframe.
    FDMSetPolicy(topOrigin, @{FDMPolicyCamera: @"allow", FDMPolicyMicrophone: @"allow"});
    FDMSetPolicy(iframeOrigin, @{FDMPolicyCamera: @"ask", FDMPolicyMicrophone: @"ask"});
    FDMFakeOrigin *origin = [FDMFakeOrigin new];
    origin.fakeHost = @"127.0.0.1";
    origin.fakeProtocol = @"http";
    origin.fakePort = [NSURLComponents componentsWithString:FDMTOrigin].port.integerValue;
    FDMFakeFrame *frame = [FDMFakeFrame new];
    frame.fakeRequest = [NSURLRequest requestWithURL:[NSURL URLWithString:[iframeOrigin stringByAppendingString:@"/frame"]]];
    frame.fakeMainFrame = NO;

    __block NSInteger decision = -1;
    ((void (*)(id, SEL, id, id, id, NSInteger, void (^)(NSInteger)))objc_msgSend)(browser, media, webView, origin, frame, 2,
        ^(NSInteger value) { decision = value; });
    FDMNavCheck(decision == 0,
                [NSString stringWithFormat:@"cross-site iframe must not inherit the top Allow, saw %ld", (long)decision]);

    // A deny on the requesting origin wins over any other setting.
    FDMSetPolicy(iframeOrigin, @{FDMPolicyCamera: @"deny", FDMPolicyMicrophone: @"ask"});
    decision = -1;
    ((void (*)(id, SEL, id, id, id, NSInteger, void (^)(NSInteger)))objc_msgSend)(browser, media, webView, origin, frame, 0,
        ^(NSInteger value) { decision = value; });
    FDMNavCheck(decision == 2, @"camera deny must be reported as deny");

    // Combined camera+microphone is granted only when both are explicitly allowed.
    FDMSetPolicy(iframeOrigin, @{FDMPolicyCamera: @"allow", FDMPolicyMicrophone: @"allow"});
    decision = -1;
    ((void (*)(id, SEL, id, id, id, NSInteger, void (^)(NSInteger)))objc_msgSend)(browser, media, webView, origin, frame, 2,
        ^(NSInteger value) { decision = value; });
    FDMNavCheck(decision == 1, @"explicit allow on both permissions must grant the combined request");

    // A mismatched origin/frame pair is refused rather than guessed.
    FDMSetPolicy(iframeOrigin, @{FDMPolicyCamera: @"allow", FDMPolicyMicrophone: @"allow"});
    FDMFakeFrame *otherFrame = [FDMFakeFrame new];
    otherFrame.fakeRequest = [NSURLRequest requestWithURL:[NSURL URLWithString:[topOrigin stringByAppendingString:@"/frame"]]];
    decision = -1;
    ((void (*)(id, SEL, id, id, id, NSInteger, void (^)(NSInteger)))objc_msgSend)(browser, media, webView, origin, otherFrame, 0,
        ^(NSInteger value) { decision = value; });
    FDMNavCheck(decision == 0, @"a frame from another origin must not borrow this origin's permission");

    [FDMSitePolicyStore.shared resetOrigin:topOrigin error:nil];
    [FDMSitePolicyStore.shared resetOrigin:iframeOrigin error:nil];
}

#pragma mark - 5. temporary enhancement off is per WebView; menu item is appended

static void FDMTestTemporaryOffAndMenu(void) {
    PandaWebView *off = FDMNewWebView();
    PandaWebView *other = FDMNewWebView();
    NSString *origin = FDMNormalizedOrigin(FDMTOrigin);
    FDMSetPolicy(origin, @{FDMPolicyUserScripts: @"on", FDMPolicyReader: @"auto"});
    FDMNavCheck(FDMNavigationAllowsUserScripts(off), @"user scripts should start allowed");
    FDMNavCheck(FDMNavigationAllowsUserScripts(other), @"user scripts should start allowed on the second tab");

    [FDMTemporaryEnhancementOff.shared setOff:YES forObject:off];
    FDMNavCheck(!FDMNavigationAllowsUserScripts(off), @"the disabled tab must stop user scripts");
    FDMNavCheck(FDMNavigationAllowsUserScripts(other), @"another tab must not be affected by a temporary off");
    [FDMTemporaryEnhancementOff.shared clearForObject:off];
    FDMNavCheck(FDMNavigationAllowsUserScripts(off), @"clearing the temporary state must restore the tab");

    PreferenceContentView *view = [PreferenceContentView new];
    view.model = [NSMutableArray array];
    [view.model addObject:[PreferenceItemModel new]];
    [view updateWithModel];
    NSInteger appended = 0;
    NSInteger addedType = 0;
    for (id item in view.model) {
        if ([FDMValue(item, @"itemType") integerValue] == 0x46444d) { appended++; addedType = 0x46444d; }
    }
    FDMNavCheck(appended == 1, @"the native menu must gain exactly one site-settings item");
    FDMNavCheck(addedType == 0x46444d, @"the appended item must carry the site-settings marker");
    [view updateWithModel];
    NSInteger afterSecond = 0;
    for (id item in view.model) if ([FDMValue(item, @"itemType") integerValue] == 0x46444d) afterSecond++;
    FDMNavCheck(afterSecond == 1, @"updating the menu twice must not duplicate the item");

    [FDMSitePolicyStore.shared resetOrigin:origin error:nil];
}

// Selected image GETs are new user actions through the original data store; they do not replay POST.
static void FDMTestSelectedImages(void) {
    PandaWebView *source = FDMNewWebView();
    [source loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:FDMNavURL(@"/plain.html")]]];
    FDMNavCheck(FDMNavWait(20, ^BOOL { return source.URL != nil; }), @"selected image source is loaded");
    unsigned long long generation = FDMNavigationGeneration(source);
    __block BOOL finished = NO; __block NSUInteger count = 0; __block NSError *failure = nil;
    FDMStartSelectedPageImages(source, @[FDMNavURL(@"/image-one.png")], generation, ^(NSUInteger started, NSError *error) { count=started; failure=error; finished=YES; });
    FDMNavCheck(FDMNavWait(30, ^BOOL { return finished; }) && count == 1 && !failure, @"one selected image is adopted exactly once");
    FDMNavCheck(FDMNavWait(30, ^BOOL { return [FDMRowForWebView(source)[@"state"] integerValue] == FDMStateCompleted; }), @"selected image reaches a confirmed file");
    NSArray *requests = FDMEntriesFor(FDMFetchServerLog(), @"/image-one.png", @"GET");
    FDMNavCheck(requests.count==1 && [requests.firstObject[@"cookie"] containsString:@"fdm_nav=1"], @"image GET uses WebKit data-store cookie");
    finished=NO; count=99;
    FDMStartSelectedPageImages(source, @[FDMNavURL(@"/image-one.png")], generation+1, ^(NSUInteger started, NSError *error) { count=started; failure=error; finished=YES; });
    FDMNavCheck(finished && count==0 && failure!=nil, @"stale page generation creates zero image requests");
}

@interface FDMBackupViewController (FDMFixtureSelectors)
- (void)documentPicker:(UIDocumentPickerViewController *)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls;
- (void)cancelImport;
@end
static void FDMTestBackupCategoryUI(void) {
    NSError *error=nil;
    NSData *payload=[FDMBackupCoordinator.shared exportCategories:@[FDMBackupCategorySitePolicies, FDMBackupCategoryScripts] error:&error];
    // Scripts need no host persistence to export an empty category in this fixture. Fall back only
    // to a strict manually encoded container, never claim a repository round-trip here.
    if (!payload) payload=FDMBackupEncode(@[
        [FDMBackupCategory category:FDMBackupCategorySitePolicies payload:[@"{\"schemaVersion\":1,\"revision\":0,\"origins\":{}}" dataUsingEncoding:NSUTF8StringEncoding] itemCount:0],
        [FDMBackupCategory category:FDMBackupCategoryScripts payload:[@"{\"schemaVersion\":1,\"scripts\":[]}" dataUsingEncoding:NSUTF8StringEncoding] itemCount:0]], @"fixture", &error);
    NSString *path=[FDMDocumentsPath() stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"browserbackup"]];
    FDMNavCheck(payload && [payload writeToFile:path atomically:YES], @"strict backup fixture file exists");
    FDMBackupViewController *page=[[FDMBackupViewController alloc] initWithStyle:UITableViewStyleInsetGrouped]; [page loadViewIfNeeded];
    [page documentPicker:nil didPickDocumentsAtURLs:@[[NSURL fileURLWithPath:path]]];
    NSSet *selection=FDMValue(page,@"_selected");
    FDMNavCheck(![selection containsObject:FDMBackupCategoryScripts], @"script import is opt-in, not preselected");
    FDMNavCheck([page.navigationItem.rightBarButtonItem.title containsString:@"预览"], @"file selection opens category selection instead of immediate import");
    FDMNavCheck(FDMValue(page,@"_pendingPlan")==nil, @"category selection does not build or execute an unseen import plan");
    [page cancelImport];
    FDMNavCheck([page.navigationItem.rightBarButtonItem.title isEqual:@"导出"] && FDMValue(page,@"_pendingContainer")==nil, @"cancel restores export UI and releases imported container");
}

#pragma mark - runner

void FDMRunNavigationRegression(NSString *origin) {
    FDMTOrigin = [origin copy]; FDMNavigationErrors = [NSMutableArray array]; FDMNavigationActions = [NSMutableArray array];
    FDMNavCheck(FDMTOrigin.length > 0, @"TEST_ORIGIN was not supplied by the runner");
    FDMNavCheck(FDMNormalizedOrigin(FDMTOrigin).length > 0, @"TEST_ORIGIN is not a valid http origin");

    __block BOOL mainCompletionRan = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ mainCompletionRan = YES; });
    FDMNavCheck(FDMNavWait(3, ^BOOL { return mainCompletionRan; }), @"fixture blocks main-queue completions; WebKit has not been exercised");
    FDMInstallNavigationHooks();
    FDMNavCheck(FDMWebKitDownloads.shared.supported, @"WKDownload is unavailable on this simulator runtime");

    FDMTestPostDownloadOnce();
    FDMTestSameURLDistinctTasks();
    FDMTestSelectedImages();
    FDMTestSitePreferences();
    FDMTestMediaPermission();
    FDMTestTemporaryOffAndMenu();
    FDMTestBackupCategoryUI();
}
