#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import "FDMIntent.h"
NS_ASSUME_NONNULL_BEGIN
// Host navigation wiring and one binding per WebView. Policy data remains in FDMPolicyStore.
FOUNDATION_EXPORT void FDMInstallNavigationHooks(void);
FOUNDATION_EXPORT void FDMInstallNavigationCreatedCallback(void (^didCaptureDownload)(void));
FOUNDATION_EXPORT NSString *FDMNavigationTabID(WKWebView *webView);
FOUNDATION_EXPORT unsigned long long FDMNavigationGeneration(WKWebView *webView);
FOUNDATION_EXPORT NSString * _Nullable FDMNavigationOrigin(WKWebView *webView);
FOUNDATION_EXPORT void FDMOpenCurrentSiteSettings(UIViewController *host);
FOUNDATION_EXPORT void FDMConfirmPolicyReload(UIViewController *host, WKWebView *webView, BOOL temporaryOff);
FOUNDATION_EXPORT BOOL FDMNavigationAllowsUserScripts(WKWebView *webView);
NS_ASSUME_NONNULL_END
