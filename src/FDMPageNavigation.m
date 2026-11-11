#import "FDMPageNavigation.h"
#import "FDMCommon.h"
#import "FDMDownloadsViewController.h"
#import "FDMNativePages.h"

static char FDMNavigationSurfaceKey;
static char FDMNavigationAppearanceKey;
static char FDMPreferenceClosingKey;
static IMP FDMOriginalPreferenceRemove;
static IMP FDMOriginalPopupDismiss;

@interface FDMNavigationSurface : NSObject
@property (nonatomic, strong) UIColor *background;
@property (nonatomic) BOOL opaque;
@property (nonatomic) BOOL clips;
@property (nonatomic) BOOL translucent;
@property (nonatomic) BOOL barHidden;
@end
@implementation FDMNavigationSurface
@end

BOOL FDMIsOwnedPage(UIViewController *page) {
    return [page isKindOfClass:FDMDownloadsViewController.class] ||
        [page isKindOfClass:FDMSitePoliciesViewController.class] ||
        [page isKindOfClass:FDMSitePolicyEditViewController.class] ||
        [page isKindOfClass:FDMBackupViewController.class] ||
        [NSStringFromClass(page.class) isEqual:@"FDMURLInputController"] ||
        [NSStringFromClass(page.class) isEqual:@"FDMIconDiagnosticsViewController"];
}

BOOL FDMIsOwnedNavigationPage(UINavigationController *navigation, UIViewController *page) {
    if (FDMIsOwnedPage(page)) return YES;
    BOOL ownedAncestor = NO;
    for (UIViewController *candidate in navigation.viewControllers) {
        if (candidate == page) return ownedAncestor;
        if (FDMIsOwnedPage(candidate)) ownedAncestor = YES;
    }
    return NO;
}

static void FDMPrepareNavigationPage(UIViewController *page) {
    // Build the destination surface before UIKit snapshots it for the push.
    // Waiting for viewDidLoad leaves one transition frame showing the browser
    // underneath, which is especially visible below the navigation bar.
    [page loadViewIfNeeded];
    page.edgesForExtendedLayout = UIRectEdgeNone;
    page.extendedLayoutIncludesOpaqueBars = NO;
    UINavigationBarAppearance *appearance = objc_getAssociatedObject(page, &FDMNavigationAppearanceKey);
    if (!appearance) {
        appearance = [[UINavigationBarAppearance alloc] init];
        [appearance configureWithOpaqueBackground];
        appearance.backgroundColor = UIColor.systemBackgroundColor;
        objc_setAssociatedObject(page, &FDMNavigationAppearanceKey, appearance, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        page.navigationItem.standardAppearance = appearance;
        page.navigationItem.scrollEdgeAppearance = appearance;
        page.navigationItem.compactAppearance = appearance;
        if (@available(iOS 15.0, *)) page.navigationItem.compactScrollEdgeAppearance = appearance;
    }
    page.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    page.view.opaque = YES;
    page.view.clipsToBounds = YES;
}

void FDMPrepareOwnedPage(UIViewController *page) {
    if (FDMIsOwnedPage(page)) FDMPrepareNavigationPage(page);
}

static void FDMCaptureNavigationSurface(UINavigationController *navigation) {
    if (!navigation || objc_getAssociatedObject(navigation, &FDMNavigationSurfaceKey)) return;
    FDMNavigationSurface *surface = [FDMNavigationSurface new];
    surface.background = navigation.view.backgroundColor;
    surface.opaque = navigation.view.opaque;
    surface.clips = navigation.view.clipsToBounds;
    surface.translucent = navigation.navigationBar.translucent;
    surface.barHidden = navigation.navigationBarHidden;
    objc_setAssociatedObject(navigation, &FDMNavigationSurfaceKey, surface, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void FDMApplyOwnedNavigationState(UINavigationController *navigation, UIViewController *page, BOOL animated) {
    if (!navigation || !FDMIsOwnedNavigationPage(navigation, page)) return;
    FDMCaptureNavigationSurface(navigation);
    FDMPrepareNavigationPage(page);
    navigation.view.backgroundColor = UIColor.systemBackgroundColor;
    navigation.view.opaque = YES;
    navigation.view.clipsToBounds = YES;
    navigation.navigationBar.translucent = NO;
    if (navigation.navigationBarHidden) [navigation setNavigationBarHidden:NO animated:animated];
}

void FDMFinishOwnedNavigationTransition(UINavigationController *navigation, UIViewController *page) {
    if (FDMIsOwnedNavigationPage(navigation, page)) {
        FDMApplyOwnedNavigationState(navigation, page, NO);
        return;
    }
    FDMNavigationSurface *surface = objc_getAssociatedObject(navigation, &FDMNavigationSurfaceKey);
    if (!surface) return;
    navigation.view.backgroundColor = surface.background;
    navigation.view.opaque = surface.opaque;
    navigation.view.clipsToBounds = surface.clips;
    navigation.navigationBar.translucent = surface.translucent;
    [navigation setNavigationBarHidden:surface.barHidden animated:NO];
    objc_setAssociatedObject(navigation, &FDMNavigationSurfaceKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void FDMShowOwnedPage(UIViewController *host, UIViewController *page) {
    if (!host || !page) return;
    UINavigationController *navigation = host.navigationController;
    id<UIViewControllerTransitionCoordinator> transition = navigation.transitionCoordinator;
    if (transition) {
        __weak UIViewController *weakHost = host;
        __weak UIViewController *weakPage = page;
        [transition animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIViewController *currentHost = weakHost;
                UIViewController *currentPage = weakPage;
                if (currentHost && currentPage) FDMShowOwnedPage(currentHost, currentPage);
            });
        }];
        return;
    }
    FDMPrepareOwnedPage(page);
    if (navigation) {
        FDMCaptureNavigationSurface(navigation);
        FDMApplyOwnedNavigationState(navigation, page, NO);
        [navigation pushViewController:page animated:YES];
    } else {
        UINavigationController *modal = [[UINavigationController alloc] initWithRootViewController:page];
        FDMApplyOwnedNavigationState(modal, page, NO);
        modal.modalPresentationStyle = UIModalPresentationFullScreen;
        [host presentViewController:modal animated:YES completion:nil];
    }
}

@interface FDMPreferenceClosing : NSObject
@property (nonatomic, weak) UIViewController *host;
@property (nonatomic, weak) UIView *panel;
@property (nonatomic, weak) UIViewController *popup;
@property (nonatomic, copy) void (^action)(UIViewController *);
@property (nonatomic) BOOL panelRemoved;
@property (nonatomic) BOOL popupDismissed;
@property (nonatomic) BOOL finished;
- (void)finishIfClosed;
@end
@implementation FDMPreferenceClosing
- (void)finishIfClosed {
    if (self.finished || !self.panelRemoved || !self.popupDismissed) return;
    self.finished = YES;
    void (^action)(UIViewController *) = self.action;
    self.action = nil;
    if (self.panel) objc_setAssociatedObject(self.panel, &FDMPreferenceClosingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (self.popup) objc_setAssociatedObject(self.popup, &FDMPreferenceClosingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Host removal/dismissal callbacks return before a new navigation transition begins.
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *host = self.host;
        if (!host) return;
        objc_setAssociatedObject(host, &FDMPreferenceClosingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (action) action(host);
    });
}
@end

static void FDMPreferenceRemoved(id self, SEL selector) {
    FDMPreferenceClosing *closing = objc_getAssociatedObject(self, &FDMPreferenceClosingKey);
    if (FDMOriginalPreferenceRemove) ((void (*)(id, SEL))FDMOriginalPreferenceRemove)(self, selector);
    if (closing) { closing.panelRemoved = YES; [closing finishIfClosed]; }
}

static void FDMPopupDismiss(id self, SEL selector, BOOL animated, void (^completion)(void)) {
    FDMPreferenceClosing *closing = objc_getAssociatedObject(self, &FDMPreferenceClosingKey);
    void (^done)(void) = closing ? ^{
        if (completion) completion();
        closing.popupDismissed = YES;
        [closing finishIfClosed];
    } : completion;
    if (FDMOriginalPopupDismiss) ((void (*)(id, SEL, BOOL, id))FDMOriginalPopupDismiss)(self, selector, animated, done);
}

static void FDMInstallClosingHook(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method || method_getImplementation(method) == replacement) return;
    *original = method_getImplementation(method);
    if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) method_setImplementation(method, replacement);
}

void FDMInstallPreferenceClosingHooks(void) {
    FDMInstallClosingHook(NSClassFromString(@"PreferenceView"), @selector(removeFromSuperview), (IMP)FDMPreferenceRemoved, &FDMOriginalPreferenceRemove);
    FDMInstallClosingHook(NSClassFromString(@"PreferencePopUpController"), @selector(dismissViewControllerAnimated:completion:), (IMP)FDMPopupDismiss, &FDMOriginalPopupDismiss);
}

void FDMClosePreferenceThenPerform(UIViewController *host, void (^action)(UIViewController *)) {
    if (!host || !action || objc_getAssociatedObject(host, &FDMPreferenceClosingKey)) return;
    FDMInstallPreferenceClosingHooks();
    UIView *panel = FDMValue(host, @"preferenceView");
    UIViewController *popup = FDMValue(host, @"popUpPreferenceController");
    if (![panel isKindOfClass:UIView.class]) panel = nil;
    if (![popup isKindOfClass:UIViewController.class]) popup = nil;
    FDMPreferenceClosing *closing = [FDMPreferenceClosing new];
    closing.host = host; closing.panel = panel; closing.popup = popup; closing.action = action;
    closing.panelRemoved = !panel.superview;
    closing.popupDismissed = !popup.presentingViewController;
    objc_setAssociatedObject(host, &FDMPreferenceClosingKey, closing, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!closing.panelRemoved) objc_setAssociatedObject(panel, &FDMPreferenceClosingKey, closing, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!closing.popupDismissed) objc_setAssociatedObject(popup, &FDMPreferenceClosingKey, closing, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SEL hide = NSSelectorFromString(@"hideUserPreferenceView");
    if ([host respondsToSelector:hide]) ((void (*)(id, SEL))objc_msgSend)(host, hide);
    else {
        if (!closing.panelRemoved) {
            [panel removeFromSuperview];
            closing.panelRemoved = !panel.superview;
        }
        if (!closing.popupDismissed) {
            [popup dismissViewControllerAnimated:YES completion:^{
                closing.popupDismissed = !popup.presentingViewController;
                [closing finishIfClosed];
            }];
        }
    }
    [closing finishIfClosed];
}
