#import "FDMBackupRepositoryImpl.h"
#import "FDMBackupSQL.h"
#import "FDMJSON.h"
#import "FDMBackupRecovery.h"
#import "FDMBackupReadBarrier.h"

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

// The host stores SearchModel dictionaries whose identity field is `uuid` and selection flag is
// `isSelected`. The portable DTO uses `id` and `selected`, so every write path must translate both
// or the host will read engines with no identity and no selection.
static NSDictionary *FDMBackupSearchHostRow(NSDictionary *portable) {
    NSMutableDictionary *row = [NSMutableDictionary dictionary];
    NSString *identifier = portable[@"id"];
    if (identifier.length) row[@"uuid"] = identifier;
    row[@"title"] = portable[@"title"] ?: @"";
    row[@"searchUrl"] = portable[@"searchUrl"] ?: @"";
    if (portable[@"suggestUrl"]) row[@"suggestUrl"] = portable[@"suggestUrl"];
    if (portable[@"type"]) row[@"type"] = portable[@"type"];
    if (portable[@"position"]) row[@"position"] = portable[@"position"];
    if (portable[@"selected"]) row[@"isSelected"] = @([portable[@"selected"] boolValue]);
    return row;
}

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
        if ([selected isKindOfClass:NSNumber.class]) engine[@"selected"] = @([selected boolValue]);
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
    NSMutableSet *identifiers = [NSMutableSet set];
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
        if (!identifier.length || identifier.length > 128 || [identifiers containsObject:identifier]) { if (error) *error = FDMRepoError(@"搜索引擎稳定标识缺失或重复"); return nil; }
        [identifiers addObject:identifier]; engine[@"id"] = identifier;
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
        if (row[@"selected"] && (![row[@"selected"] isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)row[@"selected"]) != CFBooleanGetTypeID())) {
            if (error) *error = FDMRepoError(@"selected 必须是布尔值");
            return nil;
        }
        if (row[@"selected"]) engine[@"selected"] = @([row[@"selected"] boolValue]);
        [validated addObject:engine];
    }
    return validated;
}

- (NSDictionary<NSString *, NSNumber *> *)previewCountsForValidated:(id)validated error:(NSError **)error {
    NSMutableDictionary *liveByID = [NSMutableDictionary dictionary];
    for (NSDictionary *row in [self rawEngines]) if ([row[@"uuid"] isKindOfClass:NSString.class]) liveByID[row[@"uuid"]] = row;
    NSUInteger added = 0, same = 0, conflict = 0;
    for (NSDictionary *incoming in validated) {
        NSDictionary *local = liveByID[incoming[@"id"]];
        if (!local) { added++; continue; }
        NSDictionary *converted = FDMBackupSearchHostRow(incoming);
        BOOL equal = YES;
        for (NSString *key in @[@"title", @"searchUrl", @"suggestUrl", @"type", @"position"])
            if ((local[key] || converted[key]) && ![local[key] isEqual:converted[key]]) { equal = NO; break; }
        if (equal) same++; else conflict++;
    }
    return @{FDMBackupCountAdded: @(added), FDMBackupCountIdentical: @(same), FDMBackupCountConflict: @(conflict),
        FDMBackupCountDisabled: @0, FDMBackupCountDowngraded: @0, FDMBackupCountUnsupported: @0};
}

- (id)stageMergeValidated:(id)validated replace:(BOOL)replace error:(NSError **)error {
    NSData *before = [self exportSnapshotWithRevision:NULL error:error]; if (!before) return nil;
    NSArray *raw = [self rawEngines];
    NSMutableArray *after = replace ? [NSMutableArray array] : [raw mutableCopy];
    NSMutableDictionary *known = [NSMutableDictionary dictionary];
    NSDictionary *selected = nil;
    for (NSDictionary *row in raw) {
        NSString *identifier = FDMJSONStringValue(row[@"uuid"]);
        if (identifier.length) known[identifier] = row;
        if ([row[@"isSelected"] boolValue]) selected = row;
    }
    for (NSDictionary *incoming in validated) {
        NSString *identifier = incoming[@"id"];
        NSDictionary *local = known[identifier];
        if (!replace && local) continue;
        NSMutableDictionary *row = [FDMBackupSearchHostRow(incoming) mutableCopy];
        if (!identifier.length) row[@"uuid"] = NSUUID.UUID.UUIDString;
        row[@"isSelected"] = @NO;
        [after addObject:row];
    }
    if (selected) {
        BOOL found = NO;
        for (NSUInteger i=0;i<after.count;i++) {
            NSMutableDictionary *row = [after[i] mutableCopy];
            BOOL same = [row[@"uuid"] isEqual:selected[@"uuid"]];
            if (same) { row[@"isSelected"] = @YES; found = YES; }
            after[i] = row;
        }
        // Replacement does not silently switch the user's default engine.
        if (!found) [after addObject:selected];
    } else if (replace) {
        for (NSDictionary *incoming in validated) if ([incoming[@"selected"] boolValue]) {
            for (NSMutableDictionary *row in after) if ([row[@"uuid"] isEqual:incoming[@"id"]]) row[@"isSelected"] = @YES;
        }
    }
    NSMutableArray *portable = [NSMutableArray array];
    for (NSDictionary *row in after) {
        NSMutableDictionary *item = [@{@"id": row[@"uuid"] ?: @"", @"title": row[@"title"] ?: @"",
            @"searchUrl": row[@"searchUrl"] ?: @""} mutableCopy];
        if (row[@"isSelected"]) item[@"selected"] = @([row[@"isSelected"] boolValue]);
        for (NSString *key in @[@"suggestUrl", @"type", @"position"]) if (row[key]) item[key] = row[key];
        [portable addObject:item];
    }
    FDMBackupBlobStagedSet *set = [FDMBackupBlobStagedSet new]; set.beforeSnapshot = before;
    set.beforeBlob = [_defaults arrayForKey:FDMBackupSearchKey]; set.afterBlob = [after copy];
    set.afterSnapshot = FDMJSONCanonicalData(@{@"schemaVersion": @1, @"engines": portable}, error);
    return set.afterSnapshot ? set : nil;
}
- (NSData *)commitStaged:(id)staged error:(NSError **)error {
    FDMBackupBlobStagedSet *set = staged;
    if (![set isKindOfClass:FDMBackupBlobStagedSet.class]) { if (error) *error = FDMRepoError(@"搜索暂存集无效"); return nil; }
    [_defaults setObject:set.afterBlob forKey:FDMBackupSearchKey]; [_defaults synchronize];
    if (![[_defaults arrayForKey:FDMBackupSearchKey] isEqual:set.afterBlob]) { if (error) *error = FDMRepoError(@"搜索配置读回不一致"); return nil; }
    return set.afterSnapshot;
}
- (id)stageRestoreSnapshot:(NSData *)snapshot error:(NSError **)error {
    NSArray *validated = [self validateImportPayload:snapshot error:error]; if (!validated) return nil;
    FDMBackupBlobStagedSet *set = [FDMBackupBlobStagedSet new];
    set.beforeSnapshot = [self exportSnapshotWithRevision:NULL error:error]; set.beforeBlob = [_defaults arrayForKey:FDMBackupSearchKey];
    NSMutableArray *rows = [NSMutableArray array]; for (NSDictionary *engine in validated) [rows addObject:FDMBackupSearchHostRow(engine)];
    set.afterBlob = rows; set.afterSnapshot = snapshot; return set;
}
- (BOOL)rollbackStaged:(id)staged error:(NSError **)error {
    FDMBackupBlobStagedSet *set = staged;
    if (set.beforeBlob) [_defaults setObject:set.beforeBlob forKey:FDMBackupSearchKey]; else [_defaults removeObjectForKey:FDMBackupSearchKey];
    [_defaults synchronize];
    return set.beforeBlob ? [[_defaults arrayForKey:FDMBackupSearchKey] isEqual:set.beforeBlob] : [_defaults objectForKey:FDMBackupSearchKey] == nil;
}
- (void)preparePublicationBarrier { FDMBackupProtectDefaults(_defaults, @"com.focus.searchlist", @"saved_search_list_data"); }
- (NSData *)recoverySnapshotWithError:(NSError **)error {
    id raw = [_defaults objectForKey:FDMBackupSearchKey];
    if (raw && ![raw isKindOfClass:NSArray.class]) { if (error) *error = FDMRepoError(@"原搜索配置格式未知"); return nil; }
    return FDMJSONCanonicalData(@{@"recoverySchema": @1, @"raw": raw ?: NSNull.null}, error);
}
- (BOOL)restoreRecoverySnapshot:(NSData *)snapshot error:(NSError **)error {
    NSDictionary *root = FDMJSONObjectValue(FDMJSONParseData(snapshot, error));
    if (![root[@"recoverySchema"] isEqual:@1] || (!FDMJSONArrayValue(root[@"raw"]) && root[@"raw"] != NSNull.null)) return NO;
    if (root[@"raw"] == NSNull.null) [_defaults removeObjectForKey:FDMBackupSearchKey]; else [_defaults setObject:root[@"raw"] forKey:FDMBackupSearchKey];
    [_defaults synchronize];
    return root[@"raw"] == NSNull.null ? [_defaults objectForKey:FDMBackupSearchKey] == nil : [[_defaults objectForKey:FDMBackupSearchKey] isEqual:root[@"raw"]];
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
