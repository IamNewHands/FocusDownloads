#import "FDMCommon.h"

NS_ASSUME_NONNULL_BEGIN

// Owns WKDownload objects. State still lives in FDMEngine: this class only translates WebKit's
// download callbacks into normalized engine events, so there is never a second task truth.
@interface FDMWebKitDownloads : NSObject
+ (instancetype)shared;
// YES when this build can preserve an original navigation as a WebKit download.
@property (nonatomic, readonly) BOOL supported;
// Attaches to a WKDownload produced by the host and takes over its destination and lifecycle.
- (void)adoptDownload:(id)download intent:(nullable id)intent tabID:(nullable NSString *)tabID;
// Cancels the WebKit object for a row. WebKit resume data is never persisted by this app.
- (void)cancelKey:(NSString *)key;
@end

NS_ASSUME_NONNULL_END
