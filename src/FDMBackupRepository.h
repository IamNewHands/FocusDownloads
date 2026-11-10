#import "FDMCommon.h"

NS_ASSUME_NONNULL_BEGIN

@protocol FDMBackupSQLDatabase;
@protocol FDMBackupSQLExecutor;

// One repository per selectable backup category. A repository owns exactly one storage domain
// (one SQLite database, or one NSUserDefaults suite) and exposes a transactional contract.
// The coordinator never reaches into storage itself; it only orchestrates repositories.
//
// Contract rules enforced by every implementation:
//   * exportSnapshot returns immutable bytes of the *selected fields only* plus a revision
//     fingerprint that changes whenever the underlying rows change.
//   * validateImportPayload returns a fully validated DTO. The coordinator stores that DTO in the
//     plan; commit never re-parses the payload.
//   * stageMerge produces a staged change set without touching live state.
//   * commitStaged applies the staged set inside one transaction and returns the confirmed after
//     snapshot. A failure must leave the original state intact.
//   * rollbackStaged restores the before snapshot inside one transaction.
//   * reloadHostCache asks the host to refresh its in-memory copy once, after commit.
@protocol FDMBackupRepository <NSObject>
- (NSString *)categoryIdentifier;

// Storage domain identity. Repositories that return an equal non-nil domain share one database and
// MUST be committed inside a single transaction, otherwise a reader can observe a half-applied
// restore across categories. Repositories returning nil use their own independent store.
- (nullable NSString *)storageDomain;

// Applies the staged set on an executor the coordinator already holds inside one transaction.
// This is the only write path used for a multi-category restore; commitStaged: is the convenience
// single-category form and must produce the same result.
- (BOOL)applyStaged:(id)staged onExecutor:(id<FDMBackupSQLExecutor>)executor error:(NSError **)error;

// Immutable before snapshot (category payload bytes) and its revision fingerprint.
- (nullable NSData *)exportSnapshotWithRevision:(NSString *_Nullable *_Nullable)revision error:(NSError **)error;
// The revision fingerprint without serializing the payload; used to detect concurrent changes.
- (nullable NSString *)currentRevisionWithError:(NSError **)error;

- (nullable id)validateImportPayload:(NSData *)payload error:(NSError **)error;

// Per-item classification against the live state. Keys are FDMBackupCount* below.
- (NSDictionary<NSString *, NSNumber *> *)previewCountsForValidated:(id)validated error:(NSError **)error;

// Stages the merge described by `validated` on top of the live state.
// `replace` clears the category's own rows first (still inside the staged set, not live state).
- (nullable id)stageMergeValidated:(id)validated
                           replace:(BOOL)replace
                             error:(NSError **)error;

// Applies the staged set atomically. Returns the confirmed after snapshot, or nil on failure.
- (nullable NSData *)commitStaged:(id)staged error:(NSError **)error;
// Restores `beforeSnapshot` atomically. Returns NO when the restore itself failed.
- (BOOL)rollbackStaged:(id)staged error:(NSError **)error;
// Builds a staged set that restores an exact snapshot. Used by startup journal recovery, which must
// be able to put back the recorded before bytes without re-validating a portable payload.
- (nullable id)stageRestoreSnapshot:(NSData *)snapshot error:(NSError **)error;

// Verifies, after commit and BEFORE the coordinator writes its committed marker, that the store is
// actually complete and usable. A repository with a second representation (a script's generated .js
// file) must prove that representation here. Returning NO makes the coordinator roll the whole
// restore back, so a half-restored store can never be published as success.
- (BOOL)verifyCommittedStateWithError:(NSError **)error;

// One host cache refresh after a successful commit; must not run during the transaction.
- (void)reloadHostCache;

// YES when this repository can actually perform a restore in this build/environment.
- (BOOL)isAvailable;
@optional
// Exact device-local before-image, never included in a portable backup.
- (nullable NSData *)recoverySnapshotWithError:(NSError **)error;
- (void)preparePublicationBarrier;
- (BOOL)restoreRecoverySnapshot:(NSData *)snapshot error:(NSError **)error;
@end

FOUNDATION_EXPORT NSString *const FDMBackupCountAdded;
FOUNDATION_EXPORT NSString *const FDMBackupCountIdentical;
FOUNDATION_EXPORT NSString *const FDMBackupCountConflict;
FOUNDATION_EXPORT NSString *const FDMBackupCountDowngraded;
FOUNDATION_EXPORT NSString *const FDMBackupCountDisabled;
FOUNDATION_EXPORT NSString *const FDMBackupCountUnsupported;

// A staged set is opaque to the coordinator but always carries these for the journal.
@protocol FDMBackupStagedSet <NSObject>
- (NSData *)beforeSnapshot;
- (NSData *)afterSnapshot;
@end

// One validated, conflict-resolved import plan. The coordinator builds it once from the preview;
// apply never re-parses the container payload.
@interface FDMBackupImportPlan : NSObject
@property (nonatomic, readonly, copy) NSString *backupID;
@property (nonatomic, readonly, copy) NSArray<NSString *> *categories;
@property (nonatomic, readonly) BOOL replace;
// category -> validated DTO, produced by the repository during preview.
@property (nonatomic, readonly, copy) NSDictionary<NSString *, id> *validatedByCategory;
// category -> revision fingerprint observed at preview time.
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSString *> *revisionByCategory;
// category -> per-item counts shown to the user.
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *countsByCategory;
// Categories present in the file but unsupported here, listed for the preview.
@property (nonatomic, readonly, copy) NSArray<NSString *> *unsupportedCategories;
@end

NS_ASSUME_NONNULL_END
