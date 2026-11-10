#import "FDMCommon.h"
NS_ASSUME_NONNULL_BEGIN
// Short-lived transaction snapshots only; repositories remain the sole persistent data owners.
FOUNDATION_EXPORT void FDMBackupBeginReadBarrier(void);
FOUNDATION_EXPORT BOOL FDMBackupInternalAccess(BOOL (^block)(void));
FOUNDATION_EXPORT void FDMBackupProtectDefaults(NSUserDefaults *store, NSString *scope, NSString *key);
FOUNDATION_EXPORT void FDMBackupProtectScriptFiles(NSString *directory, NSDictionary<NSString *, NSData *> *files);
FOUNDATION_EXPORT BOOL FDMBackupReadBarrierCommit(BOOL (^writeMarker)(void));
FOUNDATION_EXPORT void FDMBackupFinishReadBarrier(BOOL publish);
NS_ASSUME_NONNULL_END
