// Timing fixtures execute the same callback wrappers without private Focus frameworks.
#import <UIKit/UIKit.h>
#import <QuickLook/QuickLook.h>
#import "FDMPageNavigation.h"
#import "FDMDownloadsViewController.h"
#import "FDMNativePages.h"

void FDMTestInstallPageNavigationHooks(void);

@interface PreferenceView : UIView
@property (nonatomic) NSUInteger hideCount;
@property (nonatomic) NSUInteger cleanupCount;
- (void)hide;
- (void)finishHide;
@end
@implementation PreferenceView
- (void)hide { self.hideCount++; }
- (void)removeFromSuperview { self.cleanupCount++; [super removeFromSuperview]; }
- (void)finishHide { [self removeFromSuperview]; }
@end

@interface PreferencePopUpController : UIViewController
@property (nonatomic, strong) UIViewController *fixturePresenter;
@property (nonatomic, copy) dispatch_block_t pendingCompletion;
@property (nonatomic) NSUInteger dismissCount;
- (void)finishDismiss;
@end
@implementation PreferencePopUpController
- (UIViewController *)presentingViewController { return self.fixturePresenter; }
- (void)dismissViewControllerAnimated:(BOOL)animated completion:(void (^)(void))completion {
    self.dismissCount++;
    self.pendingCompletion = completion;
}
- (void)finishDismiss {
    self.fixturePresenter = nil;
    dispatch_block_t done = self.pendingCompletion;
    self.pendingCompletion = nil;
    if (done) done();
}
@end

@interface FDMClosingHostFixture : UIViewController
@property (nonatomic, strong) PreferenceView *preferenceView;
@property (nonatomic, strong) PreferencePopUpController *popUpPreferenceController;
@property (nonatomic) NSUInteger hideCount;
@property (nonatomic) NSUInteger originalDismissCompletionCount;
- (void)hideUserPreferenceView;
@end
@implementation FDMClosingHostFixture
- (void)hideUserPreferenceView {
    self.hideCount++;
    [self.preferenceView hide];
    if (self.popUpPreferenceController) {
        [self.popUpPreferenceController dismissViewControllerAnimated:YES completion:^{
            self.originalDismissCompletionCount++;
        }];
    }
}
@end

@interface FDMStuckClosingHostFixture : FDMClosingHostFixture
@end
@implementation FDMStuckClosingHostFixture
- (void)hideUserPreferenceView { self.hideCount++; }
@end

@interface FDMFallbackClosingHostFixture : FDMClosingHostFixture
@end
@implementation FDMFallbackClosingHostFixture
- (BOOL)respondsToSelector:(SEL)selector {
    return selector == @selector(hideUserPreferenceView) ? NO : [super respondsToSelector:selector];
}
@end

@interface FDMNavigationContextFixture : NSObject
@property (nonatomic, getter=isCancelled) BOOL cancelled;
@property (nonatomic, copy) void (^completion)(id<UIViewControllerTransitionCoordinatorContext>);
- (BOOL)animateAlongsideTransition:(void (^)(id<UIViewControllerTransitionCoordinatorContext>))animation
                       completion:(void (^)(id<UIViewControllerTransitionCoordinatorContext>))completion;
- (void)finish;
@end
@implementation FDMNavigationContextFixture
- (BOOL)animateAlongsideTransition:(void (^)(id<UIViewControllerTransitionCoordinatorContext>))animation
                       completion:(void (^)(id<UIViewControllerTransitionCoordinatorContext>))completion {
    self.completion = completion;
    return YES;
}
- (void)finish {
    void (^done)(id<UIViewControllerTransitionCoordinatorContext>) = self.completion;
    self.completion = nil;
    if (done) done((id)self);
}
@end

@interface BaseNavigationController : UINavigationController
@property (nonatomic, strong) FDMNavigationContextFixture *fixtureTransition;
@property (nonatomic) NSUInteger originalStateCount;
@property (nonatomic) NSUInteger originalWillCount;
@property (nonatomic) NSUInteger originalDidCount;
@property (nonatomic) NSUInteger pushCount;
@property (nonatomic) BOOL pushedAnimated;
- (void)applyNavigationBarStateForViewController:(UIViewController *)controller animated:(BOOL)animated;
- (void)navigationController:(UINavigationController *)navigation willShowViewController:(UIViewController *)controller animated:(BOOL)animated;
- (void)navigationController:(UINavigationController *)navigation didShowViewController:(UIViewController *)controller animated:(BOOL)animated;
@end
@implementation BaseNavigationController
- (id<UIViewControllerTransitionCoordinator>)transitionCoordinator { return (id)self.fixtureTransition; }
- (void)pushViewController:(UIViewController *)controller animated:(BOOL)animated {
    self.pushCount++;
    self.pushedAnimated = animated;
    [super pushViewController:controller animated:NO];
}
- (void)applyNavigationBarStateForViewController:(UIViewController *)controller animated:(BOOL)animated {
    NSCAssert(!FDMIsOwnedNavigationPage(self, controller), @"only host pages enter the original BaseViewController-only contract");
    self.originalStateCount++;
    [self setNavigationBarHidden:YES animated:animated];
}
- (void)navigationController:(UINavigationController *)navigation willShowViewController:(UIViewController *)controller animated:(BOOL)animated {
    self.originalWillCount++;
    [self applyNavigationBarStateForViewController:controller animated:animated];
}
- (void)navigationController:(UINavigationController *)navigation didShowViewController:(UIViewController *)controller animated:(BOOL)animated {
    self.originalDidCount++;
    [self applyNavigationBarStateForViewController:controller animated:animated];
}
@end

static void FDMDrainNavigationCallbacks(void) { CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false); }

static FDMClosingHostFixture *FDMClosingFixture(BOOL popup) {
    FDMClosingHostFixture *host = [FDMClosingHostFixture new];
    host.preferenceView = [[PreferenceView alloc] initWithFrame:CGRectMake(0, 0, 100, 200)];
    [host.view addSubview:host.preferenceView];
    if (popup) {
        host.popUpPreferenceController = [PreferencePopUpController new];
        host.popUpPreferenceController.fixturePresenter = host;
    }
    return host;
}

void FDMRunPageNavigationRegressionTests(void) {
    NSCAssert(NSThread.isMainThread, @"page-navigation tests belong to main");
    FDMTestInstallPageNavigationHooks();
    FDMTestInstallPageNavigationHooks();
    __block NSUInteger actions = 0;
    FDMClosingHostFixture *panelOnly = FDMClosingFixture(NO);
    FDMClosePreferenceThenPerform(panelOnly, ^(UIViewController *owner) { actions++; });
    FDMClosePreferenceThenPerform(panelOnly, ^(UIViewController *owner) { actions++; });
    FDMDrainNavigationCallbacks();
    NSCAssert(actions == 0 && panelOnly.hideCount == 1 && panelOnly.preferenceView.hideCount == 1, @"one host cleanup begins and navigation waits for actual panel removal");
    [panelOnly.preferenceView finishHide];
    FDMClosePreferenceThenPerform(panelOnly, ^(UIViewController *owner) { actions++; });
    NSCAssert(actions == 0 && panelOnly.preferenceView.cleanupCount == 1 && !panelOnly.preferenceView.superview, @"original removal completes before next-turn navigation");
    FDMDrainNavigationCallbacks();
    NSCAssert(actions == 1, @"exactly one action runs after panel cleanup");

    FDMClosingHostFixture *popupFirst = FDMClosingFixture(YES);
    FDMClosePreferenceThenPerform(popupFirst, ^(UIViewController *owner) { actions++; });
    [popupFirst.popUpPreferenceController finishDismiss];
    FDMDrainNavigationCallbacks();
    NSCAssert(actions == 1 && popupFirst.originalDismissCompletionCount == 1, @"original modal completion survives but panel still blocks navigation");
    [popupFirst.preferenceView finishHide];
    FDMDrainNavigationCallbacks();
    NSCAssert(actions == 2 && popupFirst.popUpPreferenceController.dismissCount == 1, @"popup-first order navigates only after both cleanup owners finish");
    FDMClosingHostFixture *panelFirst = FDMClosingFixture(YES);
    FDMClosePreferenceThenPerform(panelFirst, ^(UIViewController *owner) { actions++; });
    [panelFirst.preferenceView finishHide];
    FDMDrainNavigationCallbacks();
    NSCAssert(actions == 2, @"panel-first order still waits for actual modal completion");
    [panelFirst.popUpPreferenceController finishDismiss];
    FDMDrainNavigationCallbacks();
    NSCAssert(actions == 3 && panelFirst.originalDismissCompletionCount == 1, @"panel-first order preserves one cleanup and one action");

    __weak FDMStuckClosingHostFixture *releasedHost;
    PreferenceView *retainedPanel;
    @autoreleasepool {
        FDMStuckClosingHostFixture *stuck = [FDMStuckClosingHostFixture new];
        stuck.preferenceView = [PreferenceView new];
        [stuck.view addSubview:stuck.preferenceView];
        releasedHost = stuck;
        retainedPanel = stuck.preferenceView;
        FDMClosePreferenceThenPerform(stuck, ^(UIViewController *owner) { actions++; });
    }
    NSCAssert(!releasedHost, @"a missing host cleanup cannot retain the browser through a pending action");
    [retainedPanel finishHide];
    FDMDrainNavigationCallbacks();
    NSCAssert(actions == 3, @"pending navigation is abandoned if its host no longer exists");

    FDMFallbackClosingHostFixture *fallback = [FDMFallbackClosingHostFixture new];
    fallback.preferenceView = [PreferenceView new];
    [fallback.view addSubview:fallback.preferenceView];
    fallback.popUpPreferenceController = [PreferencePopUpController new];
    fallback.popUpPreferenceController.fixturePresenter = fallback;
    FDMClosePreferenceThenPerform(fallback, ^(UIViewController *owner) { actions++; });
    FDMDrainNavigationCallbacks();
    NSCAssert(actions == 3 && !fallback.preferenceView.superview && fallback.popUpPreferenceController.dismissCount == 1, @"missing host selector performs actual cleanup, not assumed completion");
    [fallback.popUpPreferenceController finishDismiss];
    FDMDrainNavigationCallbacks();
    NSCAssert(actions == 4, @"fallback waits for actual dismissal and executes only once");

    UIViewController *host = [UIViewController new];
    BaseNavigationController *navigation = [[BaseNavigationController alloc] initWithRootViewController:host];
    navigation.pushCount = 0;
    NSObject *delegate = [NSObject new], *gestureDelegate = [NSObject new];
    navigation.delegate = (id)delegate;
    navigation.interactivePopGestureRecognizer.delegate = (id)gestureDelegate;
    navigation.view.backgroundColor = UIColor.clearColor;
    navigation.view.opaque = NO;
    navigation.view.clipsToBounds = NO;
    navigation.navigationBar.translucent = YES;
    [navigation setNavigationBarHidden:YES animated:NO];
    FDMDownloadsViewController *downloads = [[FDMDownloadsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    FDMShowOwnedPage(host, downloads);
    NSCAssert(navigation.pushCount == 1 && navigation.pushedAnimated, @"shared entry uses native animated push; fixture suppresses the real animation");
    NSCAssert(downloads.edgesForExtendedLayout == UIRectEdgeNone && downloads.navigationItem.scrollEdgeAppearance, @"owned geometry and opaque item exist before push lifecycle");
    [navigation navigationController:navigation willShowViewController:downloads animated:YES];
    NSCAssert(!navigation.navigationBarHidden && !navigation.navigationBar.translucent && navigation.view.opaque && navigation.view.clipsToBounds, @"owned state covers top and bottom while keeping native navigation");
    FDMNavigationContextFixture *cancel = [FDMNavigationContextFixture new];
    cancel.cancelled = YES;
    navigation.fixtureTransition = cancel;
    [navigation navigationController:navigation willShowViewController:host animated:YES];
    NSCAssert(navigation.navigationBarHidden && navigation.view.clipsToBounds, @"host may animate its bar but owned transition surface stays until completion");
    [cancel finish];
    NSCAssert(navigation.topViewController == downloads && !navigation.navigationBarHidden && !navigation.navigationBar.translucent && navigation.view.clipsToBounds, @"cancelled swipe restores the actual owned top controller");
    [navigation navigationController:navigation didShowViewController:downloads animated:YES];
    NSCAssert(navigation.originalWillCount == 2 && navigation.originalDidCount == 1, @"canceled pop preserves host callbacks exactly once");
    navigation.fixtureTransition = nil;
    Class formClass = NSClassFromString(@"FDMURLInputController");
    NSCAssert(formClass, @"download URL form is present in this native fixture");
    UIViewController *form = [[formClass alloc] init];
    [navigation setViewControllers:@[host, downloads, form] animated:NO];
    [navigation navigationController:navigation willShowViewController:form animated:YES];
    [navigation navigationController:navigation didShowViewController:form animated:YES];
    NSCAssert(!navigation.navigationBarHidden && !navigation.navigationBar.translucent && navigation.view.opaque && form.navigationItem.standardAppearance, @"nested URL form keeps navigation buttons and the owned opaque surface");
    QLPreviewController *preview = [QLPreviewController new];
    [navigation setViewControllers:@[host, downloads, form, preview] animated:NO];
    [navigation navigationController:navigation willShowViewController:preview animated:YES];
    [navigation navigationController:navigation didShowViewController:preview animated:YES];
    NSCAssert(!navigation.navigationBarHidden && navigation.view.clipsToBounds && preview.navigationItem.scrollEdgeAppearance, @"system child inside the owned stack does not restore the old browser surface");
    [navigation setViewControllers:@[host, downloads] animated:NO];
    [navigation navigationController:navigation willShowViewController:downloads animated:YES];
    [navigation navigationController:navigation didShowViewController:downloads animated:YES];
    NSCAssert(!navigation.navigationBarHidden && !navigation.navigationBar.translucent && navigation.view.opaque, @"returning from a nested child keeps the owned page visible");
    [navigation setViewControllers:@[host] animated:NO];
    [navigation navigationController:navigation willShowViewController:host animated:YES];
    [navigation navigationController:navigation didShowViewController:host animated:YES];
    NSCAssert(navigation.navigationBarHidden && navigation.navigationBar.translucent && !navigation.view.opaque && !navigation.view.clipsToBounds && CGColorGetAlpha(navigation.view.backgroundColor.CGColor) == 0, @"successful pop restores original surface only when final host is shown");
    NSCAssert(navigation.delegate == (id)delegate && navigation.interactivePopGestureRecognizer.delegate == (id)gestureDelegate, @"navigation and gesture delegates are never replaced");
    NSCAssert(navigation.originalWillCount == 6 && navigation.originalDidCount == 5, @"host delegate callbacks forward exactly once through nested children and final pop");

    for (UIViewController *page in @[[[FDMSitePoliciesViewController alloc] initWithStyle:UITableViewStyleInsetGrouped],
        [[FDMSitePolicyEditViewController alloc] initWithOrigin:@"https://fixture.invalid:443"]]) {
        FDMPrepareOwnedPage(page);
        NSCAssert(page.edgesForExtendedLayout == UIRectEdgeNone && page.navigationItem.standardAppearance && page.navigationItem.scrollEdgeAppearance, @"site-list and editor share the same pre-push surface");
        UINavigationBarAppearance *appearance = page.navigationItem.standardAppearance;
        FDMPrepareOwnedPage(page);
        NSCAssert(page.navigationItem.standardAppearance == appearance, @"repeated lifecycle preparation does not replace the item's appearance");
    }
    NSLog(@"page navigation regression PASS (callback fixtures; not Focus device pixel or gesture capture)");
}
