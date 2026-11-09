#import "FDMBackupRepositoryImpl.h"
#import "FDMBackupSQL.h"
#import "FDMJSON.h"

// Fixed facts of this host build, confirmed from the binary:
//   SearchListManager init: [[NSUserDefaults alloc] initWithSuiteName:@"com.focus.searchlist"]
//   SearchListManager saveSearchEngines: -> setObject:forKey:@"saved_search_list_data"
//   SearchListManager getAllSearchEngines -> arrayForKey:@"saved_search_list_data"
static NSString *const FDMBackupSearchSuiteName = @"com.focus.searchlist";
static NSString *const FDMBackupSearchKey = @"saved_search_list_data";

// PreferenceManager encode: archivedDataWithRootObject:items -> standardUserDefaults
//   key "key_preferencemanager_commonconfig". The wallpaper blob is a binary asset and is excluded.
static NSString *const FDMBackupPreferenceCommonKey = @"key_preferencemanager_commonconfig";

static NSError *FDMRepoError(NSString *message) {
    return [NSError errorWithDomain:@"FocusDM.Backup.Repository" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

#pragma mark - staged set for key/value storage

@interface FDMBackupBlobStagedSet : NSObject <FDMBackupStagedSet>
@property (nonatomic, copy) NSData *beforeSnapshot;
@property (nonatomic, copy) NSData *afterSnapshot;
@property (nonatomic, copy) NSArray<NSDictionary *> *beforeBlob;
@property (nonatomic, copy) NSArray<NSDictionary *> *afterBlob;
@end

@implementation FDMBackupBlobStagedSet
@end

#pragma mark - search repository

@implementation FDMBackupSearchRepository {
    NSUserDefaults *_defaults;
}

- (instancetype)initWithUserDefaults:(NSUserDefaults *)defaults {
    if ((self = [super init])) _defaults = defaults;
    return self;
}

+ (NSUserDefaults *)hostSearchDefaults {
    return [[NSUserDefaults alloc] initWithSuiteName:FDMBackupSearchSuiteName];
}

- (NSString *)categoryIdentifier { return FDMBackupCategorySearch; }

- (BOOL)isAvailable { return _defaults != nil; }

// Search config is its own NSUserDefaults suite, so it does not share the SQLite transaction.
- (NSString *)storageDomain { return nil; }

// NSUserDefaults has no SQL executor; the coordinator calls commitStaged: for this repository.
- (BOOL)applyStaged:(id)staged onExecutor:(id<FDMBackupSQLExecutor>)executor error:(NSError **)error {
    if (error) *error = FDMRepoError(@"搜索配置不通过 SQL 事务提交");
    return NO;
}

// The stored value is an array of dictionaries produced by SearchModel.toDictionary. Only the fields
// the host actually round-trips are kept; unknown keys are refused so a foreign file cannot inject
// arbitrary defaults into the host model.
- (NSArray<NSDictionary *> *)rawEngines {
    id value = [_defaults arrayForKey:FDMBackupSearchKey];
    return [value isKindOfClass:NSArray.class] ? value : @[];
}

- (NSData *)exportSnapshotWithRevision:(NSString **)revision error:(NSError **)error {
    if (!_defaults) { if (error) *error = FDMRepoError(@"搜索配置不可用"); return nil; }
    NSMutableArray *engines = [NSMutableArray array];
    for (id raw in [self rawEngines]) {
        NSDictionary *row = FDMJSONObjectValue(raw);
        if (!row) continue;
        NSString *title = FDMJSONStringValue(row[@"title"]);
        NSString *url = FDMJSONStringValue(row[@"searchUrl"]);
        if (!title.length || !url.length) continue;
        NSMutableDictionary *engine = [@{@"title": title, @"searchUrl": url} mutableCopy];
        NSString *identifier = FDMJSONStringValue(row[@"uuid"]);
        if (identifier.length) engine[@"id"] = identifier;
        NSString *suggest = FDMJSONStringValue(row[@"suggestUrl"]);
        if (suggest.length) engine[@"suggestUrl"] = suggest;
        for (NSString *key in @[@"type", @"position"]) {
            if ([row[key] isKindOfClass:NSNumber.class]) engine[key] = row[key];
        }
        // isSelected is host state, not user configuration; it is exported so a restore can report
        // it, but a restore never changes which engine is currently selected.
        id selected = row[@"isSelected"];
        if ([selected isKindOfClass:NSNumber.class]) engine[@"selected"] = selected;
        [engines addObject:engine];
    }
    NSData *payload = FDMJSONCanonicalData(@{@"schemaVersion": @1, @"engines": engines}, error);
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
    if (!document) { if (error) *error = FDMRepoError(@"搜索配置必须是对象"); return nil; }
    for (NSString *key in document) {
        if (![@[@"schemaVersion", @"engines"] containsObject:key]) { if (error) *error = FDMRepoError(@"搜索配置含未知字段"); return nil; }
    }
    unsigned long long schema = 0;
    if (!FDMJSONNonNegativeInteger(document[@"schemaVersion"], 100, &schema) || schema != 1) {
        if (error) *error = FDMRepoError(@"搜索配置版本不受支持");
        return nil;
    }
    NSArray *engines = FDMJSONArrayValue(document[@"engines"]);
    if (!engines || engines.count > 100) { if (error) *error = FDMRepoError(@"搜索引擎数量无效"); return nil; }
    NSMutableArray *validated = [NSMutableArray array];
    NSMutableSet *urls = [NSMutableSet set];
    for (id raw in engines) {
        NSDictionary *row = FDMJSONObjectValue(raw);
        if (!row) { if (error) *error = FDMRepoError(@"搜索引擎条目无效"); return nil; }
        for (NSString *key in row) {
            if (![@[@"id", @"title", @"searchUrl", @"suggestUrl", @"type", @"position", @"selected"] containsObject:key]) {
                if (error) *error = FDMRepoError(@"搜索引擎条目含未知字段");
                return nil;
            }
        }
        NSString *title = FDMJSONStringValue(row[@"title"]);
        NSString *url = FDMJSONStringValue(row[@"searchUrl"]);
        if (!title.length || [title lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > FDMBackupMaxNameBytes) {
            if (error) *error = FDMRepoError(@"搜索引擎名称无效");
            return nil;
        }
        if (!url.length || [url lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > FDMBackupMaxURLBytes) {
            if (error) *error = FDMRepoError(@"搜索引擎地址无效");
            return nil;
        }
        // A search URL is a template with %@, so origin normalization does not apply; require https/http.
        NSString *lower = url.lowercaseString;
        if (!([lower hasPrefix:@"https://"] || [lower hasPrefix:@"http://"])) {
            if (error) *error = FDMRepoError(@"搜索引擎地址必须是 http/https 模板");
            return nil;
        }
        // Two engines with the same template are indistinguishable after restore.
        if ([urls containsObject:url]) { if (error) *error = FDMRepoError([NSString stringWithFormat:@"搜索引擎地址重复：%@", url]); return nil; }
        [urls addObject:url];
        NSMutableDictionary *engine = [@{@"title": title, @"searchUrl": url} mutableCopy];
        NSString *identifier = FDMJSONStringValue(row[@"id"]);
        if (identifier.length) engine[@"id"] = identifier;
        NSString *suggest = FDMJSONStringValue(row[@"suggestUrl"]);
        if (suggest.length) {
            if ([suggest lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > FDMBackupMaxURLBytes) {
                if (error) *error = FDMRepoError(@"搜索建议地址过长");
                return nil;
            }
            engine[@"suggestUrl"] = suggest;
        }
        for (NSString *key in @[@"type", @"position"]) {
            unsigned long long number = 0;
            if (row[key]) {
                if (!FDMJSONNonNegativeInteger(row[key], 1000000, &number)) { if (error) *error = FDMRepoError(@"搜索引擎数值字段无效"); return nil; }
                engine[key] = @(number);
            }
        }
        if ([row[@"selected"] isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)row[@"selected"]) != CFBooleanGetTypeID()) {
            if (error) *error = FDMRepoError(@"selected 必须是布尔值");
            return nil;
        }
        if (row[@"selected"]) engine[@"selected"] = @([row[@"selected"] boolValue]);
        [validated addObject:engine];
    }
    return validated;
}

- (NSDictionary<NSString *, NSNumber *> *)previewCountsForValidated:(id)validated error:(NSError **)error {
    NSMutableDictionary *liveByURL = [NSMutableDictionary dictionary];
    for (id raw in [self rawEngines]) {
        NSDictionary *row = FDMJSONObjectValue(raw);
        NSString *url = FDMJSONStringValue(row[@"searchUrl"]);
        if (url.length) liveByURL[url] = row;
    }
    NSUInteger added = 0, identical = 0, conflict = 0;
    for (NSDictionary *engine in validated) {
        NSDictionary *existing = liveByURL[engine[@"searchUrl"]];
        if (!existing) { added++; continue; }
        BOOL same = [FDMJSONStringValue(existing[@"title"]) isEqual:engine[@"title"]];
        if (same) identical++; else conflict++;
    }
    return @{FDMBackupCountAdded: @(added), FDMBackupCountIdentical: @(identical),
             FDMBackupCountConflict: @(conflict), FDMBackupCountDowngraded: @0,
             FDMBackupCountDisabled: @0, FDMBackupCountUnsupported: @0};
}

- (id)stageMergeValidated:(id)validated replace:(BOOL)replace error:(NSError **)error {
    if (!_defaults) { if (error) *error = FDMRepoError(@"搜索配置不可用"); return nil; }
    NSData *before = [self exportSnapshotWithRevision:NULL error:error];
    if (!before) return nil;
    NSMutableArray *merged = [NSMutableArray array];
    NSMutableDictionary *liveByURL = [NSMutableDictionary dictionary];
    NSMutableArray *liveOrder = [NSMutableArray array];
    for (id raw in [self rawEngines]) {
        NSDictionary *row = FDMJSONObjectValue(raw);
        if (!row) continue;
        NSString *url = FDMJSONStringValue(row[@"searchUrl"]);
        if (url.length) liveByURL[url] = row;
        [liveOrder addObject:row];
    }
    NSMutableSet *importedURLs = [NSMutableSet set];
    for (NSDictionary *engine in validated) [importedURLs addObject:engine[@"searchUrl"]];

    if (replace) {
        // Replace only the engines the backup carries; the selected engine stays selected if it
        // still exists, otherwise the host keeps its own default.
        for (NSDictionary *engine in validated) {
            NSMutableDictionary *copy = [engine mutableCopy];
            [copy removeObjectForKey:@"selected"];
            [merged addObject:copy];
        }
    } else {
        // keep-local: preserve every live engine in its order, then append engines that are new.
        for (NSDictionary *row in liveOrder) {
            NSMutableDictionary *copy = [row mutableCopy];
            [copy removeObjectForKey:@"selected"];
            [merged addObject:copy];
        }
        for (NSDictionary *engine in validated) {
            if (liveByURL[engine[@"searchUrl"]]) continue;
            NSMutableDictionary *copy = [engine mutableCopy];
            [copy removeObjectForKey:@"selected"];
            [merged addObject:copy];
        }
    }
    // Keep the current selection by URL so a restore never silently changes the user's default.
    NSString *selectedURL = nil;
    for (NSDictionary *row in liveOrder) {
        if ([row[@"isSelected"] boolValue]) { selectedURL = FDMJSONStringValue(row[@"searchUrl"]); break; }
    }
    BOOL selectionPresent = NO;
    for (NSMutableDictionary *row in merged) if ([row[@"searchUrl"] isEqual:selectedURL]) selectionPresent = YES;
    if (selectedURL.length && selectionPresent) {
        for (NSMutableDictionary *row in merged) row[@"isSelected"] = @([row[@"searchUrl"] isEqual:selectedURL]);
    }

    FDMBackupBlobStagedSet *staged = [[FDMBackupBlobStagedSet alloc] init];
    staged.beforeSnapshot = before;
    staged.beforeBlob = [_defaults arrayForKey:FDMBackupSearchKey];
    staged.afterBlob = merged;
    NSMutableArray *afterItems = [NSMutableArray array];
    for (NSDictionary *row in merged) {
        NSMutableDictionary *copy = [row mutableCopy];
        [copy removeObjectForKey:@"isSelected"];
        [afterItems addObject:copy];
    }
    NSData *after = FDMJSONCanonicalData(@{@"schemaVersion": @1, @"engines": afterItems}, error);
    if (!after) return nil;
    staged.afterSnapshot = after;
    return staged;
}

- (NSData *)commitStaged:(id)staged error:(NSError **)error {
    FDMBackupBlobStagedSet *set = staged;
    if (![set isKindOfClass:FDMBackupBlobStagedSet.class]) { if (error) *error = FDMRepoError(@"暂存集无效"); return nil; }
    if (!_defaults) { if (error) *error = FDMRepoError(@"搜索配置不可用"); return nil; }
    [_defaults setObject:set.afterBlob forKey:FDMBackupSearchKey];
    if (![_defaults synchronize]) { if (error) *error = FDMRepoError(@"搜索配置写入未确认"); return nil; }
    // Verify by reading the value back: synchronize's return is not a durability proof.
    NSArray *readBack = [_defaults arrayForKey:FDMBackupSearchKey];
    if (![readBack isKindOfClass:NSArray.class] || readBack.count != [set.afterBlob count]) {
        if (error) *error = FDMRepoError(@"搜索配置读回校验失败");
        return nil;
    }
    return set.afterSnapshot;
}

- (id)stageRestoreSnapshot:(NSData *)snapshot error:(NSError **)error {
    id validated = [self validateImportPayload:snapshot error:error];
    if (!validated) return nil;
    FDMBackupBlobStagedSet *set = [[FDMBackupBlobStagedSet alloc] init];
    set.beforeSnapshot = [self exportSnapshotWithRevision:NULL error:NULL] ?: [NSData data];
    set.beforeBlob = [_defaults arrayForKey:FDMBackupSearchKey];
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *engine in validated) {
        NSMutableDictionary *copy = [engine mutableCopy];
        [copy removeObjectForKey:@"selected"];
        [rows addObject:copy];
    }
    set.afterBlob = rows;
    set.afterSnapshot = snapshot;
    return set;
}

- (BOOL)rollbackStaged:(id)staged error:(NSError **)error {
    FDMBackupBlobStagedSet *set = staged;
    if (![set isKindOfClass:FDMBackupBlobStagedSet.class]) { if (error) *error = FDMRepoError(@"暂存集无效"); return NO; }
    if (!_defaults) { if (error) *error = FDMRepoError(@"搜索配置不可用"); return NO; }
    if (set.beforeBlob) [_defaults setObject:set.beforeBlob forKey:FDMBackupSearchKey];
    else [_defaults removeObjectForKey:FDMBackupSearchKey];
    [_defaults synchronize];
    NSArray *readBack = [_defaults arrayForKey:FDMBackupSearchKey];
    NSUInteger expected = set.beforeBlob ? [set.beforeBlob count] : 0;
    if ((readBack ? readBack.count : 0) != expected) {
        if (error) *error = FDMRepoError(@"搜索配置回滚读回校验失败");
        return NO;
    }
    return YES;
}

- (void)reloadHostCache {
    Class manager = NSClassFromString(@"SearchListManager");
    SEL shared = NSSelectorFromString(@"sharedInstance");
    SEL reload = NSSelectorFromString(@"getAllSearchEngines");
    if (manager && [manager respondsToSelector:shared]) {
        id instance = ((id (*)(id, SEL))objc_msgSend)((id)manager, shared);
        if (instance && [instance respondsToSelector:reload]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(instance, reload); }
            @catch (NSException *exception) { FDMLog(@"search cache reload skipped: %@", exception.reason); }
        }
    }
}

- (BOOL)verifyCommittedStateWithError:(NSError **)error {
    // The stored array must still parse into engines the host model can consume.
    NSArray *stored = [_defaults arrayForKey:FDMBackupSearchKey];
    if (![stored isKindOfClass:NSArray.class]) { if (error) *error = FDMRepoError(@"搜索配置读回不是数组"); return NO; }
    for (id raw in stored) {
        NSDictionary *row = FDMJSONObjectValue(raw);
        if (!row) { if (error) *error = FDMRepoError(@"搜索配置读回条目不是对象"); return NO; }
        NSString *url = FDMJSONStringValue(row[@"searchUrl"]);
        NSString *title = FDMJSONStringValue(row[@"title"]);
        if (!url.length || !title.length) { if (error) *error = FDMRepoError(@"搜索配置读回条目缺少名称或地址"); return NO; }
    }
    return YES;
}
@end
