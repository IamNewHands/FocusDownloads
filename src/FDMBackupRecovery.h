#import "FDMCommon.h"
NS_ASSUME_NONNULL_BEGIN
// Bounded, regular-file-only reads for untrusted portable input and local recovery records.
FOUNDATION_EXPORT NSData * _Nullable FDMReadBoundedFile(NSURL *url, NSUInteger maximum, NSError **error);
FOUNDATION_EXPORT BOOL FDMWriteDurableJSON(id object, NSString *path, NSError **error);
// Category-owned raw SQL before-images. Never included in a portable backup.
@protocol FDMBackupSQLDatabase;
FOUNDATION_EXPORT NSData * _Nullable FDMRecoverySQLSnapshot(id<FDMBackupSQLDatabase> database, NSString *table, NSArray<NSString *> *allowed, NSError **error);
FOUNDATION_EXPORT BOOL FDMRecoverySQLRestore(id<FDMBackupSQLDatabase> database, NSData *snapshot, NSString *table, NSArray<NSString *> *allowed, NSError **error);
NS_ASSUME_NONNULL_END
