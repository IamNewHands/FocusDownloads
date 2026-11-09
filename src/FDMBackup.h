#import "FDMCommon.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FDMBackupFormat;
FOUNDATION_EXPORT NSString *const FDMBackupDidChangeNotification;

FOUNDATION_EXPORT NSUInteger const FDMBackupMaxFileBytes;      // 32 MiB
FOUNDATION_EXPORT NSUInteger const FDMBackupMaxPayloadBytes;   // 16 MiB decoded, all categories
FOUNDATION_EXPORT NSUInteger const FDMBackupMaxCategoryBytes;  // 8 MiB per category
FOUNDATION_EXPORT NSUInteger const FDMBackupMaxBookmarks;      // 10000
FOUNDATION_EXPORT NSUInteger const FDMBackupMaxScripts;        // 200
FOUNDATION_EXPORT NSUInteger const FDMBackupMaxScriptBytes;    // 1 MiB per script
FOUNDATION_EXPORT NSUInteger const FDMBackupMaxNameBytes;      // 512 UTF-8
FOUNDATION_EXPORT NSUInteger const FDMBackupMaxURLBytes;       // 8192 UTF-8

// Category identifiers. Order is the export order and the UI order.
FOUNDATION_EXPORT NSString *const FDMBackupCategoryBookmarks;
FOUNDATION_EXPORT NSString *const FDMBackupCategorySearch;
FOUNDATION_EXPORT NSString *const FDMBackupCategorySitePolicies;
FOUNDATION_EXPORT NSString *const FDMBackupCategoryPreferences;
FOUNDATION_EXPORT NSString *const FDMBackupCategoryScripts;
FOUNDATION_EXPORT NSArray<NSString *> *FDMBackupCategoryOrder(void);
FOUNDATION_EXPORT NSString *FDMBackupCategoryTitle(NSString *category);
// Scripts are opt-in: they can contain keys and are off by default.
FOUNDATION_EXPORT BOOL FDMBackupCategorySelectedByDefault(NSString *category);

// One category payload as it appears inside the container.
@interface FDMBackupCategory : NSObject
@property (nonatomic, readonly, copy) NSString *identifier;
@property (nonatomic, readonly, copy) NSData *payload;
@property (nonatomic, readonly) NSUInteger itemCount;
@property (nonatomic, readonly, copy) NSString *sha256;
+ (instancetype)category:(NSString *)identifier payload:(NSData *)payload itemCount:(NSUInteger)itemCount;
@end

// Parsed, validated container. Only categories that passed validation are present.
@interface FDMBackupContainer : NSObject
@property (nonatomic, readonly, copy) NSString *backupID;
@property (nonatomic, readonly, copy) NSDate *createdAt;
@property (nonatomic, readonly, copy) NSString *producerApp;
@property (nonatomic, readonly, copy) NSString *producerVersion;
@property (nonatomic, readonly, copy) NSDictionary<NSString *, FDMBackupCategory *> *categories;
// Categories named in the file that this build does not support, for the preview to list.
@property (nonatomic, readonly, copy) NSArray<NSString *> *unsupportedCategories;
@end

FOUNDATION_EXPORT NSString *FDMBackupSHA256(NSData *data);

// Encoding. Categories are base64'd raw JSON bytes; hashes cover the decoded bytes.
FOUNDATION_EXPORT NSData * _Nullable FDMBackupEncode(NSArray<FDMBackupCategory *> *categories,
                                                     NSString *producerVersion,
                                                     NSError **error);
FOUNDATION_EXPORT FDMBackupContainer * _Nullable FDMBackupDecode(NSData *data, NSError **error);

// One repository contract: export a snapshot, validate an import, stage, commit, roll back.
@protocol FDMBackupProvider <NSObject>
- (NSString *)categoryIdentifier;
// Immutable category payload + the revision it was read at.
- (nullable NSData *)exportSnapshotWithRevision:(unsigned long long *)revision error:(NSError **)error;
- (nullable id)validateImportPayload:(NSData *)payload error:(NSError **)error;
// Counts for the preview. Keys: added, identical, conflict, downgraded, disabled, unsupported.
- (NSDictionary<NSString *, NSNumber *> *)previewCountsForValidated:(id)validated error:(NSError **)error;
// Stages the change without touching live state; returns an opaque handle.
- (nullable id)prepareImport:(id)validated expectedRevision:(unsigned long long)expected error:(NSError **)error;
- (BOOL)commitPrepared:(id)prepared error:(NSError **)error;
- (BOOL)rollbackPrepared:(id)prepared error:(NSError **)error;
- (void)reloadCommittedState;
@end

@interface FDMBackupCoordinator : NSObject
+ (instancetype)shared;
- (void)registerProvider:(id<FDMBackupProvider>)provider;
- (NSArray<NSString *> *)availableCategories;

// Export. Only the requested categories are read; each provider is asked once under one epoch.
- (nullable NSData *)exportCategories:(NSArray<NSString *> *)categories error:(NSError **)error;

// Restore. decode → preview → prepare all → journal → commit all → verify → marker.
- (nullable FDMBackupContainer *)openBackupAtURL:(NSURL *)url error:(NSError **)error;
- (NSDictionary<NSString *, NSDictionary *> *)previewContainer:(FDMBackupContainer *)container
                                                    categories:(NSArray<NSString *> *)categories
                                                         error:(NSError **)error;
- (BOOL)applyContainer:(FDMBackupContainer *)container
            categories:(NSArray<NSString *> *)categories
             conflicts:(NSDictionary<NSString *, NSString *> *)conflicts
               replace:(BOOL)replace
                 error:(NSError **)error;
// Called at launch before any configuration is exposed. Idempotent.
- (void)recoverInterruptedTransaction;
@property (nonatomic, readonly, copy, nullable) NSString *recoveryNotice;
@end

NS_ASSUME_NONNULL_END
