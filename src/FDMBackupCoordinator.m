#import "FDMBackup.h"
#import "FDMBackupRepositoryImpl.h"
#import "FDMBackupSQL.h"
#import "FDMBackupRecovery.h"
#import "FDMJSON.h"
#import "FDMPolicy.h"

static NSError *FDMBackupFailure(NSString *message) { return FDMError(message); }
static const NSUInteger FDMJournalBudget = 64 * 1024 * 1024;

@interface FDMBackupImportPlan ()
@property (nonatomic, copy) NSString *backupID;
@property (nonatomic, copy) NSArray<NSString *> *categories;
@property (nonatomic) BOOL replace;
@property (nonatomic, copy) NSDictionary<NSString *, id> *validatedByCategory;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *revisionByCategory;
@property (nonatomic, copy) NSDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *countsByCategory;
@property (nonatomic, copy) NSArray<NSString *> *unsupportedCategories;
@end
@implementation FDMBackupImportPlan @end

static NSArray *FDMOrderedCategories(NSArray *input, NSError **error) {
    if (![input isKindOfClass:NSArray.class] || !input.count || input.count > FDMBackupCategoryOrder().count ||
        [NSSet setWithArray:input].count != input.count) { if (error) *error = FDMBackupFailure(@"请选择不重复的可用类别"); return nil; }
    for (id category in input) if (![category isKindOfClass:NSString.class] || ![FDMBackupCategoryOrder() containsObject:category]) {
        if (error) *error = FDMBackupFailure(@"包含本版本不支持的类别"); return nil;
    }
    NSMutableArray *ordered = [NSMutableArray array];
    for (NSString *category in FDMBackupCategoryOrder()) if ([input containsObject:category]) [ordered addObject:category];
    return [ordered copy];
}
static NSDictionary *FDMJournalDataMap(NSDictionary<NSString *, NSData *> *data) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *key in data) result[key] = @{@"bytes": [data[key] base64EncodedStringWithOptions:0], @"sha256": FDMBackupSHA256(data[key])};
    return [result copy];
}
static NSDictionary *FDMReadJournalMap(NSDictionary *map, NSArray *categories, NSError **error) {
    if (![map isKindOfClass:NSDictionary.class] || map.count != categories.count) { if (error) *error = FDMBackupFailure(@"恢复记录前像数量不一致"); return nil; }
    NSMutableDictionary *result = [NSMutableDictionary dictionary]; NSUInteger total = 0;
    for (NSString *category in categories) {
        NSDictionary *entry = FDMJSONObjectValue(map[category]); NSString *encoded = FDMJSONStringValue(entry[@"bytes"]), *hash = FDMJSONStringValue(entry[@"sha256"]);
        if (!encoded || hash.length != 64 || encoded.length > ((32 * 1024 * 1024 + 2) / 3) * 4) {
            if (error) *error = FDMBackupFailure(@"恢复记录前像格式或长度无效"); return nil;
        }
        NSData *bytes = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
        if (!bytes || ![FDMBackupSHA256(bytes) isEqual:hash]) { if (error) *error = FDMBackupFailure(@"恢复记录前像校验失败"); return nil; }
        total += bytes.length; if (total > 32 * 1024 * 1024) { if (error) *error = FDMBackupFailure(@"恢复记录前像超过预算"); return nil; }
        result[category] = bytes;
    }
    return [result copy];
}

@implementation FDMBackupCoordinator {
    NSMutableDictionary<NSString *, id<FDMBackupRepository>> *_repositories;
    NSMutableDictionary<NSString *, id<FDMBackupSQLDatabase>> *_databases;
    NSRecursiveLock *_lock;
    NSString *_journalPath;
    NSString *_recoveryNotice;
    BOOL _recoveryBlocked;
}
+ (instancetype)shared { static id owner; static dispatch_once_t once; dispatch_once(&once, ^{ owner = [self new]; [owner registerDefaults]; }); return owner; }
- (instancetype)init {
    if ((self = [super init])) {
        _repositories = [NSMutableDictionary dictionary]; _databases = [NSMutableDictionary dictionary]; _lock = [NSRecursiveLock new];
#ifdef FDM_TESTING
        _journalPath = [FDMDirectory(@"FocusDM") stringByAppendingPathComponent:@"backup-journal.json"];
#else
        NSString *library = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
        NSString *directory = [library stringByAppendingPathComponent:@"FocusDMRecovery"];
        [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
        _journalPath = [directory stringByAppendingPathComponent:@"backup-journal.json"];
#endif
    }
    return self;
}
- (void)registerDefaults {
    id<FDMBackupSQLDatabase> database = [FDMHostDatabaseQueue hostQueueWithError:NULL];
    if (database) {
        [self registerRepository:[[FDMBackupBookmarkRepository alloc] initWithDatabase:database] database:database];
        [self registerRepository:[[FDMBackupHomeTagRepository alloc] initWithDatabase:database] database:database];
        [self registerRepository:[[FDMBackupScriptsRepository alloc] initWithDatabase:database] database:database];
    }
    [self registerRepository:[[FDMBackupSearchRepository alloc] initWithUserDefaults:FDMBackupSearchRepository.hostSearchDefaults]];
    [self registerRepository:[[FDMBackupPreferencesRepository alloc] initWithUserDefaults:NSUserDefaults.standardUserDefaults]];
    [self registerRepository:[FDMBackupPolicyRepository new]];
}
- (void)registerRepository:(id<FDMBackupRepository>)repository {
    [_lock lock]; if (repository.categoryIdentifier.length) _repositories[repository.categoryIdentifier] = repository; [_lock unlock];
}
- (void)registerRepository:(id<FDMBackupRepository>)repository database:(id<FDMBackupSQLDatabase>)database {
    [_lock lock]; [self registerRepository:repository]; if (repository.storageDomain.length && database) _databases[repository.storageDomain] = database; [_lock unlock];
}
- (NSArray<NSString *> *)availableCategories {
    [_lock lock]; NSMutableArray *result = [NSMutableArray array];
    for (NSString *category in FDMBackupCategoryOrder()) if ([_repositories[category] isAvailable]) [result addObject:category];
    [_lock unlock]; return [result copy];
}
- (BOOL)exclusiveCategories:(NSArray *)categories block:(BOOL (^)(void))block error:(NSError **)error {
    NSMutableSet *domains = [NSMutableSet set];
    for (NSString *category in categories) { NSString *domain = [_repositories[category] storageDomain]; if (domain.length) [domains addObject:domain]; }
    if (domains.count > 1) { if (error) *error = FDMBackupFailure(@"本版本不支持跨多个数据库恢复"); return NO; }
    if (!domains.count) return block();
    id database = _databases[domains.anyObject];
    if (![database respondsToSelector:@selector(performExclusiveAccess:error:)]) { if (error) *error = FDMBackupFailure(@"数据库没有恢复写入屏障"); return NO; }
    return [database performExclusiveAccess:block error:error];
}
- (NSData *)exportCategories:(NSArray *)input error:(NSError **)error {
    NSArray *categories = FDMOrderedCategories(input, error); if (!categories) return nil;
    [_lock lock]; NSMutableArray *entries = [NSMutableArray array]; __block NSError *failure = nil;
    BOOL ok = [self exclusiveCategories:categories block:^BOOL {
        for (NSString *category in categories) {
            id<FDMBackupRepository> repository = _repositories[category];
            if (!repository || !repository.isAvailable) { failure = FDMBackupFailure(@"所选类别当前不可读取"); return NO; }
            NSData *bytes = [repository exportSnapshotWithRevision:NULL error:&failure];
            id valid = bytes ? [repository validateImportPayload:bytes error:&failure] : nil;
            if (!valid) return NO;
            NSUInteger count = [category isEqual:FDMBackupCategorySitePolicies] ? [valid[@"origins"] count] : [valid count];
            [entries addObject:[FDMBackupCategory category:category payload:bytes itemCount:count]];
        }
        return YES;
    } error:&failure]; [_lock unlock];
    if (!ok) { if (error) *error = failure; return nil; }
    return FDMBackupEncode(entries, FDMPatchVersion(), error);
}
- (FDMBackupContainer *)openBackupAtURL:(NSURL *)url error:(NSError **)error {
    NSData *data = FDMReadBoundedFile(url, FDMBackupMaxFileBytes, error); return data ? FDMBackupDecode(data, error) : nil;
}
- (FDMBackupImportPlan *)previewContainer:(FDMBackupContainer *)container categories:(NSArray *)input replace:(BOOL)replace error:(NSError **)error {
    NSArray *categories = FDMOrderedCategories(input, error); if (!categories || !container) return nil;
    [_lock lock]; NSMutableDictionary *validated = [NSMutableDictionary dictionary], *revisions = [NSMutableDictionary dictionary], *counts = [NSMutableDictionary dictionary];
    NSMutableArray *usable = [NSMutableArray array], *unsupported = [container.unsupportedCategories mutableCopy]; __block NSError *failure = nil;
    BOOL ok = [self exclusiveCategories:categories block:^BOOL {
        for (NSString *category in categories) {
            id<FDMBackupRepository> repository = _repositories[category]; FDMBackupCategory *entry = container.categories[category];
            if (!entry || !repository || !repository.isAvailable) { if (![unsupported containsObject:category]) [unsupported addObject:category]; continue; }
            id dto = [repository validateImportPayload:entry.payload error:&failure]; NSString *revision = [repository currentRevisionWithError:&failure];
            NSDictionary *numbers = dto ? [repository previewCountsForValidated:dto error:&failure] : nil;
            if (!dto || !revision || !numbers) return NO;
            NSData *immutableBytes = FDMJSONCanonicalData(dto, &failure); id immutable = immutableBytes ? FDMJSONParseData(immutableBytes, &failure) : nil;
            if (!immutable) return NO;
            validated[category] = immutable; revisions[category] = revision; counts[category] = [numbers copy]; [usable addObject:category];
        }
        return YES;
    } error:&failure]; [_lock unlock];
    if (!ok || !usable.count) { if (error) *error = failure ?: FDMBackupFailure(@"没有可恢复的所选类别"); return nil; }
    FDMBackupImportPlan *plan = [FDMBackupImportPlan new]; plan.backupID = container.backupID; plan.categories = usable; plan.replace = replace;
    plan.validatedByCategory = validated; plan.revisionByCategory = revisions; plan.countsByCategory = counts; plan.unsupportedCategories = unsupported;
    return plan;
}
- (BOOL)restoreImages:(NSDictionary *)images exact:(NSDictionary *)exact categories:(NSArray *)categories steps:(NSDictionary *)steps error:(NSError **)error {
    BOOL ok = YES;
    for (NSString *category in categories.reverseObjectEnumerator) {
        id<FDMBackupRepository> repository = _repositories[category]; NSData *bytes = images[category]; NSError *failure = nil; BOOL restored = NO;
        @try {
            if ([exact[category] boolValue] && [repository respondsToSelector:@selector(restoreRecoverySnapshot:error:)]) restored = [repository restoreRecoverySnapshot:bytes error:&failure];
            else if (steps[category]) restored = [repository rollbackStaged:steps[category] error:&failure];
            else { id stage = [repository stageRestoreSnapshot:bytes error:&failure]; restored = stage && [repository commitStaged:stage error:&failure] != nil; }
            if (restored && [exact[category] boolValue]) {
                NSData *check = [repository recoverySnapshotWithError:&failure]; restored = [check isEqual:bytes];
            }
        } @catch (NSException *exception) { restored = NO; }
        if (!restored) { ok = NO; if (error && !*error) *error = failure ?: FDMBackupFailure(@"配置前像回滚未完成"); }
    }
    return ok;
}
- (BOOL)applyPlan:(FDMBackupImportPlan *)plan error:(NSError **)error {
    if (!NSThread.isMainThread) { __block BOOL result; __block NSError *failure = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{ result = [self applyPlan:plan error:&failure]; }); if (!result && error) *error = failure; return result; }
    NSArray *categories = FDMOrderedCategories(plan.categories, error); if (!categories) return NO;
    [self recoverInterruptedTransaction]; if (_recoveryBlocked) { if (error) *error = FDMBackupFailure(_recoveryNotice); return NO; }
    [_lock lock]; __block NSError *failure = nil; __block BOOL applied = NO;
    BOOL entered = [self exclusiveCategories:categories block:^BOOL {
        NSMutableDictionary *steps = [NSMutableDictionary dictionary], *before = [NSMutableDictionary dictionary], *after = [NSMutableDictionary dictionary], *exact = [NSMutableDictionary dictionary];
        NSUInteger budget = 0;
        @try {
            for (NSString *category in categories) {
                id<FDMBackupRepository> repository = _repositories[category]; NSString *revision = [repository currentRevisionWithError:&failure];
                if (!revision || ![revision isEqual:plan.revisionByCategory[category]]) { failure = FDMBackupFailure(@"配置在预览后已改变，请重新预览"); return NO; }
                id stage = [repository stageMergeValidated:plan.validatedByCategory[category] replace:plan.replace error:&failure];
                if (!stage) return NO;
                BOOL completeImage = [repository respondsToSelector:@selector(recoverySnapshotWithError:)] && [repository respondsToSelector:@selector(restoreRecoverySnapshot:error:)];
                NSData *image = completeImage ? [repository recoverySnapshotWithError:&failure] : [stage beforeSnapshot];
                NSData *expected = [stage afterSnapshot]; if (!image || !expected) return NO;
                budget += image.length + expected.length; if (budget > 32 * 1024 * 1024) { failure = FDMBackupFailure(@"恢复前像超过本地事务预算，未改配置"); return NO; }
                before[category] = image; after[category] = expected; exact[category] = @(completeImage); steps[category] = stage;
            }
        } @catch (NSException *exception) { failure = FDMBackupFailure(@"配置暂存失败，未改配置"); return NO; }
        NSMutableDictionary *journal = [@{@"schemaVersion": @2, @"transactionID": NSUUID.UUID.UUIDString,
            @"categories": categories, @"stage": @"prepared", @"before": FDMJournalDataMap(before), @"after": FDMJournalDataMap(after), @"exact": exact} mutableCopy];
        if (!FDMWriteDurableJSON(journal, _journalPath, &failure)) return NO;
        NSMutableArray *touched = [NSMutableArray array]; BOOL ok = YES;
        [FDMSitePolicyStore.shared beginRecoveryPublication];
        @try {
            NSMutableArray *sqlCategories = [NSMutableArray array]; id<FDMBackupSQLDatabase> database = nil;
            for (NSString *category in categories) if ([_repositories[category] storageDomain].length) { [sqlCategories addObject:category]; database = _databases[[_repositories[category] storageDomain]]; }
            if (sqlCategories.count) {
                [touched addObjectsFromArray:sqlCategories];
                ok = [database inTransaction:^BOOL(id<FDMBackupSQLExecutor> executor) {
                    for (NSString *category in sqlCategories) if (![_repositories[category] applyStaged:steps[category] onExecutor:executor error:&failure]) return NO;
                    return YES;
                } error:&failure];
            }
            if (ok) for (NSString *category in categories) {
                if ([_repositories[category] storageDomain].length) continue;
                [touched addObject:category];
                if (![_repositories[category] commitStaged:steps[category] error:&failure]) { ok = NO; break; }
            }
            if (ok) for (NSString *category in categories) {
                id<FDMBackupRepository> repository = _repositories[category];
                if (![repository verifyCommittedStateWithError:&failure]) { ok = NO; break; }
                NSData *check = [repository exportSnapshotWithRevision:NULL error:&failure];
                if (![check isEqual:after[category]]) { failure = FDMBackupFailure([NSString stringWithFormat:@"%@ 读回与预览不一致", FDMBackupCategoryTitle(category)]); ok = NO; break; }
            }
            if (ok) { journal[@"stage"] = @"committed"; ok = FDMWriteDurableJSON(journal, _journalPath, &failure); }
        } @catch (NSException *exception) { ok = NO; failure = FDMBackupFailure(@"恢复执行异常，正在回滚前像"); }
        if (!ok) {
            BOOL restored = [self restoreImages:before exact:exact categories:touched steps:steps error:NULL];
            _recoveryBlocked = !restored;
            if (!restored) _recoveryNotice = @"恢复失败且前像回滚未完成。配置已受保护，请重新启动重试；恢复记录保持原样。";
            if (restored) { journal[@"stage"] = @"rolledBack"; FDMWriteDurableJSON(journal, _journalPath, NULL);
                [[NSFileManager defaultManager] removeItemAtPath:_journalPath error:NULL]; }
            [FDMSitePolicyStore.shared finishRecoveryPublication:restored];
            return NO;
        }
        [FDMSitePolicyStore.shared finishRecoveryPublication:YES];
        applied = YES; return YES;
    } error:&failure]; [_lock unlock];
    if (entered && applied) {
        for (NSString *category in categories) [_repositories[category] reloadHostCache];
        [[NSFileManager defaultManager] removeItemAtPath:_journalPath error:NULL];
        [NSNotificationCenter.defaultCenter postNotificationName:FDMBackupDidChangeNotification object:nil]; return YES;
    }
    if (error) *error = failure ?: FDMBackupFailure(@"恢复未完成，配置没有发布"); return NO;
}
- (void)recoverInterruptedTransaction {
    [_lock lock]; _recoveryBlocked = NO; _recoveryNotice = nil;
    if (![[NSFileManager defaultManager] fileExistsAtPath:_journalPath]) { [_lock unlock]; return; }
    __block NSError *failure = nil; NSData *bytes = FDMReadBoundedFile([NSURL fileURLWithPath:_journalPath], FDMJournalBudget, &failure);
    NSDictionary *journal = bytes ? FDMJSONObjectValue(FDMJSONParseDataBounded(bytes, 32, FDMJournalBudget, &failure)) : nil;
    NSArray *categories = FDMOrderedCategories(journal[@"categories"], &failure); NSDictionary *images = nil, *exact = nil;
    unsigned long long version = 0;
    if (journal && categories && FDMJSONNonNegativeInteger(journal[@"schemaVersion"], 2, &version) && (version == 1 || version == 2) &&
        [journal[@"transactionID"] isKindOfClass:NSString.class] && [journal[@"transactionID"] length]) {
        if (version == 2) { images = FDMReadJournalMap(journal[@"before"], categories, &failure); exact = FDMJSONObjectValue(journal[@"exact"]); }
        else {
            // Compatibility with an internal pre-release v20 test record, not a portable input.
            NSMutableDictionary *map = [NSMutableDictionary dictionary];
            for (NSString *category in categories) {
                id encoded = journal[@"before"][category], hash = journal[@"beforeSHA256"][category];
                if (![encoded isKindOfClass:NSString.class] || ![hash isKindOfClass:NSString.class]) { failure = FDMBackupFailure(@"前像缺失"); break; }
                map[category] = @{@"bytes": encoded, @"sha256": hash};
            }
            images = failure ? nil : FDMReadJournalMap(map, categories, &failure); exact = @{};
        }
    }
    NSString *stage = FDMJSONStringValue(journal[@"stage"]);
    if (!images || !categories || ![@[@"prepared", @"committed", @"rolledBack", @"rollbackFailed"] containsObject:stage]) {
        _recoveryBlocked = YES; _recoveryNotice = @"恢复记录格式或前像校验失败，已保留记录并暂停配置启动。"; [_lock unlock]; return;
    }
    if ([stage isEqual:@"committed"] || [stage isEqual:@"rolledBack"]) { [[NSFileManager defaultManager] removeItemAtPath:_journalPath error:NULL]; [_lock unlock]; return; }
    [FDMSitePolicyStore.shared beginRecoveryPublication];
    BOOL restored = [self exclusiveCategories:categories block:^BOOL {
        return [self restoreImages:images exact:exact categories:categories steps:@{} error:&failure];
    } error:&failure];
    [FDMSitePolicyStore.shared finishRecoveryPublication:restored];
    if (restored) { for (NSString *category in categories) [_repositories[category] reloadHostCache];
        [[NSFileManager defaultManager] removeItemAtPath:_journalPath error:NULL]; _recoveryNotice = @"已从中断的恢复事务还原原配置。"; }
    else { _recoveryBlocked = YES; _recoveryNotice = @"中断事务的前像仍无法完整恢复。已保持配置保护与原恢复记录。"; }
    [_lock unlock];
}
- (NSString *)recoveryNotice { return _recoveryNotice; }
- (BOOL)recoveryBlocked { return _recoveryBlocked; }
@end
