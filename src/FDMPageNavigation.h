#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
BOOL FDMIsOwnedPage(UIViewController *page);
BOOL FDMIsOwnedNavigationPage(UINavigationController *navigation, UIViewController *page);
void FDMPrepareOwnedPage(UIViewController *page);
void FDMShowOwnedPage(UIViewController *host, UIViewController *page);
void FDMApplyOwnedNavigationState(UINavigationController *navigation, UIViewController *page, BOOL animated);
void FDMFinishOwnedNavigationTransition(UINavigationController *navigation, UIViewController *page);
void FDMClosePreferenceThenPerform(UIViewController *host, void (^action)(UIViewController *));
void FDMInstallPreferenceClosingHooks(void);
NS_ASSUME_NONNULL_END
