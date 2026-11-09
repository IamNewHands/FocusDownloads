// FocusDM host integration only. Download, storage, policy, backup and icon responsibilities each have one owner.
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import "FDMCommon.h"
#import "FDMEngine.h"
#import "FDMIcons.h"
#import "FDMHostDownloads.h"
#import "FDMDownloadsViewController.h"
#import "FDMPolicy.h"
#import "FDMIntent.h"
#import "FDMBackup.h"
#import "FDMNativePages.h"
#import "FDMWebKitDownloads.h"

static NSString *const FDMDownloadsLink = @"focusdm://downloads";
static NSString *const FDMSitePoliciesLink = @"focusdm://site-policies";
static NSString *const FDMBackupLink = @"focusdm://backup";
static IMP FDMOriginalSettingsAppear;
static IMP FDMOriginalSettingsSelect;
static IMP FDMOriginalPreferenceSelect;
static IMP FDMOriginalPreferenceUpdate;
static IMP FDMOriginalNavigationState;
static IMP FDMOriginalHostDownload;
static IMP FDMOriginalDidFinishLaunch;
static IMP FDMOriginalBackgroundEvents;
static IMP FDMOriginalDidEnterBackground;
static IMP FDMOriginalUpdateUserAgent;
static IMP FDMOriginalApplyWebScale;
static IMP FDMOriginalMenuAction;

static void FDMInstallHostHooks(void);
static void FDMOpenPage(UIViewController *host, UIViewController *page);
static void FDMShowDownloadPill(void);
static void FDMApplyNavigationPreferences(id webView, NSString *origin, id preferences);
static NSString *FDMOriginForWebView(id webView);
static UIViewController *FDMTopController(UIViewController *controller);
static UIWindow *FDMActiveWindow(void);

static BOOL FDMInstallHook(Class cls, SEL selector, IMP replacement, IMP *original) {
    if (!cls || !selector) return NO;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) { FDMLog(@"host hook missing %@ %@", NSStringFromClass(cls), NSStringFromSelector(selector)); return NO; }
    IMP previous = method_getImplementation(method);
    if (previous == replacement) return YES;
    if (original) *original = previous;
    if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) method_setImplementation(method, replacement);
    return YES;
}

// The same replacement can be installed on more than one class (the host has two navigation
// delegates). One shared `original` pointer would then dispatch a delegate's call into the other
// class's implementation, so originals are keyed by class + selector.
static NSMutableDictionary<NSString *, NSValue *> *FDMOriginalIMPMap(void) {
    static NSMutableDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ map = [NSMutableDictionary dictionary]; });
    return map;
}

static NSString *FDMIMPKey(Class cls, SEL selector) {
    return [NSString stringWithFormat:@"%@|%@", NSStringFromClass(cls), NSStringFromSelector(selector)];
}

static BOOL FDMInstallClassHook(Class cls, SEL selector, IMP replacement) {
    if (!cls || !selector) return NO;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) { FDMLog(@"host hook missing %@ %@", NSStringFromClass(cls), NSStringFromSelector(selector)); return NO; }
    IMP previous = method_getImplementation(method);
    if (previous == replacement) return YES;
    @synchronized (FDMOriginalIMPMap()) { FDMOriginalIMPMap()[FDMIMPKey(cls, selector)] = [NSValue valueWithPointer:previous]; }
    if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) method_setImplementation(method, replacement);
    return YES;
}

static IMP FDMOriginalIMPFor(id object, SEL selector) {
    for (Class cls = object_getClass(object); cls; cls = class_getSuperclass(cls)) {
        @synchronized (FDMOriginalIMPMap()) {
            NSValue *value = FDMOriginalIMPMap()[FDMIMPKey(cls, selector)];
            if (value) return value.pointerValue;
        }
    }
    return NULL;
}

static UIWindow *FDMActiveWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive || ![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) if (window.isKeyWindow) return window;
    }
    // Focus 2.9.7 has no UIApplicationSceneManifest and uses AppDelegate.window.
    for (UIWindow *window in UIApplication.sharedApplication.windows) if (window.isKeyWindow) return window;
    return nil;
}

static UIViewController *FDMTopController(UIViewController *controller) {
    if (!controller) return nil;
    if (controller.presentedViewController) return FDMTopController(controller.presentedViewController);
    if ([controller isKindOfClass:UINavigationController.class]) return FDMTopController(((UINavigationController *)controller).topViewController);
    if ([controller isKindOfClass:UITabBarController.class]) return FDMTopController(((UITabBarController *)controller).selectedViewController);
    return controller;
}

static void FDMOpenPage(UIViewController *host, UIViewController *page);

static void FDMOpenDownloads(UIViewController *host) {
    FDMOpenPage(host, [[FDMDownloadsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped]);
}

static void FDMOpenPage(UIViewController *host, UIViewController *page) {
    if (!host || !page) return;
    if (host.navigationController.transitionCoordinator) return;
    if (host.navigationController) [host.navigationController pushViewController:page animated:YES];
    else {
        UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:page];
        navigation.modalPresentationStyle = UIModalPresentationFullScreen;
        [host presentViewController:navigation animated:YES completion:nil];
    }
}
static NSString *FDMHeaderTitle(id header) {
    return [header isKindOfClass:NSString.class] ? header : FDMString(FDMValue(header, @"title"));
}

// Inserts one native SettingModel row into the section that contains the existing "进阶" header.
// The row is rendered by the host's own cellForRowAtIndexPath:, so icon, insets and height match.
static void FDMEnsureSettingsRow(UIViewController *controller, NSString *title, NSString *link) {
    @try {
        id model = FDMValue(controller, @"model");
        id headers = FDMValue(controller, @"sectionHeaderModel");
        if (![model isKindOfClass:NSMutableArray.class]) return;
        NSMutableArray *sections = model;
        for (NSArray *section in sections) {
            if (![section isKindOfClass:NSArray.class]) continue;
            for (id row in section) if ([FDMString(FDMValue(row, @"link")) isEqual:link]) return;
        }
        NSInteger selected = -1;
        if ([headers isKindOfClass:NSArray.class]) {
            for (NSUInteger index = 0; index < MIN(sections.count, [headers count]); index++) {
                if ([FDMHeaderTitle(headers[index]) containsString:@"进阶"]) { selected = (NSInteger)index; break; }
            }
        }
        if (selected < 0) {
            for (NSInteger index = (NSInteger)sections.count - 1; index >= 0; index--) {
                if ([sections[index] isKindOfClass:NSArray.class] && [sections[index] count]) { selected = index; break; }
            }
        }
        if (selected < 0) return;
        NSMutableArray *rows = [sections[selected] mutableCopy];
        Class modelClass = NSClassFromString(@"SettingModel");
        if (!modelClass) return;
        id row = [[modelClass alloc] init];
        id template = nil;
        for (id candidate in rows.reverseObjectEnumerator) if (FDMString(FDMValue(candidate, @"link")).length) { template = candidate; break; }
        [row setValue:title forKey:@"title"];
        [row setValue:link forKey:@"link"];
        for (NSString *key in @[@"imageName", @"imageBackgroundColor", @"type"]) {
            id value = FDMValue(template, key);
            if (value) [row setValue:value forKey:key];
        }
        [row setValue:@YES forKey:@"isLastInSection"];
        id last = rows.lastObject;
        if (last) [last setValue:@NO forKey:@"isLastInSection"];
        [rows addObject:row];
        sections[selected] = rows;
        UITableView *table = FDMValue(controller, @"tableView");
        if ([table isKindOfClass:UITableView.class]) [table reloadData];
    } @catch (NSException *exception) { FDMLog(@"settings row failed %@", exception.reason); }
}

static UIViewController *FDMPageForLink(NSString *link) {
    if ([link isEqual:FDMDownloadsLink]) return [[FDMDownloadsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    if ([link isEqual:FDMSitePoliciesLink]) return [[FDMSitePoliciesViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    if ([link isEqual:FDMBackupLink]) return [[FDMBackupViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    return nil;
}

static void FDMSettingsAppear(id self, SEL selector, BOOL animated) {
    if (FDMOriginalSettingsAppear) ((void (*)(id, SEL, BOOL))FDMOriginalSettingsAppear)(self, selector, animated);
    FDMEnsureSettingsRow(self, @"下载管理", FDMDownloadsLink);
    FDMEnsureSettingsRow(self, @"网站规则", FDMSitePoliciesLink);
    FDMEnsureSettingsRow(self, @"数据备份", FDMBackupLink);
}

static void FDMSettingsSelect(id self, SEL selector, UITableView *table, NSIndexPath *path) {
    id sections = FDMValue(self, @"model");
    if ([sections isKindOfClass:NSArray.class] && path.section >= 0 && path.section < [sections count]) {
        id rows = sections[path.section];
        if ([rows isKindOfClass:NSArray.class] && path.row >= 0 && path.row < [rows count]) {
            NSString *link = FDMString(FDMValue(rows[path.row], @"link"));
            UIViewController *page = FDMPageForLink(link);
            if (page) {
                [table deselectRowAtIndexPath:path animated:YES];
                FDMOpenPage(self, page);
                return;
            }
        }
    }
    if (FDMOriginalSettingsSelect) ((void (*)(id, SEL, UITableView *, NSIndexPath *))FDMOriginalSettingsSelect)(self, selector, table, path);
}

static NSInteger FDMPreferenceType(id model) {
    return [FDMValue(model, @"itemType") respondsToSelector:@selector(integerValue)] ? [FDMValue(model, @"itemType") integerValue] : -1;
}

static void FDMPreferenceSelect(id self, SEL selector, id model) {
    if (FDMPreferenceType(model) == 17) {
        SEL hide = NSSelectorFromString(@"hideUserPreferenceView");
        if ([self respondsToSelector:hide]) ((void (*)(id, SEL))objc_msgSend)(self, hide);
        FDMOpenDownloads(self);
    } else if (FDMOriginalPreferenceSelect) ((void (*)(id, SEL, id))FDMOriginalPreferenceSelect)(self, selector, model);
}

static void FDMPreferenceUpdate(id self, SEL selector, id model) {
    if (FDMPreferenceType(model) == 17) {
        @try {
            [model setValue:@"下载管理" forKey:@"title"];
            [model setValue:@"tool_down_icon" forKey:@"imageName"];
        } @catch (NSException *exception) { FDMLog(@"preference style unavailable"); }
    }
    if (FDMOriginalPreferenceUpdate) ((void (*)(id, SEL, id))FDMOriginalPreferenceUpdate)(self, selector, model);
}

static void FDMNavigationState(id self, SEL selector, UIViewController *controller, BOOL animated) {
    // Only task-owned pages are exempt. Every host and third-party controller keeps the host contract.
    if ([controller isKindOfClass:FDMDownloadsViewController.class] ||
        [controller isKindOfClass:FDMSitePoliciesViewController.class] ||
        [controller isKindOfClass:FDMSitePolicyEditViewController.class] ||
        [controller isKindOfClass:FDMBackupViewController.class] ||
        [NSStringFromClass(controller.class) isEqual:@"FDMIconDiagnosticsViewController"]) return;
    if (FDMOriginalNavigationState) ((void (*)(id, SEL, id, BOOL))FDMOriginalNavigationState)(self, selector, controller, animated);
}

#pragma mark - site policy host wiring

// The host resolves its global UA here on every navigation; a site override is applied on top of it
// so removing an override restores the current global baseline rather than a hardcoded nil.
static void FDMUpdateUserAgent(id self, SEL selector, id url) {
    if (FDMOriginalUpdateUserAgent) ((void (*)(id, SEL, id))FDMOriginalUpdateUserAgent)(self, selector, url);
    @try {
        NSString *origin = FDMNormalizedOrigin(FDMString(url) ?: [url absoluteString]);
        if (!origin) return;
        NSDictionary *entry = [FDMSitePolicyStore.shared entryForOrigin:origin];
        if (!entry) return;
        id webView = FDMValue(self, @"webView");
        if (!webView) return;
        NSDictionary *baseline = FDMPolicyGlobalBaseline();
        id agent = entry[FDMPolicyUserAgent];
        if (agent == NSNull.null) {
            // Explicit removal: fall back to whatever the global baseline is now.
            agent = baseline[FDMPolicyUserAgent];
            if (agent == NSNull.null) agent = nil;
        } else if (![agent isKindOfClass:NSString.class]) {
            return;
        }
        [webView setValue:agent forKey:@"customUserAgent"];
    } @catch (NSException *exception) { FDMLog(@"site UA override skipped: %@", exception.reason); }
}

// The host derives page zoom from its own font-size setting; a site override replaces that result.
static void FDMApplyWebScale(id self, SEL selector) {
    if (FDMOriginalApplyWebScale) ((void (*)(id, SEL))FDMOriginalApplyWebScale)(self, selector);
    @try {
        id webView = self;
        NSString *current = FDMString(FDMValue(webView, @"URL"));
        NSString *origin = FDMNormalizedOrigin(current);
        if (!origin) return;
        NSDictionary *entry = [FDMSitePolicyStore.shared entryForOrigin:origin];
        id zoom = entry[FDMPolicyPageZoom];
        if (![zoom isKindOfClass:NSNumber.class]) return;
        double value = [zoom doubleValue];
        if (!isfinite(value) || value < 0.5 || value > 3.0) return;
        [webView setValue:@(value) forKey:@"pageZoom"];
    } @catch (NSException *exception) { FDMLog(@"site zoom override skipped: %@", exception.reason); }
}

static NSString *FDMOriginForWebView(id webView) {
    return FDMNormalizedOrigin(FDMString(FDMValue(webView, @"URL")));
}

// Captures the real navigation request so a download response can reuse its exact context.
static void FDMRecordIntent(id webView, id navigationAction, unsigned long long generation) {
    if (!webView || !navigationAction) return;
    NSURLRequest *request = FDMValue(navigationAction, @"request");
    if (![request isKindOfClass:NSURLRequest.class]) return;
    NSString *tabID = FDMString(FDMValue(webView, @"focusdmTabID"));
    if (!tabID.length) {
        tabID = NSUUID.UUID.UUIDString;
        @try { [webView setValue:tabID forKey:@"focusdmTabID"]; }
        @catch (NSException *exception) { objc_setAssociatedObject(webView, "FocusDMTabID", tabID, OBJC_ASSOCIATION_COPY_NONATOMIC); }
    }
    id dataStore = FDMValue(FDMValue(webView, @"configuration"), @"websiteDataStore");
    NSString *source = FDMOriginForWebView(webView);
    BOOL userInitiated = [FDMValue(navigationAction, @"navigationType") integerValue] == 0;
    [FDMIntentRegistry.shared registerRequest:request tabID:tabID navigationGeneration:generation
                                 sourceOrigin:source suggestedFilename:nil dataStore:dataStore userInitiated:userInitiated];
}

static void FDMNavAction(id self, SEL selector, WKWebView *webView, id navigationAction, id preferences, void (^decisionHandler)(NSInteger)) {
    NSString *origin = FDMNormalizedOrigin(FDMString(FDMValue(FDMValue(navigationAction, @"request"), @"URL")));
    if (origin) {
        FDMApplyNavigationPreferences(webView, origin, preferences);
        unsigned long long generation = [FDMValue(webView, @"focusdmNavigationGeneration") unsignedLongLongValue] + 1;
        @try { [webView setValue:@(generation) forKey:@"focusdmNavigationGeneration"]; }
        @catch (NSException *exception) { /* generation stays advisory only */ }
        FDMRecordIntent(webView, navigationAction, generation);
    }
    IMP original = FDMOriginalIMPFor(self, selector);
    if (original) ((void (*)(id, SEL, id, id, id, void (^)(NSInteger)))original)(self, selector, webView, navigationAction, preferences, decisionHandler);
    else if (decisionHandler) decisionHandler(1);
}

// A response that is a download becomes a WKDownload so the original request context (POST body,
// cookies, one-time ticket) is preserved instead of being re-requested as an anonymous GET.
static void FDMNavResponse(id self, SEL selector, WKWebView *webView, id navigationResponse, void (^decisionHandler)(NSInteger)) {
    NSHTTPURLResponse *response = FDMValue(navigationResponse, @"response");
    BOOL isDownload = NO;
    if ([response isKindOfClass:NSHTTPURLResponse.class]) {
        NSString *disposition = response.allHeaderFields[@"Content-Disposition"];
        NSString *mime = response.MIMEType.lowercaseString;
        BOOL attachment = [disposition.lowercaseString containsString:@"attachment"];
        // A navigation that resolves to a non-document body is a file the user asked for.
        BOOL fileBody = mime.length && ![mime hasPrefix:@"text/html"] && ![mime hasPrefix:@"application/xhtml"]
            && ![mime hasPrefix:@"application/json"] && ![mime hasPrefix:@"text/xml"];
        isDownload = attachment || fileBody;
        if (isDownload) FDMLog(@"download response origin=%@ status=%ld mime=%@", FDMOriginForURL(response.URL), (long)response.statusCode, mime);
    }
    if (isDownload) {
        NSString *filename = nil;
        NSString *disposition = response.allHeaderFields[@"Content-Disposition"];
        NSRange range = [disposition rangeOfString:@"filename=" options:NSCaseInsensitiveSearch];
        if (range.location != NSNotFound) {
            filename = [disposition substringFromIndex:NSMaxRange(range)];
            filename = [filename stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\"'; "]];
        }
        NSString *tabID = FDMString(FDMValue(webView, @"focusdmTabID"));
        FDMDownloadIntent *intent = [FDMIntentRegistry.shared takeIntentMatchingURL:response.URL];
        SEL downloadSelector = NSSelectorFromString(@"startDownloadUsingRequest:completionHandler:");
        NSURLRequest *original = FDMValue(navigationResponse, @"request");
        if ([webView respondsToSelector:downloadSelector] && [original isKindOfClass:NSURLRequest.class]) {
            // Keep the original navigation as a WebKit download. The completion handler receives the
            // WKDownload; it is adopted by the single WebKit transport owner.
            ((void (*)(id, SEL, id, id))objc_msgSend)(webView, downloadSelector, original, ^(id download) {
                if (download) [FDMWebKitDownloads.shared adoptDownload:download intent:intent tabID:tabID];
                else FDMLog(@"webkit download start returned no download");
                FDMShowDownloadPill();
            });
            if (decisionHandler) decisionHandler(0);  // cancel the navigation; the download carries it
            return;
        }
        // No WKDownload on this system: say so instead of silently re-requesting the URL as a GET.
        FDMLog(@"download response cannot be preserved on this system version");
        if (intent) {
            [FDMEngine.shared startIntent:intent request:[FDMIntentRegistry.shared requestForIntent:intent.intentID] error:nil];
        }
        FDMShowDownloadPill();
        (void)filename;
    }
    IMP original = FDMOriginalIMPFor(self, selector);
    if (original) ((void (*)(id, SEL, id, id, void (^)(NSInteger)))original)(self, selector, webView, navigationResponse, decisionHandler);
    else if (decisionHandler) decisionHandler(1);
}

// Applies per-site preferences to a navigation before it commits.
static void FDMApplyNavigationPreferences(id webView, NSString *origin, id preferences) {
    if (!origin) return;
    NSDictionary *entry = [FDMSitePolicyStore.shared entryForOrigin:origin];
    if (!entry) return;
    BOOL enhancementsOff = [FDMTemporaryEnhancementOff.shared isOffForObject:webView];
    @try {
        id mode = entry[FDMPolicyContentMode];
        if ([mode isKindOfClass:NSString.class] && preferences) {
            // 0 = recommended (mobile), 1 = desktop.
            [preferences setValue:@([mode isEqual:@"desktop"] ? 1 : 0) forKey:@"preferredContentMode"];
        }
        id javascript = entry[FDMPolicyPageJavaScript];
        if ([javascript isKindOfClass:NSString.class] && preferences) {
            [preferences setValue:@([javascript isEqual:@"on"]) forKey:@"allowsContentJavaScript"];
        }
        (void)enhancementsOff;
    } @catch (NSException *exception) { FDMLog(@"navigation preferences skipped: %@", exception.reason); }
}

static void FDMShowDownloadPill(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = FDMActiveWindow();
        if (!window || [window viewWithTag:0x46444D50]) return;
        UIButton *pill = [UIButton buttonWithType:UIButtonTypeSystem];
        pill.tag = 0x46444D50;
        pill.translatesAutoresizingMaskIntoConstraints = NO;
        [pill setTitle:@"查看下载" forState:UIControlStateNormal];
        pill.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCallout];
        [pill setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        pill.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.92];
        pill.layer.cornerRadius = 22;
        [window addSubview:pill];
        [NSLayoutConstraint activateConstraints:@[
            [pill.centerXAnchor constraintEqualToAnchor:window.centerXAnchor],
            [pill.bottomAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.bottomAnchor constant:-68],
            [pill.widthAnchor constraintGreaterThanOrEqualToConstant:112],
            [pill.heightAnchor constraintGreaterThanOrEqualToConstant:44],
        ]];
        __weak UIButton *weakPill = pill;
        [pill addAction:[UIAction actionWithHandler:^(UIAction *action) {
            [weakPill removeFromSuperview];
            FDMOpenDownloads(FDMTopController(FDMActiveWindow().rootViewController));
        }] forControlEvents:UIControlEventTouchUpInside];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 9 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [weakPill removeFromSuperview];
        });
    });
}

static void FDMHostDownload(id self, SEL selector, id url, id title) {
    if (FDMOriginalHostDownload) ((void (*)(id, SEL, id, id))FDMOriginalHostDownload)(self, selector, url, title);
    dispatch_async(dispatch_get_main_queue(), ^{ [FDMHostDownloads.shared refresh]; FDMShowDownloadPill(); });
}

static BOOL FDMDidFinishLaunch(id self, SEL selector, UIApplication *application, NSDictionary *options) {
    FDMInstallHostHooks();
    FDMInstallIconHooks();
    (void)FDMEngine.shared;
    // A previous restore may have been interrupted; settle it before any configuration is exposed.
    [FDMBackupCoordinator.shared recoverInterruptedTransaction];
    BOOL result = FDMOriginalDidFinishLaunch ? ((BOOL (*)(id, SEL, id, id))FDMOriginalDidFinishLaunch)(self, selector, application, options) : YES;
    dispatch_async(dispatch_get_main_queue(), ^{ [FDMHostDownloads.shared refresh]; });
    return result;
}

static void FDMBackgroundEvents(id self, SEL selector, UIApplication *application, NSString *identifier, void (^completion)(void)) {
    if ([identifier isEqual:FDMBackgroundSessionIdentifier]) {
        [FDMEngine.shared setBackgroundCompletion:completion];
        return;
    }
    if (FDMOriginalBackgroundEvents) ((void (*)(id, SEL, id, id, id))FDMOriginalBackgroundEvents)(self, selector, application, identifier, completion);
    else if (completion) completion();
}

static void FDMDidEnterBackground(id self, SEL selector, UIApplication *application) {
    FDMFlushIconWrites();
    if (FDMOriginalDidEnterBackground) ((void (*)(id, SEL, id))FDMOriginalDidEnterBackground)(self, selector, application);
}

// Adds "网站设置" to the host's own command alert without replacing it: the original builds and
// presents the alert, then we append one action for the current origin.
static void FDMCommandMenu(id self, SEL selector, id sender) {
    if (FDMOriginalMenuAction) ((void (*)(id, SEL, id))FDMOriginalMenuAction)(self, selector, sender);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = FDMTopController(FDMActiveWindow().rootViewController);
        UIAlertController *alert = [top isKindOfClass:UIAlertController.class] ? (UIAlertController *)top : nil;
        if (!alert || alert.preferredStyle != UIAlertControllerStyleActionSheet) return;
        for (UIAlertAction *existing in alert.actions) if ([existing.title containsString:@"网站设置"]) return;
        id tab = FDMValue(FDMValue(self, @"tabManager"), @"selectedTab");
        NSString *origin = FDMOriginForWebView(FDMValue(tab, @"webView"));
        if (!origin) return;
        __weak typeof(self) weakSelf = self;
        [alert addAction:[UIAlertAction actionWithTitle:@"网站设置" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            FDMSitePolicyEditViewController *page = [[FDMSitePolicyEditViewController alloc] initWithOrigin:origin];
            page.didChangePolicy = ^(BOOL reload) {
                if (!reload) return;
                id webView = FDMValue(FDMValue(FDMValue(weakSelf, @"tabManager"), @"selectedTab"), @"webView");
                SEL reloadSelector = NSSelectorFromString(@"reload");
                if ([webView respondsToSelector:reloadSelector]) ((void (*)(id, SEL))objc_msgSend)(webView, reloadSelector);
            };
            FDMOpenPage(weakSelf, page);
        }]];
    });
}

static void FDMInstallHostHooks(void) {
    Class settings = NSClassFromString(@"SettingViewController");
    FDMInstallHook(settings, @selector(viewWillAppear:), (IMP)FDMSettingsAppear, &FDMOriginalSettingsAppear);
    FDMInstallHook(settings, @selector(tableView:didSelectRowAtIndexPath:), (IMP)FDMSettingsSelect, &FDMOriginalSettingsSelect);
    FDMInstallHook(NSClassFromString(@"BrowserViewController"), NSSelectorFromString(@"preferenceViewDidSelectItem:"), (IMP)FDMPreferenceSelect, &FDMOriginalPreferenceSelect);
    FDMInstallHook(NSClassFromString(@"PreferenceItemCell"), NSSelectorFromString(@"updateWithModel:"), (IMP)FDMPreferenceUpdate, &FDMOriginalPreferenceUpdate);
    FDMInstallHook(NSClassFromString(@"BaseNavigationController"), NSSelectorFromString(@"applyNavigationBarStateForViewController:animated:"), (IMP)FDMNavigationState, &FDMOriginalNavigationState);
    FDMInstallHook(NSClassFromString(@"FileManager"), NSSelectorFromString(@"downloadWithUrl:title:"), (IMP)FDMHostDownload, &FDMOriginalHostDownload);
    // Site policy: UA is re-resolved per navigation, zoom per page load, and preferences per action.
    FDMInstallHook(NSClassFromString(@"Tab"), NSSelectorFromString(@"updateUserAgentWithURL:"), (IMP)FDMUpdateUserAgent, &FDMOriginalUpdateUserAgent);
    FDMInstallHook(NSClassFromString(@"PandaWebView"), NSSelectorFromString(@"applyWebScaleForCurrentURL"), (IMP)FDMApplyWebScale, &FDMOriginalApplyWebScale);
    // The host has two navigation delegates; both must be wrapped or one path bypasses the policy.
    // They share one replacement IMP, so the original is recorded per class.
    FDMInstallClassHook(NSClassFromString(@"WebViewNavDelegate"), @selector(webView:decidePolicyForNavigationAction:preferences:decisionHandler:), (IMP)FDMNavAction);
    FDMInstallClassHook(NSClassFromString(@"WebViewNavDelegate"), @selector(webView:decidePolicyForNavigationResponse:decisionHandler:), (IMP)FDMNavResponse);
    FDMInstallClassHook(browser, @selector(webView:decidePolicyForNavigationAction:preferences:decisionHandler:), (IMP)FDMNavAction);
    FDMInstallClassHook(browser, @selector(webView:decidePolicyForNavigationResponse:decisionHandler:), (IMP)FDMNavResponse);
    FDMInstallHook(browser, NSSelectorFromString(@"_showCommandMenu:"), (IMP)FDMCommandMenu, &FDMOriginalMenuAction);
}

__attribute__((constructor)) static void FDMInitialize(void) {
    @autoreleasepool {
        FDMInstallCrashHandlers();
        FDMInstallHostHooks();
        FDMInstallIconHooks();
        Class delegate = NSClassFromString(@"AppDelegate");
        FDMInstallHook(delegate, @selector(application:didFinishLaunchingWithOptions:), (IMP)FDMDidFinishLaunch, &FDMOriginalDidFinishLaunch);
        FDMInstallHook(delegate, @selector(application:handleEventsForBackgroundURLSession:completionHandler:), (IMP)FDMBackgroundEvents, &FDMOriginalBackgroundEvents);
        FDMInstallHook(delegate, @selector(applicationDidEnterBackground:), (IMP)FDMDidEnterBackground, &FDMOriginalDidEnterBackground);
    }
}
