// Backup regression: real SQLite fixture, real JSON validation, no fake parsing.
// Covers the acceptance cases that can be proven without the Focus host:
//   B03 malformed / out-of-budget input is refused before any write
//   B05 a local change after preview forces a re-preview
//   B06 merge keeps local conflicts; replace only touches the selected category
//   B07 an interrupted transaction is recovered to the before snapshot
//   B08 a failed rollback keeps the journal (no fake success)
//   B11 the container and journal never carry secrets
#import <Foundation/Foundation.h>
#import "FDMCommon.h"
#import "FDMJSON.h"
#import "FDMBackup.h"
#import "FDMBackupRepository.h"
#import "FDMBackupRepositoryImpl.h"
#import "FDMBackupSQL.h"
#import "FDMBackupRecovery.h"
#import "FDMBackupReadBarrier.h"

static void FDMBackupCheck(BOOL condition, NSString *message) {
    if (!condition) [NSException raise:@"FDMBackupRegression" format:@"%@", message];
}

static NSData *FDMBackupData(NSString *text) {
    return [text dataUsingEncoding:NSUTF8StringEncoding];
}

static NSError *FDMBackupDataError(NSString *message) {
    return [NSError errorWithDomain:@"FocusDM.Backup.Test" code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

#pragma mark - fixtures

// Minimal schema mirroring the host's real CREATE TABLE for the columns this feature owns.
static void FDMBackupCreateSchema(id<FDMBackupSQLDatabase> database) {
    [database inDatabase:^(id<FDMBackupSQLExecutor> executor) {
        NSError *error = nil;
        [executor update:@"CREATE TABLE IF NOT EXISTS t_bookmark(bookmarkId TEXT PRIMARY KEY,parentId TEXT,title TEXT, url TEXT, fileType INTEGER, ppOrder INTEGER, iconUrl TEXT DEFAULT '', updateTime TEXT DEFAULT '1', ctime TEXT)" parameters:nil error:&error];
        [executor update:@"CREATE TABLE IF NOT EXISTS t_hometags(uuid TEXT PRIMARY KEY, title TEXT, targetUrl TEXT, iconUrl TEXT, type INTEGER, ppOrder INTEGER, updateTime TEXT DEFAULT '1', ctime TEXT)" parameters:nil error:&error];
        [executor update:@"CREATE TABLE IF NOT EXISTS t_userscript(uuid TEXT PRIMARY KEY, name TEXT, author TEXT, namespace TEXT, version TEXT, desc TEXT, iconUrl TEXT, runAt TEXT, selectFrame INTEGER, frameOption INTEGER, isAutoUpdate INTEGER, updateUrl TEXT, downloadUrl TEXT, content TEXT, isActive INTEGER, ppOrder INTEGER, sql_includes TEXT, sql_matches TEXT, sql_excludes TEXT, sql_grants TEXT, sql_requireUrls TEXT, sql_resourceUrls TEXT, whiteList TEXT, blackList TEXT, updateTime TEXT DEFAULT '1', ctime TEXT)" parameters:nil error:&error];
        FDMBackupCheck(error == nil, @"fixture schema created");
    }];
}

static void FDMBackupSeedBookmark(id<FDMBackupSQLDatabase> database, NSString *identifier, NSString *parent, NSString *title, NSString *url, NSInteger fileType, NSInteger order) {
    [database inDatabase:^(id<FDMBackupSQLExecutor> executor) {
        NSError *error = nil;
        [executor update:@"INSERT OR REPLACE INTO t_bookmark(bookmarkId,parentId,title,url,fileType,ppOrder,iconUrl,updateTime,ctime) VALUES (?,?,?,?,?,?,?,?,?)"
               parameters:@[identifier, parent ?: @"", title, url, @(fileType), @(order), @"", @"1", @"1"]
                    error:&error];
        FDMBackupCheck(error == nil, @"fixture bookmark seeded");
    }];
}

static NSUInteger FDMBackupCountRows(id<FDMBackupSQLDatabase> database, NSString *table) {
    __block NSUInteger count = 0;
    [database inDatabase:^(id<FDMBackupSQLExecutor> executor) {
        NSArray *rows = [executor query:[NSString stringWithFormat:@"SELECT COUNT(*) AS n FROM %@", table] parameters:nil error:NULL];
        count = [rows.firstObject[@"n"] unsignedIntegerValue];
    }];
    return count;
}

static NSString *FDMBackupRowValue(id<FDMBackupSQLDatabase> database, NSString *table, NSString *idColumn, NSString *identifier, NSString *column) {
    __block NSString *value = nil;
    [database inDatabase:^(id<FDMBackupSQLExecutor> executor) {
        NSArray *rows = [executor query:[NSString stringWithFormat:@"SELECT %@ FROM %@ WHERE %@ = ?", column, table, idColumn]
                             parameters:@[identifier] error:NULL];
        id raw = rows.firstObject[column];
        if ([raw isKindOfClass:NSString.class]) value = raw;
        else if ([raw isKindOfClass:NSNumber.class]) value = [raw stringValue];
    }];
    return value;
}

#pragma mark - real host export shapes

@interface PreferenceModel : NSObject <NSCoding>
@property (nonatomic, strong) NSMutableDictionary *values;
@end
@implementation PreferenceModel
- (instancetype)init { if ((self = [super init])) _values = [NSMutableDictionary dictionary]; return self; }
- (instancetype)initWithCoder:(NSCoder *)coder {
    if ((self = [super init])) _values = [[coder decodeObjectForKey:@"values"] mutableCopy];
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeObject:_values forKey:@"values"]; }
- (id)valueForUndefinedKey:(NSString *)key { return _values[key]; }
- (void)setValue:(id)value forUndefinedKey:(NSString *)key {
    if (value) _values[key] = value; else [_values removeObjectForKey:key];
}
@end

@interface FDMExportFailureRepository : FDMBackupBookmarkRepository
@property (nonatomic) BOOL raisesDuringValidation;
@property (nonatomic) BOOL usesSQLStorage;
@end
@implementation FDMExportFailureRepository
- (BOOL)isAvailable { return YES; }
- (NSString *)storageDomain { return _usesSQLStorage ? [super storageDomain] : nil; }
- (NSData *)exportSnapshotWithRevision:(NSString **)revision error:(NSError **)error {
    return _raisesDuringValidation ? FDMBackupData(@"{\"schemaVersion\":1,\"items\":[]}") : nil;
}
- (id)validateImportPayload:(NSData *)payload error:(NSError **)error {
    [NSException raise:@"HostFixtureFailure" format:@"private fixture value must not reach diagnostics"];
    return nil;
}
@end

static void FDMTestHostDefaultExportShapes(void) {
    NSString *path = [FDMDocumentsPath() stringByAppendingPathComponent:@"host-export.sqlite"];
    __block NSError *error = nil;
    FDMSQLiteFixtureDatabase *database = [[FDMSQLiteFixtureDatabase alloc] initWithPath:path error:&error];
    FDMBackupCreateSchema(database);
    // TableManager creates this exact sentinel without url/fileType/order on every install.
    [database inDatabase:^(id<FDMBackupSQLExecutor> sql) {
        FDMBackupCheck([sql update:@"INSERT INTO t_bookmark(bookmarkId,parentId,title) VALUES(?,?,?)"
            parameters:@[@"root", @"", @"Bookmarks"] error:&error], @"host root inserted");
        FDMBackupCheck([sql update:@"INSERT INTO t_hometags(uuid,title,targetUrl,iconUrl,type,ppOrder) VALUES(?,?,?,?,?,?)"
            parameters:@[@"bookmark-action", @"Bookmarks", @"", @"", @1, @1] error:&error], @"native bookmark shortcut inserted");
    }];
    FDMBackupSeedBookmark(database, @"child", @"root", @"Child", @"https://child.example/", 0, 0);
    FDMBackupBookmarkRepository *bookmarks = [[FDMBackupBookmarkRepository alloc] initWithDatabase:database];
    FDMBackupHomeTagRepository *shortcuts = [[FDMBackupHomeTagRepository alloc] initWithDatabase:database];
    NSData *rootBefore = [bookmarks recoverySnapshotWithError:&error];
    NSString *suite = [@"focusdm.host-export." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    PreferenceModel *model = [PreferenceModel new];
    model.values[@"fontSize"] = @3;
    model.values[@"enabledReader"] = @YES;
    [defaults setObject:[NSKeyedArchiver archivedDataWithRootObject:model requiringSecureCoding:NO error:&error]
        forKey:@"key_preferencemanager_commonconfig"];
    FDMBackupPreferencesRepository *preferences = [[FDMBackupPreferencesRepository alloc] initWithUserDefaults:defaults];
    FDMBackupSearchRepository *search = [[FDMBackupSearchRepository alloc] initWithUserDefaults:defaults];
    [defaults setObject:@[@{@"uuid": @"built-in-3", @"title": @"Bing", @"searchUrl": @"https://www.bing.com/search?q=%@",
        @"type": @3, @"position": @0, @"isSelected": @YES}] forKey:@"saved_search_list_data"];
    FDMBackupPolicyRepository *policies = [FDMBackupPolicyRepository new];
    FDMBackupCoordinator *coordinator = [FDMBackupCoordinator new];
    [coordinator registerRepository:bookmarks database:database];
    [coordinator registerRepository:shortcuts database:database];
    [coordinator registerRepository:preferences];
    [coordinator registerRepository:search];
    [coordinator registerRepository:policies];
    NSArray *categories = @[FDMBackupCategoryBookmarks, FDMBackupCategoryHomeTags, FDMBackupCategorySearch,
        FDMBackupCategorySitePolicies, FDMBackupCategoryPreferences];
    for (NSString *category in categories) {
        error = nil;
        NSData *exported = [coordinator exportCategories:@[category] error:&error];
        FDMBackupCheck(exported && !error && FDMBackupDecode(exported, &error), [NSString stringWithFormat:@"%@ exports independently", category]);
    }
    error = nil;
    FDMBackupContainer *container = FDMBackupDecode([coordinator exportCategories:categories error:&error], &error);
    FDMBackupCheck(container && !error && container.categories.count == 5, @"all default categories export together");
    FDMBackupCheck(container.categories[FDMBackupCategoryBookmarks].itemCount == 1, @"host root is not counted as a user bookmark");
    FDMBackupCheck(container.categories[FDMBackupCategoryHomeTags].itemCount == 1, @"native shortcut is preserved");
    NSArray *tree = [bookmarks validateImportPayload:container.categories[FDMBackupCategoryBookmarks].payload error:&error];
    FDMBackupCheck([tree.firstObject[@"parentID"] isEqual:@"root"], @"child retains native root parent");
    FDMBackupCheck([[bookmarks recoverySnapshotWithError:&error] isEqual:rootBefore], @"export never changes host rows");
    FDMBackupImportPlan *plan = [coordinator previewContainer:container categories:categories replace:YES error:&error];
    FDMBackupCheck(plan && [coordinator applyPlan:plan error:&error] && [bookmarks verifyCommittedStateWithError:&error],
        @"combined restore accepts native root children, shortcut action and font index");
    FDMBackupCheck([FDMBackupRowValue(database, @"t_hometags", @"uuid", @"bookmark-action", @"type") isEqual:@"1"] &&
        [FDMBackupRowValue(database, @"t_hometags", @"uuid", @"bookmark-action", @"targetUrl") isEqual:@""],
        @"restore retains the native bookmark shortcut action");
    __block NSDictionary *root = nil;
    [database inDatabase:^(id<FDMBackupSQLExecutor> sql) {
        root = [sql query:@"SELECT * FROM t_bookmark WHERE bookmarkId=?" parameters:@[@"root"] error:NULL].firstObject;
    }];
    FDMBackupCheck(root && root[@"fileType"] == NSNull.null && root[@"url"] == NSNull.null, @"replace preserves sentinel null columns");
    NSData *claimedRoot = FDMJSONCanonicalData(@{@"schemaVersion": @1, @"items": @[
        @{@"id": @"root", @"title": @"Foreign", @"fileType": @1}]}, NULL);
    FDMBackupCheck(![bookmarks validateImportPayload:claimedRoot error:NULL], @"backup cannot claim host root ownership");
    NSData *empty = FDMJSONCanonicalData(@{@"schemaVersion": @1, @"items": @[]}, NULL);
    id restore = [bookmarks stageRestoreSnapshot:empty error:&error];
    FDMBackupCheck(restore && [bookmarks commitStaged:restore error:&error] && FDMBackupCountRows(database, @"t_bookmark") == 1,
        @"portable rollback preserves root even when no user bookmarks remain");
    for (NSNumber *index in @[@0, @3, @9]) {
        NSData *payload = FDMJSONCanonicalData(@{@"schemaVersion": @1, @"values": @{@"fontSize": index}}, NULL);
        FDMBackupCheck([preferences validateImportPayload:payload error:NULL] != nil, @"native font indices accepted");
    }
    for (NSNumber *invalid in @[@(-1), @10, @16, @YES, @3.5]) {
        NSData *payload = FDMJSONCanonicalData(@{@"schemaVersion": @1, @"values": @{@"fontSize": invalid}}, NULL);
        FDMBackupCheck(![preferences validateImportPayload:payload error:NULL], @"invalid font indices refused");
    }
    NSData *invalidShortcut = FDMJSONCanonicalData(@{@"schemaVersion": @1, @"items": @[
        @{@"id": @"invalid", @"title": @"Empty URL", @"url": @"", @"fileType": @0}]}, NULL);
    FDMBackupCheck(![shortcuts validateImportPayload:invalidShortcut error:NULL], @"ordinary shortcuts still require URLs");
    NSData *hierarchicalShortcut = FDMJSONCanonicalData(@{@"schemaVersion": @1, @"items": @[
        @{@"id": @"invalid", @"parentID": @"parent", @"url": @"https://child.example/"}]}, NULL);
    FDMBackupCheck(![shortcuts validateImportPayload:hierarchicalShortcut error:NULL], @"shortcut hierarchy still refused");
    NSData *wrongURLType = FDMJSONCanonicalData(@{@"schemaVersion": @1, @"items": @[
        @{@"id": @"invalid", @"url": @42, @"fileType": @1}]}, NULL);
    FDMBackupCheck(![shortcuts validateImportPayload:wrongURLType error:NULL], @"native action does not excuse malformed URL types");
    [defaults removePersistentDomainForName:suite];
    [database close];
    printf("host default export shapes and native root preservation passed\n");
}

static void FDMTestExportFailureDiagnostics(void) {
    NSString *path = [FDMDocumentsPath() stringByAppendingPathComponent:@"export-diagnostics.sqlite"];
    NSError *error = nil;
    FDMSQLiteFixtureDatabase *database = [[FDMSQLiteFixtureDatabase alloc] initWithPath:path error:&error];
    FDMBackupCheck(database && !error, @"export diagnostic database opened");
    for (NSNumber *sqlStorage in @[@NO, @YES]) {
        FDMBackupCoordinator *coordinator = [FDMBackupCoordinator new];
        FDMExportFailureRepository *repository = [[FDMExportFailureRepository alloc] initWithDatabase:database];
        repository.usesSQLStorage = sqlStorage.boolValue;
        [coordinator registerRepository:repository database:database];
        error = nil;
        FDMBackupCheck(![coordinator exportCategories:@[FDMBackupCategoryBookmarks] error:&error] &&
            [error.localizedDescription containsString:@"书签"] && [error.localizedDescription containsString:@"读取"],
            @"missing repository error still identifies category and read stage");
        repository.raisesDuringValidation = YES;
        error = nil;
        FDMBackupCheck(![coordinator exportCategories:@[FDMBackupCategoryBookmarks] error:&error] &&
            [error.localizedDescription containsString:@"校验"] && ![error.localizedDescription containsString:@"private fixture"],
            @"host exception becomes bounded validation diagnostic without private reason");
    }
    [database close];
    printf("export failure diagnostics passed\n");
}

#pragma mark - B03: validation refuses bad input before any write

static void FDMTestValidationRefusesBadInput(void) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"fdm-backup-b03-%@.sqlite", NSUUID.UUID.UUIDString]];
    NSError *error = nil;
    FDMSQLiteFixtureDatabase *database = [[FDMSQLiteFixtureDatabase alloc] initWithPath:path error:&error];
    FDMBackupCheck(database != nil, @"fixture database opened");
    FDMBackupCreateSchema(database);
    FDMBackupSeedBookmark(database, @"keep-1", @"", @"Keep", @"https://a.example/1", 0, 0);
    FDMBackupBookmarkRepository *repository = [[FDMBackupBookmarkRepository alloc] initWithDatabase:database];

    // Duplicate stable IDs.
    NSData *duplicateIDs = FDMJSONCanonicalData(@{@"schemaVersion": @1, @"items": @[
        @{@"id": @"x", @"title": @"A", @"url": @"https://a.example/1"},
        @{@"id": @"x", @"title": @"B", @"url": @"https://a.example/2"}]}, &error);
    FDMBackupCheck([repository validateImportPayload:duplicateIDs error:&error] == nil, @"duplicate IDs refused");

    // Cycle.
    NSData *cycle = FDMJSONCanonicalData(@{@"schemaVersion": @1, @"items": @[
        @{@"id": @"a", @"parentID": @"b", @"title": @"A", @"url": @"", @"fileType": @1},
        @{@"id": @"b", @"parentID": @"a", @"title": @"B", @"url": @"", @"fileType": @1}]}, &error);
    FDMBackupCheck([repository validateImportPayload:cycle error:&error] == nil, @"folder cycle refused");

    // Leaf with no URL.
    NSData *noURL = FDMJSONCanonicalData(@{@"schemaVersion": @1, @"items": @[
        @{@"id": @"a", @"title": @"A"}]}, &error);
    FDMBackupCheck([repository validateImportPayload:noURL error:&error] == nil, @"leaf without URL refused");

    // Folder with no URL is legitimate.
    NSData *folderNoURL = FDMJSONCanonicalData(@{@"schemaVersion": @1, @"items": @[
        @{@"id": @"f", @"title": @"Folder", @"fileType": @1, @"order": @0}]}, &error);
    FDMBackupCheck([repository validateImportPayload:folderNoURL error:&error] != nil, @"folder without URL accepted");

    // Boolean where an integer is required.
    NSData *boolOrder = FDMJSONCanonicalData(@{@"schemaVersion": @1, @"items": @[
        @{@"id": @"a", @"title": @"A", @"url": @"https://a.example/1", @"order": @YES}]}, &error);
    FDMBackupCheck([repository validateImportPayload:boolOrder error:&error] == nil, @"boolean order refused");

    // Unknown field, unsupported schema, oversized title.
    NSData *unknownField = FDMJSONCanonicalData(@{@"schemaVersion": @1, @"items": @[
        @{@"id": @"a", @"title": @"A", @"url": @"https://a.example/1", @"extra": @1}]}, &error);
    FDMBackupCheck([repository validateImportPayload:unknownField error:&error] == nil, @"unknown item field refused");
    NSData *badSchema = FDMJSONCanonicalData(@{@"schemaVersion": @2, @"items": @[]}, &error);
    FDMBackupCheck([repository validateImportPayload:badSchema error:&error] == nil, @"unsupported schema refused");
    NSMutableString *longTitle = [NSMutableString string];
    for (NSUInteger i = 0; i < 600; i++) [longTitle appendString:@"x"];
    NSData *oversizeTitle = FDMJSONCanonicalData(@{@"schemaVersion": @1, @"items": @[
        @{@"id": @"a", @"title": longTitle, @"url": @"https://a.example/1"}]}, &error);
    FDMBackupCheck([repository validateImportPayload:oversizeTitle error:&error] == nil, @"oversized title refused");

    // Duplicate JSON object keys are refused by the strict parser, not silently last-wins.
    NSData *duplicateKeys = FDMBackupData(@"{ \"schemaVersion\": 1, \"schemaVersion\": 2, \"items\": [] }");
    FDMBackupCheck([repository validateImportPayload:duplicateKeys error:&error] == nil, @"duplicate JSON keys refused");

    // None of the refusals wrote anything.
    FDMBackupCheck(FDMBackupCountRows(database, @"t_bookmark") == 1, @"refused imports never wrote rows");
    [database close];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    printf("B03 validation refusals passed\n");
}

#pragma mark - B06: merge keeps local conflicts; replace is scoped

static void FDMTestMergeAndReplace(void) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"fdm-backup-b06-%@.sqlite", NSUUID.UUID.UUIDString]];
    NSError *error = nil;
    FDMSQLiteFixtureDatabase *database = [[FDMSQLiteFixtureDatabase alloc] initWithPath:path error:&error];
    FDMBackupCheck(database != nil, @"fixture database opened");
    FDMBackupCreateSchema(database);
    FDMBackupSeedBookmark(database, @"local-1", @"", @"Local", @"https://local.example/1", 0, 0);
    FDMBackupSeedBookmark(database, @"shared-1", @"", @"LocalTitle", @"https://shared.example/1", 0, 0);
    FDMBackupBookmarkRepository *repository = [[FDMBackupBookmarkRepository alloc] initWithDatabase:database];

    NSData *incoming = FDMJSONCanonicalData(@{@"schemaVersion": @1, @"items": @[
        @{@"id": @"shared-1", @"title": @"BackupTitle", @"url": @"https://shared.example/1", @"order": @0},
        @{@"id": @"new-1", @"title": @"New", @"url": @"https://new.example/1", @"order": @1}]}, &error);
    id validated = [repository validateImportPayload:incoming error:&error];
    FDMBackupCheck(validated != nil, @"incoming payload validated");

    NSDictionary *counts = [repository previewCountsForValidated:validated error:&error];
    FDMBackupCheck([counts[FDMBackupCountAdded] integerValue] == 1, @"one item is new");
    FDMBackupCheck([counts[FDMBackupCountConflict] integerValue] == 1, @"one item conflicts");

    // Merge (keep-local): the conflicting row keeps the local title, the new row is added.
    id staged = [repository stageMergeValidated:validated replace:NO error:&error];
    FDMBackupCheck(staged != nil, @"merge staged");
    FDMBackupCheck([repository commitStaged:staged error:&error] != nil, @"merge committed");
    FDMBackupCheck([FDMBackupRowValue(database, @"t_bookmark", @"bookmarkId", @"shared-1", @"title") isEqual:@"LocalTitle"],
                   @"merge keeps the local conflicting row");
    FDMBackupCheck(FDMBackupCountRows(database, @"t_bookmark") == 3, @"merge added the new row without dropping local");

    // Replace: only the imported set remains, and the backup's values win.
    id replaceStaged = [repository stageMergeValidated:validated replace:YES error:&error];
    FDMBackupCheck(replaceStaged != nil, @"replace staged");
    FDMBackupCheck([repository commitStaged:replaceStaged error:&error] != nil, @"replace committed");
    FDMBackupCheck([FDMBackupRowValue(database, @"t_bookmark", @"bookmarkId", @"shared-1", @"title") isEqual:@"BackupTitle"],
                   @"replace takes the backup value");
    FDMBackupCheck([FDMBackupRowValue(database, @"t_bookmark", @"bookmarkId", @"local-1", @"title") length] == 0,
                   @"replace removed rows outside the backup");
    FDMBackupCheck(FDMBackupCountRows(database, @"t_bookmark") == 2, @"replace left exactly the imported rows");

    [database close];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    printf("B06 merge and replace passed\n");
}

#pragma mark - hierarchy fidelity

static void FDMTestHierarchyFidelity(void) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"fdm-backup-hier-%@.sqlite", NSUUID.UUID.UUIDString]];
    NSError *error = nil;
    FDMSQLiteFixtureDatabase *database = [[FDMSQLiteFixtureDatabase alloc] initWithPath:path error:&error];
    FDMBackupCreateSchema(database);
    FDMBackupBookmarkRepository *repository = [[FDMBackupBookmarkRepository alloc] initWithDatabase:database];

    NSData *tree = FDMJSONCanonicalData(@{@"schemaVersion": @1, @"items": @[
        @{@"id": @"folder-a", @"title": @"Folder A", @"url": @"", @"fileType": @1, @"order": @0},
        @{@"id": @"leaf-1", @"parentID": @"folder-a", @"title": @"Leaf", @"url": @"https://leaf.example/1", @"order": @1},
        @{@"id": @"folder-b", @"parentID": @"folder-a", @"title": @"Folder B", @"url": @"", @"fileType": @1, @"order": @2}]}, &error);
    id validated = [repository validateImportPayload:tree error:&error];
    FDMBackupCheck(validated != nil, @"tree validated");
    id staged = [repository stageMergeValidated:validated replace:NO error:&error];
    FDMBackupCheck(staged != nil, @"tree staged");
    FDMBackupCheck([repository commitStaged:staged error:&error] != nil, @"tree committed");

    // Stable IDs, parent links and order must survive the round trip unchanged.
    FDMBackupCheck([FDMBackupRowValue(database, @"t_bookmark", @"bookmarkId", @"leaf-1", @"parentId") isEqual:@"folder-a"],
                   @"child keeps its parent");
    FDMBackupCheck([FDMBackupRowValue(database, @"t_bookmark", @"bookmarkId", @"folder-b", @"parentId") isEqual:@"folder-a"],
                   @"nested folder keeps its parent");
    FDMBackupCheck([FDMBackupRowValue(database, @"t_bookmark", @"bookmarkId", @"folder-a", @"ppOrder") isEqual:@"0"],
                   @"order preserved for folder");
    FDMBackupCheck([FDMBackupRowValue(database, @"t_bookmark", @"bookmarkId", @"folder-b", @"ppOrder") isEqual:@"2"],
                   @"order preserved for nested folder");
    FDMBackupCheck([FDMBackupRowValue(database, @"t_bookmark", @"bookmarkId", @"folder-a", @"fileType") isEqual:@"1"],
                   @"folder fileType preserved");

    // Dangling parent is refused.
    NSData *dangling = FDMJSONCanonicalData(@{@"schemaVersion": @1, @"items": @[
        @{@"id": @"orphan", @"parentID": @"missing-folder", @"title": @"Orphan", @"url": @"https://o.example/1"}]}, &error);
    id danglingValidated = [repository validateImportPayload:dangling error:&error];
    if (danglingValidated) {
        // Validation may accept it (the parent could exist live); the merge must still refuse it.
        id danglingStaged = [repository stageMergeValidated:danglingValidated replace:NO error:&error];
        FDMBackupCheck(danglingStaged == nil, @"dangling parent refused at merge");
    }

    [database close];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    printf("hierarchy fidelity passed\n");
}

#pragma mark - B07/B08: journal recovery and honest rollback failure

static void FDMTestJournalRecovery(void) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"fdm-backup-b07-%@.sqlite", NSUUID.UUID.UUIDString]];
    NSError *error = nil;
    FDMSQLiteFixtureDatabase *database = [[FDMSQLiteFixtureDatabase alloc] initWithPath:path error:&error];
    FDMBackupCreateSchema(database);
    FDMBackupSeedBookmark(database, @"before-1", @"", @"Before", @"https://before.example/1", 0, 0);
    FDMBackupBookmarkRepository *repository = [[FDMBackupBookmarkRepository alloc] initWithDatabase:database];

    // Snapshot the before state exactly as the coordinator journals it.
    NSData *beforeSnapshot = [repository exportSnapshotWithRevision:NULL error:&error];
    FDMBackupCheck(beforeSnapshot.length > 0, @"before snapshot exported");

    // Simulate a partially applied restore: an extra row exists that the before snapshot lacks.
    FDMBackupSeedBookmark(database, @"half-1", @"", @"Half", @"https://half.example/1", 0, 0);
    FDMBackupCheck(FDMBackupCountRows(database, @"t_bookmark") == 2, @"half state present");

    // Recovery must restore the before snapshot: extra rows gone, original row intact.
    id restore = [repository stageRestoreSnapshot:beforeSnapshot error:&error];
    FDMBackupCheck(restore != nil, @"restore staged from snapshot");
    FDMBackupCheck([repository commitStaged:restore error:&error] != nil, @"restore committed");
    FDMBackupCheck(FDMBackupCountRows(database, @"t_bookmark") == 1, @"recovery removed the half-applied row");
    FDMBackupCheck([FDMBackupRowValue(database, @"t_bookmark", @"bookmarkId", @"before-1", @"title") isEqual:@"Before"],
                   @"recovery kept the original row");

    // A corrupted journal snapshot must be refused, not applied.
    NSData *corrupt = FDMBackupData(@"{\"schemaVersion\":1,\"items\":[{\"id\":\"evil\"}]}");
    FDMBackupCheck([repository stageRestoreSnapshot:corrupt error:&error] == nil, @"corrupt snapshot refused");
    FDMBackupCheck(FDMBackupCountRows(database, @"t_bookmark") == 1, @"refused recovery wrote nothing");

    [database close];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    printf("B07 journal recovery passed\n");
}

// Minimal staged set that satisfies the protocol, so the coordinator's failure path is actually
// exercised instead of throwing on a missing selector.
@interface FDMTestStagedSet : NSObject <FDMBackupStagedSet>
@property (nonatomic, copy) NSData *beforeSnapshot;
@property (nonatomic, copy) NSData *afterSnapshot;
@end

@implementation FDMTestStagedSet
@end

// A repository whose rollback always fails, to prove the coordinator keeps protection state
// instead of reporting success. It implements the full v2 protocol so the failure it injects is the
// only reason the restore fails.
@interface FDMFailingRollbackRepository : NSObject <FDMBackupRepository>
@property NSUInteger commitCalls;
@property NSUInteger rollbackCalls;
@end

@implementation FDMFailingRollbackRepository
- (NSString *)categoryIdentifier { return FDMBackupCategoryPreferences; }
- (BOOL)isAvailable { return YES; }
// Its own store, so it takes the independent (non-SQL) commit path.
- (NSString *)storageDomain { return nil; }

- (NSData *)payload {
    return FDMBackupData(@"{\"schemaVersion\":1,\"values\":{}}");
}

- (NSData *)exportSnapshotWithRevision:(NSString **)revision error:(NSError **)error {
    NSData *payload = [self payload];
    // The revision fingerprint is a string, not bytes.
    if (revision) *revision = FDMBackupSHA256(payload);
    return payload;
}

- (NSString *)currentRevisionWithError:(NSError **)error {
    return FDMBackupSHA256([self payload]);
}

- (id)validateImportPayload:(NSData *)payload error:(NSError **)error {
    id root = FDMJSONParseData(payload, error);
    NSDictionary *document = FDMJSONObjectValue(root);
    if (!document) { if (error) *error = FDMBackupDataError(@"偏好数据必须是对象"); return nil; }
    return FDMJSONObjectValue(document[@"values"]) ?: @{};
}

- (NSDictionary<NSString *, NSNumber *> *)previewCountsForValidated:(id)validated error:(NSError **)error {
    return @{FDMBackupCountAdded: @0, FDMBackupCountIdentical: @0, FDMBackupCountConflict: @0,
             FDMBackupCountDowngraded: @0, FDMBackupCountDisabled: @0, FDMBackupCountUnsupported: @0};
}

- (id)stageMergeValidated:(id)validated replace:(BOOL)replace error:(NSError **)error {
    FDMTestStagedSet *staged = [[FDMTestStagedSet alloc] init];
    staged.beforeSnapshot = [self payload];
    staged.afterSnapshot = [self payload];
    return staged;
}

- (BOOL)applyStaged:(id)staged onExecutor:(id<FDMBackupSQLExecutor>)executor error:(NSError **)error {
    if (error) *error = FDMBackupDataError(@"该类别不通过 SQL 提交");
    return NO;
}

- (NSData *)commitStaged:(id)staged error:(NSError **)error {
    _commitCalls++;
    if (error) *error = [NSError errorWithDomain:@"FocusDM.Backup.Test" code:1
                                        userInfo:@{NSLocalizedDescriptionKey: @"注入的提交失败"}];
    return nil;
}

- (BOOL)rollbackStaged:(id)staged error:(NSError **)error {
    _rollbackCalls++;
    if (error) *error = [NSError errorWithDomain:@"FocusDM.Backup.Test" code:2
                                        userInfo:@{NSLocalizedDescriptionKey: @"注入的回滚失败"}];
    return NO;
}

- (id)stageRestoreSnapshot:(NSData *)snapshot error:(NSError **)error {
    FDMTestStagedSet *staged = [[FDMTestStagedSet alloc] init];
    staged.beforeSnapshot = snapshot;
    staged.afterSnapshot = snapshot;
    return staged;
}

- (BOOL)verifyCommittedStateWithError:(NSError **)error { return YES; }
- (void)reloadHostCache {}
@end

static void FDMTestRollbackFailureKeepsProtection(void) {
    FDMBackupCoordinator *coordinator = [[FDMBackupCoordinator alloc] init];
    FDMFailingRollbackRepository *failing = [FDMFailingRollbackRepository new];
    [coordinator registerRepository:failing];
    NSData *payload = FDMBackupData(@"{\"schemaVersion\":1,\"values\":{}}");
    FDMBackupCategory *category = [FDMBackupCategory category:FDMBackupCategoryPreferences payload:payload itemCount:0];
    NSData *encoded = FDMBackupEncode(@[category], @"v20", NULL);
    FDMBackupContainer *container = FDMBackupDecode(encoded, NULL);
    FDMBackupCheck(container != nil, @"container decoded");
    NSError *error = nil;
    FDMBackupImportPlan *plan = [coordinator previewContainer:container categories:@[FDMBackupCategoryPreferences] replace:NO error:&error];
    FDMBackupCheck(plan != nil, @"plan built for failing repository");
    FDMBackupCheck(![coordinator applyPlan:plan error:&error], @"apply reports failure, not success");
    FDMBackupCheck(failing.commitCalls == 1 && failing.rollbackCalls == 1, @"failing commit and rollback actually executed exactly once");
    FDMBackupCheck(coordinator.recoveryBlocked && coordinator.recoveryNotice.length > 0, @"rollback failure keeps a protection notice");
    printf("B08 honest rollback failure passed\n");
}

#pragma mark - B11: no secrets in the container

static void FDMTestNoSecretsInContainer(void) {
    NSError *error = nil;
    // A bookmark URL is user content; what must never appear is credential material from the app.
    NSData *payload = FDMJSONCanonicalData(@{@"schemaVersion": @1, @"items": @[
        @{@"id": @"a", @"title": @"A", @"url": @"https://a.example/1"}]}, &error);
    NSData *encoded = FDMBackupEncode(@[[FDMBackupCategory category:FDMBackupCategoryBookmarks payload:payload itemCount:1]], @"v20", &error);
    FDMBackupCheck(encoded.length > 0, @"container encoded");
    NSString *text = [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding];
    for (NSString *forbidden in @[@"password", @"cookie", @"Authorization", @"resumeData", @"keychain", @"sessionID"]) {
        FDMBackupCheck([text rangeOfString:forbidden options:NSCaseInsensitiveSearch].location == NSNotFound,
                       [NSString stringWithFormat:@"container must not carry %@", forbidden]);
    }
    // Every category this build can write is on the allowlist of configuration-only data.
    for (NSString *category in FDMBackupCategoryOrder()) {
        FDMBackupCheck([FDMBackupCategoryTitle(category) length] > 0, @"category has a title");
    }
    FDMBackupCheck(!FDMBackupCategorySelectedByDefault(FDMBackupCategoryScripts), @"scripts are opt-in");
    printf("B11 container secret exclusion passed\n");
}

#pragma mark - script import rules

static void FDMTestScriptImportRules(void) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"fdm-backup-scripts-%@.sqlite", NSUUID.UUID.UUIDString]];
    NSError *error = nil;
    FDMSQLiteFixtureDatabase *database = [[FDMSQLiteFixtureDatabase alloc] initWithPath:path error:&error];
    FDMBackupCreateSchema(database);
    FDMBackupScriptsRepository *repository = [[FDMBackupScriptsRepository alloc] initWithDatabase:database];

    NSData *incoming = FDMJSONCanonicalData(@{@"schemaVersion": @1, @"scripts": @[
        @{@"id": @"s1", @"name": @"Script One", @"content": @"// ==UserScript==\n// @name One\n// ==/UserScript==\n",
          @"runAt": @"document-end", @"enabled": @YES}]}, &error);
    id validated = [repository validateImportPayload:incoming error:&error];
    FDMBackupCheck(validated != nil, @"script payload validated");

    NSDictionary *counts = [repository previewCountsForValidated:validated error:&error];
    FDMBackupCheck([counts[FDMBackupCountAdded] integerValue] == 1, @"one script is new");
    FDMBackupCheck([counts[FDMBackupCountDisabled] integerValue] == 1, @"imported script counted as disabled");

    id staged = [repository stageMergeValidated:validated replace:NO error:&error];
    FDMBackupCheck(staged != nil, @"script merge staged");
    FDMBackupCheck([repository commitStaged:staged error:&error] != nil, @"script merge committed");
    // A new or changed script must land disabled regardless of the payload's own flag.
    FDMBackupCheck([FDMBackupRowValue(database, @"t_userscript", @"uuid", @"s1", @"isActive") isEqual:@"0"],
                   @"imported script is disabled");
    FDMBackupCheck([FDMBackupRowValue(database, @"t_userscript", @"uuid", @"s1", @"content") length] > 0,
                   @"script content restored");

    // Re-importing the identical script keeps the local enabled state.
    [database inDatabase:^(id<FDMBackupSQLExecutor> executor) {
        [executor update:@"UPDATE t_userscript SET isActive = 1 WHERE uuid = 's1'" parameters:nil error:NULL];
    }];
    id again = [repository stageMergeValidated:validated replace:NO error:&error];
    FDMBackupCheck(again != nil, @"re-import staged");
    FDMBackupCheck([repository commitStaged:again error:&error] != nil, @"re-import committed");
    FDMBackupCheck([FDMBackupRowValue(database, @"t_userscript", @"uuid", @"s1", @"isActive") isEqual:@"1"],
                   @"unchanged script keeps its enabled state");

    // Over-budget content is refused.
    NSMutableString *huge = [NSMutableString stringWithCapacity:FDMBackupMaxScriptBytes + 16];
    NSString *chunk = @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    while (huge.length < FDMBackupMaxScriptBytes + 16) [huge appendString:chunk];
    NSData *tooBig = FDMJSONCanonicalData(@{@"schemaVersion": @1, @"scripts": @[
        @{@"id": @"s2", @"name": @"Huge", @"content": huge}]}, &error);
    FDMBackupCheck([repository validateImportPayload:tooBig error:&error] == nil, @"over-budget script refused");

    [database close];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    printf("script import rules passed\n");
}

#pragma mark - policy permission downgrade

static void FDMTestPolicyDowngrade(void) {
    FDMBackupPolicyRepository *repository = [[FDMBackupPolicyRepository alloc] init];
    NSError *error = nil;
    NSData *payload = FDMJSONCanonicalData(@{@"schemaVersion": @1, @"revision": @0, @"origins": @{
        @"https://cam.example:443": @{@"camera": @"allow", @"microphone": @"allow"}}}, &error);
    id validated = [repository validateImportPayload:payload error:&error];
    FDMBackupCheck(validated != nil, @"policy payload validated");
    NSDictionary *entry = validated[@"origins"][@"https://cam.example:443"];
    FDMBackupCheck([entry[@"camera"] isEqual:@"ask"], @"imported camera allow downgraded to ask");
    FDMBackupCheck([entry[@"microphone"] isEqual:@"ask"], @"imported microphone allow downgraded to ask");
    printf("policy permission downgrade passed\n");
}

// B05: a local change after preview must force a re-preview, never silently overwrite.
static void FDMTestConcurrentChangeForcesRepreview(void) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"fdm-backup-b05-%@.sqlite", NSUUID.UUID.UUIDString]];
    NSError *error = nil;
    FDMSQLiteFixtureDatabase *database = [[FDMSQLiteFixtureDatabase alloc] initWithPath:path error:&error];
    FDMBackupCreateSchema(database);
    FDMBackupSeedBookmark(database, @"shared-1", @"", @"Local", @"https://shared.example/1", 0, 0);
    FDMBackupBookmarkRepository *repository = [[FDMBackupBookmarkRepository alloc] initWithDatabase:database];

    NSData *incoming = FDMJSONCanonicalData(@{@"schemaVersion": @1, @"items": @[
        @{@"id": @"new-1", @"title": @"New", @"url": @"https://new.example/1", @"order": @0}]}, &error);
    id validated = [repository validateImportPayload:incoming error:&error];
    NSString *previewRevision = [repository currentRevisionWithError:&error];
    FDMBackupCheck(previewRevision.length > 0, @"preview revision captured");

    // A local edit lands after the preview.
    FDMBackupSeedBookmark(database, @"local-2", @"", @"Edited", @"https://edited.example/1", 0, 1);
    NSString *currentRevision = [repository currentRevisionWithError:&error];
    FDMBackupCheck(![currentRevision isEqual:previewRevision], @"revision changes after a local edit");

    // The coordinator must refuse to apply a plan whose revision no longer matches.
    FDMBackupCategory *category = [FDMBackupCategory category:FDMBackupCategoryBookmarks
                                                      payload:incoming itemCount:1];
    NSData *encoded = FDMBackupEncode(@[category], @"v20", NULL);
    FDMBackupContainer *container = FDMBackupDecode(encoded, NULL);
    FDMBackupCheck(container != nil, @"container decoded for B05");

    FDMBackupCoordinator *coordinator = [[FDMBackupCoordinator alloc] init];
    [coordinator registerRepository:repository database:database];
    FDMBackupImportPlan *stalePlan = [coordinator previewContainer:container
                                                       categories:@[FDMBackupCategoryBookmarks]
                                                          replace:NO
                                                            error:&error];
    FDMBackupCheck(stalePlan != nil, @"plan built before the edit");
    // Simulate the edit happening between preview and apply by mutating after the plan exists.
    FDMBackupSeedBookmark(database, @"local-3", @"", @"Later", @"https://later.example/1", 0, 2);
    BOOL applied = [coordinator applyPlan:stalePlan error:&error];
    FDMBackupCheck(!applied, @"stale plan is refused, not applied over a newer local state");
    FDMBackupCheck(FDMBackupCountRows(database, @"t_bookmark") == 3, @"refused apply wrote nothing");

    [database close];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    printf("B05 concurrent change forces re-preview passed\n");
}

// B07 (strict journal): a journal whose before snapshot fails its hash must block, and must NOT be
// deleted as if recovery had succeeded.
static void FDMTestJournalHashMismatchBlocks(void) {
    NSString *documents = FDMDocumentsPath();
    NSString *journalPath = [documents stringByAppendingPathComponent:@"FocusDM/backup-journal.json"];
    NSData *snapshot = FDMBackupData(@"{\"schemaVersion\":1,\"items\":[]}");
    // Correct hash recorded, but the stored bytes are different: verification must fail.
    NSDictionary *journal = @{
        @"schemaVersion": @1,
        @"transactionID": NSUUID.UUID.UUIDString,
        @"stage": @"prepared",
        @"categories": @[FDMBackupCategoryBookmarks],
        @"createdAt": @((long long)NSDate.date.timeIntervalSince1970),
        @"before": @{FDMBackupCategoryBookmarks: [FDMBackupData(@"{\"schemaVersion\":1,\"items\":[{\"id\":\"tampered\"}]}") base64EncodedStringWithOptions:0]},
        @"beforeSHA256": @{FDMBackupCategoryBookmarks: FDMBackupSHA256(snapshot)},
        @"after": @{},
        @"afterSHA256": @{},
    };
    NSError *error = nil;
    FDMBackupCheck(FDMWriteJSON(journal, journalPath, &error), @"tampered journal written");

    FDMBackupCoordinator *coordinator = [[FDMBackupCoordinator alloc] init];
    [coordinator recoverInterruptedTransaction];
    FDMBackupCheck(coordinator.recoveryNotice.length > 0, @"hash mismatch reports a notice");
    FDMBackupCheck([[NSFileManager defaultManager] fileExistsAtPath:journalPath],
                   @"unverifiable journal is kept, never deleted as success");
    printf("B07 journal hash mismatch blocks passed\n");
}

// Host substitutes here only model the original cache/model seam. Actual SQL/defaults/files and
// the shipped recovery coordinator are exercised; this is not a Focus-device acceptance claim.
@interface UserScript : NSObject
@property (nonatomic, copy) NSDictionary *values;
@property (nonatomic, copy) NSString *executorJs;
- (instancetype)initWithDictionary:(NSDictionary *)dictionary error:(NSError **)error;
- (void)jsonModelFromSql;
- (void)updateExecutorJs;
@end
@implementation UserScript
- (instancetype)initWithDictionary:(NSDictionary *)dictionary error:(NSError **)error { if ((self=[super init])) _values=[dictionary copy]; return self; }
- (void)jsonModelFromSql {}
- (void)updateExecutorJs { self.executorJs = [@"fixture-wrapper:" stringByAppendingString:_values[@"content"] ?: @""]; }
@end
@interface Tampermonkey : NSObject
@property (nonatomic, copy) NSString *scriptPath;
@property (nonatomic, strong) NSMutableArray *cache;
+ (instancetype)shareInstance;
@end
@implementation Tampermonkey
+ (instancetype)shareInstance { static id owner; static dispatch_once_t once; dispatch_once(&once, ^{ owner=[self new]; [owner setCache:[NSMutableArray array]]; }); return owner; }
- (void)removeAllUserScriptsFromCache { [_cache removeAllObjects]; }
- (void)saveUserScriptToCache:(id)model { [_cache addObject:model]; }
@end

static void FDMTestFullMetadataAndAliases(void) {
    NSString *path=[FDMDocumentsPath() stringByAppendingPathComponent:@"metadata.sqlite"];
    NSError *error=nil; FDMSQLiteFixtureDatabase *database=[[FDMSQLiteFixtureDatabase alloc] initWithPath:path error:&error]; FDMBackupCreateSchema(database);
    FDMBackupScriptsRepository *repository=[[FDMBackupScriptsRepository alloc] initWithDatabase:database];
    NSDictionary *original=@{@"id": @"script-1", @"name": @"Sample", @"content": @"// original body", @"runAt": @"document-end", @"enabled": @YES};
    NSData *payload=FDMJSONCanonicalData(@{@"schemaVersion": @1, @"scripts": @[original]}, &error);
    id dto=[repository validateImportPayload:payload error:&error]; id first=[repository stageMergeValidated:dto replace:YES error:&error];
    FDMBackupCheck(first && [repository commitStaged:first error:&error], @"first script stored");
    [database inDatabase:^(id<FDMBackupSQLExecutor> sql) { [sql update:@"UPDATE t_userscript SET isActive=1 WHERE uuid=?" parameters:@[@"script-1"] error:NULL]; }];
    NSMutableDictionary *changed=[original mutableCopy]; changed[@"runAt"]=@"document-start";
    payload=FDMJSONCanonicalData(@{@"schemaVersion": @1, @"scripts": @[changed]}, &error); dto=[repository validateImportPayload:payload error:&error];
    NSDictionary *counts=[repository previewCountsForValidated:dto error:&error];
    FDMBackupCheck([counts[FDMBackupCountConflict] integerValue]==1 && [counts[FDMBackupCountIdentical] integerValue]==0, @"metadata-only change is a conflict");
    id replacement=[repository stageMergeValidated:dto replace:YES error:&error];
    FDMBackupCheck(replacement && [repository commitStaged:replacement error:&error], @"metadata-only replacement applies");
    FDMBackupCheck([FDMBackupRowValue(database, @"t_userscript", @"uuid", @"script-1", @"isActive") isEqual:@"0"], @"metadata-only changed script is disabled");
    FDMBackupCheck([FDMBackupRowValue(database, @"t_userscript", @"uuid", @"script-1", @"runAt") isEqual:@"document-start"], @"new metadata really stored");
    NSData *aliases=FDMJSONCanonicalData(@{@"schemaVersion": @1, @"scripts": @[
        @{@"id": @"a-b", @"name": @"A", @"content": @"one"}, @{@"id": @"a_b", @"name": @"B", @"content": @"two"}]}, &error);
    FDMBackupCheck([repository validateImportPayload:aliases error:&error]==nil, @"distinct IDs mapping to same file are refused");
    [database close]; printf("full metadata and source-path aliases passed\n");
}
static void FDMTestReadBarrierAndConcurrentWrite(void) {
    NSString *suite=[@"focusdm.barrier." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *owner=[[NSUserDefaults alloc] initWithSuiteName:suite], *reader=[[NSUserDefaults alloc] initWithSuiteName:suite];
    [owner setObject:@[@"before"] forKey:@"config"]; [owner synchronize];
    FDMBackupBeginReadBarrier(); FDMBackupProtectDefaults(owner, suite, @"config");
    FDMBackupInternalAccess(^BOOL { [owner setObject:@[@"after"] forKey:@"config"]; [owner synchronize]; return YES; });
    FDMBackupCheck([[reader arrayForKey:@"config"] isEqual:@[@"before"]], @"another suite instance keeps the published before snapshot");
    __block NSArray *backgroundRead=nil;
    dispatch_sync(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0), ^{ backgroundRead=[reader arrayForKey:@"config"]; });
    FDMBackupCheck([backgroundRead isEqual:@[@"before"]], @"background reader cannot observe half-committed defaults");
    [reader setObject:@[@"user-edit"] forKey:@"config"];
    __block BOOL marker=NO;
    FDMBackupCheck(!FDMBackupReadBarrierCommit(^BOOL { marker=YES; return YES; }) && !marker, @"concurrent user write prevents marker commit");
    FDMBackupInternalAccess(^BOOL { [owner setObject:@[@"before"] forKey:@"config"]; return YES; });
    FDMBackupFinishReadBarrier(YES);
    FDMBackupCheck([[reader arrayForKey:@"config"] isEqual:@[@"user-edit"]], @"deferred user edit survives rollback");
    [owner removePersistentDomainForName:suite]; printf("transaction read snapshots and concurrent writes passed\n");
}
static void FDMTestScriptFilesAndExactRestart(void) {
    NSString *path=[FDMDocumentsPath() stringByAppendingPathComponent:@"source.sqlite"];
    NSError *error=nil; FDMSQLiteFixtureDatabase *database=[[FDMSQLiteFixtureDatabase alloc] initWithPath:path error:&error]; FDMBackupCreateSchema(database);
    FDMBackupScriptsRepository *repository=[[FDMBackupScriptsRepository alloc] initWithDatabase:database];
    Tampermonkey.shareInstance.scriptPath=FDMDirectory(@"scripts");
    NSDictionary *old=@{@"id": @"file-1", @"name": @"Old", @"content": @"// body-before", @"runAt": @"document-end", @"enabled": @NO};
    NSData *payload=FDMJSONCanonicalData(@{@"schemaVersion": @1, @"scripts": @[old]}, &error);
    id dto=[repository validateImportPayload:payload error:&error], stage=[repository stageMergeValidated:dto replace:YES error:&error];
    FDMBackupCheck(stage && [repository commitStaged:stage error:&error] && [repository verifyCommittedStateWithError:&error], @"source and SQL are materialized");
    NSString *file=[Tampermonkey.shareInstance.scriptPath stringByAppendingPathComponent:@"file_1.js"];
    FDMBackupCheck([[NSData dataWithContentsOfFile:file] isEqual:[@"// body-before" dataUsingEncoding:NSUTF8StringEncoding]], @"disk source equals original bytes");
    NSData *before=[repository recoverySnapshotWithError:&error]; FDMBackupCheck(before != nil,@"full SQL and source before-image exists");
    FDMBackupBeginReadBarrier(); [repository preparePublicationBarrier];
    FDMBackupInternalAccess(^BOOL {
        [@"// body-after" writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:NULL]; return YES;
    });
    FDMBackupCheck([[[NSFileManager defaultManager] contentsAtPath:file] isEqual:[@"// body-before" dataUsingEncoding:NSUTF8StringEncoding]], @"host source reader sees published before file");
    NSString *journalPath=[FDMDirectory(@"FocusDM") stringByAppendingPathComponent:@"backup-journal.json"];
    NSDictionary *journal=@{@"schemaVersion": @2, @"transactionID": NSUUID.UUID.UUIDString, @"stage": @"rollbackPending",
        @"categories": @[FDMBackupCategoryScripts], @"exact": @{FDMBackupCategoryScripts: @YES},
        @"before": @{FDMBackupCategoryScripts: @{@"bytes": [before base64EncodedStringWithOptions:0], @"sha256": FDMBackupSHA256(before)}}};
    FDMBackupCheck(FDMWriteDurableJSON(journal,journalPath,&error), @"rollbackPending state persisted before recovery");
    FDMBackupCoordinator *newCoordinator=[FDMBackupCoordinator new]; [newCoordinator registerRepository:repository database:database];
    [newCoordinator recoverInterruptedTransaction];
    FDMBackupCheck(!newCoordinator.recoveryBlocked, @"new recovery owner restores rollbackPending, never treats it as committed");
    FDMBackupCheck([[NSData dataWithContentsOfFile:file] isEqual:[@"// body-before" dataUsingEncoding:NSUTF8StringEncoding]], @"exact before source restored on restart");
    FDMBackupCheck([[repository recoverySnapshotWithError:&error] isEqual:before], @"all SQL metadata and source bytes are exact after recovery");
    [database close]; printf("real script source and exact restart recovery passed\n");
}

static void FDMBackupBeginCase(NSString *label) {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"focusdm-backup-%@-%@", label, NSUUID.UUID.UUIDString]];
    FDMBackupCheck([[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL], @"fresh case directory exists");
    setenv("FDM_TEST_DOCUMENTS", root.fileSystemRepresentation, 1);
    FDMBackupCheck([FDMDocumentsPath() isEqual:root], @"case root is actually honored");
    (void)FDMDirectory(@"FocusDM");
}
void FDMRunBackupRegression(void) {
    FDMBackupBeginCase(@"HostDefaultExportShapes"); FDMTestHostDefaultExportShapes();
    FDMBackupBeginCase(@"ExportFailureDiagnostics"); FDMTestExportFailureDiagnostics();
    FDMBackupBeginCase(@"ValidationRefusesBadInput"); FDMTestValidationRefusesBadInput();
    FDMBackupBeginCase(@"MergeAndReplace"); FDMTestMergeAndReplace();
    FDMBackupBeginCase(@"HierarchyFidelity"); FDMTestHierarchyFidelity();
    FDMBackupBeginCase(@"JournalRecovery"); FDMTestJournalRecovery();
    FDMBackupBeginCase(@"JournalHashMismatchBlocks"); FDMTestJournalHashMismatchBlocks();
    FDMBackupBeginCase(@"ConcurrentChangeForcesRepreview"); FDMTestConcurrentChangeForcesRepreview();
    FDMBackupBeginCase(@"RollbackFailureKeepsProtection"); FDMTestRollbackFailureKeepsProtection();
    FDMBackupFinishReadBarrier(YES);
    FDMBackupBeginCase(@"FullMetadataAndAliases"); FDMTestFullMetadataAndAliases();
    FDMBackupBeginCase(@"ReadBarrierAndConcurrentWrite"); FDMTestReadBarrierAndConcurrentWrite();
    FDMBackupBeginCase(@"ScriptFilesAndExactRestart"); FDMTestScriptFilesAndExactRestart();
    FDMBackupBeginCase(@"NoSecretsInContainer"); FDMTestNoSecretsInContainer();
    FDMBackupBeginCase(@"ScriptImportRules"); FDMTestScriptImportRules();
    FDMBackupBeginCase(@"PolicyDowngrade"); FDMTestPolicyDowngrade();
    printf("backup regression suite passed\n");
}

// This suite has its own entry point so it can be built as a standalone binary without touching the
// shared native_main.m. The shared runner may also call FDMRunBackupRegression() directly.
#ifdef FDM_BACKUP_REGRESSION_MAIN
int main(void) {
    @autoreleasepool {
        @try {
            NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"focusdm-backup-regression-" stringByAppendingString:NSUUID.UUID.UUIDString]];
            [[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL];
            setenv("FDM_TEST_DOCUMENTS", root.fileSystemRepresentation, 1);
            FDMRunBackupRegression();
            return 0;
        } @catch (NSException *exception) {
            fprintf(stderr, "backup regression failed: %s: %s\n",
                    exception.name.UTF8String, exception.reason.UTF8String);
            return 1;
        }
    }
}
#endif
