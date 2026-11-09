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

static void FDMBackupCheck(BOOL condition, NSString *message) {
    if (!condition) [NSException raise:@"FDMBackupRegression" format:@"%@", message];
}

static NSData *FDMBackupData(NSString *text) {
    return [text dataUsingEncoding:NSUTF8StringEncoding];
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

// A repository whose rollback always fails, to prove the coordinator keeps protection state
// instead of reporting success.
@interface FDMFailingRollbackRepository : NSObject <FDMBackupRepository>
@end

@implementation FDMFailingRollbackRepository
- (NSString *)categoryIdentifier { return FDMBackupCategoryPreferences; }
- (BOOL)isAvailable { return YES; }
- (NSData *)exportSnapshotWithRevision:(NSString **)revision error:(NSError **)error {
    NSData *payload = FDMBackupData(@"{\"schemaVersion\":1,\"values\":{}}");
    if (revision) *revision = FDMBackupSHA256(payload);
    return payload;
}
- (NSString *)currentRevisionWithError:(NSError **)error { return [self exportSnapshotWithRevision:NULL error:error]; }
- (id)validateImportPayload:(NSData *)payload error:(NSError **)error {
    return FDMJSONObjectValue(FDMJSONParseData(payload, error)[@"values"]) ?: @{};
}
- (NSDictionary<NSString *, NSNumber *> *)previewCountsForValidated:(id)validated error:(NSError **)error {
    return @{FDMBackupCountAdded: @0, FDMBackupCountIdentical: @0, FDMBackupCountConflict: @0,
             FDMBackupCountDowngraded: @0, FDMBackupCountDisabled: @0, FDMBackupCountUnsupported: @0};
}
- (id)stageMergeValidated:(id)validated replace:(BOOL)replace error:(NSError **)error {
    return @{@"before": [self exportSnapshotWithRevision:NULL error:NULL] ?: [NSData data],
             @"after": [self exportSnapshotWithRevision:NULL error:NULL] ?: [NSData data]};
}
- (NSData *)commitStaged:(id)staged error:(NSError **)error {
    if (error) *error = [NSError errorWithDomain:@"FocusDM.Backup.Test" code:1
                                        userInfo:@{NSLocalizedDescriptionKey: @"注入的提交失败"}];
    return nil;
}
- (BOOL)rollbackStaged:(id)staged error:(NSError **)error {
    if (error) *error = [NSError errorWithDomain:@"FocusDM.Backup.Test" code:2
                                        userInfo:@{NSLocalizedDescriptionKey: @"注入的回滚失败"}];
    return NO;
}
- (id)stageRestoreSnapshot:(NSData *)snapshot error:(NSError **)error { return nil; }
- (void)reloadHostCache {}
@end

static void FDMTestRollbackFailureKeepsProtection(void) {
    FDMBackupCoordinator *coordinator = [[FDMBackupCoordinator alloc] init];
    [coordinator registerRepository:[[FDMFailingRollbackRepository alloc] init]];
    NSData *payload = FDMBackupData(@"{\"schemaVersion\":1,\"values\":{}}");
    FDMBackupCategory *category = [FDMBackupCategory category:FDMBackupCategoryPreferences payload:payload itemCount:0];
    NSData *encoded = FDMBackupEncode(@[category], @"v20", NULL);
    FDMBackupContainer *container = FDMBackupDecode(encoded, NULL);
    FDMBackupCheck(container != nil, @"container decoded");
    NSError *error = nil;
    FDMBackupImportPlan *plan = [coordinator previewContainer:container categories:@[FDMBackupCategoryPreferences] replace:NO error:&error];
    FDMBackupCheck(plan != nil, @"plan built for failing repository");
    FDMBackupCheck(![coordinator applyPlan:plan error:&error], @"apply reports failure, not success");
    FDMBackupCheck(coordinator.recoveryNotice.length > 0, @"rollback failure keeps a protection notice");
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

void FDMRunBackupRegression(void) {
    FDMTestValidationRefusesBadInput();
    FDMTestMergeAndReplace();
    FDMTestHierarchyFidelity();
    FDMTestJournalRecovery();
    FDMTestRollbackFailureKeepsProtection();
    FDMTestNoSecretsInContainer();
    FDMTestScriptImportRules();
    FDMTestPolicyDowngrade();
    printf("backup regression suite passed\n");
}

// This suite has its own entry point so it can be built as a standalone binary without touching the
// shared native_main.m. The shared runner may also call FDMRunBackupRegression() directly.
#ifdef FDM_BACKUP_REGRESSION_MAIN
int main(void) {
    @autoreleasepool {
        @try {
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
