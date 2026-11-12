#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FDMTranslateProxy : NSObject

/// Installs translation enhancements:
/// 1. Intercepts web page translation HTTP requests in TranslateHelper to fix dead Microsoft endpoints
///    and provide auto-failover to high-availability no-VPN channels (Edge translate text API).
/// 2. Hooks PandaWebView canPerformAction:withSender: and adds _systemTranslate: / translate:
///    to restore iOS native system translation (including offline language pack support) on text selection.
+ (void)installHooks;

@end

NS_ASSUME_NONNULL_END
