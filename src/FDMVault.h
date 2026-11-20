#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Device-local Keychain objects. Never synchronized, enumerated, exported, or stored in Documents.
// FDM_TESTING uses an explicit process-local fake vault; it is not encryption/platform evidence.
FOUNDATION_EXPORT BOOL FDMVaultPut(NSString *objectID, NSData *data, NSTimeInterval expiresAt, NSError **error);
FOUNDATION_EXPORT NSData * _Nullable FDMVaultGet(NSString *objectID, NSError **error);
// Drops the device-local object. Deleting a download must not leave its request behind.
FOUNDATION_EXPORT void FDMVaultRemove(NSString *objectID);
NS_ASSUME_NONNULL_END
