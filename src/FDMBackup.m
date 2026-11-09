#import "FDMBackup.h"
#import "FDMJSON.h"
#import <CommonCrypto/CommonDigest.h>

NSString *const FDMBackupFormat = @"ios-browser-backup";
NSString *const FDMBackupDidChangeNotification = @"FDMBackupDidChange";

NSUInteger const FDMBackupMaxFileBytes = 32 * 1024 * 1024;
NSUInteger const FDMBackupMaxPayloadBytes = 16 * 1024 * 1024;
NSUInteger const FDMBackupMaxCategoryBytes = 8 * 1024 * 1024;
NSUInteger const FDMBackupMaxBookmarks = 10000;
NSUInteger const FDMBackupMaxScripts = 200;
NSUInteger const FDMBackupMaxScriptBytes = 1024 * 1024;
NSUInteger const FDMBackupMaxNameBytes = 512;
NSUInteger const FDMBackupMaxURLBytes = 8192;

NSString *const FDMBackupCategoryBookmarks = @"bookmarks";
NSString *const FDMBackupCategorySearch = @"searchConfiguration";
NSString *const FDMBackupCategorySitePolicies = @"sitePolicies";
NSString *const FDMBackupCategoryPreferences = @"allowedPreferences";
NSString *const FDMBackupCategoryScripts = @"userScripts";

NSArray<NSString *> *FDMBackupCategoryOrder(void) {
    static NSArray *order;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        order = @[FDMBackupCategoryBookmarks, FDMBackupCategorySearch, FDMBackupCategorySitePolicies,
                  FDMBackupCategoryPreferences, FDMBackupCategoryScripts];
    });
    return order;
}

NSString *FDMBackupCategoryTitle(NSString *category) {
    NSDictionary *titles = @{FDMBackupCategoryBookmarks: @"书签与主页快捷项",
                             FDMBackupCategorySearch: @"搜索配置",
                             FDMBackupCategorySitePolicies: @"站点策略",
                             FDMBackupCategoryPreferences: @"允许的偏好设置",
                             FDMBackupCategoryScripts: @"用户脚本"};
    return titles[category] ?: category;
}

BOOL FDMBackupCategorySelectedByDefault(NSString *category) {
    return ![category isEqual:FDMBackupCategoryScripts];
}

static NSError *FDMBackupError(NSString *message) {
    return [NSError errorWithDomain:@"FocusDM.Backup" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

NSString *FDMBackupSHA256(NSData *data) {
    if (![data isKindOfClass:NSData.class]) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

#pragma mark - DTO

@interface FDMBackupCategory ()
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSData *payload;
@property (nonatomic) NSUInteger itemCount;
@property (nonatomic, copy) NSString *sha256;
@end

@implementation FDMBackupCategory
+ (instancetype)category:(NSString *)identifier payload:(NSData *)payload itemCount:(NSUInteger)itemCount {
    FDMBackupCategory *category = [[self alloc] init];
    category.identifier = identifier;
    category.payload = payload;
    category.itemCount = itemCount;
    category.sha256 = FDMBackupSHA256(payload);
    return category;
}
@end

@interface FDMBackupContainer ()
@property (nonatomic, copy) NSString *backupID;
@property (nonatomic, copy) NSDate *createdAt;
@property (nonatomic, copy) NSString *producerApp;
@property (nonatomic, copy) NSString *producerVersion;
@property (nonatomic, copy) NSDictionary<NSString *, FDMBackupCategory *> *categories;
@property (nonatomic, copy) NSArray<NSString *> *unsupportedCategories;
@end

@implementation FDMBackupContainer
@end

#pragma mark - encode

NSData *FDMBackupEncode(NSArray<FDMBackupCategory *> *categories, NSString *producerVersion, NSError **error) {
    if (!categories.count) { if (error) *error = FDMBackupError(@"没有选中任何可备份类别"); return nil; }
    NSMutableArray *entries = [NSMutableArray array];
    NSUInteger decodedTotal = 0;
    NSMutableSet *seen = [NSMutableSet set];
    for (FDMBackupCategory *category in categories) {
        if (![category isKindOfClass:FDMBackupCategory.class] || !category.identifier.length || !category.payload.length) {
            if (error) *error = FDMBackupError(@"备份类别内容无效");
            return nil;
        }
        if ([seen containsObject:category.identifier]) { if (error) *error = FDMBackupError([NSString stringWithFormat:@"备份类别重复：%@", category.identifier]); return nil; }
        [seen addObject:category.identifier];
        if (category.payload.length > FDMBackupMaxCategoryBytes) { if (error) *error = FDMBackupError([NSString stringWithFormat:@"%@ 内容超出单类别上限", FDMBackupCategoryTitle(category.identifier)]); return nil; }
        decodedTotal += category.payload.length;
        if (decodedTotal > FDMBackupMaxPayloadBytes) { if (error) *error = FDMBackupError(@"备份内容总大小超出上限"); return nil; }
        [entries addObject:@{@"id": category.identifier,
                             @"schemaVersion": @1,
                             @"encoding": @"json-utf8-base64",
                             @"itemCount": @(category.itemCount),
                             @"byteLength": @(category.payload.length),
                             @"sha256": category.sha256 ?: @"",
                             @"dataBase64": [category.payload base64EncodedStringWithOptions:0]}];
    }
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    NSDictionary *container = @{@"format": FDMBackupFormat,
                                @"schemaVersion": @1,
                                @"backupID": NSUUID.UUID.UUIDString,
                                @"createdAt": [formatter stringFromDate:NSDate.date],
                                @"producer": @{@"app": @"focus-browser-patch", @"version": producerVersion ?: FDMPatchVersion()},
                                @"categories": entries};
    NSData *encoded = FDMJSONCanonicalData(container, error);
    if (encoded.length > FDMBackupMaxFileBytes) { if (error) *error = FDMBackupError(@"备份文件超出大小上限"); return nil; }
    return encoded;
}

#pragma mark - decode

FDMBackupContainer *FDMBackupDecode(NSData *data, NSError **error) {
    if (data.length > FDMBackupMaxFileBytes) { if (error) *error = FDMBackupError(@"备份文件超出 32 MiB 上限"); return nil; }
    id root = FDMJSONParseData(data, error);
    NSDictionary *input = FDMJSONObjectValue(root);
    if (!input) { if (error) *error = FDMBackupError(@"备份文件不是有效对象"); return nil; }
    for (NSString *key in input) {
        if (![@[@"format", @"schemaVersion", @"backupID", @"createdAt", @"producer", @"categories"] containsObject:key]) {
            if (error) *error = FDMBackupError([NSString stringWithFormat:@"备份含未知顶层字段：%@", key]);
            return nil;
        }
    }
    if (![FDMJSONStringValue(input[@"format"]) isEqual:FDMBackupFormat]) {
        if (error) *error = FDMBackupError(@"不是本应用的备份文件");
        return nil;
    }
    unsigned long long schema = 0;
    if (!FDMJSONNonNegativeInteger(input[@"schemaVersion"], 100, &schema) || schema != 1) {
        if (error) *error = FDMBackupError(@"备份文件版本不受支持");
        return nil;
    }
    NSString *backupID = FDMJSONStringValue(input[@"backupID"]);
    if (!backupID.length || backupID.length > 128) { if (error) *error = FDMBackupError(@"备份标识无效"); return nil; }
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    NSString *createdText = FDMJSONStringValue(input[@"createdAt"]);
    NSDate *createdAt = createdText.length ? [formatter dateFromString:createdText] : nil;
    if (!createdAt) { if (error) *error = FDMBackupError(@"备份创建时间无效"); return nil; }
    NSDictionary *producer = FDMJSONObjectValue(input[@"producer"]);
    if (!producer) { if (error) *error = FDMBackupError(@"备份缺少来源信息"); return nil; }
    for (NSString *key in producer) {
        if (![@[@"app", @"version"] containsObject:key]) { if (error) *error = FDMBackupError(@"备份来源含未知字段"); return nil; }
    }
    NSString *app = FDMJSONStringValue(producer[@"app"]);
    NSString *version = FDMJSONStringValue(producer[@"version"]);
    if (!app.length || !version.length) { if (error) *error = FDMBackupError(@"备份来源信息不完整"); return nil; }
    NSArray *rawCategories = FDMJSONArrayValue(input[@"categories"]);
    if (!rawCategories.count) { if (error) *error = FDMBackupError(@"备份不含任何类别"); return nil; }

    NSMutableDictionary *categories = [NSMutableDictionary dictionary];
    NSMutableArray *unsupported = [NSMutableArray array];
    NSUInteger decodedTotal = 0;
    for (id raw in rawCategories) {
        NSDictionary *entry = FDMJSONObjectValue(raw);
        if (!entry) { if (error) *error = FDMBackupError(@"备份类别条目无效"); return nil; }
        for (NSString *key in entry) {
            if (![@[@"id", @"schemaVersion", @"encoding", @"itemCount", @"byteLength", @"sha256", @"dataBase64"] containsObject:key]) {
                if (error) *error = FDMBackupError(@"备份类别含未知字段");
                return nil;
            }
        }
        NSString *identifier = FDMJSONStringValue(entry[@"id"]);
        if (!identifier.length) { if (error) *error = FDMBackupError(@"备份类别缺少标识"); return nil; }
        if (categories[identifier] || [unsupported containsObject:identifier]) {
            if (error) *error = FDMBackupError([NSString stringWithFormat:@"备份类别重复：%@", identifier]);
            return nil;
        }
        unsigned long long categorySchema = 0;
        if (!FDMJSONNonNegativeInteger(entry[@"schemaVersion"], 100, &categorySchema) || categorySchema != 1) {
            if (error) *error = FDMBackupError([NSString stringWithFormat:@"%@ 的版本不受支持", identifier]);
            return nil;
        }
        if (![FDMJSONStringValue(entry[@"encoding"]) isEqual:@"json-utf8-base64"]) {
            if (error) *error = FDMBackupError([NSString stringWithFormat:@"%@ 的编码方式不受支持", identifier]);
            return nil;
        }
        unsigned long long itemCount = 0;
        if (!FDMJSONNonNegativeInteger(entry[@"itemCount"], 10000000, &itemCount)) { if (error) *error = FDMBackupError(@"类别项目数量无效"); return nil; }
        unsigned long long byteLength = 0;
        if (!FDMJSONNonNegativeInteger(entry[@"byteLength"], FDMBackupMaxCategoryBytes, &byteLength)) {
            if (error) *error = FDMBackupError([NSString stringWithFormat:@"%@ 的长度字段无效或超出上限", identifier]);
            return nil;
        }
        NSString *hash = FDMJSONStringValue(entry[@"sha256"]);
        if (hash.length != 64) { if (error) *error = FDMBackupError(@"类别校验值格式无效"); return nil; }
        NSString *base64 = FDMJSONStringValue(entry[@"dataBase64"]);
        if (![base64 isKindOfClass:NSString.class]) { if (error) *error = FDMBackupError(@"类别数据缺失"); return nil; }
        // Bound the encoded length before decoding so a hostile file cannot expand past the budget.
        NSUInteger maxEncoded = ((FDMBackupMaxCategoryBytes + 2) / 3) * 4 + 4;
        if (base64.length > maxEncoded) { if (error) *error = FDMBackupError([NSString stringWithFormat:@"%@ 的编码长度超出上限", identifier]); return nil; }
        NSData *decoded = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
        if (!decoded) { if (error) *error = FDMBackupError([NSString stringWithFormat:@"%@ 的 base64 数据无效", identifier]); return nil; }
        if (decoded.length != byteLength) { if (error) *error = FDMBackupError([NSString stringWithFormat:@"%@ 的实际长度与声明不符", identifier]); return nil; }
        if (![FDMBackupSHA256(decoded) isEqual:hash]) { if (error) *error = FDMBackupError([NSString stringWithFormat:@"%@ 的校验值不匹配", identifier]); return nil; }
        if (![FDMBackupCategoryOrder() containsObject:identifier]) {
            // Unknown categories are reported, never silently applied.
            [unsupported addObject:identifier];
            continue;
        }
        decodedTotal += decoded.length;
        if (decodedTotal > FDMBackupMaxPayloadBytes) { if (error) *error = FDMBackupError(@"备份内容总大小超出上限"); return nil; }
        categories[identifier] = [FDMBackupCategory category:identifier payload:decoded itemCount:(NSUInteger)itemCount];
    }
    if (!categories.count && !unsupported.count) { if (error) *error = FDMBackupError(@"备份不含可用类别"); return nil; }
    FDMBackupContainer *container = [[FDMBackupContainer alloc] init];
    container.backupID = backupID;
    container.createdAt = createdAt;
    container.producerApp = app;
    container.producerVersion = version;
    container.categories = categories;
    container.unsupportedCategories = unsupported;
    return container;
}
