#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
NS_ASSUME_NONNULL_BEGIN
// Explicit new user GET intents; never replay an existing navigation/POST response.
FOUNDATION_EXPORT void FDMStartSelectedPageImages(WKWebView *webView, NSArray<NSString *> *urls, unsigned long long generation,
    void (^completion)(NSUInteger started, NSError * _Nullable error));
FOUNDATION_EXPORT void FDMOpenPageImages(UIViewController *host);
NS_ASSUME_NONNULL_END
