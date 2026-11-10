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
#import "FDMPageImages.h"
#import "FDMPageNavigation.h"

static NSString *const FDMDownloadsLink = @"focusdm://downloads";
static NSString *const FDMSitePoliciesLink = @"focusdm://site-policies";
static NSString *const FDMBackupLink = @"focusdm://backup";
static IMP FDMOriginalSettingsAppear;
static IMP FDMOriginalSettingsUpdate;
static IMP FDMOriginalSettingsSelect;
static IMP FDMOriginalPreferenceSelect;
static IMP FDMOriginalPreferenceUpdate;
static IMP FDMOriginalNavigationState;
static IMP FDMOriginalNavigationWillShow;
static IMP FDMOriginalNavigationDidShow;
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
    FDMShowOwnedPage(host, page);
}
static NSString *FDMHeaderTitle(id header) {
    return [header isKindOfClass:NSString.class] ? header : FDMString(FDMValue(header, @"title"));
}

static NSArray<NSDictionary *> *FDMSettingsEntries(void) {
    return @[@{@"title": @"下载管理", @"link": FDMDownloadsLink},
             @{@"title": @"网站规则", @"link": FDMSitePoliciesLink},
             @{@"title": @"数据备份", @"link": FDMBackupLink}];
}

static BOOL FDMIsSettingsLink(NSString *link) {
    return [link isEqual:FDMDownloadsLink] || [link isEqual:FDMSitePoliciesLink] || [link isEqual:FDMBackupLink];
}

static BOOL FDMSetSettingsValue(id row, NSString *key, id value) {
    id old = FDMValue(row, key);
    if (old == value || [old isEqual:value]) return NO;
    [row setValue:value forKey:key];
    return YES;
}

// Focus 2.9.7 renders type 0 as SettingVipCell and type 17 as RecommendCell.
// A task-owned type takes its ordinary SettingCell branch without inheriting VIP behavior.
static const int FDMSettingsRowType = 0x46444d;
static void FDMEnsureSettingsRows(UIViewController *controller) {
    @try {
        id model = FDMValue(controller, @"model");
        id headers = FDMValue(controller, @"sectionHeaderModel");
        if (![model isKindOfClass:NSMutableArray.class]) return;
        NSMutableArray *sections = model;
        NSInteger selected = -1;
        NSString *advanced = [NSBundle.mainBundle localizedStringForKey:@"setting.advance.title" value:@"进阶功能" table:nil];
        if ([headers isKindOfClass:NSArray.class]) {
            for (NSUInteger index = 0; index < MIN(sections.count, [headers count]); index++) {
                NSString *title = FDMHeaderTitle(headers[index]);
                if ([title isEqual:advanced] || [title containsString:@"进阶"]) { selected = (NSInteger)index; break; }
            }
        }
        if (selected < 0) {
            for (NSUInteger index = 0; index < sections.count && selected < 0; index++) {
                if (![sections[index] isKindOfClass:NSArray.class]) continue;
                for (id row in sections[index]) {
                    NSInteger type = [FDMValue(row, @"type") integerValue];
                    if (type > 0 && type != 17 && !FDMIsSettingsLink(FDMString(FDMValue(row, @"link")))) {
                        selected = (NSInteger)index; break;
                    }
                }
            }
        }
        if (selected < 0 || ![sections[selected] isKindOfClass:NSArray.class]) return;
        Class modelClass = NSClassFromString(@"SettingModel");
        if (!modelClass) return;
        id template = nil;
        for (id candidate in [sections[selected] reverseObjectEnumerator]) {
            NSInteger type = [FDMValue(candidate, @"type") integerValue];
            if (type > 0 && type != 17 && !FDMIsSettingsLink(FDMString(FDMValue(candidate, @"link")))) {
                template = candidate; break;
            }
        }
        BOOL changed = NO;
        NSMutableArray *updated = [NSMutableArray arrayWithCapacity:sections.count];
        NSMutableDictionary *existing = [NSMutableDictionary dictionary];
        for (id section in sections) {
            if (![section isKindOfClass:NSArray.class]) { [updated addObject:section]; continue; }
            NSMutableArray *rows = [NSMutableArray array];
            for (id row in section) {
                NSString *link = FDMString(FDMValue(row, @"link"));
                if (FDMIsSettingsLink(link)) {
                    if (!existing[link]) existing[link] = row;
                } else [rows addObject:row];
            }
            [updated addObject:rows];
        }
        NSMutableArray *rows = updated[selected];
        for (NSDictionary *entry in FDMSettingsEntries()) {
            id row = existing[entry[@"link"]] ?: [[modelClass alloc] init];
            changed |= FDMSetSettingsValue(row, @"title", entry[@"title"]);
            changed |= FDMSetSettingsValue(row, @"link", entry[@"link"]);
            changed |= FDMSetSettingsValue(row, @"type", @(FDMSettingsRowType));
            changed |= FDMSetSettingsValue(row, @"content", nil);
            for (NSString *key in @[@"imageName", @"imageBackgroundColor"]) {
                id value = FDMValue(template, key);
                if (value) changed |= FDMSetSettingsValue(row, key, value);
            }
            [rows addObject:row];
        }
        for (NSUInteger index = 0; index < sections.count; index++) {
            id original = sections[index], replacement = updated[index];
            if (![replacement isKindOfClass:NSArray.class]) continue;
            BOOL different = ![original isEqual:replacement];
            if (different || index == (NSUInteger)selected) {
                for (NSUInteger rowIndex = 0; rowIndex < [replacement count]; rowIndex++) {
                    changed |= FDMSetSettingsValue(replacement[rowIndex], @"isFirstInSection", @(rowIndex == 0));
                    changed |= FDMSetSettingsValue(replacement[rowIndex], @"isLastInSection", @(rowIndex + 1 == [replacement count]));
                }
            }
            if (different) { sections[index] = replacement; changed = YES; }
        }
        UITableView *table = FDMValue(controller, @"tableView");
        if (changed && [table isKindOfClass:UITableView.class]) [table reloadData];
    } @catch (NSException *exception) { FDMLog(@"settings rows failed %@", exception.reason); }
}

static UIViewController *FDMPageForLink(NSString *link) {
    if ([link isEqual:FDMDownloadsLink]) return [[FDMDownloadsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    if ([link isEqual:FDMSitePoliciesLink]) return [[FDMSitePoliciesViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    if ([link isEqual:FDMBackupLink]) return [[FDMBackupViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    return nil;
}

static void FDMSettingsAppear(id self, SEL selector, BOOL animated) {
    if (FDMOriginalSettingsAppear) ((void (*)(id, SEL, BOOL))FDMOriginalSettingsAppear)(self, selector, animated);
    FDMEnsureSettingsRows(self);
}

static void FDMSettingsUpdate(id self, SEL selector) {
    if (FDMOriginalSettingsUpdate) ((void (*)(id, SEL))FDMOriginalSettingsUpdate)(self, selector);
    FDMEnsureSettingsRows(self);
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
    if (FDMPreferenceType(model) == 0x464449) {
        FDMClosePreferenceThenPerform(self, ^(UIViewController *host) { FDMOpenPageImages(host); }); return;
    }
    if (FDMPreferenceType(model) == 0x46444d) {
        FDMClosePreferenceThenPerform(self, ^(UIViewController *host) { FDMOpenCurrentSiteSettings(host); });
        return;
    }
    if (FDMPreferenceType(model) == 17) {
        FDMClosePreferenceThenPerform(self, ^(UIViewController *host) { FDMOpenDownloads(host); });
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
    if (FDMIsOwnedNavigationPage(self, controller)) { FDMApplyOwnedNavigationState(self, controller, animated); return; }
    if (FDMOriginalNavigationState) ((void (*)(id, SEL, id, BOOL))FDMOriginalNavigationState)(self, selector, controller, animated);
}

static void FDMNavigationWillShow(id self, SEL selector, UINavigationController *navigation, UIViewController *controller, BOOL animated) {
    if (FDMOriginalNavigationWillShow) ((void (*)(id, SEL, id, id, BOOL))FDMOriginalNavigationWillShow)(self, selector, navigation, controller, animated);
    __weak UINavigationController *weakNavigation = navigation;
    [navigation.transitionCoordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        if (!context.isCancelled) return;
        UINavigationController *current = weakNavigation;
        if (!current) return;
        FDMFinishOwnedNavigationTransition(current, current.topViewController);
        FDMNavigationState(current, NSSelectorFromString(@"applyNavigationBarStateForViewController:animated:"), current.topViewController, NO);
    }];
}

static void FDMNavigationDidShow(id self, SEL selector, UINavigationController *navigation, UIViewController *controller, BOOL animated) {
    FDMFinishOwnedNavigationTransition(navigation, controller);
    if (FDMOriginalNavigationDidShow) ((void (*)(id, SEL, id, id, BOOL))FDMOriginalNavigationDidShow)(self, selector, navigation, controller, animated);
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
    FDMInstallHook(settings, NSSelectorFromString(@"updateWithModel"), (IMP)FDMSettingsUpdate, &FDMOriginalSettingsUpdate);
    FDMInstallHook(settings, @selector(tableView:didSelectRowAtIndexPath:), (IMP)FDMSettingsSelect, &FDMOriginalSettingsSelect);
    FDMInstallHook(NSClassFromString(@"BrowserViewController"), NSSelectorFromString(@"preferenceViewDidSelectItem:"), (IMP)FDMPreferenceSelect, &FDMOriginalPreferenceSelect);
    FDMInstallHook(NSClassFromString(@"PreferenceItemCell"), NSSelectorFromString(@"updateWithModel:"), (IMP)FDMPreferenceUpdate, &FDMOriginalPreferenceUpdate);
    FDMInstallHook(NSClassFromString(@"BaseNavigationController"), NSSelectorFromString(@"applyNavigationBarStateForViewController:animated:"), (IMP)FDMNavigationState, &FDMOriginalNavigationState);
    FDMInstallHook(NSClassFromString(@"BaseNavigationController"), @selector(navigationController:willShowViewController:animated:), (IMP)FDMNavigationWillShow, &FDMOriginalNavigationWillShow);
    FDMInstallHook(NSClassFromString(@"BaseNavigationController"), @selector(navigationController:didShowViewController:animated:), (IMP)FDMNavigationDidShow, &FDMOriginalNavigationDidShow);
    FDMInstallPreferenceClosingHooks();
    FDMInstallHook(NSClassFromString(@"FileManager"), NSSelectorFromString(@"downloadWithUrl:title:"), (IMP)FDMHostDownload, &FDMOriginalHostDownload);
    FDMInstallNavigationCreatedCallback(^{ FDMShowDownloadPill(); });
    FDMInstallNavigationHooks();
}

#if defined(FDM_TESTING)
void FDMTestInstallSettingsHooks(void) {
    Class settings = NSClassFromString(@"SettingViewController");
    FDMInstallHook(settings, @selector(viewWillAppear:), (IMP)FDMSettingsAppear, &FDMOriginalSettingsAppear);
    FDMInstallHook(settings, NSSelectorFromString(@"updateWithModel"), (IMP)FDMSettingsUpdate, &FDMOriginalSettingsUpdate);
    FDMInstallHook(settings, @selector(tableView:didSelectRowAtIndexPath:), (IMP)FDMSettingsSelect, &FDMOriginalSettingsSelect);
}
void FDMTestInstallPageNavigationHooks(void) {
    Class navigation = NSClassFromString(@"BaseNavigationController");
    FDMInstallHook(navigation, NSSelectorFromString(@"applyNavigationBarStateForViewController:animated:"), (IMP)FDMNavigationState, &FDMOriginalNavigationState);
    FDMInstallHook(navigation, @selector(navigationController:willShowViewController:animated:), (IMP)FDMNavigationWillShow, &FDMOriginalNavigationWillShow);
    FDMInstallHook(navigation, @selector(navigationController:didShowViewController:animated:), (IMP)FDMNavigationDidShow, &FDMOriginalNavigationDidShow);
    FDMInstallPreferenceClosingHooks();
}
#else
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
#endif
