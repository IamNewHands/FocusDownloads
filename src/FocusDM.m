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
#import "FDMNavigation.h"

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

static void FDMInstallHostHooks(void);
static void FDMOpenPage(UIViewController *host, UIViewController *page);
static void FDMShowDownloadPill(void);
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
    if (FDMPreferenceType(model) == 0x46444d) {
        SEL hide = NSSelectorFromString(@"hideUserPreferenceView");
        if ([self respondsToSelector:hide]) ((void (*)(id, SEL))objc_msgSend)(self, hide);
        FDMOpenCurrentSiteSettings(self);
        return;
    }
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
    if (FDMBackupCoordinator.shared.recoveryBlocked) {
        UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        UIViewController *controller = [UIViewController new]; controller.view.backgroundColor = UIColor.systemBackgroundColor;
        UILabel *label = [UILabel new]; label.numberOfLines = 0;
        label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; label.adjustsFontForContentSizeCategory = YES;
        label.text = [@"配置恢复尚未完成，浏览器没有载入混合配置。\n\n" stringByAppendingString:FDMBackupCoordinator.shared.recoveryNotice ?: @"请重新打开应用重试恢复。"];
        label.translatesAutoresizingMaskIntoConstraints = NO; [controller.view addSubview:label];
        [NSLayoutConstraint activateConstraints:@[[label.leadingAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.leadingAnchor constant:24],
            [label.trailingAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.trailingAnchor constant:-24],
            [label.centerYAnchor constraintEqualToAnchor:controller.view.centerYAnchor]]];
        window.rootViewController = controller; [self setValue:window forKey:@"window"]; [window makeKeyAndVisible];
        return YES;
    }
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

static void FDMInstallHostHooks(void) {
    Class settings = NSClassFromString(@"SettingViewController");
    FDMInstallHook(settings, @selector(viewWillAppear:), (IMP)FDMSettingsAppear, &FDMOriginalSettingsAppear);
    FDMInstallHook(settings, @selector(tableView:didSelectRowAtIndexPath:), (IMP)FDMSettingsSelect, &FDMOriginalSettingsSelect);
    FDMInstallHook(NSClassFromString(@"BrowserViewController"), NSSelectorFromString(@"preferenceViewDidSelectItem:"), (IMP)FDMPreferenceSelect, &FDMOriginalPreferenceSelect);
    FDMInstallHook(NSClassFromString(@"PreferenceItemCell"), NSSelectorFromString(@"updateWithModel:"), (IMP)FDMPreferenceUpdate, &FDMOriginalPreferenceUpdate);
    FDMInstallHook(NSClassFromString(@"BaseNavigationController"), NSSelectorFromString(@"applyNavigationBarStateForViewController:animated:"), (IMP)FDMNavigationState, &FDMOriginalNavigationState);
    FDMInstallHook(NSClassFromString(@"FileManager"), NSSelectorFromString(@"downloadWithUrl:title:"), (IMP)FDMHostDownload, &FDMOriginalHostDownload);
    FDMInstallNavigationCreatedCallback(^{ FDMShowDownloadPill(); });
    FDMInstallNavigationHooks();
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
