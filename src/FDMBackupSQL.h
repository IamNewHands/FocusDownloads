#import "FDMCommon.h"

NS_ASSUME_NONNULL_BEGIN

@protocol FDMBackupSQLExecutor;

// Minimal SQL surface the backup repositories need. The live host object is FMDatabaseQueue; the
// regression build injects a fixture that wraps the system SQLite library. Keeping this behind a
// protocol means the repository logic is identical in both, and no fake JSON parsing is involved.
@protocol FDMBackupSQLDatabase <NSObject>
// Runs the block inside one serialized database access. The block receives an executor whose
// statements run on that same connection.
- (void)inDatabase:(void (^)(id<FDMBackupSQLExecutor> executor))block;

// Runs the block inside one transaction and returns YES only when COMMIT verifiably succeeded.
//
// FMDB's own -inTransaction: returns void and its BOOL* rollback flag only reports what the block
// asked for, so it cannot prove a commit succeeded. This implementation therefore issues
// BEGIN IMMEDIATE / COMMIT / ROLLBACK itself on the connection FMDB hands to inDatabase:, and
// treats a COMMIT failure as a failure (then rolls back).
- (BOOL)inTransaction:(BOOL (^)(id<FDMBackupSQLExecutor> executor))block error:(NSError **)error;
@end

// A whole-batch access holder. The queue stays entered for the entire restore, so no other reader of
// the same connection can observe a partially written multi-category state.
@protocol FDMBackupSQLAtomicAccess <NSObject>
- (nullable id<FDMBackupSQLExecutor>)executor;
- (BOOL)commitWithError:(NSError **)error;
- (void)rollback;
@end

@protocol FDMBackupSQLBatchDatabase <FDMBackupSQLDatabase>
// Enters the queue once and begins an IMMEDIATE transaction. Every call inside the block runs on
// that same held connection. Returns NO when the queue could not be entered or BEGIN failed.
- (BOOL)performAtomicBatch:(void (^)(id<FDMBackupSQLAtomicAccess> access))block error:(NSError **)error;
@end

@protocol FDMBackupSQLExecutor <NSObject>
// Parameterized query. Returns row dictionaries keyed by column name, or nil with an error.
- (nullable NSArray<NSDictionary *> *)query:(NSString *)sql
                                 parameters:(nullable NSArray *)parameters
                                      error:(NSError **)error;
// Parameterized statement. Returns NO with an error when the statement failed.
- (BOOL)update:(NSString *)sql parameters:(nullable NSArray *)parameters error:(NSError **)error;
@end

// Bridges the host FMDatabaseQueue (resolved at runtime, no link-time dependency) to the protocol.
@interface FDMHostDatabaseQueue : NSObject <FDMBackupSQLBatchDatabase>
// Returns nil when the host database is unavailable in this process.
+ (nullable instancetype)hostQueueWithError:(NSError **)error;
// Test/regression entry: wrap an already-open queue-like object.
- (instancetype)initWithQueue:(id)queue;
@end

#ifdef FDM_TESTING
// A real SQLite fixture over the system library. Only compiled into the regression build.
@interface FDMSQLiteFixtureDatabase : NSObject <FDMBackupSQLBatchDatabase>
- (nullable instancetype)initWithPath:(NSString *)path error:(NSError **)error;
- (BOOL)close;
@end
#endif

// Convenience wrappers used by the repositories so they never touch FMDB types directly.
FOUNDATION_EXPORT BOOL FDMBackupTableColumns(id<FDMBackupSQLExecutor> executor,
                                             NSString *table,
                                             NSSet<NSString *> *_Nullable *_Nullable columns,
                                             NSError **error);

NS_ASSUME_NONNULL_END
