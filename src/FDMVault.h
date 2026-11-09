#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Device-local Keychain objects. Never synchronized, enumerated, exported, or stored in Documents.
// FDM_TESTING uses an explicit process-local fake vault; it is not encryption/platform evidence.
FOUNDATION_EXPORT BOOL FDMVaultPut(NSString *objectID, NSData *data, NSTimeInterval expiresAt, NSError **error);
FOUNDATION_EXPORT NSData * _Nullable FDMVaultGet(NSString *objectID, NSError **error);
NS_ASSUME_NONNULL_END
