#import "FDMBackupRepositoryImpl.h"
#import "FDMPolicy.h"
#import "FDMJSON.h"

static NSError *FDMRepoError(NSString *message) {
    return [NSError errorWithDomain:@"FocusDM.Backup.Repository" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

@interface FDMBackupPolicyStagedSet : NSObject <FDMBackupStagedSet>
@property (nonatomic, copy) NSData *beforeSnapshot;
@property (nonatomic, copy) NSData *afterSnapshot;
@property (nonatomic, copy) NSDictionary *beforeDocument;
@property (nonatomic, copy) NSDictionary *afterDocument;
@property (nonatomic) unsigned long long expectedRevision;
// Revision the store will hold after commit: the store always increments by one.
@property (nonatomic) unsigned long long afterRevision;
// Exact before document (including its own revision) for rollback, which must not re-validate a
// portable payload because that would downgrade camera/microphone Allow back to Ask.
@property (nonatomic, copy) NSDictionary *exactBeforeDocument;
@end

@implementation FDMBackupPolicyStagedSet
@end

// Site policy has exactly one owner, FDMSitePolicyStore. This repository never writes the file
// itself: it delegates every read and write so there is no second source of truth.
@implementation FDMBackupPolicyRepository

- (NSString *)categoryIdentifier { return FDMBackupCategorySitePolicies; }

- (BOOL)isAvailable { return FDMSitePolicyStore.shared.writable; }

// Site policy is a JSON file owned by FDMSitePolicyStore, not the SQLite database.
- (NSString *)storageDomain { return nil; }

- (BOOL)applyStaged:(id)staged onExecutor:(id<FDMBackupSQLExecutor>)executor error:(NSError **)error {
    if (error) *error = FDMRepoError(@"站点策略不通过 SQL 事务提交");
    return NO;
}

- (NSData *)exportSnapshotWithRevision:(NSString **)revision error:(NSError **)error {
    if (!FDMSitePolicyStore.shared.writable) { if (error) *error = FDMRepoError(@"站点规则文件不可写或格式未知"); return nil; }
    NSDictionary *snapshot = FDMSitePolicyStore.shared.transactionSnapshot;
    NSData *payload = FDMJSONCanonicalData(snapshot, error);
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
    if (!root) return nil;
    NSDictionary *document = FDMSitePolicyValidateDocument(root, error);
    if (!document) return nil;
    // Imported permissions never auto-grant: an explicit "allow" becomes "ask", and the number of
    // downgraded entries is reported so the preview is truthful.
    NSMutableDictionary *origins = [NSMutableDictionary dictionary];
    NSUInteger downgraded = 0;
    for (NSString *origin in document[@"origins"]) {
        NSMutableDictionary *entry = [document[@"origins"][origin] mutableCopy];
        for (NSString *field in @[FDMPolicyCamera, FDMPolicyMicrophone]) {
            if ([entry[field] isEqual:@"allow"]) { entry[field] = @"ask"; downgraded++; }
        }
        origins[origin] = entry;
    }
    return @{@"schemaVersion": @1, @"revision": document[@"revision"], @"origins": origins, @"importDowngraded": @(downgraded)};
}

- (NSDictionary<NSString *, NSNumber *> *)previewCountsForValidated:(id)validated error:(NSError **)error {
    NSDictionary *current = FDMSitePolicyStore.shared.transactionSnapshot[@"origins"] ?: @{};
    NSUInteger added = 0, identical = 0, conflict = 0, downgraded = [validated[@"importDowngraded"] unsignedIntegerValue];
    for (NSString *origin in validated[@"origins"]) {
        NSDictionary *incoming = validated[@"origins"][origin];
        NSDictionary *existing = current[origin];
        if (!existing) { added++; continue; }
        if ([existing isEqual:incoming]) identical++; else conflict++;
    }
    return @{FDMBackupCountAdded: @(added), FDMBackupCountIdentical: @(identical),
             FDMBackupCountConflict: @(conflict), FDMBackupCountDowngraded: @(downgraded),
             FDMBackupCountDisabled: @0, FDMBackupCountUnsupported: @0};
}

- (id)stageMergeValidated:(id)validated replace:(BOOL)replace error:(NSError **)error {
    NSDictionary *snapshot = FDMSitePolicyStore.shared.transactionSnapshot;
    NSDictionary *before = FDMJSONObjectValue(FDMJSONParseData(FDMJSONCanonicalData(snapshot, NULL), NULL)) ?: snapshot;
    NSMutableDictionary *origins = replace ? [NSMutableDictionary dictionary]
                                           : ([before[@"origins"] mutableCopy] ?: [NSMutableDictionary dictionary]);
    for (NSString *origin in validated[@"origins"]) {
        NSDictionary *incoming = validated[@"origins"][origin];
        if (!replace) {
            NSDictionary *existing = origins[origin];
            // keep-local: an identical entry is a no-op, a differing entry keeps the local value.
            if (existing) continue;
        }
        origins[origin] = incoming;
    }
    unsigned long long revision = [before[@"revision"] unsignedLongLongValue];
    BOOL changed = ![origins isEqual:before[@"origins"]];
    if (changed && revision >= 9007199254740991ULL) { if (error) *error = FDMRepoError(@"站点版本已到上限，未改配置"); return nil; }
    NSDictionary *after = @{@"schemaVersion": @1, @"revision": @(revision + (changed ? 1 : 0)), @"origins": origins};
    NSData *afterPayload = FDMJSONCanonicalData(after, error);
    if (!afterPayload) return nil;
    FDMBackupPolicyStagedSet *staged = [[FDMBackupPolicyStagedSet alloc] init];
    staged.beforeDocument = before;
    staged.afterDocument = after;
    staged.expectedRevision = revision;
    staged.afterRevision = [after[@"revision"] unsignedLongLongValue];
    staged.exactBeforeDocument = before;
    staged.beforeSnapshot = FDMJSONCanonicalData(before, NULL) ?: [NSData data];
    staged.afterSnapshot = afterPayload;
    return staged;
}

- (NSData *)commitStaged:(id)staged error:(NSError **)error {
    FDMBackupPolicyStagedSet *set = staged;
    if (![set isKindOfClass:FDMBackupPolicyStagedSet.class]) { if (error) *error = FDMRepoError(@"暂存集无效"); return nil; }
    // The store performs its own atomic write and revision check; a concurrent change is refused.
    // publish:YES notifies the host once, which is what a user-visible restore wants.
    if (FDMSitePolicyStore.shared.revision != set.expectedRevision) { if (error) *error = FDMRepoError(@"站点规则在暂存后已改变，请重新预览"); return nil; }
    if (![FDMSitePolicyStore.shared restoreDocument:set.afterDocument publish:NO error:error]) return nil;
    return set.afterSnapshot;
}

// Restores an exact policy document. This deliberately does NOT go through validateImportPayload,
// because that path downgrades camera/microphone "allow" to "ask". A rollback must put back the
// bytes that were there before, including original permissions and the original revision.
- (id)stageRestoreSnapshot:(NSData *)snapshot error:(NSError **)error {
    id root = FDMJSONParseData(snapshot, error);
    if (!root) return nil;
    // Strict structural validation, but without the import-time permission downgrade.
    NSDictionary *document = FDMSitePolicyValidateDocument(root, error);
    if (!document) return nil;
    NSDictionary *before = FDMSitePolicyStore.shared.transactionSnapshot;
    unsigned long long beforeRevision = [before[@"revision"] unsignedLongLongValue];
    // The store's write path increments the revision, so we stage the exact target revision and let
    // the caller's expected value be the live one.
    NSDictionary *after = document;
    FDMBackupPolicyStagedSet *staged = [[FDMBackupPolicyStagedSet alloc] init];
    staged.beforeDocument = before;
    staged.afterDocument = after;
    staged.expectedRevision = beforeRevision;
    staged.afterRevision = beforeRevision + 1;
    staged.exactBeforeDocument = before;
    staged.beforeSnapshot = FDMJSONCanonicalData(before, NULL) ?: [NSData data];
    staged.afterSnapshot = snapshot;
    return staged;
}

- (NSData *)recoverySnapshotWithError:(NSError **)error { return [self exportSnapshotWithRevision:NULL error:error]; }
- (BOOL)restoreRecoverySnapshot:(NSData *)snapshot error:(NSError **)error {
    NSDictionary *document = FDMSitePolicyValidateDocument(FDMJSONParseData(snapshot, error), error);
    return document && [FDMSitePolicyStore.shared restoreDocument:document publish:NO error:error];
}
- (BOOL)rollbackStaged:(id)staged error:(NSError **)error {
    FDMBackupPolicyStagedSet *set = staged;
    if (![set isKindOfClass:FDMBackupPolicyStagedSet.class]) { if (error) *error = FDMRepoError(@"暂存集无效"); return NO; }
    // restoreDocument:publish: writes the exact document, so the original revision and the original
    // camera/microphone Allow values come back unchanged. No import normalization is applied.
    NSDictionary *exact = set.exactBeforeDocument ?: set.beforeDocument;
    if (!exact) { if (error) *error = FDMRepoError(@"原站点策略快照不可用，回滚未完成"); return NO; }
    if (![FDMSitePolicyStore.shared restoreDocument:exact publish:NO error:error]) return NO;
    NSDictionary *live = FDMSitePolicyStore.shared.transactionSnapshot;
    if (![live[@"origins"] isEqual:(exact[@"origins"] ?: @{})]) {
        if (error) *error = FDMRepoError(@"站点策略回滚读回不一致");
        return NO;
    }
    return YES;
}

- (void)reloadHostCache {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:FDMSitePolicyDidChangeNotification object:nil];
    });
}

- (BOOL)verifyCommittedStateWithError:(NSError **)error {
    if (!FDMSitePolicyStore.shared.writable) {
        if (error) *error = FDMRepoError(@"站点规则文件不可写");
        return NO;
    }
    // The store always increments the revision, so completeness is judged on the origins only.
    NSDictionary *snapshot = FDMSitePolicyStore.shared.transactionSnapshot;
    NSDictionary *origins = FDMJSONObjectValue(snapshot[@"origins"]);
    if (!origins) { if (error) *error = FDMRepoError(@"站点规则读回失败"); return NO; }
    return YES;
}
@end
