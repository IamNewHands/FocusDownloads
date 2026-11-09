#import "FDMBackup.h"
#import "FDMBackupRepositoryImpl.h"
#import "FDMBackupSQL.h"
#import "FDMJSON.h"
#import "FDMPolicy.h"

static NSString *const FDMBackupJournalName = @"backup-journal.json";

static NSError *FDMCoordinatorError(NSString *message) {
    return [NSError errorWithDomain:@"FocusDM.Backup" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

#pragma mark - plan

@interface FDMBackupImportPlan ()
@property (nonatomic, copy) NSString *backupID;
@property (nonatomic, copy) NSArray<NSString *> *categories;
@property (nonatomic) BOOL replace;
@property (nonatomic, copy) NSDictionary<NSString *, id> *validatedByCategory;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *revisionByCategory;
@property (nonatomic, copy) NSDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *countsByCategory;
@property (nonatomic, copy) NSArray<NSString *> *unsupportedCategories;
@end

@implementation FDMBackupImportPlan
@end

#pragma mark - journal

// The journal holds the exact before/after snapshot bytes so recovery never re-derives state.
// It contains only category payloads and identifiers — no request secrets, cookies or file paths.
static NSDictionary *FDMJournalRecord(NSString *transactionID,
                                      NSArray<NSString *> *categories,
                                      NSDictionary<NSString *, NSData *> *before,
                                      NSDictionary<NSString *, NSData *> *after,
                                      NSString *stage) {
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"schemaVersion"] = @1;
    record[@"transactionID"] = transactionID ?: @"";
    record[@"stage"] = stage ?: @"prepared";
    record[@"categories"] = categories ?: @[];
    record[@"createdAt"] = @((long long)NSDate.date.timeIntervalSince1970);
    NSMutableDictionary *beforeMap = [NSMutableDictionary dictionary];
    NSMutableDictionary *afterMap = [NSMutableDictionary dictionary];
    NSMutableDictionary *beforeHash = [NSMutableDictionary dictionary];
    NSMutableDictionary *afterHash = [NSMutableDictionary dictionary];
    for (NSString *category in before) {
        beforeMap[category] = [before[category] base64EncodedStringWithOptions:0];
        beforeHash[category] = FDMBackupSHA256(before[category]) ?: @"";
    }
    for (NSString *category in after) {
        afterMap[category] = [after[category] base64EncodedStringWithOptions:0];
        afterHash[category] = FDMBackupSHA256(after[category]) ?: @"";
    }
    record[@"before"] = beforeMap;
    record[@"after"] = afterMap;
    record[@"beforeSHA256"] = beforeHash;
    record[@"afterSHA256"] = afterHash;
    return record;
}

// Decodes a journal snapshot map, verifying each entry against its recorded hash so a corrupted
// journal cannot drive a restore of arbitrary bytes.
static NSDictionary<NSString *, NSData *> *FDMJournalSnapshots(id rawMap, id rawHashes, NSError **error) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSDictionary *map = FDMJSONObjectValue(rawMap);
    NSDictionary *hashes = FDMJSONObjectValue(rawHashes);
    if (!map) return result;
    for (NSString *category in map) {
        NSString *base64 = FDMJSONStringValue(map[category]);
        if (!base64.length) continue;
        NSData *data = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
        if (!data.length) { if (error) *error = FDMCoordinatorError(@"journal 快照不是有效数据"); return nil; }
        NSString *expected = FDMJSONStringValue(hashes[category]);
        if (expected.length && ![FDMBackupSHA256(data) isEqual:expected]) {
            if (error) *error = FDMCoordinatorError(@"journal 快照校验失败");
            return nil;
        }
        result[category] = data;
    }
    return result;
}

#pragma mark - coordinator

@implementation FDMBackupCoordinator {
    dispatch_queue_t _queue;
    NSMutableDictionary<NSString *, id<FDMBackupRepository>> *_repositories;
    // domain -> the one database object shared by every repository on that domain.
    NSMutableDictionary<NSString *, id<FDMBackupSQLDatabase>> *_domainDatabases;
    NSString *_journalPath;
    NSString *_recoveryNotice;
    // Serializes export, preview and apply so a snapshot epoch cannot interleave with a commit.
    NSLock *_barrier;
}

+ (instancetype)shared {
    static FDMBackupCoordinator *coordinator;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        coordinator = [[self alloc] init];
        [coordinator registerDefaultRepositories];
    });
    return coordinator;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("FocusDM.backup", DISPATCH_QUEUE_SERIAL);
        _repositories = [NSMutableDictionary dictionary];
        _domainDatabases = [NSMutableDictionary dictionary];
        _barrier = [[NSLock alloc] init];
        _journalPath = [FDMDirectory(@"FocusDM") stringByAppendingPathComponent:FDMBackupJournalName];
    }
    return self;
}

- (void)registerDefaultRepositories {
    NSError *error = nil;
    id<FDMBackupSQLDatabase> database = [FDMHostDatabaseQueue hostQueueWithError:&error];
    if (database) {
        // All three SQLite-backed categories receive the same queue object, so the coordinator can
        // hold one transaction across them.
        FDMBackupBookmarkRepository *bookmarks = [[FDMBackupBookmarkRepository alloc] initWithDatabase:database];
        FDMBackupHomeTagRepository *homeTags = [[FDMBackupHomeTagRepository alloc] initWithDatabase:database];
        FDMBackupScriptsRepository *scripts = [[FDMBackupScriptsRepository alloc] initWithDatabase:database];
        [self registerRepository:bookmarks database:database];
        [self registerRepository:homeTags database:database];
        [self registerRepository:scripts database:database];
    } else {
        FDMLog(@"backup: host database unavailable (%@); bookmark/script categories disabled", error.localizedDescription);
    }
    NSUserDefaults *searchDefaults = [FDMBackupSearchRepository hostSearchDefaults];
    if (searchDefaults) [self registerRepository:[[FDMBackupSearchRepository alloc] initWithUserDefaults:searchDefaults]];
    [self registerRepository:[[FDMBackupPreferencesRepository alloc] initWithUserDefaults:NSUserDefaults.standardUserDefaults]];
    [self registerRepository:[[FDMBackupPolicyRepository alloc] init]];
}

- (void)registerRepository:(id<FDMBackupRepository>)repository {
    if (!repository) return;
    NSString *identifier = [repository categoryIdentifier];
    if (!identifier.length) return;
    dispatch_sync(_queue, ^{ self->_repositories[identifier] = repository; });
}

// Registers a repository together with the database object that owns its storage domain. All
// repositories on one domain must receive the same object, otherwise they would open separate
// connections and the coordinator could not hold one transaction across them.
- (void)registerRepository:(id<FDMBackupRepository>)repository database:(id<FDMBackupSQLDatabase>)database {
    if (!repository) return;
    NSString *identifier = [repository categoryIdentifier];
    NSString *domain = [repository storageDomain];
    if (!identifier.length) return;
    dispatch_sync(_queue, ^{
        self->_repositories[identifier] = repository;
        if (domain.length && database) self->_domainDatabases[domain] = database;
    });
}

- (NSArray<NSString *> *)availableCategories {
    __block NSMutableArray *available = [NSMutableArray array];
    dispatch_sync(_queue, ^{
        for (NSString *category in FDMBackupCategoryOrder()) {
            id<FDMBackupRepository> repository = self->_repositories[category];
            if (repository && [repository isAvailable]) [available addObject:category];
        }
    });
    return available;
}

- (id<FDMBackupRepository>)repositoryFor:(NSString *)category {
    __block id<FDMBackupRepository> repository;
    dispatch_sync(_queue, ^{ repository = self->_repositories[category]; });
    return repository;
}

// The database shared by every repository that reports this domain. Bookmarks, home shortcuts and
// scripts all resolve to the host's single FMDatabaseQueue.
- (id<FDMBackupSQLDatabase>)databaseForDomain:(NSString *)domain {
    __block id<FDMBackupSQLDatabase> database;
    dispatch_sync(_queue, ^{ database = self->_domainDatabases[domain]; });
    return database;
}

- (NSData *)exportCategories:(NSArray<NSString *> *)categories error:(NSError **)error {
    if (!categories.count) { if (error) *error = FDMCoordinatorError(@"没有选中任何类别"); return nil; }
    [_barrier lock];
    NSMutableArray *payloads = [NSMutableArray array];
    __block NSError *failure = nil;
    @try {
        for (NSString *category in categories) {
            id<FDMBackupRepository> repository = [self repositoryFor:category];
            if (!repository) { failure = FDMCoordinatorError([NSString stringWithFormat:@"不支持的类别：%@", category]); break; }
            NSData *payload = [repository exportSnapshotWithRevision:NULL error:&failure];
            if (!payload) break;
            id validated = [repository validateImportPayload:payload error:&failure];
            if (!validated) break;
            NSUInteger count = [validated isKindOfClass:NSArray.class] ? [validated count]
                             : ([validated isKindOfClass:NSDictionary.class] ? [validated count] : 0);
            [payloads addObject:[FDMBackupCategory category:category payload:payload itemCount:count]];
        }
    } @finally {
        [_barrier unlock];
    }
    if (failure) { if (error) *error = failure; return nil; }
    if (!payloads.count) { if (error) *error = FDMCoordinatorError(@"没有可导出的类别"); return nil; }
    return FDMBackupEncode(payloads, FDMPatchVersion(), error);
}

- (FDMBackupContainer *)openBackupAtURL:(NSURL *)url error:(NSError **)error {
    if (!url.isFileURL) { if (error) *error = FDMCoordinatorError(@"只能导入本地备份文件"); return nil; }
    NSNumber *size = nil;
    [url getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
    if (size && size.unsignedLongLongValue > FDMBackupMaxFileBytes) {
        if (error) *error = FDMCoordinatorError(@"备份文件超出 32 MiB 上限");
        return nil;
    }
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:error];
    if (!data.length) { if (error && !*error) *error = FDMCoordinatorError(@"无法读取备份文件"); return nil; }
    return FDMBackupDecode(data, error);
}

- (FDMBackupImportPlan *)previewContainer:(FDMBackupContainer *)container
                               categories:(NSArray<NSString *> *)categories
                                  replace:(BOOL)replace
                                    error:(NSError **)error {
    if (!container || !categories.count) { if (error) *error = FDMCoordinatorError(@"没有选中任何类别"); return nil; }
    [_barrier lock];
    NSMutableDictionary *validated = [NSMutableDictionary dictionary];
    NSMutableDictionary *revisions = [NSMutableDictionary dictionary];
    NSMutableDictionary *counts = [NSMutableDictionary dictionary];
    NSMutableArray *usable = [NSMutableArray array];
    NSMutableArray *unsupported = [container.unsupportedCategories mutableCopy] ?: [NSMutableArray array];
    NSError *failure = nil;
    @try {
        for (NSString *category in categories) {
            id<FDMBackupRepository> repository = [self repositoryFor:category];
            FDMBackupCategory *entry = container.categories[category];
            if (!repository || !entry || ![repository isAvailable]) {
                if (![unsupported containsObject:category]) [unsupported addObject:category];
                continue;
            }
            id dto = [repository validateImportPayload:entry.payload error:&failure];
            if (!dto) break;
            NSString *revision = [repository currentRevisionWithError:&failure];
            if (!revision) break;
            NSDictionary *categoryCounts = [repository previewCountsForValidated:dto error:&failure];
            if (!categoryCounts) break;
            validated[category] = dto;
            revisions[category] = revision;
            counts[category] = categoryCounts;
            [usable addObject:category];
        }
    } @finally {
        [_barrier unlock];
    }
    if (failure) { if (error) *error = failure; return nil; }
    if (!usable.count) {
        if (error) *error = FDMCoordinatorError(@"备份中没有本版本可恢复的类别");
        return nil;
    }
    FDMBackupImportPlan *plan = [[FDMBackupImportPlan alloc] init];
    plan.backupID = container.backupID;
    plan.categories = usable;
    plan.replace = replace;
    plan.validatedByCategory = validated;
    plan.revisionByCategory = revisions;
    plan.countsByCategory = counts;
    plan.unsupportedCategories = unsupported;
    return plan;
}

- (BOOL)applyPlan:(FDMBackupImportPlan *)plan error:(NSError **)error {
    if (!plan.categories.count) { if (error) *error = FDMCoordinatorError(@"计划中没有可恢复的类别"); return NO; }
    // A leftover journal means a previous restore did not reach its committed marker. Recovering it
    // first is mandatory: applying a new plan on top of a half-restored state would compound it.
    [self recoverInterruptedTransaction];
    if (_recoveryNotice.length) {
        if (error) *error = FDMCoordinatorError(_recoveryNotice);
        return NO;
    }

    [_barrier lock];
    NSString *transactionID = NSUUID.UUID.UUIDString;
    NSMutableArray *staged = [NSMutableArray array];
    NSMutableDictionary *beforeMap = [NSMutableDictionary dictionary];
    NSMutableDictionary *afterMap = [NSMutableDictionary dictionary];
    NSError *failure = nil;
    @try {
        // Re-check the revision captured at preview: a concurrent local change must force a new preview.
        for (NSString *category in plan.categories) {
            id<FDMBackupRepository> repository = [self repositoryFor:category];
            NSString *expected = plan.revisionByCategory[category];
            NSString *current = [repository currentRevisionWithError:&failure];
            if (!current) break;
            if (expected && ![current isEqual:expected]) {
                failure = FDMCoordinatorError([NSString stringWithFormat:@"%@ 在预览后已被修改，请重新预览", FDMBackupCategoryTitle(category)]);
                break;
            }
            id set = [repository stageMergeValidated:plan.validatedByCategory[category] replace:plan.replace error:&failure];
            if (!set) break;
            [staged addObject:@{@"category": category, @"repository": repository, @"set": set}];
            beforeMap[category] = [set beforeSnapshot] ?: [NSData data];
            afterMap[category] = [set afterSnapshot] ?: [NSData data];
        }
    } @catch (NSException *exception) {
        failure = FDMCoordinatorError([NSString stringWithFormat:@"暂存失败：%@", exception.reason]);
    }
    // NOTE: the barrier stays held from here until the committed marker is written. Releasing it
    // earlier would let a reader observe the database committed but preferences/policy not yet
    // applied — a half-published configuration.
    if (failure) { [_barrier unlock]; if (error) *error = failure; return NO; }

    // Persist the journal before touching live state, so any crash has a defined recovery path.
    NSDictionary *journal = FDMJournalRecord(transactionID, plan.categories, beforeMap, afterMap, @"prepared");
    NSError *journalError = nil;
    if (!FDMWriteJSON(journal, _journalPath, &journalError)) {
        // Nothing was written to live state, so the barrier can be released immediately.
        [_barrier unlock];
        if (error) *error = journalError;
        return NO;
    }

    NSMutableArray *committed = [NSMutableArray array];
    BOOL ok = YES;
    // Categories that share a storage domain must commit in ONE transaction: separate transactions
    // would let a reader observe a half-applied restore (bookmarks written, scripts not).
    NSMutableDictionary<NSString *, NSMutableArray *> *groups = [NSMutableDictionary dictionary];
    NSMutableArray *independent = [NSMutableArray array];
    for (NSDictionary *step in staged) {
        id<FDMBackupRepository> repository = step[@"repository"];
        NSString *domain = [repository storageDomain];
        if (!domain.length) { [independent addObject:step]; continue; }
        NSMutableArray *group = groups[domain];
        if (!group) { group = [NSMutableArray array]; groups[domain] = group; }
        [group addObject:step];
    }

    // One held queue entry and one transaction for the whole shared-domain batch. Committing each
    // category separately would let a reader see bookmarks restored but scripts not.
    for (NSString *domain in groups) {
        NSArray *group = groups[domain];
        id<FDMBackupSQLDatabase> database = [self databaseForDomain:domain];
        if (!database) {
            ok = NO;
            failure = FDMCoordinatorError([NSString stringWithFormat:@"数据库不可用：%@", domain]);
            break;
        }
        id<FDMBackupSQLBatchDatabase> batch = (id<FDMBackupSQLBatchDatabase>)database;
        if (![batch respondsToSelector:@selector(performAtomicBatch:error:)]) {
            ok = NO;
            failure = FDMCoordinatorError(@"数据库不支持整批事务");
            break;
        }
        __block BOOL groupOK = NO;
        __block NSError *groupError = nil;
        BOOL entered = [batch performAtomicBatch:^(id<FDMBackupSQLAtomicAccess> access) {
            NSError *inner = nil;
            for (NSDictionary *step in group) {
                id<FDMBackupRepository> repository = step[@"repository"];
                if (![repository applyStaged:step[@"set"] onExecutor:[access executor] error:&inner]) {
                    groupError = inner;
                    [access rollback];
                    return;
                }
            }
            NSError *commitError = nil;
            if (![access commitWithError:&commitError]) {
                groupError = commitError;
                return;
            }
            groupOK = YES;
        } error:&groupError];
        if (!entered || !groupOK) { ok = NO; failure = groupError ?: FDMCoordinatorError(@"批次事务未提交"); break; }
        for (NSDictionary *step in group) [committed addObject:step];
    }
    // Independent stores (NSUserDefaults, policy file) commit through their own atomic path.
    if (ok) {
        for (NSDictionary *step in independent) {
            id<FDMBackupRepository> repository = step[@"repository"];
            NSError *commitError = nil;
            NSData *after = [repository commitStaged:step[@"set"] error:&commitError];
            if (!after) {
                ok = NO;
                failure = commitError;
                // A repository whose commit failed may still have changed part of its store (for
                // example NSUserDefaults written then a verification read failing). It must be part
                // of the rollback set, otherwise its half-applied state survives the restore.
                [committed addObject:step];
                break;
            }
            [committed addObject:step];
        }
    }
    if (ok) {
        // Read-back verification: the committed state must match the plan's after snapshot, and each
        // repository must prove its own store is complete (e.g. a script's generated .js exists).
        for (NSDictionary *step in staged) {
            id<FDMBackupRepository> repository = step[@"repository"];
            NSString *category = step[@"category"];
            NSData *live = [repository exportSnapshotWithRevision:NULL error:&failure];
            if (!live) { ok = NO; break; }
            NSData *expected = afterMap[category];
            // The site policy store owns a monotonic revision that advances on every write, so its
            // snapshot can never be byte-identical; that category verifies through its own hook.
            BOOL revisionBearing = [category isEqual:FDMBackupCategorySitePolicies];
            if (expected.length && !revisionBearing && ![live isEqualToData:expected]) {
                ok = NO;
                failure = FDMCoordinatorError([NSString stringWithFormat:@"%@ 提交后读回不一致", FDMBackupCategoryTitle(category)]);
                break;
            }
            if (![repository verifyCommittedStateWithError:&failure]) {
                ok = NO;
                if (!failure) failure = FDMCoordinatorError([NSString stringWithFormat:@"%@ 提交后完整性校验失败", FDMBackupCategoryTitle(category)]);
                break;
            }
        }
    }

    if (!ok) {
        BOOL rolledBack = [self rollbackCommitted:committed error:NULL];
        NSMutableDictionary *updated = [journal mutableCopy];
        updated[@"stage"] = rolledBack ? @"rolledBack" : @"rollbackFailed";
        FDMWriteJSON(updated, _journalPath, nil);
        if (rolledBack) {
            [[NSFileManager defaultManager] removeItemAtPath:_journalPath error:nil];
        } else {
            // Keep the journal: it is the only record of what still needs restoring.
            _recoveryNotice = @"恢复失败且回滚未完成；已保留保护状态，请重启应用后重试或重新导入原备份";
        }
        [_barrier unlock];
        if (error) *error = failure ?: FDMCoordinatorError(@"导入未完成，已回滚");
        return NO;
    }

    NSMutableDictionary *done = [journal mutableCopy];
    done[@"stage"] = @"committed";
    NSError *markerError = nil;
    if (!FDMWriteJSON(done, _journalPath, &markerError)) {
        // A failed committed marker means a restart would restore the before state; that is only
        // safe if we roll back now, so the on-disk state matches the recorded before snapshot.
        BOOL rolledBack = [self rollbackCommitted:committed error:NULL];
        if (!rolledBack) _recoveryNotice = @"提交标记写入失败且回滚未完成；已保留保护状态";
        [_barrier unlock];
        if (error) *error = markerError;
        return NO;
    }

    // The marker is written: the restore is durable. Release the barrier before the host cache
    // refresh so a reload that re-enters the coordinator cannot deadlock.
    [_barrier unlock];

    // Publish once, then refresh each host cache outside the transaction.
    for (NSDictionary *step in staged) {
        @try { [step[@"repository"] reloadHostCache]; }
        @catch (NSException *exception) { FDMLog(@"backup cache reload skipped: %@", exception.reason); }
    }
    [[NSFileManager defaultManager] removeItemAtPath:_journalPath error:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:FDMBackupDidChangeNotification object:nil];
    });
    return YES;
}

- (BOOL)rollbackCommitted:(NSArray<NSDictionary *> *)committed error:(NSError **)error {
    BOOL allRestored = YES;
    // Newest first: a later category may depend on an earlier one's rows.
    for (NSDictionary *step in [committed reverseObjectEnumerator]) {
        id<FDMBackupRepository> repository = step[@"repository"];
        NSError *rollbackError = nil;
        if (![repository rollbackStaged:step[@"set"] error:&rollbackError]) {
            allRestored = NO;
            FDMLog(@"backup rollback failed for %@: %@", step[@"category"], rollbackError.localizedDescription);
        }
    }
    if (!allRestored && error) *error = FDMCoordinatorError(@"回滚未完成");
    return allRestored;
}

- (void)recoverInterruptedTransaction {
    id raw = FDMReadJSON(_journalPath, nil);
    if (![raw isKindOfClass:NSDictionary.class]) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:_journalPath]) {
            _recoveryNotice = @"上次恢复事务记录无法读取；已保留原配置，请检查后重试";
        }
        return;
    }
    NSDictionary *journal = raw;
    NSString *stage = FDMJSONStringValue(journal[@"stage"]);
    if ([stage isEqual:@"committed"]) {
        // The commit finished; only the marker cleanup was interrupted.
        [[NSFileManager defaultManager] removeItemAtPath:_journalPath error:nil];
        _recoveryNotice = nil;
        return;
    }
    NSArray *categories = FDMJSONArrayValue(journal[@"categories"]) ?: @[];
    NSError *decodeError = nil;
    NSDictionary *before = FDMJournalSnapshots(journal[@"before"], journal[@"beforeSHA256"], &decodeError);
    if (!before || decodeError) {
        // Without a trustworthy before snapshot we must not guess; keep protection state.
        _recoveryNotice = @"上次恢复事务的前像无法校验；已保留原配置与事务记录，请重新导入原备份";
        return;
    }
    BOOL restoredAll = YES;
    for (NSString *category in categories) {
        id<FDMBackupRepository> repository = [self repositoryFor:category];
        NSData *snapshot = before[category];
        if (!repository || !snapshot) { restoredAll = NO; continue; }
        NSError *restoreError = nil;
        id staged = [repository stageRestoreSnapshot:snapshot error:&restoreError];
        if (!staged) { restoredAll = NO; FDMLog(@"backup recovery staging failed for %@", category); continue; }
        if (![repository commitStaged:staged error:&restoreError]) {
            restoredAll = NO;
            FDMLog(@"backup recovery failed for %@: %@", category, restoreError.localizedDescription);
        }
    }
    if (restoredAll) {
        for (NSString *category in categories) {
            id<FDMBackupRepository> repository = [self repositoryFor:category];
            @try { [repository reloadHostCache]; }
            @catch (NSException *exception) { FDMLog(@"backup recovery cache reload skipped: %@", exception.reason); }
        }
        [[NSFileManager defaultManager] removeItemAtPath:_journalPath error:nil];
        _recoveryNotice = @"上次数据恢复未完成，已回到恢复前的配置";
    } else {
        // Keep the journal: deleting it here would be a fake successful rollback.
        _recoveryNotice = @"上次数据恢复未能完整回滚；已保留事务记录与保护状态，请重启后重试";
    }
}

- (NSString *)recoveryNotice { return _recoveryNotice; }
@end
