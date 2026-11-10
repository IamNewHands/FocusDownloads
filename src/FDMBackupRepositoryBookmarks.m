#import "FDMBackupRepositoryImpl.h"
#import "FDMBackupSQL.h"
#import "FDMJSON.h"
#import "FDMBackupRecovery.h"
#import "FDMPolicy.h"

NSString *const FDMBackupCountAdded = @"added";
NSString *const FDMBackupCountIdentical = @"identical";
NSString *const FDMBackupCountConflict = @"conflict";
NSString *const FDMBackupCountDowngraded = @"downgraded";
NSString *const FDMBackupCountDisabled = @"disabled";
NSString *const FDMBackupCountUnsupported = @"unsupported";

static NSError *FDMRepoError(NSString *message) {
    return [NSError errorWithDomain:@"FocusDM.Backup.Repository" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL FDMRepoBoundedString(id value, NSUInteger maxBytes, BOOL required, NSError **error, NSString *label) {
    if (value == nil || value == NSNull.null) {
        if (required) { if (error) *error = FDMRepoError([NSString stringWithFormat:@"%@ 缺失", label]); return NO; }
        return YES;
    }
    if (![value isKindOfClass:NSString.class]) {
        if (error) *error = FDMRepoError([NSString stringWithFormat:@"%@ 必须是字符串", label]);
        return NO;
    }
    NSUInteger bytes = [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (bytes > maxBytes) { if (error) *error = FDMRepoError([NSString stringWithFormat:@"%@ 超出长度上限", label]); return NO; }
    if (required && bytes == 0) { if (error) *error = FDMRepoError([NSString stringWithFormat:@"%@ 不能为空", label]); return NO; }
    return YES;
}

// The after snapshot must be byte-identical to what exportSnapshot would produce next time, so it is
// always rebuilt by sorting items by stable ID exactly like the SQL ORDER BY in readRowsWithError:.
static NSData *FDMBackupSortedItemsPayload(NSDictionary<NSString *, NSDictionary *> *byID, NSError **error) {
    NSArray *sorted = [byID.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"id"] compare:b[@"id"]];
    }];
    return FDMJSONCanonicalData(@{@"schemaVersion": @1, @"items": sorted}, error);
}
static BOOL FDMRepoInteger(id value, long long minimum, long long maximum, long long *out, NSError **error, NSString *label) {
    if (!FDMJSONNonNegativeInteger(value, (unsigned long long)maximum, NULL) && [value isKindOfClass:NSNumber.class]) {
        // fall through to the signed check below
    }
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        if (error) *error = FDMRepoError([NSString stringWithFormat:@"%@ 必须是整数", label]);
        return NO;
    }
    double raw = [value doubleValue];
    if (!isfinite(raw) || raw != floor(raw) || raw < (double)minimum || raw > (double)maximum) {
        if (error) *error = FDMRepoError([NSString stringWithFormat:@"%@ 超出允许范围", label]);
        return NO;
    }
    if (out) *out = (long long)raw;
    return YES;
}

static NSString *FDMRepoStringOrEmpty(id value) {
    return [value isKindOfClass:NSString.class] ? value : @"";
}

#pragma mark - shared tree validation

// Validates a bookmark-shaped item list: unique stable IDs, resolvable parents, no cycles, bounded
// depth, bounded name/url lengths. A folder may carry an empty url; a leaf may not.
static NSArray<NSDictionary *> *FDMValidateBookmarkItems(NSArray *items,
                                                         BOOL allowEmptyURLForFolders,
                                                         NSUInteger maxItems,
                                                         NSError **error) {
    if (![items isKindOfClass:NSArray.class]) { if (error) *error = FDMRepoError(@"条目必须是数组"); return nil; }
    if (items.count > maxItems) { if (error) *error = FDMRepoError(@"条目数量超出上限"); return nil; }
    NSMutableArray *validated = [NSMutableArray arrayWithCapacity:items.count];
    NSMutableSet *ids = [NSMutableSet set];
    for (id raw in items) {
        NSDictionary *row = FDMJSONObjectValue(raw);
        if (!row) { if (error) *error = FDMRepoError(@"条目必须是对象"); return nil; }
        for (NSString *key in row) {
            if (![@[@"id", @"parentID", @"title", @"url", @"iconURL", @"fileType", @"order"] containsObject:key]) {
                if (error) *error = FDMRepoError([NSString stringWithFormat:@"条目含未知字段：%@", key]);
                return nil;
            }
        }
        NSString *identifier = FDMJSONStringValue(row[@"id"]);
        if (!identifier.length || identifier.length > 128) { if (error) *error = FDMRepoError(@"条目缺少有效标识"); return nil; }
        if ([ids containsObject:identifier]) { if (error) *error = FDMRepoError([NSString stringWithFormat:@"条目标识重复：%@", identifier]); return nil; }
        [ids addObject:identifier];

        NSString *parent = FDMJSONStringValue(row[@"parentID"]);
        if (parent && parent.length > 128) { if (error) *error = FDMRepoError(@"父级标识过长"); return nil; }
        if (!FDMRepoBoundedString(row[@"title"] ?: @"", FDMBackupMaxNameBytes, NO, error, @"标题")) return nil;
        if (!FDMRepoBoundedString(row[@"iconURL"] ?: @"", FDMBackupMaxURLBytes, NO, error, @"图标地址")) return nil;

        long long fileType = 0;
        if (row[@"fileType"] && !FDMRepoInteger(row[@"fileType"], -1, 100, &fileType, error, @"fileType")) return nil;
        BOOL isFolder = fileType != 0;

        NSString *url = FDMJSONStringValue(row[@"url"]);
        if (url.length) {
            if (!FDMRepoBoundedString(url, FDMBackupMaxURLBytes, YES, error, @"地址")) return nil;
            if (!FDMNormalizedOrigin(url) && ![url hasPrefix:@"focus://"] && ![url hasPrefix:@"javascript:"] && ![url hasPrefix:@"file:"]) {
                if (error) *error = FDMRepoError([NSString stringWithFormat:@"地址不是有效链接：%@", url]);
                return nil;
            }
        } else if (!(allowEmptyURLForFolders && isFolder)) {
            if (error) *error = FDMRepoError(@"非文件夹条目必须带地址");
            return nil;
        }

        long long order = 0;
        if (row[@"order"] && !FDMRepoInteger(row[@"order"], 0, 1000000, &order, error, @"顺序")) return nil;

        NSMutableDictionary *entry = [@{@"id": identifier, @"title": FDMRepoStringOrEmpty(row[@"title"]),
                                        @"url": url ?: @"", @"iconURL": FDMRepoStringOrEmpty(row[@"iconURL"]),
                                        @"fileType": @(fileType), @"order": @(order)} mutableCopy];
        if (parent.length) entry[@"parentID"] = parent;
        [validated addObject:entry];
    }

    // Parent resolution and cycle detection over the combined (existing + imported) view happens at
    // merge time; here we only refuse a parent that is neither imported nor already known.
    NSMutableDictionary<NSString *, NSString *> *parentOf = [NSMutableDictionary dictionary];
    for (NSDictionary *row in validated) parentOf[row[@"id"]] = row[@"parentID"] ?: @"";
    for (NSDictionary *row in validated) {
        NSString *parent = row[@"parentID"];
        if (!parent.length) continue;
        if (parentOf[parent] == nil) continue;  // may exist in the live database; checked at merge
        NSMutableSet *seen = [NSMutableSet set];
        NSString *cursor = row[@"id"];
        NSUInteger depth = 0;
        while (cursor.length) {
            if ([seen containsObject:cursor]) { if (error) *error = FDMRepoError(@"文件夹存在循环引用"); return nil; }
            [seen addObject:cursor];
            if (++depth > 32) { if (error) *error = FDMRepoError(@"层级过深"); return nil; }
            cursor = parentOf[cursor];
        }
    }
    return validated;
}

// Detects a cycle using the merged parent map, which includes live rows the import does not touch.
static BOOL FDMValidateMergedTree(NSDictionary<NSString *, NSString *> *parentOf, NSError **error) {
    for (NSString *identifier in parentOf) {
        NSMutableSet *seen = [NSMutableSet set];
        NSString *cursor = identifier;
        NSUInteger depth = 0;
        while (cursor.length) {
            if ([seen containsObject:cursor]) { if (error) *error = FDMRepoError(@"合并后存在循环引用"); return NO; }
            [seen addObject:cursor];
            if (++depth > 32) { if (error) *error = FDMRepoError(@"合并后层级过深"); return NO; }
            cursor = parentOf[cursor];
        }
    }
    return YES;
}

#pragma mark - staged set

@interface FDMBackupSQLStagedSet : NSObject <FDMBackupStagedSet>
@property (nonatomic, copy) NSData *beforeSnapshot;
@property (nonatomic, copy) NSData *afterSnapshot;
// Rows to write, already resolved (merge done at stage time).
@property (nonatomic, copy) NSArray<NSDictionary *> *rowsToWrite;
// Row identities to delete (only when replace is requested, or when a conflict is resolved to ours).
@property (nonatomic, copy) NSArray<NSString *> *idsToDelete;
@end

@implementation FDMBackupSQLStagedSet
@end

#pragma mark - bookmark repository

@interface FDMBackupBookmarkRepository ()
@property (nonatomic, strong) id<FDMBackupSQLDatabase> database;
@end

@implementation FDMBackupBookmarkRepository

- (instancetype)initWithDatabase:(id<FDMBackupSQLDatabase>)database {
    if ((self = [super init])) _database = database;
    return self;
}

- (NSString *)categoryIdentifier { return FDMBackupCategoryBookmarks; }

- (BOOL)isAvailable { return self.database != nil; }

// Both bookmark categories live in the host's single SQLite database, so they must share one
// transaction during a restore.
- (NSString *)storageDomain { return @"host.sqlite3"; }

- (NSString *)tableName { return @"t_bookmark"; }
- (NSString *)idColumn { return @"bookmarkId"; }
- (NSArray<NSString *> *)columns { return @[@"bookmarkId", @"parentId", @"title", @"url", @"iconUrl", @"fileType", @"ppOrder", @"updateTime", @"ctime"]; }

- (NSArray<NSDictionary *> *)readRowsWithError:(NSError **)error {
    __block NSArray *rows = nil;
    __block NSError *failure = nil;
    [self.database inDatabase:^(id<FDMBackupSQLExecutor> executor) {
        NSSet *columns = nil;
        if (!FDMBackupTableColumns(executor, self.tableName, &columns, &failure)) return;
        // Only select columns that actually exist: the host migrates with ALTER TABLE, so an older
        // user database can lack iconUrl/ppOrder/updateTime.
        NSMutableArray *selected = [NSMutableArray array];
        for (NSString *column in self.columns) if ([columns containsObject:column]) [selected addObject:column];
        NSString *sql = [NSString stringWithFormat:@"SELECT %@ FROM %@ ORDER BY %@",
                         [selected componentsJoinedByString:@","], self.tableName, self.idColumn];
        rows = [executor query:sql parameters:nil error:&failure];
    }];
    if (failure) { if (error) *error = failure; return nil; }
    return rows ?: @[];
}

- (NSData *)exportSnapshotWithRevision:(NSString **)revision error:(NSError **)error {
    NSArray *rows = [self readRowsWithError:error];
    if (!rows) return nil;
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:rows.count];
    for (NSDictionary *row in rows) {
        NSMutableDictionary *item = [NSMutableDictionary dictionary];
        item[@"id"] = FDMRepoStringOrEmpty(row[self.idColumn]);
        if (![item[@"id"] length]) continue;
        item[@"title"] = FDMRepoStringOrEmpty(row[@"title"]);
        item[@"url"] = FDMRepoStringOrEmpty(row[@"url"]);
        NSString *parent = FDMRepoStringOrEmpty(row[@"parentId"]); if (parent.length) item[@"parentID"] = parent;
        item[@"iconURL"] = FDMRepoStringOrEmpty(row[@"iconUrl"]);
        item[@"fileType"] = [row[@"fileType"] isKindOfClass:NSNumber.class] ? row[@"fileType"] : @0;
        item[@"order"] = [row[@"ppOrder"] isKindOfClass:NSNumber.class] ? row[@"ppOrder"] : @0;
        [items addObject:item];
    }
    NSData *payload = FDMJSONCanonicalData(@{@"schemaVersion": @1, @"items": items}, error);
    if (payload && revision) *revision = FDMBackupSHA256(payload);
    return payload;
}

- (NSString *)currentRevisionWithError:(NSError **)error {
    NSString *revision = nil;
    if (![self exportSnapshotWithRevision:&revision error:error]) return nil;
    return revision;
}

- (id)validateImportPayload:(NSData *)payload error:(NSError **)error {
    id root = FDMJSONParseData(payload, error);
    NSDictionary *document = FDMJSONObjectValue(root);
    if (!document) { if (error) *error = FDMRepoError(@"书签数据必须是对象"); return nil; }
    for (NSString *key in document) {
        if (![@[@"schemaVersion", @"items"] containsObject:key]) { if (error) *error = FDMRepoError(@"书签数据含未知字段"); return nil; }
    }
    unsigned long long schema = 0;
    if (!FDMJSONNonNegativeInteger(document[@"schemaVersion"], 100, &schema) || schema != 1) {
        if (error) *error = FDMRepoError(@"书签数据版本不受支持");
        return nil;
    }
    return FDMValidateBookmarkItems(FDMJSONArrayValue(document[@"items"]), YES, FDMBackupMaxBookmarks, error);
}

- (NSDictionary<NSString *, NSNumber *> *)previewCountsForValidated:(id)validated error:(NSError **)error {
    NSArray *live = [self readRowsWithError:error];
    if (!live) return nil;
    NSMutableDictionary *byID = [NSMutableDictionary dictionary];
    for (NSDictionary *row in live) {
        NSString *identifier = FDMRepoStringOrEmpty(row[self.idColumn]);
        if (identifier.length) byID[identifier] = row;
    }
    NSUInteger added = 0, identical = 0, conflict = 0;
    for (NSDictionary *item in validated) {
        NSDictionary *existing = byID[item[@"id"]];
        if (!existing) { added++; continue; }
        BOOL same = [FDMRepoStringOrEmpty(existing[@"title"]) isEqual:item[@"title"]] &&
                    [FDMRepoStringOrEmpty(existing[@"url"]) isEqual:item[@"url"]] &&
                    [FDMRepoStringOrEmpty(existing[@"parentId"]) isEqual:(item[@"parentID"] ?: @"")] &&
                    [FDMRepoStringOrEmpty(existing[@"iconUrl"]) isEqual:item[@"iconURL"]];
        NSNumber *liveFileType = [existing[@"fileType"] isKindOfClass:NSNumber.class] ? existing[@"fileType"] : @0;
        NSNumber *liveOrder = [existing[@"ppOrder"] isKindOfClass:NSNumber.class] ? existing[@"ppOrder"] : @0;
        same = same && [liveFileType isEqual:item[@"fileType"]] && [liveOrder isEqual:item[@"order"]];
        if (same) identical++; else conflict++;
    }
    return @{FDMBackupCountAdded: @(added), FDMBackupCountIdentical: @(identical),
             FDMBackupCountConflict: @(conflict), FDMBackupCountDowngraded: @0,
             FDMBackupCountDisabled: @0, FDMBackupCountUnsupported: @0};
}

// Merge rule: identical stable ID with all fields equal is a no-op; otherwise the local row wins
// (keep-local-conflict) unless `replace` was requested, in which case the backup wins.
- (id)stageMergeValidated:(id)validated replace:(BOOL)replace error:(NSError **)error {
    NSArray *live = [self readRowsWithError:error];
    if (!live) return nil;
    NSData *before = [self exportSnapshotWithRevision:NULL error:error];
    if (!before) return nil;

    NSMutableDictionary *liveByID = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *mergedParents = [NSMutableDictionary dictionary];
    for (NSDictionary *row in live) {
        NSString *identifier = FDMRepoStringOrEmpty(row[self.idColumn]);
        if (!identifier.length) continue;
        liveByID[identifier] = row;
        mergedParents[identifier] = FDMRepoStringOrEmpty(row[@"parentId"]);
    }

    NSMutableArray *toWrite = [NSMutableArray array];
    NSMutableArray *toDelete = [NSMutableArray array];
    for (NSDictionary *item in validated) {
        NSString *identifier = item[@"id"];
        NSDictionary *existing = liveByID[identifier];
        if (existing && !replace) {
            // keep-local: only add when absent, never overwrite an existing local row.
            continue;
        }
        [toWrite addObject:item];
        mergedParents[identifier] = item[@"parentID"] ?: @"";
    }
    if (replace) {
        NSMutableSet *imported = [NSMutableSet set];
        for (NSDictionary *item in validated) [imported addObject:item[@"id"]];
        for (NSString *identifier in liveByID) if (![imported containsObject:identifier]) { [toDelete addObject:identifier]; [mergedParents removeObjectForKey:identifier]; }
    }

    // A parent must exist after the merge; a dangling parent would orphan the subtree.
    for (NSDictionary *item in toWrite) {
        NSString *parent = item[@"parentID"];
        if (parent.length && mergedParents[parent] == nil) {
            if (error) *error = FDMRepoError([NSString stringWithFormat:@"引用了不存在的父级：%@", parent]);
            return nil;
        }
    }
    if (!FDMValidateMergedTree(mergedParents, error)) return nil;

    FDMBackupSQLStagedSet *staged = [[FDMBackupSQLStagedSet alloc] init];
    staged.beforeSnapshot = before;
    staged.rowsToWrite = toWrite;
    staged.idsToDelete = toDelete;
    // The after snapshot is the before snapshot with the written rows applied and deleted rows gone.
    // It must be sorted by stable ID, because the read-back compares these bytes with a fresh export.
    NSMutableDictionary *afterByID = [NSMutableDictionary dictionary];
    id beforeRoot = FDMJSONParseData(before, NULL);
    for (NSDictionary *item in FDMJSONArrayValue(FDMJSONObjectValue(beforeRoot)[@"items"])) afterByID[item[@"id"]] = item;
    for (NSString *identifier in toDelete) [afterByID removeObjectForKey:identifier];
    for (NSDictionary *item in toWrite) afterByID[item[@"id"]] = item;
    NSData *after = FDMBackupSortedItemsPayload(afterByID, error);
    if (!after) return nil;
    staged.afterSnapshot = after;
    return staged;
}

- (BOOL)applyStaged:(id)staged onExecutor:(id<FDMBackupSQLExecutor>)executor error:(NSError **)error {
    FDMBackupSQLStagedSet *set = staged;
    if (![set isKindOfClass:FDMBackupSQLStagedSet.class]) { if (error) *error = FDMRepoError(@"暂存集无效"); return NO; }
    return [self writeStagedSet:set onExecutor:executor error:error];
}

// Writes one staged set on a caller-owned connection. Shared by the single-category commit and by
// the coordinator's multi-category transaction, so both paths execute identical SQL.
- (BOOL)writeStagedSet:(FDMBackupSQLStagedSet *)set
            onExecutor:(id<FDMBackupSQLExecutor>)executor
                 error:(NSError **)error {
    NSSet *columns = nil;
    if (!FDMBackupTableColumns(executor, self.tableName, &columns, error)) return NO;
    if (set.idsToDelete.count) {
        NSMutableArray *marks = [NSMutableArray array];
        for (NSUInteger i = 0; i < set.idsToDelete.count; i++) [marks addObject:@"?"];
        NSString *sql = [NSString stringWithFormat:@"DELETE FROM %@ WHERE %@ IN (%@)",
                         self.tableName, self.idColumn, [marks componentsJoinedByString:@","]];
        if (![executor update:sql parameters:set.idsToDelete error:error]) return NO;
    }
    for (NSDictionary *item in set.rowsToWrite) {
        NSMutableArray *names = [NSMutableArray array];
        NSMutableArray *marks = [NSMutableArray array];
        NSMutableArray *values = [NSMutableArray array];
        void (^add)(NSString *, id) = ^(NSString *column, id value) {
            if (![columns containsObject:column]) return;
            [names addObject:column];
            [marks addObject:@"?"];
            [values addObject:value ?: NSNull.null];
        };
        add(self.idColumn, item[@"id"]);
        add(@"parentId", item[@"parentID"] ?: @"");
        add(@"title", item[@"title"]);
        add(@"url", item[@"url"]);
        add(@"iconUrl", item[@"iconURL"] ?: @"");
        add(@"fileType", item[@"fileType"] ?: @0);
        add(@"ppOrder", item[@"order"] ?: @0);
        NSString *now = [NSString stringWithFormat:@"%.0f", NSDate.date.timeIntervalSince1970];
        add(@"updateTime", now);
        add(@"ctime", now);
        NSString *sql = [NSString stringWithFormat:@"INSERT OR REPLACE INTO %@ (%@) VALUES (%@)",
                         self.tableName, [names componentsJoinedByString:@","],
                         [marks componentsJoinedByString:@","]];
        if (![executor update:sql parameters:values error:error]) return NO;
    }
    return YES;
}

- (NSData *)commitStaged:(id)staged error:(NSError **)error {
    FDMBackupSQLStagedSet *set = staged;
    if (![set isKindOfClass:FDMBackupSQLStagedSet.class]) { if (error) *error = FDMRepoError(@"暂存集无效"); return nil; }
    __block NSError *failure = nil;
    BOOL ok = [self.database inTransaction:^BOOL(id<FDMBackupSQLExecutor> executor) {
        return [self writeStagedSet:set onExecutor:executor error:&failure];
    } error:&failure];
    if (!ok) { if (error) *error = failure ?: FDMRepoError(@"书签写入失败"); return nil; }
    return set.afterSnapshot;
}

- (id)stageRestoreSnapshot:(NSData *)snapshot error:(NSError **)error {
    // A recorded before snapshot is internal, but it is still validated so a corrupted journal cannot
    // write arbitrary rows.
    id validated = [self validateImportPayload:snapshot error:error];
    if (!validated) return nil;
    NSArray *live = [self readRowsWithError:error];
    if (!live) return nil;
    NSMutableArray *toDelete = [NSMutableArray array];
    NSMutableSet *kept = [NSMutableSet set];
    for (NSDictionary *item in validated) [kept addObject:item[@"id"]];
    for (NSDictionary *row in live) {
        NSString *identifier = FDMRepoStringOrEmpty(row[self.idColumn]);
        if (identifier.length && ![kept containsObject:identifier]) [toDelete addObject:identifier];
    }
    FDMBackupSQLStagedSet *set = [[FDMBackupSQLStagedSet alloc] init];
    set.beforeSnapshot = [self exportSnapshotWithRevision:NULL error:NULL] ?: [NSData data];
    set.afterSnapshot = snapshot;
    set.rowsToWrite = validated;
    set.idsToDelete = toDelete;
    return set;
}

- (NSData *)recoverySnapshotWithError:(NSError **)error {
    return FDMRecoverySQLSnapshot(self.database, self.tableName, self.columns, error);
}
- (BOOL)restoreRecoverySnapshot:(NSData *)snapshot error:(NSError **)error {
    return FDMRecoverySQLRestore(self.database, snapshot, self.tableName, self.columns, error);
}
- (BOOL)rollbackStaged:(id)staged error:(NSError **)error {
    FDMBackupSQLStagedSet *set = staged;
    if (![set isKindOfClass:FDMBackupSQLStagedSet.class]) { if (error) *error = FDMRepoError(@"暂存集无效"); return NO; }
    id restore = [self stageRestoreSnapshot:set.beforeSnapshot error:error];
    if (!restore) return NO;
    return [self commitStaged:restore error:error] != nil;
}

- (void)reloadHostCache {
    // The host keeps an in-memory bookmark list; refresh it once, after the transaction committed.
    Class common = NSClassFromString(@"CommonDataManager");
    SEL shared = NSSelectorFromString(@"shareInstance");
    SEL reload = NSSelectorFromString(@"reloadBookMarks");
    if (common && [common respondsToSelector:shared]) {
        id manager = ((id (*)(id, SEL))objc_msgSend)((id)common, shared);
        if (manager && [manager respondsToSelector:reload]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(manager, reload); }
            @catch (NSException *exception) { FDMLog(@"bookmark cache reload skipped: %@", exception.reason); }
        }
    }
}

- (BOOL)verifyCommittedStateWithError:(NSError **)error {
    NSArray *live = [self readRowsWithError:error];
    if (!live) return NO;
    // Every restored row must have its identity and, unless it is a folder, a URL.
    for (NSDictionary *row in live) {
        NSString *identifier = FDMRepoStringOrEmpty(row[self.idColumn]);
        if (!identifier.length) { if (error) *error = FDMRepoError(@"存在没有标识的书签行"); return NO; }
        NSString *url = FDMRepoStringOrEmpty(row[@"url"]);
        NSNumber *fileType = [row[@"fileType"] isKindOfClass:NSNumber.class] ? row[@"fileType"] : @0;
        if (!url.length && fileType.integerValue == 0) {
            if (error) *error = FDMRepoError([NSString stringWithFormat:@"书签缺少地址：%@", identifier]);
            return NO;
        }
    }
    return YES;
}
@end

#pragma mark - home tags

// Home shortcuts share the same database object but keep their own table and validation rules.
@interface FDMBackupHomeTagRepository ()
@property (nonatomic, strong) id<FDMBackupSQLDatabase> database;
@end

@implementation FDMBackupHomeTagRepository

- (instancetype)initWithDatabase:(id<FDMBackupSQLDatabase>)database {
    if ((self = [super init])) _database = database;
    return self;
}

- (NSString *)categoryIdentifier { return FDMBackupCategoryHomeTags; }

- (BOOL)isAvailable { return self.database != nil; }

- (NSString *)storageDomain { return @"host.sqlite3"; }

- (NSString *)tableName { return @"t_hometags"; }
- (NSString *)idColumn { return @"uuid"; }
- (NSArray<NSString *> *)columns { return @[@"uuid", @"title", @"targetUrl", @"iconUrl", @"type", @"ppOrder", @"updateTime", @"ctime"]; }

- (NSArray<NSDictionary *> *)readRowsWithError:(NSError **)error {
    __block NSArray *rows = nil;
    __block NSError *failure = nil;
    [self.database inDatabase:^(id<FDMBackupSQLExecutor> executor) {
        NSSet *columns = nil;
        if (!FDMBackupTableColumns(executor, self.tableName, &columns, &failure)) return;
        NSMutableArray *selected = [NSMutableArray array];
        for (NSString *column in self.columns) if ([columns containsObject:column]) [selected addObject:column];
        NSString *sql = [NSString stringWithFormat:@"SELECT %@ FROM %@ ORDER BY %@",
                         [selected componentsJoinedByString:@","], self.tableName, self.idColumn];
        rows = [executor query:sql parameters:nil error:&failure];
    }];
    if (failure) { if (error) *error = failure; return nil; }
    return rows ?: @[];
}

- (NSData *)exportSnapshotWithRevision:(NSString **)revision error:(NSError **)error {
    NSArray *rows = [self readRowsWithError:error];
    if (!rows) return nil;
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:rows.count];
    for (NSDictionary *row in rows) {
        NSString *identifier = FDMRepoStringOrEmpty(row[@"uuid"]);
        if (!identifier.length) continue;
        NSMutableDictionary *item = [@{@"id": identifier,
                                       @"title": FDMRepoStringOrEmpty(row[@"title"]),
                                       @"url": FDMRepoStringOrEmpty(row[@"targetUrl"]),
                                       @"iconURL": FDMRepoStringOrEmpty(row[@"iconUrl"])} mutableCopy];
        if ([row[@"type"] isKindOfClass:NSNumber.class]) item[@"fileType"] = row[@"type"];
        if ([row[@"ppOrder"] isKindOfClass:NSNumber.class]) item[@"order"] = row[@"ppOrder"];
        [items addObject:item];
    }
    NSData *payload = FDMJSONCanonicalData(@{@"schemaVersion": @1, @"items": items}, error);
    if (payload && revision) *revision = FDMBackupSHA256(payload);
    return payload;
}

- (NSString *)currentRevisionWithError:(NSError **)error {
    NSString *revision = nil;
    if (![self exportSnapshotWithRevision:&revision error:error]) return nil;
    return revision;
}

- (id)validateImportPayload:(NSData *)payload error:(NSError **)error {
    id root = FDMJSONParseData(payload, error);
    NSDictionary *document = FDMJSONObjectValue(root);
    if (!document) { if (error) *error = FDMRepoError(@"快捷项数据必须是对象"); return nil; }
    for (NSString *key in document) {
        if (![@[@"schemaVersion", @"items"] containsObject:key]) { if (error) *error = FDMRepoError(@"快捷项数据含未知字段"); return nil; }
    }
    unsigned long long schema = 0;
    if (!FDMJSONNonNegativeInteger(document[@"schemaVersion"], 100, &schema) || schema != 1) {
        if (error) *error = FDMRepoError(@"快捷项数据版本不受支持");
        return nil;
    }
    // Shortcut items are always leaves: no folders, no hierarchy, url required.
    return FDMValidateBookmarkItems(FDMJSONArrayValue(document[@"items"]), NO, 500, error);
}

- (NSDictionary<NSString *, NSNumber *> *)previewCountsForValidated:(id)validated error:(NSError **)error {
    NSArray *live = [self readRowsWithError:error];
    if (!live) return nil;
    NSMutableDictionary *byID = [NSMutableDictionary dictionary];
    for (NSDictionary *row in live) {
        NSString *identifier = FDMRepoStringOrEmpty(row[@"uuid"]);
        if (identifier.length) byID[identifier] = row;
    }
    NSUInteger added = 0, identical = 0, conflict = 0, unsupported = 0;
    for (NSDictionary *item in validated) {
        NSDictionary *existing = byID[item[@"id"]];
        if (!existing) { added++; continue; }
        // A reserved built-in row cannot be restored by this category; report it, do not pretend.
        if (FDMBackupHomeTagTypeIsReserved(existing[@"type"])) { unsupported++; continue; }
        BOOL same = [FDMRepoStringOrEmpty(existing[@"title"]) isEqual:item[@"title"]] &&
                    [FDMRepoStringOrEmpty(existing[@"targetUrl"]) isEqual:item[@"url"]] &&
                    [FDMRepoStringOrEmpty(existing[@"iconUrl"]) isEqual:item[@"iconURL"]];
        if (same) identical++; else conflict++;
    }
    return @{FDMBackupCountAdded: @(added), FDMBackupCountIdentical: @(identical),
             FDMBackupCountConflict: @(conflict), FDMBackupCountDowngraded: @0,
             FDMBackupCountDisabled: @0, FDMBackupCountUnsupported: @(unsupported)};
}

// The host runs `DELETE FROM t_hometags WHERE type=2`, so type=2 is a built-in/reserved row that the
// application recreates itself. A restore must never delete or overwrite those rows, and a portable
// file must not be able to claim ownership of them.
static BOOL FDMBackupHomeTagTypeIsReserved(NSNumber *type) {
    return [type isKindOfClass:NSNumber.class] && type.integerValue == 2;
}

- (id)stageMergeValidated:(id)validated replace:(BOOL)replace error:(NSError **)error {
    NSArray *live = [self readRowsWithError:error];
    if (!live) return nil;
    NSData *before = [self exportSnapshotWithRevision:NULL error:error];
    if (!before) return nil;
    NSMutableSet *liveIDs = [NSMutableSet set];
    NSMutableSet *reservedIDs = [NSMutableSet set];
    for (NSDictionary *row in live) {
        NSString *identifier = FDMRepoStringOrEmpty(row[@"uuid"]);
        if (!identifier.length) continue;
        [liveIDs addObject:identifier];
        if (FDMBackupHomeTagTypeIsReserved(row[@"type"])) [reservedIDs addObject:identifier];
    }
    NSMutableArray *toWrite = [NSMutableArray array];
    for (NSDictionary *item in validated) {
        // A reserved built-in row is never replaced, even when the backup carries the same ID.
        if ([reservedIDs containsObject:item[@"id"]]) continue;
        if (!replace && [liveIDs containsObject:item[@"id"]]) continue;  // keep local
        [toWrite addObject:item];
    }
    NSMutableArray *toDelete = [NSMutableArray array];
    if (replace) {
        NSMutableSet *imported = [NSMutableSet set];
        for (NSDictionary *item in validated) [imported addObject:item[@"id"]];
        for (NSString *identifier in liveIDs) {
            if ([imported containsObject:identifier]) continue;
            // Built-in rows survive a replace: the host would recreate them anyway, and deleting them
            // is not something a backup file should be able to request.
            if ([reservedIDs containsObject:identifier]) continue;
            [toDelete addObject:identifier];
        }
    }
    FDMBackupSQLStagedSet *set = [[FDMBackupSQLStagedSet alloc] init];
    set.beforeSnapshot = before;
    set.rowsToWrite = toWrite;
    set.idsToDelete = toDelete;
    NSMutableDictionary *afterByID = [NSMutableDictionary dictionary];
    id beforeRoot = FDMJSONParseData(before, NULL);
    for (NSDictionary *item in FDMJSONArrayValue(FDMJSONObjectValue(beforeRoot)[@"items"])) afterByID[item[@"id"]] = item;
    for (NSString *identifier in toDelete) [afterByID removeObjectForKey:identifier];
    for (NSDictionary *item in toWrite) afterByID[item[@"id"]] = item;
    NSData *after = FDMBackupSortedItemsPayload(afterByID, error);
    if (!after) return nil;
    set.afterSnapshot = after;
    return set;
}

- (BOOL)applyStaged:(id)staged onExecutor:(id<FDMBackupSQLExecutor>)executor error:(NSError **)error {
    FDMBackupSQLStagedSet *set = staged;
    if (![set isKindOfClass:FDMBackupSQLStagedSet.class]) { if (error) *error = FDMRepoError(@"暂存集无效"); return NO; }
    return [self writeStagedSet:set onExecutor:executor error:error];
}

- (BOOL)writeStagedSet:(FDMBackupSQLStagedSet *)set
            onExecutor:(id<FDMBackupSQLExecutor>)executor
                 error:(NSError **)error {
    NSSet *columns = nil;
    if (!FDMBackupTableColumns(executor, self.tableName, &columns, error)) return NO;
    if (set.idsToDelete.count) {
        NSMutableArray *marks = [NSMutableArray array];
        for (NSUInteger i = 0; i < set.idsToDelete.count; i++) [marks addObject:@"?"];
        NSString *sql = [NSString stringWithFormat:@"DELETE FROM %@ WHERE %@ IN (%@)",
                         self.tableName, self.idColumn, [marks componentsJoinedByString:@","]];
        if (![executor update:sql parameters:set.idsToDelete error:error]) return NO;
    }
    for (NSDictionary *item in set.rowsToWrite) {
        NSMutableArray *names = [NSMutableArray array];
        NSMutableArray *marks = [NSMutableArray array];
        NSMutableArray *values = [NSMutableArray array];
        void (^add)(NSString *, id) = ^(NSString *column, id value) {
            if (![columns containsObject:column]) return;
            [names addObject:column];
            [marks addObject:@"?"];
            [values addObject:value ?: NSNull.null];
        };
        add(self.idColumn, item[@"id"]);
        add(@"title", item[@"title"]);
        add(@"targetUrl", item[@"url"]);
        add(@"iconUrl", item[@"iconURL"] ?: @"");
        add(@"type", item[@"fileType"] ?: @0);
        add(@"ppOrder", item[@"order"] ?: @0);
        NSString *now = [NSString stringWithFormat:@"%.0f", NSDate.date.timeIntervalSince1970];
        add(@"updateTime", now);
        add(@"ctime", now);
        NSString *sql = [NSString stringWithFormat:@"INSERT OR REPLACE INTO %@ (%@) VALUES (%@)",
                         self.tableName, [names componentsJoinedByString:@","],
                         [marks componentsJoinedByString:@","]];
        if (![executor update:sql parameters:values error:error]) return NO;
    }
    return YES;
}

- (NSData *)commitStaged:(id)staged error:(NSError **)error {
    FDMBackupSQLStagedSet *set = staged;
    if (![set isKindOfClass:FDMBackupSQLStagedSet.class]) { if (error) *error = FDMRepoError(@"暂存集无效"); return nil; }
    __block NSError *failure = nil;
    BOOL ok = [self.database inTransaction:^BOOL(id<FDMBackupSQLExecutor> executor) {
        return [self writeStagedSet:set onExecutor:executor error:&failure];
    } error:&failure];
    if (!ok) { if (error) *error = failure ?: FDMRepoError(@"快捷项写入失败"); return nil; }
    return set.afterSnapshot;
}

- (id)stageRestoreSnapshot:(NSData *)snapshot error:(NSError **)error {
    id validated = [self validateImportPayload:snapshot error:error];
    if (!validated) return nil;
    NSArray *live = [self readRowsWithError:error];
    if (!live) return nil;
    NSMutableSet *kept = [NSMutableSet set];
    for (NSDictionary *item in validated) [kept addObject:item[@"id"]];
    NSMutableArray *toDelete = [NSMutableArray array];
    for (NSDictionary *row in live) {
        NSString *identifier = FDMRepoStringOrEmpty(row[@"uuid"]);
        if (identifier.length && ![kept containsObject:identifier]) [toDelete addObject:identifier];
    }
    FDMBackupSQLStagedSet *set = [[FDMBackupSQLStagedSet alloc] init];
    set.beforeSnapshot = [self exportSnapshotWithRevision:NULL error:NULL] ?: [NSData data];
    set.afterSnapshot = snapshot;
    set.rowsToWrite = validated;
    set.idsToDelete = toDelete;
    return set;
}

- (NSData *)recoverySnapshotWithError:(NSError **)error {
    return FDMRecoverySQLSnapshot(self.database, self.tableName, self.columns, error);
}
- (BOOL)restoreRecoverySnapshot:(NSData *)snapshot error:(NSError **)error {
    return FDMRecoverySQLRestore(self.database, snapshot, self.tableName, self.columns, error);
}
- (BOOL)rollbackStaged:(id)staged error:(NSError **)error {
    FDMBackupSQLStagedSet *set = staged;
    if (![set isKindOfClass:FDMBackupSQLStagedSet.class]) { if (error) *error = FDMRepoError(@"暂存集无效"); return NO; }
    id restore = [self stageRestoreSnapshot:set.beforeSnapshot error:error];
    if (!restore) return NO;
    return [self commitStaged:restore error:error] != nil;
}

- (void)reloadHostCache {
    Class common = NSClassFromString(@"CommonDataManager");
    SEL shared = NSSelectorFromString(@"shareInstance");
    SEL reload = NSSelectorFromString(@"reloadCustomTagModels");
    if (common && [common respondsToSelector:shared]) {
        id manager = ((id (*)(id, SEL))objc_msgSend)((id)common, shared);
        if (manager && [manager respondsToSelector:reload]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(manager, reload); }
            @catch (NSException *exception) { FDMLog(@"hometag cache reload skipped: %@", exception.reason); }
        }
    }
}

- (BOOL)verifyCommittedStateWithError:(NSError **)error {
    NSArray *live = [self readRowsWithError:error];
    if (!live) return NO;
    for (NSDictionary *row in live) {
        NSString *identifier = FDMRepoStringOrEmpty(row[@"uuid"]);
        if (!identifier.length) { if (error) *error = FDMRepoError(@"存在没有标识的快捷项行"); return NO; }
        NSString *url = FDMRepoStringOrEmpty(row[@"targetUrl"]);
        if (!url.length) {
            if (error) *error = FDMRepoError([NSString stringWithFormat:@"快捷项缺少地址：%@", identifier]);
            return NO;
        }
    }
    return YES;
}
@end
