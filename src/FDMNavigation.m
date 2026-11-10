#import "FDMNavigation.h"
#import "FDMPolicy.h"
#import "FDMEngine.h"
#import "FDMWebKitDownloads.h"
#import "FDMNativePages.h"

static char FDMNavBindingKey;
static IMP FDMNavOriginalAction, FDMNavOriginalResponse, FDMNavOriginalRedirect, FDMNavOriginalFinish;
static IMP FDMNavOriginalUA, FDMNavOriginalZoom, FDMNavOriginalRules, FDMNavOriginalLoadJS, FDMNavOriginalReader;
static IMP FDMNavOriginalCreated, FDMNavOriginalRemoved, FDMNavOriginalMenu;
static IMP FDMNavOriginalAddRule, FDMNavOriginalRemoveRule, FDMNavOriginalRemoveRules;
static IMP FDMNavOriginalAddScript, FDMNavOriginalSetCompleteBlock, FDMNavOriginalImmediateUserJS;
static __thread void *FDMNavScriptWebView;
static __thread void *FDMNavScriptCompletion;
static char FDMNavControllerKey;
static __thread unsigned long long FDMNavUserScriptGeneration;
static __thread BOOL FDMNavUserScriptPhase;
static void (^FDMNavDownloadNotice)(void);

@interface FDMNavigationBinding : NSObject
@property (nonatomic, copy) NSString *tabID;
@property (nonatomic) unsigned long long generation;
@property (nonatomic, copy) NSString *origin;
@property (nonatomic, copy) NSURLRequest *request;
@property (nonatomic, strong) FDMDownloadIntent *intent;
@property (nonatomic, weak) WKNavigationAction *action;
@property (nonatomic, strong) NSMutableArray *cancellations;
@property (nonatomic, copy) NSArray<WKUserScript *> *userScripts;
@property (nonatomic, strong) NSMutableArray<WKContentRuleList *> *rules;
@property (nonatomic) BOOL isolatedController;
@end
@implementation FDMNavigationBinding
- (instancetype)init { if ((self = [super init])) { _tabID = NSUUID.UUID.UUIDString;
    _cancellations = [NSMutableArray array]; _rules = [NSMutableArray array]; _isolatedController = YES; } return self; }
@end
static FDMNavigationBinding *FDMBinding(WKWebView *webView) {
    if (!webView) return nil;
    FDMNavigationBinding *binding = objc_getAssociatedObject(webView, &FDMNavBindingKey);
    if (!binding) { binding = [FDMNavigationBinding new]; objc_setAssociatedObject(webView, &FDMNavBindingKey, binding, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    return binding;
}
NSString *FDMNavigationTabID(WKWebView *webView) { return FDMBinding(webView).tabID; }
unsigned long long FDMNavigationGeneration(WKWebView *webView) { return FDMBinding(webView).generation; }
NSString *FDMNavigationOrigin(WKWebView *webView) { return FDMBinding(webView).origin ?: FDMOriginForURL(webView.URL); }
static void FDMCancelPending(FDMNavigationBinding *binding) {
    NSArray *callbacks = [binding.cancellations copy]; [binding.cancellations removeAllObjects];
    for (id callback in callbacks) { dispatch_block_t cancel = callback; cancel(); }
}
static BOOL FDMHook(Class cls, SEL selector, IMP implementation, IMP *original) {
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method) {
        if (cls) FDMLog(@"navigation hook missing %@ %@", NSStringFromClass(cls), NSStringFromSelector(selector));
        return NO;
    }
    IMP old = method_getImplementation(method); if (old == implementation) return YES;
    if (original) *original = old;
    if (!class_addMethod(cls, selector, implementation, method_getTypeEncoding(method))) method_setImplementation(method, implementation);
    return YES;
}
static NSDictionary *FDMNavEntry(WKWebView *webView) {
    NSString *origin = FDMNavigationOrigin(webView); return origin ? [FDMSitePolicyStore.shared entryForOrigin:origin] : nil;
}
BOOL FDMNavigationAllowsUserScripts(WKWebView *webView) {
    return ![FDMTemporaryEnhancementOff.shared isOffForObject:webView] && ![FDMNavEntry(webView)[FDMPolicyUserScripts] isEqual:@"off"];
}
static UIViewController *FDMNavPresenter(UIViewController *host) {
    UIViewController *presenter = host;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    return presenter;
}
static void FDMNavPush(UIViewController *host, UIViewController *page) {
    if (host.navigationController) [host.navigationController pushViewController:page animated:YES];
    else { UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:page];
        nav.modalPresentationStyle = UIModalPresentationFullScreen; [host presentViewController:nav animated:YES completion:nil]; }
}
void FDMOpenCurrentSiteSettings(UIViewController *host) {
    id manager = FDMValue(host, @"tabManager");
    WKWebView *webView = FDMValue(FDMValue(manager, @"selectedTab"), @"webView");
    NSString *origin = FDMOriginForURL(webView.URL);
    if (!origin) return;
    FDMSitePolicyEditViewController *page = [[FDMSitePolicyEditViewController alloc] initWithOrigin:origin];
    page.webView = webView;
    __weak WKWebView *weakWebView = webView;
    __weak UIViewController *weakHost = host;
    page.didChangePolicy = ^(BOOL reload) { if (reload) FDMConfirmPolicyReload(weakHost, weakWebView, NO); };
    FDMNavPush(host, page);
}
void FDMConfirmPolicyReload(UIViewController *host, WKWebView *webView, BOOL temporaryOff) {
    if (!host || !webView) return;
    FDMNavigationBinding *binding = FDMBinding(webView);
    if (binding.request.HTTPMethod.length && ![binding.request.HTTPMethod.uppercaseString isEqual:@"GET"]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"已保存，下次导航生效"
            message:@"当前页面来自表单或POST请求，不会自动重放。请使用网页自身的操作重新打开。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [FDMNavPresenter(host) presentViewController:alert animated:YES completion:nil]; return;
    }
    unsigned long long generation = binding.generation;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重载当前网页？"
        message:@"重载会丢失网页内尚未提交的输入。取消不会清除数据；已保存规则仍对下次导航生效。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak WKWebView *weakWebView = webView;
    [alert addAction:[UIAlertAction actionWithTitle:@"重载" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        WKWebView *source = weakWebView;
        if (!source || FDMBinding(source).generation != generation) return;
        if (temporaryOff) [FDMTemporaryEnhancementOff.shared setOff:YES forObject:source];
        [source reload];
    }]];
    [FDMNavPresenter(host) presentViewController:alert animated:YES completion:nil];
}

static void FDMApplyPrefs(WKWebView *webView, WKWebpagePreferences *preferences, NSString *origin) {
    NSDictionary *entry = origin ? [FDMSitePolicyStore.shared entryForOrigin:origin] : nil;
    if (!entry) return;
    if ([entry[FDMPolicyContentMode] isEqual:@"desktop"]) preferences.preferredContentMode = WKContentModeDesktop;
    else if ([entry[FDMPolicyContentMode] isEqual:@"mobile"]) preferences.preferredContentMode = WKContentModeMobile;
    if (entry[FDMPolicyPageJavaScript]) preferences.allowsContentJavaScript = [entry[FDMPolicyPageJavaScript] isEqual:@"on"];
}
static BOOL FDMIsExternal(WKNavigationAction *action) {
    NSString *scheme = action.request.URL.scheme.lowercaseString;
    return scheme.length && ![@[@"http", @"https", @"about", @"data", @"blob", @"file", @"javascript"] containsObject:scheme];
}
static void FDMPerformOriginalAction(id self, SEL selector, WKWebView *webView, WKNavigationAction *action,
    WKWebpagePreferences *preferences, void (^done)(WKNavigationActionPolicy, WKWebpagePreferences *)) {
    if (FDMNavOriginalAction) ((void (*)(id, SEL, id, id, id, id))FDMNavOriginalAction)(self, selector, webView, action, preferences, done);
    else done(WKNavigationActionPolicyAllow, preferences);
}
static void FDMReconfigureUserScripts(WKWebView *webView, NSDictionary *previous) {
    NSDictionary *current = FDMNavEntry(webView);
    BOOL temporaryOff = [FDMTemporaryEnhancementOff.shared isOffForObject:webView];
    if (!current[FDMPolicyUserScripts] && !previous[FDMPolicyUserScripts] && !temporaryOff) return;
    if (!FDMBinding(webView).isolatedController) return;
    Class cls = NSClassFromString(@"SystemScriptManager");
    SEL shared = NSSelectorFromString(@"shareInstance"), inject = NSSelectorFromString(@"injectUserSciptsToWebView:completion:");
    id manager = [cls respondsToSelector:shared] ? ((id (*)(id, SEL))objc_msgSend)(cls, shared) : nil;
    if ([manager respondsToSelector:inject]) ((void (*)(id, SEL, id, id))objc_msgSend)(manager, inject, webView, ^{});
}
static void FDMNavigationAction(id self, SEL selector, WKWebView *webView, WKNavigationAction *action,
    WKWebpagePreferences *preferences, void (^decision)(WKNavigationActionPolicy, WKWebpagePreferences *)) {
    NSCAssert(NSThread.isMainThread, @"Navigation must execute on main");
    FDMNavigationBinding *binding = FDMBinding(webView);
    BOOL main = action.targetFrame.isMainFrame || !action.targetFrame;
    if (main && !FDMIsExternal(action)) {
        if (binding.action != action) {
            NSDictionary *previous = FDMNavEntry(webView);
            FDMCancelPending(binding); [FDMIntentRegistry.shared invalidateTab:binding.tabID];
            binding.generation++; binding.action = action; binding.request = action.request;
            binding.origin = FDMOriginForURL(action.request.URL);
            binding.intent = [FDMIntentRegistry.shared registerRequest:action.request tabID:binding.tabID
                navigationGeneration:binding.generation sourceOrigin:FDMOriginForURL(action.sourceFrame.request.URL) ?: FDMOriginForURL(webView.URL)
                suggestedFilename:nil dataStore:webView.configuration.websiteDataStore userInitiated:action.navigationType == WKNavigationTypeLinkActivated];
            FDMReconfigureUserScripts(webView, previous);
        }
    }
    __block BOOL consumed = NO;
    void (^once)(WKNavigationActionPolicy, WKWebpagePreferences *) = ^(WKNavigationActionPolicy policy, WKWebpagePreferences *p) {
        if (consumed) return; consumed = YES;
        WKWebpagePreferences *effective = p ?: preferences;
        if (main) FDMApplyPrefs(webView, effective, binding.origin);
        decision(policy, effective);
    };
    if (@available(iOS 14.5, *)) {
        if (action.shouldPerformDownload) { once(WKNavigationActionPolicyDownload, preferences); return; }
    }
    NSString *sourceOrigin = FDMOriginForURL(action.sourceFrame.request.URL) ?: FDMOriginForURL(webView.URL);
    NSDictionary *entry = sourceOrigin ? [FDMSitePolicyStore.shared entryForOrigin:sourceOrigin] : nil;
    NSString *external = entry[FDMPolicyExternalApps];
    if (FDMIsExternal(action) && external && ![external isEqual:@"allow"]) {
        if ([external isEqual:@"deny"] || !action.sourceFrame.isMainFrame) { once(WKNavigationActionPolicyCancel, preferences); return; }
        id tabManager = FDMValue(self, @"tabManager"); UIViewController *browser = FDMValue(tabManager, @"browser");
        if (!browser || browser.presentedViewController) { once(WKNavigationActionPolicyCancel, preferences); return; }
        unsigned long long generation = binding.generation;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"打开外部App？"
            message:[NSString stringWithFormat:@"来源：%@\n目标应用协议：%@", sourceOrigin, action.request.URL.scheme]
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) { once(WKNavigationActionPolicyCancel, preferences); }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"打开" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            if (binding.generation != generation) { once(WKNavigationActionPolicyCancel, preferences); return; }
            // User approval does not bypass the host's block/login/maps/store checks.
            FDMPerformOriginalAction(self, selector, webView, action, preferences, once);
        }]];
        [binding.cancellations addObject:[^{ once(WKNavigationActionPolicyCancel, preferences); [alert dismissViewControllerAnimated:NO completion:nil]; } copy]];
        [browser presentViewController:alert animated:YES completion:nil]; return;
    }
    FDMPerformOriginalAction(self, selector, webView, action, preferences, once);
}
static void FDMNavigationResponse(id self, SEL selector, WKWebView *webView, WKNavigationResponse *response,
    void (^decision)(WKNavigationResponsePolicy)) {
    FDMNavigationBinding *binding = FDMBinding(webView);
    NSHTTPURLResponse *http = [response.response isKindOfClass:NSHTTPURLResponse.class] ? (id)response.response : nil;
    NSString *disposition = nil;
    for (NSString *key in http.allHeaderFields) if ([key.lowercaseString isEqual:@"content-disposition"]) disposition = http.allHeaderFields[key];
    BOOL download = [disposition.lowercaseString containsString:@"attachment"] || !response.canShowMIMEType;
    if (download) {
        if (@available(iOS 14.5, *)) { decision(WKNavigationResponsePolicyDownload); return; }
        // On iOS14.0-14.4 a POST response cannot be converted. Do not silently create a new GET.
        FDMLog(@"WK download requires iOS14.5+ task origin=%@", binding.origin);
        decision(WKNavigationResponsePolicyCancel); return;
    }
    if (FDMNavOriginalResponse) ((void (*)(id, SEL, id, id, id))FDMNavOriginalResponse)(self, selector, webView, response, decision);
    else decision(WKNavigationResponsePolicyAllow);
}
static void FDMBecameDownload(id self, SEL selector, WKWebView *webView, id responseOrAction, id download) {
    FDMNavigationBinding *binding = FDMBinding(webView);
    FDMDownloadIntent *intent = binding.intent;
    if (intent && ![FDMIntentRegistry.shared claimIntent:intent.intentID tabID:binding.tabID generation:binding.generation]) {
        if (@available(iOS 14.5, *)) [(WKDownload *)download cancel:nil]; return;
    }
    [FDMWebKitDownloads.shared adoptDownload:download intent:intent tabID:binding.tabID];
    if (FDMNavDownloadNotice) FDMNavDownloadNotice();
}
static void FDMNavigationRedirect(id self, SEL selector, WKWebView *webView, WKNavigation *navigation) {
    FDMNavigationBinding *binding = FDMBinding(webView);
    binding.origin = FDMOriginForURL(webView.URL);
    if (FDMNavOriginalRedirect) ((void (*)(id, SEL, id, id))FDMNavOriginalRedirect)(self, selector, webView, navigation);
}
static void FDMNavigationFinish(id self, SEL selector, WKWebView *webView, WKNavigation *navigation) {
    if (FDMNavOriginalFinish) ((void (*)(id, SEL, id, id))FDMNavOriginalFinish)(self, selector, webView, navigation);
    FDMBinding(webView).origin = FDMOriginForURL(webView.URL);
    NSDictionary *entry = FDMNavEntry(webView);
    if (entry[FDMPolicyPageZoom]) webView.pageZoom = [entry[FDMPolicyPageZoom] doubleValue];
}
static void FDMUserAgent(id self, SEL selector, id url) {
    if (FDMNavOriginalUA) ((void (*)(id, SEL, id))FDMNavOriginalUA)(self, selector, url);
    WKWebView *webView = FDMValue(self, @"webView");
    NSString *origin = FDMNormalizedOrigin(FDMString(url)); NSDictionary *entry = origin ? [FDMSitePolicyStore.shared entryForOrigin:origin] : nil;
    NSString *agent = [entry[FDMPolicyUserAgent] isKindOfClass:NSString.class] ? entry[FDMPolicyUserAgent] : nil;
    if (agent) webView.customUserAgent = agent; // otherwise the host just restored its current global UA
}
static void FDMPageZoom(id self, SEL selector) {
    if (FDMNavOriginalZoom) ((void (*)(id, SEL))FDMNavOriginalZoom)(self, selector);
    WKWebView *webView = self; id zoom = FDMNavEntry(webView)[FDMPolicyPageZoom];
    if (zoom) webView.pageZoom = [zoom doubleValue];
}
static WKWebView *FDMControllerWebView(WKUserContentController *controller) {
    NSMapTable *map = objc_getAssociatedObject(controller, &FDMNavControllerKey);
    return [map objectForKey:@"webView"];
}
static void FDMTrackController(WKWebView *webView) {
    WKUserContentController *controller = webView.configuration.userContentController;
    WKWebView *old = FDMControllerWebView(controller);
    if (old && old != webView) {
        FDMBinding(old).isolatedController = NO; FDMBinding(webView).isolatedController = NO;
        // No per-tab mutation is allowed on a shared controller until real isolation is established.
        return;
    }
    NSMapTable *map = [NSMapTable strongToWeakObjectsMapTable]; [map setObject:webView forKey:@"webView"];
    objc_setAssociatedObject(controller, &FDMNavControllerKey, map, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void FDMAddRule(id self, SEL selector, WKContentRuleList *rule) {
    WKWebView *webView = FDMControllerWebView(self);
    FDMNavigationBinding *binding = webView ? FDMBinding(webView) : nil;
    NSDictionary *entry = webView ? FDMNavEntry(webView) : nil;
    if (binding.isolatedController && ([entry[FDMPolicyContentBlocking] isEqual:@"off"] ||
        [FDMTemporaryEnhancementOff.shared isOffForObject:webView])) return;
    if (FDMNavOriginalAddRule) ((void (*)(id, SEL, id))FDMNavOriginalAddRule)(self, selector, rule);
    if (binding && ![binding.rules containsObject:rule]) [binding.rules addObject:rule];
}
static void FDMRemoveRule(id self, SEL selector, WKContentRuleList *rule) {
    [FDMBinding(FDMControllerWebView(self)).rules removeObject:rule];
    if (FDMNavOriginalRemoveRule) ((void (*)(id, SEL, id))FDMNavOriginalRemoveRule)(self, selector, rule);
}
static void FDMRemoveRules(id self, SEL selector) {
    [FDMBinding(FDMControllerWebView(self)).rules removeAllObjects];
    if (FDMNavOriginalRemoveRules) ((void (*)(id, SEL))FDMNavOriginalRemoveRules)(self, selector);
}
static void FDMAddUserScript(id self, SEL selector, WKUserScript *script) {
    WKWebView *webView = FDMControllerWebView(self);
    if (webView && FDMNavUserScriptPhase && (!FDMNavigationAllowsUserScripts(webView) ||
        FDMBinding(webView).generation != FDMNavUserScriptGeneration)) return;
    if (FDMNavOriginalAddScript) ((void (*)(id, SEL, id))FDMNavOriginalAddScript)(self, selector, script);
}
static void FDMRules(id self, SEL selector, id url) {
    if (FDMNavOriginalRules) ((void (*)(id, SEL, id))FDMNavOriginalRules)(self, selector, url);
    WKWebView *webView = self; NSDictionary *entry = FDMNavEntry(webView);
    BOOL off = [FDMTemporaryEnhancementOff.shared isOffForObject:webView] || [entry[FDMPolicyContentBlocking] isEqual:@"off"];
    if (off && FDMBinding(webView).isolatedController) {
        for (WKContentRuleList *rule in [FDMBinding(webView).rules copy])
            [webView.configuration.userContentController removeContentRuleList:rule];
    } else if ([entry[FDMPolicyContentBlocking] isEqual:@"on"]) {
        Class cls = NSClassFromString(@"AdBlockManager"); SEL shared = NSSelectorFromString(@"shareInstance");
        id manager = [cls respondsToSelector:shared] ? ((id (*)(id, SEL))objc_msgSend)(cls, shared) : nil;
        SEL load = NSSelectorFromString(@"loadSavedRulesWithWebView:");
        if ([manager respondsToSelector:load]) ((void (*)(id, SEL, id))objc_msgSend)(manager, load, webView);
    }
}
static void FDMSetScriptCompleteBlock(id self, SEL selector, void (^complete)(id)) {
    if (!FDMNavScriptWebView || !complete) {
        if (FDMNavOriginalSetCompleteBlock) ((void (*)(id, SEL, id))FDMNavOriginalSetCompleteBlock)(self, selector, complete);
        return;
    }
    __weak WKWebView *weakWebView = (__bridge id)FDMNavScriptWebView;
    unsigned long long generation = FDMBinding(weakWebView).generation;
    void (^done)(void) = [(__bridge id)FDMNavScriptCompletion copy];
    void (^guarded)(id) = ^(id result) {
        WKWebView *webView = weakWebView;
        if (!webView || FDMBinding(webView).generation != generation || !FDMNavigationAllowsUserScripts(webView)) {
            if (done) done(); return;
        }
        unsigned long long previousGeneration = FDMNavUserScriptGeneration;
        BOOL previousPhase = FDMNavUserScriptPhase;
        FDMNavUserScriptGeneration = generation; FDMNavUserScriptPhase = YES;
        @try { complete(result); }
        @finally { FDMNavUserScriptGeneration = previousGeneration; FDMNavUserScriptPhase = previousPhase; }
    };
    if (FDMNavOriginalSetCompleteBlock) ((void (*)(id, SEL, id))FDMNavOriginalSetCompleteBlock)(self, selector, guarded);
}
static void FDMLoadUserJS(id self, SEL selector, WKWebView *webView, void (^completion)(void)) {
    // Run the real loader: mandatory install/bridge helper survives. Only its user-script query
    // completion is bound to the originating navigation and filtered before injection.
    void *previousWebView = FDMNavScriptWebView, *previousCompletion = FDMNavScriptCompletion;
    FDMNavScriptWebView = (__bridge void *)webView; FDMNavScriptCompletion = (__bridge void *)completion;
    @try {
        if (FDMNavOriginalLoadJS) ((void (*)(id, SEL, id, id))FDMNavOriginalLoadJS)(self, selector, webView, completion);
        else if (completion) completion();
    } @finally { FDMNavScriptWebView = previousWebView; FDMNavScriptCompletion = previousCompletion; }
}
static void FDMImmediateUserJS(id self, SEL selector, id script) {
    WKWebView *webView = FDMValue(FDMValue(FDMValue(self, @"tabManager"), @"selectedTab"), @"webView");
    if (!FDMNavigationAllowsUserScripts(webView)) return;
    if (FDMNavOriginalImmediateUserJS) ((void (*)(id, SEL, id))FDMNavOriginalImmediateUserJS)(self, selector, script);
}
static void FDMReaderDetected(id self, SEL selector, NSNotification *notification) {
    WKWebView *webView = self;
    NSDictionary *entry = FDMNavEntry(webView);
    BOOL disabled = [entry[FDMPolicyReader] isEqual:@"off"] || [FDMTemporaryEnhancementOff.shared isOffForObject:webView];
    if (disabled) {
        UIView *button = FDMValue(webView, @"readerButton"); button.hidden = YES; return;
    }
    if (FDMNavOriginalReader) ((void (*)(id, SEL, id))FDMNavOriginalReader)(self, selector, notification);
    if (![entry[FDMPolicyReader] isEqual:@"auto"] || notification.userInfo[@"webView"] != webView) return;
    id model = notification.object;
    NSURL *articleURL = [NSURL URLWithString:FDMString(FDMValue(model, @"currentUrl")) ?: @""];
    if (![FDMOriginForURL(articleURL) isEqual:FDMOriginForURL(webView.URL)] || ![FDMValue(model, @"isReaderModeAvailable") boolValue]) return;
    // Reuse the host article detector. No synthetic article model or login/form auto-conversion.
    SEL enter = NSSelectorFromString(@"enterReaderWithModel:");
    if ([webView respondsToSelector:enter]) ((void (*)(id, SEL, id))objc_msgSend)(webView, enter, model);
}
static void FDMMediaPermission(id self, SEL selector, WKWebView *webView, WKSecurityOrigin *origin, WKFrameInfo *frame,
    NSInteger type, void (^decision)(NSInteger)) {
    if (!origin || !frame || type < 0 || type > 2) { decision(0); return; }
    NSString *host = origin.host; if ([host containsString:@":"] && ![host hasPrefix:@"["]) host = [NSString stringWithFormat:@"[%@]", host];
    NSString *requested = FDMNormalizedOrigin([NSString stringWithFormat:@"%@://%@:%ld", origin.protocol, host,
        (long)(origin.port ?: ([origin.protocol.lowercaseString isEqual:@"https"] ? 443 : 80))]);
    NSString *frameOrigin = FDMOriginForURL(frame.request.URL);
    if (!requested || ![requested isEqual:frameOrigin]) { decision(0); return; }
    NSDictionary *entry = [FDMSitePolicyStore.shared entryForOrigin:requested];
    BOOL camera = type == 0 || type == 2, microphone = type == 1 || type == 2;
    if ((camera && [entry[FDMPolicyCamera] isEqual:@"deny"]) || (microphone && [entry[FDMPolicyMicrophone] isEqual:@"deny"])) { decision(2); return; }
    BOOL allow = (!camera || [entry[FDMPolicyCamera] isEqual:@"allow"]) && (!microphone || [entry[FDMPolicyMicrophone] isEqual:@"allow"]);
    // The requested origin owns permission, not the top site's Allow; system TCC still applies.
    decision(allow ? 1 : 0);
}
static void FDMCreated(id self, SEL selector, id tab, WKWebView *webView) {
    FDMBinding(webView); FDMTrackController(webView);
    if (FDMNavOriginalCreated) ((void (*)(id, SEL, id, id))FDMNavOriginalCreated)(self, selector, tab, webView);
}
static void FDMRemoved(id self, SEL selector, id tab, WKWebView *webView) {
    FDMNavigationBinding *binding = FDMBinding(webView); FDMCancelPending(binding);
    [FDMIntentRegistry.shared invalidateTab:binding.tabID]; [FDMEngine.shared invalidateWebKitContextForTabID:binding.tabID];
    [FDMTemporaryEnhancementOff.shared clearForObject:webView];
    if (FDMNavOriginalRemoved) ((void (*)(id, SEL, id, id))FDMNavOriginalRemoved)(self, selector, tab, webView);
}
static void FDMMenuModel(id self, SEL selector) {
    if (FDMNavOriginalMenu) ((void (*)(id, SEL))FDMNavOriginalMenu)(self, selector);
    NSMutableArray *model = FDMValue(self, @"model");
    if (![model isKindOfClass:NSMutableArray.class]) return;
    Class cls = NSClassFromString(@"PreferenceItemModel"); if (!cls) return;
    NSArray *additions = @[@{@"title": @"网站设置", @"type": @(0x46444d), @"icon": @"tool_ua_icon"},
        @{@"title": @"下载本页图片", @"type": @(0x464449), @"icon": @"tool_down_icon"}];
    for (NSDictionary *addition in additions) {
        BOOL exists = NO;
        for (id old in model) if ([FDMValue(old, @"itemType") integerValue] == [addition[@"type"] integerValue]) { exists = YES; break; }
        if (exists) continue;
        id item = [[cls alloc] init];
        [item setValue:addition[@"title"] forKey:@"title"]; [item setValue:addition[@"icon"] forKey:@"imageName"];
        [item setValue:addition[@"type"] forKey:@"itemType"]; [item setValue:@NO forKey:@"shouldAffectByHomeURL"];
        [model addObject:item];
    }
    UICollectionView *collection = FDMValue(self, @"collectionView"); [collection reloadData];
}
void FDMInstallNavigationCreatedCallback(void (^callback)(void)) { FDMNavDownloadNotice = [callback copy]; }
void FDMInstallNavigationHooks(void) {
    // One delegate owner only: aggregator preserves host fan-out on all non-download paths.
    Class aggregate = NSClassFromString(@"WebViewNavDelegate"), browser = NSClassFromString(@"BrowserViewController");
    FDMHook(aggregate, @selector(webView:decidePolicyForNavigationAction:preferences:decisionHandler:), (IMP)FDMNavigationAction, &FDMNavOriginalAction);
    FDMHook(aggregate, @selector(webView:decidePolicyForNavigationResponse:decisionHandler:), (IMP)FDMNavigationResponse, &FDMNavOriginalResponse);
    FDMHook(aggregate, @selector(webView:didReceiveServerRedirectForProvisionalNavigation:), (IMP)FDMNavigationRedirect, &FDMNavOriginalRedirect);
    FDMHook(aggregate, @selector(webView:didFinishNavigation:), (IMP)FDMNavigationFinish, &FDMNavOriginalFinish);
    if (aggregate) {
        class_addMethod(aggregate, @selector(webView:navigationAction:didBecomeDownload:), (IMP)FDMBecameDownload, "v40@0:8@16@24@32");
        class_addMethod(aggregate, @selector(webView:navigationResponse:didBecomeDownload:), (IMP)FDMBecameDownload, "v40@0:8@16@24@32");
    }
    if (browser) class_addMethod(browser, NSSelectorFromString(@"webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:"), (IMP)FDMMediaPermission, "v56@0:8@16@24@32q40@?48");
    FDMHook(browser, NSSelectorFromString(@"tab:didCreateWebView:"), (IMP)FDMCreated, &FDMNavOriginalCreated);
    FDMHook(browser, NSSelectorFromString(@"tab:didDeleteWebView:"), (IMP)FDMRemoved, &FDMNavOriginalRemoved);
    FDMHook(NSClassFromString(@"Tab"), NSSelectorFromString(@"updateUserAgentWithURL:"), (IMP)FDMUserAgent, &FDMNavOriginalUA);
    FDMHook(NSClassFromString(@"PandaWebView"), NSSelectorFromString(@"applyWebScaleForCurrentURL"), (IMP)FDMPageZoom, &FDMNavOriginalZoom);
    FDMHook(NSClassFromString(@"PandaWebView"), NSSelectorFromString(@"updateRuleListIfNeedWithUrl:"), (IMP)FDMRules, &FDMNavOriginalRules);
    FDMHook(NSClassFromString(@"SystemScriptManager"), NSSelectorFromString(@"loadJsEngine:completion:"), (IMP)FDMLoadUserJS, &FDMNavOriginalLoadJS);
    FDMHook(NSClassFromString(@"DatabaseUnit"), NSSelectorFromString(@"setCompleteBlock:"), (IMP)FDMSetScriptCompleteBlock, &FDMNavOriginalSetCompleteBlock);
    FDMHook(browser, NSSelectorFromString(@"_addUserScript:"), (IMP)FDMImmediateUserJS, &FDMNavOriginalImmediateUserJS);
    FDMHook(NSClassFromString(@"PandaWebView"), NSSelectorFromString(@"readerDetectorNotification:"), (IMP)FDMReaderDetected, &FDMNavOriginalReader);
    FDMHook(NSClassFromString(@"PreferenceContentView"), NSSelectorFromString(@"updateWithModel"), (IMP)FDMMenuModel, &FDMNavOriginalMenu);
    FDMHook(WKUserContentController.class, @selector(addContentRuleList:), (IMP)FDMAddRule, &FDMNavOriginalAddRule);
    FDMHook(WKUserContentController.class, @selector(removeContentRuleList:), (IMP)FDMRemoveRule, &FDMNavOriginalRemoveRule);
    FDMHook(WKUserContentController.class, @selector(removeAllContentRuleLists), (IMP)FDMRemoveRules, &FDMNavOriginalRemoveRules);
    FDMHook(WKUserContentController.class, @selector(addUserScript:), (IMP)FDMAddUserScript, &FDMNavOriginalAddScript);
}
