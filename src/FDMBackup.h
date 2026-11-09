#import "FDMCommon.h"
#import "FDMBackupRepository.h"

NS_ASSUME_NONNULL_BEGIN

@protocol FDMBackupSQLDatabase;

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
// Home shortcut items share the bookmark database but are a separate selectable category.
FOUNDATION_EXPORT NSString *const FDMBackupCategoryHomeTags;
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

// Orchestrates repositories. Every write happens inside each repository's own transaction; the
// coordinator only sequences them, keeps the journal, and guarantees a defined recovery path.
@interface FDMBackupCoordinator : NSObject
+ (instancetype)shared;

// Injection point for the regression build; production uses the host providers.
- (void)registerRepository:(id<FDMBackupRepository>)repository;
// Registers a repository together with the database that owns its storage domain. Repositories that
// share one database must be registered with the same object so a multi-category restore commits in
// a single transaction.
- (void)registerRepository:(id<FDMBackupRepository>)repository database:(id<FDMBackupSQLDatabase>)database;

- (NSArray<NSString *> *)availableCategories;

// Export. Only the requested categories are read, each once, under one serial consistency epoch.
- (nullable NSData *)exportCategories:(NSArray<NSString *> *)categories error:(NSError **)error;

// Opens and fully validates a backup file without changing any state.
- (nullable FDMBackupContainer *)openBackupAtURL:(NSURL *)url error:(NSError **)error;

// Validates, classifies and freezes an import plan. `replace` selects replacement of the chosen
// categories; NO keeps local rows on conflict (the default).
- (nullable FDMBackupImportPlan *)previewContainer:(FDMBackupContainer *)container
                                        categories:(NSArray<NSString *> *)categories
                                           replace:(BOOL)replace
                                             error:(NSError **)error;

// Applies a frozen plan: barrier → journal(before/after) → per-category transaction → read-back
// verify → committed marker. A failure at any point restores the before snapshots.
- (BOOL)applyPlan:(FDMBackupImportPlan *)plan error:(NSError **)error;

// Called at launch before any configuration is exposed. Idempotent.
- (void)recoverInterruptedTransaction;
@property (nonatomic, readonly, copy, nullable) NSString *recoveryNotice;
@end

NS_ASSUME_NONNULL_END
