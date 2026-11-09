#import "FDMBackupRepository.h"
#import "FDMBackup.h"

NS_ASSUME_NONNULL_BEGIN

// Bookmarks (t_bookmark) and home shortcut items (t_hometags) live in the same SQLite database, so
// both share one repository implementation over one injected FDMBackupSQLDatabase.
//
// Fidelity rules this repository enforces:
//   * stable ID: bookmarkId / uuid is carried through import unchanged; never regenerated.
//   * hierarchy: parentId must reference an existing or imported folder; cycles are refused.
//   * order: ppOrder is preserved; a stable sort is used so equal orders do not shuffle.
//   * folder: fileType != 0 marks a folder and may legitimately have an empty url.
@interface FDMBackupBookmarkRepository : NSObject <FDMBackupRepository>
- (instancetype)initWithDatabase:(id<FDMBackupSQLDatabase>)database;
@end

@interface FDMBackupHomeTagRepository : NSObject <FDMBackupRepository>
- (instancetype)initWithDatabase:(id<FDMBackupSQLDatabase>)database;
@end

// Search engines are an NSUserDefaults array of dictionaries under suite com.focus.searchlist,
// key saved_search_list_data. The suite name and key are fixed facts of this host build.
@interface FDMBackupSearchRepository : NSObject <FDMBackupRepository>
- (instancetype)initWithUserDefaults:(NSUserDefaults *)defaults;
+ (nullable NSUserDefaults *)hostSearchDefaults;
@end

// Preferences are two NSKeyedArchiver blobs in standardUserDefaults. Only the common config blob is
// a backup category; the wallpaper blob is excluded because it is a binary asset, not a setting.
@interface FDMBackupPreferencesRepository : NSObject <FDMBackupRepository>
- (instancetype)initWithUserDefaults:(NSUserDefaults *)defaults;
@end

// User scripts: SQL metadata+content in t_userscript, plus one generated .js per script produced by
// the host. Restore writes the rows, then asks the host to regenerate the .js files.
@interface FDMBackupScriptsRepository : NSObject <FDMBackupRepository>
- (instancetype)initWithDatabase:(id<FDMBackupSQLDatabase>)database;
@end

// Site policies reuse the single FDMPolicy owner; this repository only adapts it to the contract.
@interface FDMBackupPolicyRepository : NSObject <FDMBackupRepository>
@end

NS_ASSUME_NONNULL_END
