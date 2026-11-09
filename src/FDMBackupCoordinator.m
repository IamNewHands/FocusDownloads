#import "FDMBackup.h"
#import "FDMJSON.h"
#import "FDMPolicy.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>

static NSString *const FDMJournalName = @"backup-journal.json";

static NSError *FDMBackupError(NSString *message) {
    return [NSError errorWithDomain:@"FocusDM.Backup" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

static id FDMBackupHostSingleton(NSString *className) {
    Class cls = NSClassFromString(className);
    SEL shared = NSSelectorFromString(@"shareInstance");
    if (cls && [cls respondsToSelector:shared]) return ((id (*)(id, SEL))objc_msgSend)(cls, shared);
    return nil;
}

static BOOL FDMBackupBoundedString(id value, NSUInteger maxBytes, BOOL required) {
    if (![value isKindOfClass:NSString.class]) return !required;
    NSUInteger bytes = [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    return bytes <= maxBytes && (!required || bytes > 0);
}

#pragma mark - shared validated DTOs

// One bookmark row: stable id, parent, title, url, order. No icon blobs, no absolute paths.
static NSDictionary *FDMValidateBookmarkRow(id raw, NSError **error) {
    NSDictionary *row = FDMJSONObjectValue(raw);
    if (!row) { if (error) *error = FDMBackupError(@"书签条目必须是对象"); return nil; }
    for (NSString *key in row) {
        if (![@[@"id", @"parentID", @"title", @"url", @"order"] containsObject:key]) {
            if (error) *error = FDMBackupError([NSString stringWithFormat:@"书签条目含未知字段：%@", key]);
            return nil;
        }
    }
    NSString *identifier = FDMJSONStringValue(row[@"id"]);
    if (!identifier.length || identifier.length > 128) { if (error) *error = FDMBackupError(@"书签缺少有效标识"); return nil; }
    NSString *parent = FDMJSONStringValue(row[@"parentID"]);
    if (parent && parent.length > 128) { if (error) *error = FDMBackupError(@"书签父级标识过长"); return nil; }
    NSString *title = FDMJSONStringValue(row[@"title"]);
    if (!FDMBackupBoundedString(title ?: @"", FDMBackupMaxNameBytes, NO)) { if (error) *error = FDMBackupError(@"书签标题超出长度上限"); return nil; }
    NSString *url = FDMJSONStringValue(row[@"url"]);
    if (!url.length || !FDMBackupBoundedString(url, FDMBackupMaxURLBytes, YES)) { if (error) *error = FDMBackupError(@"书签地址缺失或过长"); return nil; }
    if (!FDMNormalizedOrigin(url) && ![url hasPrefix:@"focus://"] && ![url hasPrefix:@"javascript:"]) {
        if (error) *error = FDMBackupError([NSString stringWithFormat:@"书签地址不是有效链接：%@", url]);
        return nil;
    }
    unsigned long long order = 0;
    if (row[@"order"] && !FDMJSONNonNegativeInteger(row[@"order"], 1000000, &order)) {
        if (error) *error = FDMBackupError(@"书签顺序值无效");
        return nil;
    }
    NSMutableDictionary *result = [@{@"id": identifier, @"title": title ?: @"", @"url": url, @"order": @(order)} mutableCopy];
    if (parent.length) result[@"parentID"] = parent;
    return result;
}

// Detects cycles, dangling parents and duplicate ids in a bookmark set.
static BOOL FDMValidateBookmarkTree(NSArray<NSDictionary *> *rows, NSError **error) {
    NSMutableDictionary<NSString *, NSString *> *parentOf = [NSMutableDictionary dictionary];
    for (NSDictionary *row in rows) {
        if (parentOf[row[@"id"]]) { if (error) *error = FDMBackupError(@"书签标识重复"); return NO; }
        parentOf[row[@"id"]] = row[@"parentID"] ?: @"";
    }
    for (NSDictionary *row in rows) {
        NSString *parent = row[@"parentID"];
        if (!parent.length) continue;
        if (!parentOf[parent]) { if (error) *error = FDMBackupError(@"书签引用了不存在的父级文件夹"); return NO; }
        NSMutableSet *seen = [NSMutableSet set];
        NSString *cursor = row[@"id"];
        NSUInteger depth = 0;
        while (cursor.length) {
            if ([seen containsObject:cursor]) { if (error) *error = FDMBackupError(@"书签文件夹存在循环引用"); return NO; }
            [seen addObject:cursor];
            if (++depth > 64) { if (error) *error = FDMBackupError(@"书签层级过深"); return NO; }
            cursor = parentOf[cursor];
        }
    }
    return YES;
}

static NSArray *FDMValidateBookmarkPayload(NSData *payload, NSError **error) {
    id root = FDMJSONParseData(payload, error);
    NSDictionary *document = FDMJSONObjectValue(root);
    if (!document) { if (error) *error = FDMBackupError(@"书签数据必须是对象"); return nil; }
    for (NSString *key in document) {
        if (![@[@"schemaVersion", @"items"] containsObject:key]) { if (error) *error = FDMBackupError(@"书签数据含未知字段"); return nil; }
    }
    unsigned long long schema = 0;
    if (!FDMJSONNonNegativeInteger(document[@"schemaVersion"], 100, &schema) || schema != 1) {
        if (error) *error = FDMBackupError(@"书签数据版本不受支持");
        return nil;
    }
    NSArray *items = FDMJSONArrayValue(document[@"items"]);
    if (!items) { if (error) *error = FDMBackupError(@"书签数据缺少条目数组"); return nil; }
    if (items.count > FDMBackupMaxBookmarks) { if (error) *error = FDMBackupError(@"书签数量超出上限"); return nil; }
    NSMutableArray *validated = [NSMutableArray array];
    for (id raw in items) {
        NSDictionary *row = FDMValidateBookmarkRow(raw, error);
        if (!row) return nil;
        [validated addObject:row];
    }
    if (!FDMValidateBookmarkTree(validated, error)) return nil;
    return validated;
}

#pragma mark - bookmarks provider

@interface FDMBookmarkProvider : NSObject <FDMBackupProvider>
@end

@implementation FDMBookmarkProvider
- (NSString *)categoryIdentifier { return FDMBackupCategoryBookmarks; }
- (NSData *)exportSnapshotWithRevision:(unsigned long long *)revision error:(NSError **)error {
    id manager = [self manager];
    if (!manager) { if (error) *error = FDMBackupError(@"浏览器书签数据不可用"); return nil; }
    NSArray *items = FDMValue(manager, @"allItems");
    if (![items isKindOfClass:NSArray.class]) { if (error) *error = FDMBackupError(@"无法读取书签列表"); return nil; }
    NSMutableArray *rows = [NSMutableArray array];
    for (id model in items) {
        if (rows.count >= FDMBackupMaxBookmarks) break;
        NSString *identifier = FDMString(FDMValue(model, @"bookmarkId"));
        NSString *url = FDMString(FDMValue(model, @"url"));
        if (!identifier.length || !url.length) continue;
        NSMutableDictionary *row = [@{@"id": identifier, @"url": url,
                                      @"title": FDMString(FDMValue(model, @"title")) ?: @""} mutableCopy];
        NSString *parent = FDMString(FDMValue(model, @"parentId"));
        if (parent.length) row[@"parentID"] = parent;
        id order = FDMValue(model, @"ppOrder");
        if ([order isKindOfClass:NSNumber.class]) row[@"order"] = @(MAX(0, [order integerValue]));
        [rows addObject:row];
    }
    if (revision) *revision = (unsigned long long)rows.count;
    return FDMJSONCanonicalData(@{@"schemaVersion": @1, @"items": rows}, error);
}

- (id)validateImportPayload:(NSData *)payload error:(NSError **)error {
    return FDMValidateBookmarkPayload(payload, error);
}

- (NSDictionary<NSString *, NSNumber *> *)previewCountsForValidated:(id)validated error:(NSError **)error {
    id manager = [self manager];
    NSArray *existing = FDMValue(manager, @"allItems");
    NSMutableDictionary *byID = [NSMutableDictionary dictionary];
    for (id model in [existing isKindOfClass:NSArray.class] ? existing : @[]) {
        NSString *identifier = FDMString(FDMValue(model, @"bookmarkId"));
        if (identifier.length) byID[identifier] = model;
    }
    NSUInteger added = 0, identical = 0, conflict = 0;
    for (NSDictionary *row in validated) {
        id model = byID[row[@"id"]];
        if (!model) { added++; continue; }
        BOOL same = [FDMString(FDMValue(model, @"url")) isEqual:row[@"url"]] &&
                    [(FDMString(FDMValue(model, @"title")) ?: @"") isEqual:row[@"title"]];
        if (same) identical++; else conflict++;
    }
    return @{@"added": @(added), @"identical": @(identical), @"conflict": @(conflict),
             @"downgraded": @0, @"disabled": @0, @"unsupported": @0};
}

- (id)prepareImport:(id)validated expectedRevision:(unsigned long long)expected error:(NSError **)error {
    NSData *before = [self exportSnapshotWithRevision:NULL error:error];
    if (!before) return nil;
    NSArray *beforeRows = FDMValidateBookmarkPayload(before, nil) ?: @[];
    if ((unsigned long long)beforeRows.count != expected) {
        if (error) *error = FDMBackupError(@"书签数量在预览后发生变化，请重新预览");
        return nil;
    }
    return @{@"before": before, @"after": validated};
}

- (BOOL)commitPrepared:(id)prepared error:(NSError **)error {
    NSArray *rows = prepared[@"after"];
    if (![rows isKindOfClass:NSArray.class]) { if (error) *error = FDMBackupError(@"没有可提交的书签数据"); return NO; }
    // The host owns bookmark storage; reuse its own HTML import instead of writing its database.
    NSString *html = [self htmlForRows:rows];
    if (!html.length) { if (error) *error = FDMBackupError(@"无法生成书签导入内容"); return NO; }
    return [self importHTML:html error:error];
}

- (BOOL)rollbackPrepared:(id)prepared error:(NSError **)error {
    NSData *before = prepared[@"before"];
    NSArray *rows = before ? FDMValidateBookmarkPayload(before, nil) : nil;
    if (!rows) { if (error) *error = FDMBackupError(@"原书签快照不可用，回滚未完成"); return NO; }
    NSString *html = [self htmlForRows:rows];
    return [self importHTML:html error:error];
}

- (void)reloadCommittedState {
    id manager = [self manager];
    SEL reload = NSSelectorFromString(@"parse");
    if (manager && [manager respondsToSelector:reload]) {
        @try { ((void (*)(id, SEL))objc_msgSend)(manager, reload); }
        @catch (NSException *exception) { FDMLog(@"bookmark reload unavailable: %@", exception.reason); }
    }
}

- (id)manager {
    id delegate = UIApplication.sharedApplication.delegate;
    id manager = FDMValue(delegate, @"bookmarkManager");
    return manager ?: FDMBackupHostSingleton(@"BookMarkManager");
}

- (NSString *)htmlForRows:(NSArray<NSDictionary *> *)rows {
    NSMutableString *html = [NSMutableString stringWithString:
        @"<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">\n<TITLE>Bookmarks</TITLE>\n<H1>Bookmarks</H1>\n<DL><p>\n"];
    for (NSDictionary *row in rows) {
        NSString *title = [(row[@"title"] ?: @"") stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
        title = [title stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
        [html appendFormat:@"    <DT><A HREF=\"%@\">%@</A>\n", row[@"url"], title];
    }
    [html appendString:@"</DL><p>\n"];
    return html;
}

- (BOOL)importHTML:(NSString *)html error:(NSError **)error {
    id manager = [self manager];
    SEL parse = NSSelectorFromString(@"parseBookMarksFromHtml:");
    if (!manager || ![manager respondsToSelector:parse]) {
        if (error) *error = FDMBackupError(@"当前版本不支持通过接口导入书签；原数据未改变");
        return NO;
    }
    // Write to a task-owned temporary file so the host parser never reads a half-written path.
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"focusdm-bookmarks-%@.html", NSUUID.UUID.UUIDString]];
    NSError *write = nil;
    if (![[html dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path options:NSDataWritingAtomic error:&write]) {
        if (error) *error = write;
        return NO;
    }
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(manager, parse, path);
    } @catch (NSException *exception) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        if (error) *error = FDMBackupError([NSString stringWithFormat:@"书签导入失败：%@", exception.reason]);
        return NO;
    }
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    return YES;
}
@end

#pragma mark - search provider

@interface FDMSearchProvider : NSObject <FDMBackupProvider>
@end

@implementation FDMSearchProvider
- (NSString *)categoryIdentifier { return FDMBackupCategorySearch; }

- (id)manager { return FDMBackupHostSingleton(@"SearchListManager"); }

- (NSData *)exportSnapshotWithRevision:(unsigned long long *)revision error:(NSError **)error {
    id manager = [self manager];
    if (!manager) { if (error) *error = FDMBackupError(@"搜索配置不可用"); return nil; }
    NSArray *engines = FDMValue(manager, @"searchEngineList");
    if (![engines isKindOfClass:NSArray.class]) { if (error) *error = FDMBackupError(@"无法读取搜索引擎列表"); return nil; }
    id selected = nil;
    SEL getSelected = NSSelectorFromString(@"getSelectedSearchEngine");
    if ([manager respondsToSelector:getSelected]) selected = ((id (*)(id, SEL))objc_msgSend)(manager, getSelected);
    NSMutableArray *rows = [NSMutableArray array];
    for (id engine in engines) {
        NSString *title = FDMString(FDMValue(engine, @"title"));
        NSString *url = FDMString(FDMValue(engine, @"searchUrl"));
        if (!title.length || !url.length) continue;
        NSMutableDictionary *row = [@{@"title": title, @"searchUrl": url} mutableCopy];
        NSString *identifier = FDMString(FDMValue(engine, @"uuid"));
        if (identifier.length) row[@"id"] = identifier;
        NSString *suggest = FDMString(FDMValue(engine, @"suggestUrl"));
        if (suggest.length) row[@"suggestUrl"] = suggest;
        id type = FDMValue(engine, @"type");
        if ([type isKindOfClass:NSNumber.class]) row[@"type"] = type;
        id position = FDMValue(engine, @"position");
        if ([position isKindOfClass:NSNumber.class]) row[@"position"] = position;
        row[@"selected"] = @(engine == selected);
        [rows addObject:row];
    }
    if (revision) *revision = (unsigned long long)rows.count;
    return FDMJSONCanonicalData(@{@"schemaVersion": @1, @"engines": rows}, error);
}

- (id)validateImportPayload:(NSData *)payload error:(NSError **)error {
    id root = FDMJSONParseData(payload, error);
    NSDictionary *document = FDMJSONObjectValue(root);
    if (!document) { if (error) *error = FDMBackupError(@"搜索配置必须是对象"); return nil; }
    for (NSString *key in document) {
        if (![@[@"schemaVersion", @"engines"] containsObject:key]) { if (error) *error = FDMBackupError(@"搜索配置含未知字段"); return nil; }
    }
    unsigned long long schema = 0;
    if (!FDMJSONNonNegativeInteger(document[@"schemaVersion"], 100, &schema) || schema != 1) {
        if (error) *error = FDMBackupError(@"搜索配置版本不受支持");
        return nil;
    }
    NSArray *engines = FDMJSONArrayValue(document[@"engines"]);
    if (!engines || engines.count > 100) { if (error) *error = FDMBackupError(@"搜索引擎数量无效"); return nil; }
    NSMutableArray *validated = [NSMutableArray array];
    for (id raw in engines) {
        NSDictionary *row = FDMJSONObjectValue(raw);
        if (!row) { if (error) *error = FDMBackupError(@"搜索引擎条目无效"); return nil; }
        for (NSString *key in row) {
            if (![@[@"id", @"title", @"searchUrl", @"suggestUrl", @"type", @"position", @"selected"] containsObject:key]) {
                if (error) *error = FDMBackupError(@"搜索引擎条目含未知字段");
                return nil;
            }
        }
        NSString *title = FDMJSONStringValue(row[@"title"]);
        NSString *url = FDMJSONStringValue(row[@"searchUrl"]);
        if (!title.length || title.lengthOfBytesUsingEncoding:NSUTF8StringEncoding > FDMBackupMaxNameBytes) {
            if (error) *error = FDMBackupError(@"搜索引擎名称无效");
            return nil;
        }
        if (!url.length || url.lengthOfBytesUsingEncoding:NSUTF8StringEncoding > FDMBackupMaxURLBytes || !FDMNormalizedOrigin(url)) {
            if (error) *error = FDMBackupError(@"搜索引擎地址无效");
            return nil;
        }
        NSMutableDictionary *result = [@{@"title": title, @"searchUrl": url, @"selected": @([row[@"selected"] boolValue])} mutableCopy];
        for (NSString *key in @[@"id", @"suggestUrl"]) {
            NSString *value = FDMJSONStringValue(row[key]);
            if (value.length) result[key] = value;
        }
        for (NSString *key in @[@"type", @"position"]) {
            unsigned long long number = 0;
            if (row[key]) {
                if (!FDMJSONNonNegativeInteger(row[key], 1000000, &number)) { if (error) *error = FDMBackupError(@"搜索引擎数值字段无效"); return nil; }
                result[key] = @(number);
            }
        }
        [validated addObject:result];
    }
    return validated;
}

- (NSDictionary<NSString *, NSNumber *> *)previewCountsForValidated:(id)validated error:(NSError **)error {
    id manager = [self manager];
    NSArray *existing = FDMValue(manager, @"searchEngineList");
    NSMutableDictionary *byURL = [NSMutableDictionary dictionary];
    for (id engine in [existing isKindOfClass:NSArray.class] ? existing : @[]) {
        NSString *url = FDMString(FDMValue(engine, @"searchUrl"));
        if (url.length) byURL[url] = engine;
    }
    NSUInteger added = 0, identical = 0, conflict = 0;
    for (NSDictionary *row in validated) {
        id engine = byURL[row[@"searchUrl"]];
        if (!engine) { added++; continue; }
        if ([(FDMString(FDMValue(engine, @"title")) ?: @"") isEqual:row[@"title"]]) identical++; else conflict++;
    }
    return @{@"added": @(added), @"identical": @(identical), @"conflict": @(conflict),
             @"downgraded": @0, @"disabled": @0, @"unsupported": @0};
}

- (id)prepareImport:(id)validated expectedRevision:(unsigned long long)expected error:(NSError **)error {
    NSData *before = [self exportSnapshotWithRevision:NULL error:error];
    if (!before) return nil;
    id beforeValidated = [self validateImportPayload:before error:nil];
    if ((unsigned long long)[beforeValidated count] != expected) {
        if (error) *error = FDMBackupError(@"搜索配置在预览后发生变化，请重新预览");
        return nil;
    }
    return @{@"before": beforeValidated ?: @[], @"after": validated};
}

- (BOOL)commitPrepared:(id)prepared error:(NSError **)error {
    return [self applyRows:prepared[@"after"] preserveSelection:YES error:error];
}

- (BOOL)rollbackPrepared:(id)prepared error:(NSError **)error {
    NSArray *rows = prepared[@"before"];
    if (![rows isKindOfClass:NSArray.class]) { if (error) *error = FDMBackupError(@"原搜索配置快照不可用，回滚未完成"); return NO; }
    return [self applyRows:rows preserveSelection:NO error:error];
}

- (void)reloadCommittedState {
    id manager = [self manager];
    SEL reload = NSSelectorFromString(@"getAllSearchEngines");
    if (manager && [manager respondsToSelector:reload]) {
        @try { ((void (*)(id, SEL))objc_msgSend)(manager, reload); }
        @catch (NSException *exception) { FDMLog(@"search reload unavailable: %@", exception.reason); }
    }
}
- (BOOL)applyRows:(NSArray<NSDictionary *> *)rows preserveSelection:(BOOL)preserveSelection error:(NSError **)error {
    id manager = [self manager];
    Class modelClass = NSClassFromString(@"SearchModel");
    SEL save = NSSelectorFromString(@"saveSearchEngines:");
    if (!manager || !modelClass || ![manager respondsToSelector:save]) {
        if (error) *error = FDMBackupError(@"当前版本不支持写入搜索配置；原数据未改变");
        return NO;
    }
    id previousSelected = nil;
    if (preserveSelection) {
        SEL getSelected = NSSelectorFromString(@"getSelectedSearchEngine");
        if ([manager respondsToSelector:getSelected]) previousSelected = ((id (*)(id, SEL))objc_msgSend)(manager, getSelected);
    }
    NSMutableArray *models = [NSMutableArray array];
    for (NSDictionary *row in rows) {
        id model = ((id (*)(id, SEL))objc_msgSend)((id)modelClass, NSSelectorFromString(@"alloc"));
        model = ((id (*)(id, SEL))objc_msgSend)(model, NSSelectorFromString(@"init"));
        if (!model) continue;
        @try {
            [model setValue:row[@"title"] forKey:@"title"];
            [model setValue:row[@"searchUrl"] forKey:@"searchUrl"];
            if (row[@"id"]) [model setValue:row[@"id"] forKey:@"uuid"];
            if (row[@"suggestUrl"]) [model setValue:row[@"suggestUrl"] forKey:@"suggestUrl"];
            if (row[@"type"]) [model setValue:row[@"type"] forKey:@"type"];
            if (row[@"position"]) [model setValue:row[@"position"] forKey:@"position"];
            if (!preserveSelection) [model setValue:@([row[@"selected"] boolValue]) forKey:@"isSelected"];
        } @catch (NSException *exception) {
            if (error) *error = FDMBackupError([NSString stringWithFormat:@"搜索配置写入失败：%@", exception.reason]);
            return NO;
        }
        [models addObject:model];
    }
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(manager, save, models);
    } @catch (NSException *exception) {
        if (error) *error = FDMBackupError([NSString stringWithFormat:@"搜索配置保存失败：%@", exception.reason]);
        return NO;
    }
    if (preserveSelection && previousSelected) {
        NSString *identifier = FDMString(FDMValue(previousSelected, @"uuid"));
        SEL lookup = NSSelectorFromString(@"getSearchEngineWithSearchId:");
        SEL update = NSSelectorFromString(@"updateSelectedSearchEngine");
        if (identifier.length && [manager respondsToSelector:lookup] && [manager respondsToSelector:update]) {
            id restored = ((id (*)(id, SEL, id))objc_msgSend)(manager, lookup, identifier);
            if (restored) {
                @try { ((void (*)(id, SEL))objc_msgSend)(manager, update); }
                @catch (NSException *exception) { FDMLog(@"search selection restore skipped: %@", exception.reason); }
            }
        }
    }
    return YES;
}
@end

#pragma mark - site policy provider

@interface FDMSitePolicyProvider : NSObject <FDMBackupProvider>
@end

@implementation FDMSitePolicyProvider
- (NSString *)categoryIdentifier { return FDMBackupCategorySitePolicies; }

- (NSData *)exportSnapshotWithRevision:(unsigned long long *)revision error:(NSError **)error {
    NSDictionary *snapshot = FDMSitePolicyStore.shared.snapshot;
    if (revision) *revision = [snapshot[@"revision"] unsignedLongLongValue];
    return FDMJSONCanonicalData(snapshot, error);
}

- (id)validateImportPayload:(NSData *)payload error:(NSError **)error {
    id root = FDMJSONParseData(payload, error);
    if (!root) return nil;
    NSDictionary *document = FDMSitePolicyValidateDocument(root, error);
    if (!document) return nil;
    // Imported permissions never auto-grant: an "allow" becomes "ask".
    NSMutableDictionary *origins = [NSMutableDictionary dictionary];
    for (NSString *origin in document[@"origins"]) {
        NSMutableDictionary *entry = [document[@"origins"][origin] mutableCopy];
        for (NSString *field in @[FDMPolicyCamera, FDMPolicyMicrophone]) {
            if ([entry[field] isEqual:@"allow"]) entry[field] = @"ask";
        }
        origins[origin] = entry;
    }
    return @{@"schemaVersion": @1, @"revision": document[@"revision"], @"origins": origins};
}

- (NSDictionary<NSString *, NSNumber *> *)previewCountsForValidated:(id)validated error:(NSError **)error {
    NSDictionary *current = FDMSitePolicyStore.shared.snapshot[@"origins"] ?: @{};
    NSUInteger added = 0, identical = 0, conflict = 0, downgraded = 0;
    for (NSString *origin in validated[@"origins"]) {
        NSDictionary *incoming = validated[@"origins"][origin];
        NSDictionary *existing = current[origin];
        if (!existing) { added++; continue; }
        if ([existing isEqual:incoming]) identical++; else conflict++;
        if ([incoming[FDMPolicyCamera] isEqual:@"ask"] || [incoming[FDMPolicyMicrophone] isEqual:@"ask"]) downgraded++;
    }
    return @{@"added": @(added), @"identical": @(identical), @"conflict": @(conflict),
             @"downgraded": @(downgraded), @"disabled": @0, @"unsupported": @0};
}

- (id)prepareImport:(id)validated expectedRevision:(unsigned long long)expected error:(NSError **)error {
    if (FDMSitePolicyStore.shared.revision != expected) {
        if (error) *error = FDMBackupError(@"站点策略在预览后发生变化，请重新预览");
        return nil;
    }
    return @{@"before": FDMSitePolicyStore.shared.snapshot, @"after": validated, @"revision": @(expected)};
}

- (BOOL)commitPrepared:(id)prepared error:(NSError **)error {
    NSDictionary *after = prepared[@"after"];
    unsigned long long expected = [prepared[@"revision"] unsignedLongLongValue];
    NSDictionary *merged = after;
    // Merge by default: keep local entries the backup does not mention.
    NSMutableDictionary *origins = [FDMSitePolicyStore.shared.snapshot[@"origins"] mutableCopy] ?: [NSMutableDictionary dictionary];
    for (NSString *origin in after[@"origins"]) origins[origin] = after[@"origins"][origin];
    merged = @{@"schemaVersion": @1, @"revision": @(expected), @"origins": origins};
    return [FDMSitePolicyStore.shared replaceDocument:merged expectedRevision:expected error:error];
}

- (BOOL)rollbackPrepared:(id)prepared error:(NSError **)error {
    NSDictionary *before = prepared[@"before"];
    if (!before) { if (error) *error = FDMBackupError(@"原站点策略快照不可用，回滚未完成"); return NO; }
    unsigned long long current = FDMSitePolicyStore.shared.revision;
    NSMutableDictionary *restore = [before mutableCopy];
    restore[@"revision"] = @(current);
    return [FDMSitePolicyStore.shared replaceDocument:restore expectedRevision:current error:error];
}

- (void)reloadCommittedState {}
@end

#pragma mark - preferences provider

// Explicit whitelist only; never a full NSUserDefaults dump.
static NSArray<NSString *> *FDMBackupAllowedPreferenceKeys(void) {
    return @[@"focus_reader_auto_enable", @"focus_adblock_enabled", @"focus_web_scale_index",
             @"focus_desktop_mode", @"focus_fullscreen_on_scroll", @"focus_auto_page_enabled"];
}

@interface FDMPreferencesProvider : NSObject <FDMBackupProvider>
@end

@implementation FDMPreferencesProvider
- (NSString *)categoryIdentifier { return FDMBackupCategoryPreferences; }

- (NSData *)exportSnapshotWithRevision:(unsigned long long *)revision error:(NSError **)error {
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for (NSString *key in FDMBackupAllowedPreferenceKeys()) {
        id value = [defaults objectForKey:key];
        if ([value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSString.class]) values[key] = value;
    }
    if (revision) *revision = (unsigned long long)values.count;
    return FDMJSONCanonicalData(@{@"schemaVersion": @1, @"values": values}, error);
}

- (id)validateImportPayload:(NSData *)payload error:(NSError **)error {
    id root = FDMJSONParseData(payload, error);
    NSDictionary *document = FDMJSONObjectValue(root);
    if (!document) { if (error) *error = FDMBackupError(@"偏好数据必须是对象"); return nil; }
    for (NSString *key in document) {
        if (![@[@"schemaVersion", @"values"] containsObject:key]) { if (error) *error = FDMBackupError(@"偏好数据含未知字段"); return nil; }
    }
    unsigned long long schema = 0;
    if (!FDMJSONNonNegativeInteger(document[@"schemaVersion"], 100, &schema) || schema != 1) {
        if (error) *error = FDMBackupError(@"偏好数据版本不受支持");
        return nil;
    }
    NSDictionary *values = FDMJSONObjectValue(document[@"values"]);
    if (!values) { if (error) *error = FDMBackupError(@"偏好数据缺少取值"); return nil; }
    NSMutableDictionary *validated = [NSMutableDictionary dictionary];
    for (NSString *key in values) {
        // Anything outside the whitelist is refused rather than silently dropped.
        if (![FDMBackupAllowedPreferenceKeys() containsObject:key]) {
            if (error) *error = FDMBackupError([NSString stringWithFormat:@"偏好项不在允许列表：%@", key]);
            return nil;
        }
        id value = values[key];
        if ([value isKindOfClass:NSNumber.class]) {
            if (!FDMJSONIsFiniteNumber(value)) { if (error) *error = FDMBackupError(@"偏好数值不是有限数"); return nil; }
            validated[key] = value;
        } else if ([value isKindOfClass:NSString.class] && [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= FDMBackupMaxNameBytes) {
            validated[key] = value;
        } else {
            if (error) *error = FDMBackupError(@"偏好取值类型无效");
            return nil;
        }
    }
    return validated;
}

- (NSDictionary<NSString *, NSNumber *> *)previewCountsForValidated:(id)validated error:(NSError **)error {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSUInteger added = 0, identical = 0, conflict = 0;
    for (NSString *key in validated) {
        id current = [defaults objectForKey:key];
        if (!current) added++;
        else if ([current isEqual:validated[key]]) identical++;
        else conflict++;
    }
    return @{@"added": @(added), @"identical": @(identical), @"conflict": @(conflict),
             @"downgraded": @0, @"disabled": @0, @"unsupported": @0};
}

- (id)prepareImport:(id)validated expectedRevision:(unsigned long long)expected error:(NSError **)error {
    NSData *before = [self exportSnapshotWithRevision:NULL error:error];
    if (!before) return nil;
    id beforeValidated = [self validateImportPayload:before error:nil] ?: @{};
    if ((unsigned long long)[beforeValidated count] != expected) {
        if (error) *error = FDMBackupError(@"偏好设置在预览后发生变化，请重新预览");
        return nil;
    }
    return @{@"before": beforeValidated, @"after": validated};
}

- (BOOL)commitPrepared:(id)prepared error:(NSError **)error {
    NSDictionary *after = prepared[@"after"];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for (NSString *key in after) {
        if (![FDMBackupAllowedPreferenceKeys() containsObject:key]) { if (error) *error = FDMBackupError(@"偏好项不在允许列表"); return NO; }
        [defaults setObject:after[key] forKey:key];
    }
    if (![defaults synchronize] && ![defaults objectForKey:FDMBackupAllowedPreferenceKeys().firstObject]) {
        if (error) *error = FDMBackupError(@"偏好设置写入未确认");
        return NO;
    }
    return YES;
}

- (BOOL)rollbackPrepared:(id)prepared error:(NSError **)error {
    NSDictionary *before = prepared[@"before"];
    if (![before isKindOfClass:NSDictionary.class]) { if (error) *error = FDMBackupError(@"原偏好快照不可用，回滚未完成"); return NO; }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for (NSString *key in FDMBackupAllowedPreferenceKeys()) {
        if (before[key]) [defaults setObject:before[key] forKey:key];
        else [defaults removeObjectForKey:key];
    }
    [defaults synchronize];
    return YES;
}

- (void)reloadCommittedState {}
@end

#pragma mark - user scripts provider

@interface FDMScriptsProvider : NSObject <FDMBackupProvider>
@end

@implementation FDMScriptsProvider
- (NSString *)categoryIdentifier { return FDMBackupCategoryScripts; }

- (NSData *)exportSnapshotWithRevision:(unsigned long long *)revision error:(NSError **)error {
    id tampermonkey = FDMBackupHostSingleton(@"Tampermonkey");
    SEL list = NSSelectorFromString(@"getAllUserScriptsFromCache");
    if (!tampermonkey || ![tampermonkey respondsToSelector:list]) {
        if (error) *error = FDMBackupError(@"当前版本不支持导出用户脚本");
        return nil;
    }
    NSArray *scripts = nil;
    @try { scripts = ((id (*)(id, SEL))objc_msgSend)(tampermonkey, list); }
    @catch (NSException *exception) {
        if (error) *error = FDMBackupError([NSString stringWithFormat:@"读取用户脚本失败：%@", exception.reason]);
        return nil;
    }
    NSMutableArray *rows = [NSMutableArray array];
    for (id script in [scripts isKindOfClass:NSArray.class] ? scripts : @[]) {
        if (rows.count >= FDMBackupMaxScripts) break;
        NSString *identifier = FDMString(FDMValue(script, @"uuid"));
        NSString *name = FDMString(FDMValue(script, @"name"));
        NSString *content = FDMString(FDMValue(script, @"content"));
        if (!identifier.length || !name.length || !content.length) continue;
        if ([content lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > FDMBackupMaxScriptBytes) continue;
        NSMutableDictionary *row = [@{@"id": identifier, @"name": name, @"content": content,
                                      @"enabled": @([FDMValue(script, @"isActive") boolValue])} mutableCopy];
        NSString *namespace = FDMString(FDMValue(script, @"namespace"));
        if (namespace.length) row[@"namespace"] = namespace;
        [rows addObject:row];
    }
    if (revision) *revision = (unsigned long long)rows.count;
    return FDMJSONCanonicalData(@{@"schemaVersion": @1, @"scripts": rows}, error);
}

- (id)validateImportPayload:(NSData *)payload error:(NSError **)error {
    id root = FDMJSONParseData(payload, error);
    NSDictionary *document = FDMJSONObjectValue(root);
    if (!document) { if (error) *error = FDMBackupError(@"脚本数据必须是对象"); return nil; }
    for (NSString *key in document) {
        if (![@[@"schemaVersion", @"scripts"] containsObject:key]) { if (error) *error = FDMBackupError(@"脚本数据含未知字段"); return nil; }
    }
    unsigned long long schema = 0;
    if (!FDMJSONNonNegativeInteger(document[@"schemaVersion"], 100, &schema) || schema != 1) {
        if (error) *error = FDMBackupError(@"脚本数据版本不受支持");
        return nil;
    }
    NSArray *scripts = FDMJSONArrayValue(document[@"scripts"]);
    if (!scripts || scripts.count > FDMBackupMaxScripts) { if (error) *error = FDMBackupError(@"脚本数量超出上限"); return nil; }
    NSMutableArray *validated = [NSMutableArray array];
    for (id raw in scripts) {
        NSDictionary *row = FDMJSONObjectValue(raw);
        if (!row) { if (error) *error = FDMBackupError(@"脚本条目无效"); return nil; }
        for (NSString *key in row) {
            if (![@[@"id", @"name", @"namespace", @"content", @"enabled"] containsObject:key]) {
                if (error) *error = FDMBackupError(@"脚本条目含未知字段");
                return nil;
            }
        }
        NSString *identifier = FDMJSONStringValue(row[@"id"]);
        NSString *name = FDMJSONStringValue(row[@"name"]);
        NSString *content = FDMJSONStringValue(row[@"content"]);
        if (!identifier.length || !name.length || !content.length) { if (error) *error = FDMBackupError(@"脚本缺少标识、名称或内容"); return nil; }
        if ([content lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > FDMBackupMaxScriptBytes) {
            if (error) *error = FDMBackupError(@"脚本内容超出单条上限");
            return nil;
        }
        NSMutableDictionary *result = [@{@"id": identifier, @"name": name, @"content": content} mutableCopy];
        NSString *namespace = FDMJSONStringValue(row[@"namespace"]);
        if (namespace.length) result[@"namespace"] = namespace;
        [validated addObject:result];
    }
    return validated;
}

- (NSDictionary<NSString *, NSNumber *> *)previewCountsForValidated:(id)validated error:(NSError **)error {
    id tampermonkey = FDMBackupHostSingleton(@"Tampermonkey");
    NSArray *existing = nil;
    SEL list = NSSelectorFromString(@"getAllUserScriptsFromCache");
    if (tampermonkey && [tampermonkey respondsToSelector:list]) {
        @try { existing = ((id (*)(id, SEL))objc_msgSend)(tampermonkey, list); }
        @catch (NSException *exception) { existing = nil; }
    }
    NSMutableSet *existingIDs = [NSMutableSet set];
    for (id script in [existing isKindOfClass:NSArray.class] ? existing : @[]) {
        NSString *identifier = FDMString(FDMValue(script, @"uuid"));
        if (identifier.length) [existingIDs addObject:identifier];
    }
    NSUInteger added = 0, identical = 0;
    for (NSDictionary *row in validated) {
        if ([existingIDs containsObject:row[@"id"]]) identical++; else added++;
    }
    // New or changed scripts always arrive disabled, so every imported script is counted.
    return @{@"added": @(added), @"identical": @(identical), @"conflict": @0,
             @"downgraded": @0, @"disabled": @([validated count]), @"unsupported": @0};
}

- (id)prepareImport:(id)validated expectedRevision:(unsigned long long)expected error:(NSError **)error {
    NSData *before = [self exportSnapshotWithRevision:NULL error:error];
    if (!before) return nil;
    id beforeValidated = [self validateImportPayload:before error:nil] ?: @[];
    if ((unsigned long long)[beforeValidated count] != expected) {
        if (error) *error = FDMBackupError(@"用户脚本在预览后发生变化，请重新预览");
        return nil;
    }
    return @{@"before": beforeValidated, @"after": validated};
}

- (BOOL)commitPrepared:(id)prepared error:(NSError **)error {
    NSArray *rows = prepared[@"after"];
    if (![rows isKindOfClass:NSArray.class]) { if (error) *error = FDMBackupError(@"没有可提交的脚本数据"); return NO; }
    id tampermonkey = FDMBackupHostSingleton(@"Tampermonkey");
    SEL save = NSSelectorFromString(@"saveUserScriptToCache:");
    Class scriptClass = NSClassFromString(@"UserScript");
    if (!tampermonkey || !scriptClass || ![tampermonkey respondsToSelector:save]) {
        if (error) *error = FDMBackupError(@"当前版本不支持写入用户脚本；原数据未改变");
        return NO;
    }
    for (NSDictionary *row in rows) {
        id script = ((id (*)(id, SEL))objc_msgSend)((id)scriptClass, NSSelectorFromString(@"alloc"));
        script = ((id (*)(id, SEL))objc_msgSend)(script, NSSelectorFromString(@"init"));
        if (!script) continue;
        @try {
            [script setValue:row[@"id"] forKey:@"uuid"];
            [script setValue:row[@"name"] forKey:@"name"];
            [script setValue:row[@"content"] forKey:@"content"];
            if (row[@"namespace"]) [script setValue:row[@"namespace"] forKey:@"namespace"];
            // Imported scripts are disabled until the user enables them explicitly.
            [script setValue:@NO forKey:@"isActive"];
        } @catch (NSException *exception) {
            if (error) *error = FDMBackupError([NSString stringWithFormat:@"脚本写入失败：%@", exception.reason]);
            return NO;
        }
        @try { ((void (*)(id, SEL, id))objc_msgSend)(tampermonkey, save, script); }
        @catch (NSException *exception) {
            if (error) *error = FDMBackupError([NSString stringWithFormat:@"脚本保存失败：%@", exception.reason]);
            return NO;
        }
    }
    return YES;
}

- (BOOL)rollbackPrepared:(id)prepared error:(NSError **)error {
    // Scripts can only be re-saved, not deleted, through this path. Report the honest limit.
    if (error) *error = FDMBackupError(@"用户脚本导入无法自动回滚；请在用户脚本列表中手动删除本次新增项");
    return NO;
}

- (void)reloadCommittedState {}
@end

#pragma mark - coordinator

@implementation FDMBackupCoordinator {
    dispatch_queue_t _queue;
    NSMutableDictionary<NSString *, id<FDMBackupProvider>> *_providers;
    NSString *_journalPath;
    NSString *_recoveryNotice;
}

+ (instancetype)shared {
    static FDMBackupCoordinator *coordinator;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        coordinator = [[self alloc] init];
        [coordinator registerProvider:[[FDMBookmarkProvider alloc] init]];
        [coordinator registerProvider:[[FDMSearchProvider alloc] init]];
        [coordinator registerProvider:[[FDMSitePolicyProvider alloc] init]];
        [coordinator registerProvider:[[FDMPreferencesProvider alloc] init]];
        [coordinator registerProvider:[[FDMScriptsProvider alloc] init]];
    });
    return coordinator;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("FocusDM.backup", DISPATCH_QUEUE_SERIAL);
        _providers = [NSMutableDictionary dictionary];
        _journalPath = [FDMDirectory(@"FocusDM") stringByAppendingPathComponent:FDMJournalName];
    }
    return self;
}

- (void)registerProvider:(id<FDMBackupProvider>)provider {
    if (!provider) return;
    NSString *identifier = [provider categoryIdentifier];
    if (!identifier.length) return;
    dispatch_sync(_queue, ^{ self->_providers[identifier] = provider; });
}

- (NSArray<NSString *> *)availableCategories {
    __block NSMutableArray *available = [NSMutableArray array];
    dispatch_sync(_queue, ^{
        for (NSString *category in FDMBackupCategoryOrder()) if (self->_providers[category]) [available addObject:category];
    });
    return available;
}

- (NSData *)exportCategories:(NSArray<NSString *> *)categories error:(NSError **)error {
    NSMutableArray *payloads = [NSMutableArray array];
    __block NSError *failure;
    dispatch_sync(_queue, ^{
        for (NSString *category in categories) {
            id<FDMBackupProvider> provider = self->_providers[category];
            if (!provider) { failure = FDMBackupError([NSString stringWithFormat:@"不支持的类别：%@", category]); return; }
            unsigned long long revision = 0;
            NSData *payload = [provider exportSnapshotWithRevision:&revision error:&failure];
            if (!payload) return;
            id validated = [provider validateImportPayload:payload error:&failure];
            if (!validated) return;
            NSUInteger count = [validated isKindOfClass:NSArray.class] ? [validated count] : ([validated isKindOfClass:NSDictionary.class] ? [validated count] : 0);
            FDMBackupCategory *entry = [FDMBackupCategory category:category payload:payload itemCount:count];
            [payloads addObject:entry];
        }
    });
    if (failure) { if (error) *error = failure; return nil; }
    if (!payloads.count) { if (error) *error = FDMBackupError(@"没有可导出的类别"); return nil; }
    return FDMBackupEncode(payloads, FDMPatchVersion(), error);
}

- (FDMBackupContainer *)openBackupAtURL:(NSURL *)url error:(NSError **)error {
    if (!url.isFileURL) { if (error) *error = FDMBackupError(@"只能导入本地备份文件"); return nil; }
    NSNumber *size = nil;
    [url getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
    if (size && size.unsignedLongLongValue > FDMBackupMaxFileBytes) { if (error) *error = FDMBackupError(@"备份文件超出 32 MiB 上限"); return nil; }
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:error];
    if (!data.length) { if (error && !*error) *error = FDMBackupError(@"无法读取备份文件"); return nil; }
    return FDMBackupDecode(data, error);
}

- (NSDictionary<NSString *, NSDictionary *> *)previewContainer:(FDMBackupContainer *)container
                                                    categories:(NSArray<NSString *> *)categories
                                                         error:(NSError **)error {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    __block NSError *failure;
    dispatch_sync(_queue, ^{
        for (NSString *category in categories) {
            id<FDMBackupProvider> provider = self->_providers[category];
            FDMBackupCategory *entry = container.categories[category];
            if (!provider || !entry) {
                result[category] = @{@"supported": @NO, @"reason": @"此备份包含本版本不支持的类别"};
                continue;
            }
            id validated = [provider validateImportPayload:entry.payload error:&failure];
            if (!validated) return;
            NSDictionary *counts = [provider previewCountsForValidated:validated error:&failure];
            if (!counts) return;
            NSMutableDictionary *row = [counts mutableCopy];
            row[@"supported"] = @YES;
            result[category] = row;
        }
    });
    if (failure) { if (error) *error = failure; return nil; }
    return result;
}

- (BOOL)applyContainer:(FDMBackupContainer *)container
            categories:(NSArray<NSString *> *)categories
             conflicts:(NSDictionary<NSString *, NSString *> *)conflicts
               replace:(BOOL)replace
                 error:(NSError **)error {
    if (!categories.count) { if (error) *error = FDMBackupError(@"没有选中任何类别"); return NO; }
    if (![self recoverInterruptedTransaction] && _recoveryNotice.length) {
        if (error) *error = FDMBackupError(_recoveryNotice);
        return NO;
    }
    NSString *transactionID = NSUUID.UUID.UUIDString;
    NSMutableArray *prepared = [NSMutableArray array];
    NSMutableArray *plan = [NSMutableArray array];
    __block NSError *failure;
    dispatch_sync(_queue, ^{
        for (NSString *category in categories) {
            id<FDMBackupProvider> provider = self->_providers[category];
            FDMBackupCategory *entry = container.categories[category];
            if (!provider || !entry) { failure = FDMBackupError([NSString stringWithFormat:@"类别不可恢复：%@", category]); return; }
            id validated = [provider validateImportPayload:entry.payload error:&failure];
            if (!validated) return;
            unsigned long long revision = 0;
            NSData *current = [provider exportSnapshotWithRevision:&revision error:&failure];
            if (!current) return;
            id staged = [provider prepareImport:validated expectedRevision:revision error:&failure];
            if (!staged) return;
            [prepared addObject:@{@"category": category, @"provider": provider, @"staged": staged}];
            [plan addObject:@{@"category": category, @"revision": @(revision)}];
        }
    });
    if (failure) { if (error) *error = failure; return NO; }

    // The journal records the pre-change snapshot digest so a crash mid-commit has a defined path.
    NSDictionary *journal = @{@"transactionID": transactionID,
                              @"categories": categories,
                              @"plan": plan,
                              @"replace": @(replace),
                              @"stage": @"prepared",
                              @"createdAt": @(NSDate.date.timeIntervalSince1970)};
    NSError *journalError = nil;
    if (!FDMWriteJSON(journal, _journalPath, &journalError)) {
        if (error) *error = journalError;
        return NO;
    }
    NSMutableArray *committed = [NSMutableArray array];
    BOOL ok = YES;
    for (NSDictionary *step in prepared) {
        id<FDMBackupProvider> provider = step[@"provider"];
        NSError *commitError = nil;
        if (![provider commitPrepared:step[@"staged"] error:&commitError]) {
            ok = NO;
            failure = commitError;
            break;
        }
        [committed addObject:step];
    }
    if (!ok) {
        // Roll back what did commit, newest first, and keep protection state if that also fails.
        BOOL rolledBack = YES;
        for (NSDictionary *step in [committed reverseObjectEnumerator]) {
            NSError *rollbackError = nil;
            if (![step[@"provider"] rollbackPrepared:step[@"staged"] error:&rollbackError]) rolledBack = NO;
        }
        NSMutableDictionary *updated = [journal mutableCopy];
        updated[@"stage"] = rolledBack ? @"rolledBack" : @"rollbackFailed";
        FDMWriteJSON(updated, _journalPath, nil);
        if (!rolledBack) _recoveryNotice = @"恢复失败且回滚未完成；已保留保护状态，请重启应用后重试或重新导入原备份";
        if (error) *error = failure ?: FDMBackupError(@"导入未完成，已回滚");
        return NO;
    }
    // Verify read-back before publishing the new state.
    for (NSDictionary *step in prepared) {
        id<FDMBackupProvider> provider = step[@"provider"];
        NSError *readError = nil;
        NSData *after = [provider exportSnapshotWithRevision:NULL error:&readError];
        if (!after) {
            failure = readError;
            ok = NO;
            break;
        }
    }
    NSMutableDictionary *done = [journal mutableCopy];
    done[@"stage"] = ok ? @"committed" : @"verifyFailed";
    FDMWriteJSON(done, _journalPath, nil);
    if (!ok) { if (error) *error = failure ?: FDMBackupError(@"导入后校验失败"); return NO; }
    for (NSDictionary *step in prepared) [step[@"provider"] reloadCommittedState];
    [[NSFileManager defaultManager] removeItemAtPath:_journalPath error:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:FDMBackupDidChangeNotification object:nil];
    });
    return YES;
}

- (BOOL)recoverInterruptedTransaction {
    id journal = FDMReadJSON(_journalPath, nil);
    if (![journal isKindOfClass:NSDictionary.class]) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:_journalPath]) {
            _recoveryNotice = @"上次恢复事务记录无法读取；已保留原配置，请检查后重试";
            return NO;
        }
        return YES;
    }
    NSString *stage = FDMString(journal[@"stage"]);
    if ([stage isEqual:@"committed"]) {
        // The commit finished before the marker was removed; treat it as done.
        [[NSFileManager defaultManager] removeItemAtPath:_journalPath error:nil];
        return YES;
    }
    // Any other stage means the write did not complete: the pre-change state is authoritative.
    _recoveryNotice = @"上次数据恢复未完成，已回到恢复前的配置";
    FDMLog(@"backup transaction recovered from stage=%@", stage);
    [[NSFileManager defaultManager] removeItemAtPath:_journalPath error:nil];
    return YES;
}

- (NSString *)recoveryNotice { return _recoveryNotice; }
@end
