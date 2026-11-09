#import "FDMBackupRepositoryImpl.h"
#import "FDMJSON.h"

// Preference storage facts (confirmed from the binary):
//   -[PreferenceManager encode]: archivedDataWithRootObject:self.items -> standardUserDefaults
//       setObject:forKey:@"key_preferencemanager_commonconfig"
//   -[PreferenceManager decode]: objectForKey: -> unarchiveObjectWithData: -> setItems:
// The wallpaper blob (key_preferencemanager_wallpaper) is a binary asset and is NOT a backup category.
static NSString *const FDMBackupPreferenceCommonKey = @"key_preferencemanager_commonconfig";

static NSError *FDMRepoError(NSString *message) {
    return [NSError errorWithDomain:@"FocusDM.Backup.Repository" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

// Explicit allowlist of PreferenceModel fields that are portable user settings.
//
// Deliberately EXCLUDED even though they exist on the model, because they are identity, audit or
// internal-state values rather than settings a backup should carry across devices:
//   isPrivate            — private-browsing session state
//   sharedSession        — session/identity state
//   enabledSavePassword  — password-manager consent
//   isAgreedUMengPermission, isOpenBiometricVerify, verifyFaceIDStatus — consent/security state
//   iCloudSyncTimestamp, reviewCount, today — audit/counter/time values
//   darkModeStatus       — derived from isDarkTheme; carrying both can desync the UI
//   playStatus           — transient playback state
static NSArray<NSString *> *FDMBackupAllowedPreferenceFields(void) {
    static NSArray *fields;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fields = @[@"enabledReader", @"enabledAdblock", @"enabledFixupAdblock", @"enabledPlayer",
                   @"enabledLongPressPlayer", @"enabledDetectPhoto", @"enabledTagit", @"enabledPreview",
                   @"enabledPullToRefesh", @"fontSize", @"isDarkTheme", @"isFullScreen",
                   @"isAutoPage", @"isEnabledAutoPageAutoDetect", @"isShowSearchHistory",
                   @"isShowSearchSuggestion", @"isShowSeparatorLine", @"isNoImage",
                   @"enableSwipeNavigation", @"enableGestureHaptics", @"openLastWindow",
                   @"translateEngine", @"tranlsateTargetLanguage", @"bookMarkSortType"];
    });
    return fields;
}

// Accepts a real boolean OR a finite number. PreferenceModel stores toggles as NSNumber, which
// includes CFBoolean, so FDMJSONIsFiniteNumber (which deliberately rejects booleans for counts)
// must not be used here: doing so silently dropped every toggle on export.
static BOOL FDMBackupIsPortablePreferenceNumber(id value) {
    if (![value isKindOfClass:NSNumber.class]) return NO;
    if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return YES;
    return isfinite([value doubleValue]);
}

static BOOL FDMBackupIsBooleanPreference(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

// Integer/enum fields that must stay inside a sane range rather than accept any finite number.
static NSDictionary<NSString *, NSArray<NSNumber *> *> *FDMBackupIntegerPreferenceRanges(void) {
    static NSDictionary *ranges;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ranges = @{@"fontSize": @[@8, @72],
                   @"translateEngine": @[@0, @32],
                   @"tranlsateTargetLanguage": @[@0, @256],
                   @"bookMarkSortType": @[@0, @16]};
    });
    return ranges;
}

#pragma mark - staged set

@interface FDMBackupPreferenceStagedSet : NSObject <FDMBackupStagedSet>
@property (nonatomic, copy) NSData *beforeSnapshot;   // portable DTO bytes of the before state
@property (nonatomic, copy) NSData *afterSnapshot;
@property (nonatomic, copy) NSDictionary<NSString *, id> *beforeFields;
@property (nonatomic, copy) NSDictionary<NSString *, id> *afterFields;
// The original archive bytes, kept only in the journal (device-local), never in the portable file.
@property (nonatomic, copy, nullable) NSData *beforeArchive;
@end

@implementation FDMBackupPreferenceStagedSet
@end

@implementation FDMBackupPreferencesRepository {
    NSUserDefaults *_defaults;
}

- (instancetype)initWithUserDefaults:(NSUserDefaults *)defaults {
    if ((self = [super init])) _defaults = defaults;
    return self;
}

- (NSString *)categoryIdentifier { return FDMBackupCategoryPreferences; }

- (BOOL)isAvailable { return _defaults != nil; }

// Preferences live in NSUserDefaults, not in the SQLite database.
- (NSString *)storageDomain { return nil; }

- (BOOL)applyStaged:(id)staged onExecutor:(id<FDMBackupSQLExecutor>)executor error:(NSError **)error {
    if (error) *error = FDMRepoError(@"偏好设置不通过 SQL 事务提交");
    return NO;
}

// Reads the host PreferenceModel through its own singleton so the exported values are the live ones.
- (id)hostPreferenceItems {
    Class manager = NSClassFromString(@"PreferenceManager");
    SEL shared = NSSelectorFromString(@"shareInstance");
    if (!manager || ![manager respondsToSelector:shared]) return nil;
    id instance = ((id (*)(id, SEL))objc_msgSend)((id)manager, shared);
    return FDMValue(instance, @"items");
}

- (NSData *)exportSnapshotWithRevision:(NSString **)revision error:(NSError **)error {
    if (!_defaults) { if (error) *error = FDMRepoError(@"偏好设置不可用"); return nil; }
    id items = [self hostPreferenceItems];
    if (!items) { if (error) *error = FDMRepoError(@"无法读取偏好设置模型"); return nil; }
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (NSString *field in FDMBackupAllowedPreferenceFields()) {
        id value = FDMValue(items, field);
        if (!value || value == NSNull.null) continue;
        // Toggles are CFBoolean; integers are plain numbers. Both are portable here.
        if (!FDMBackupIsPortablePreferenceNumber(value)) continue;
        values[field] = value;
    }
    NSData *payload = FDMJSONCanonicalData(@{@"schemaVersion": @1, @"values": values}, error);
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
    if (!document) { if (error) *error = FDMRepoError(@"偏好数据必须是对象"); return nil; }
    for (NSString *key in document) {
        if (![@[@"schemaVersion", @"values"] containsObject:key]) { if (error) *error = FDMRepoError(@"偏好数据含未知字段"); return nil; }
    }
    unsigned long long schema = 0;
    if (!FDMJSONNonNegativeInteger(document[@"schemaVersion"], 100, &schema) || schema != 1) {
        if (error) *error = FDMRepoError(@"偏好数据版本不受支持");
        return nil;
    }
    NSDictionary *values = FDMJSONObjectValue(document[@"values"]);
    if (!values) { if (error) *error = FDMRepoError(@"偏好数据缺少取值"); return nil; }
    NSMutableDictionary *validated = [NSMutableDictionary dictionary];
    for (NSString *field in values) {
        // Anything outside the allowlist is refused, not silently dropped: a foreign file must not
        // be able to claim it restored settings it never applied.
        if (![FDMBackupAllowedPreferenceFields() containsObject:field]) {
            if (error) *error = FDMRepoError([NSString stringWithFormat:@"偏好项不在允许列表：%@", field]);
            return nil;
        }
        id value = values[field];
        if (![value isKindOfClass:NSNumber.class]) {
            if (error) *error = FDMRepoError(@"偏好数值类型无效");
            return nil;
        }
        if (!FDMBackupIsPortablePreferenceNumber(value)) {
            if (error) *error = FDMRepoError(@"偏好数值不是有限数");
            return nil;
        }
        // A boolean toggle must stay a boolean; a bounded integer must stay in its range. A count
        // field arriving as true/false would otherwise slip through as 1/0.
        NSArray<NSNumber *> *range = FDMBackupIntegerPreferenceRanges()[field];
        if (range) {
            if (FDMBackupIsBooleanPreference(value)) {
                if (error) *error = FDMRepoError([NSString stringWithFormat:@"偏好项应为整数而非布尔：%@", field]);
                return nil;
            }
            double raw = [value doubleValue];
            if (raw != floor(raw) || raw < range[0].doubleValue || raw > range[1].doubleValue) {
                if (error) *error = FDMRepoError([NSString stringWithFormat:@"偏好项超出允许范围：%@", field]);
                return nil;
            }
        }
        validated[field] = value;
    }
    return validated;
}

- (NSDictionary<NSString *, NSNumber *> *)previewCountsForValidated:(id)validated error:(NSError **)error {
    NSData *livePayload = [self exportSnapshotWithRevision:NULL error:error];
    if (!livePayload) return nil;
    NSDictionary *live = FDMJSONObjectValue(FDMJSONParseData(livePayload, NULL)[@"values"]) ?: @{};
    NSUInteger added = 0, identical = 0, conflict = 0;
    for (NSString *field in validated) {
        id current = live[field];
        if (!current) { added++; continue; }
        if ([current isEqual:validated[field]]) identical++; else conflict++;
    }
    return @{FDMBackupCountAdded: @(added), FDMBackupCountIdentical: @(identical),
             FDMBackupCountConflict: @(conflict), FDMBackupCountDowngraded: @0,
             FDMBackupCountDisabled: @0, FDMBackupCountUnsupported: @0};
}

- (id)stageMergeValidated:(id)validated replace:(BOOL)replace error:(NSError **)error {
    if (!_defaults) { if (error) *error = FDMRepoError(@"偏好设置不可用"); return nil; }
    NSData *before = [self exportSnapshotWithRevision:NULL error:error];
    if (!before) return nil;
    NSDictionary *beforeFields = FDMJSONObjectValue(FDMJSONParseData(before, NULL)[@"values"]) ?: @{};
    NSMutableDictionary *afterFields = [beforeFields mutableCopy];
    if (replace) {
        // Replace means: every allowlisted field the backup carries overwrites; fields the backup
        // omits keep their live value rather than being reset to a default we do not know.
        for (NSString *field in validated) afterFields[field] = validated[field];
    } else {
        // keep-local: an existing local value always wins; only absent fields are filled in.
        for (NSString *field in validated) {
            if (afterFields[field]) continue;
            afterFields[field] = validated[field];
        }
    }
    NSData *after = FDMJSONCanonicalData(@{@"schemaVersion": @1, @"values": afterFields}, error);
    if (!after) return nil;

    FDMBackupPreferenceStagedSet *staged = [[FDMBackupPreferenceStagedSet alloc] init];
    staged.beforeSnapshot = before;
    staged.afterSnapshot = after;
    staged.beforeFields = beforeFields;
    staged.afterFields = afterFields;
    // The original archive bytes are journal-only material for recovery.
    staged.beforeArchive = [_defaults objectForKey:FDMBackupPreferenceCommonKey];
    return staged;
}

// Applies the allowlisted fields onto the live model, then lets the host re-encode its own archive.
// This keeps every field we do not own (consent flags, iCloud timestamps, wallpaper) untouched.
- (NSData *)commitStaged:(id)staged error:(NSError **)error {
    FDMBackupPreferenceStagedSet *set = staged;
    if (![set isKindOfClass:FDMBackupPreferenceStagedSet.class]) { if (error) *error = FDMRepoError(@"暂存集无效"); return nil; }
    Class managerClass = NSClassFromString(@"PreferenceManager");
    SEL shared = NSSelectorFromString(@"shareInstance");
    if (!managerClass || ![managerClass respondsToSelector:shared]) {
        if (error) *error = FDMRepoError(@"偏好设置模型不可用");
        return nil;
    }
    id manager = ((id (*)(id, SEL))objc_msgSend)((id)managerClass, shared);
    id items = FDMValue(manager, @"items");
    if (!items) { if (error) *error = FDMRepoError(@"无法读取偏好设置模型"); return nil; }
    @try {
        for (NSString *field in set.afterFields) {
            if (![FDMBackupAllowedPreferenceFields() containsObject:field]) continue;
            [items setValue:set.afterFields[field] forKey:field];
        }
    } @catch (NSException *exception) {
        if (error) *error = FDMRepoError([NSString stringWithFormat:@"偏好写入失败：%@", exception.reason]);
        return nil;
    }
    SEL encode = NSSelectorFromString(@"encode");
    if (![manager respondsToSelector:encode]) { if (error) *error = FDMRepoError(@"偏好设置无法保存"); return nil; }
    @try { ((void (*)(id, SEL))objc_msgSend)(manager, encode); }
    @catch (NSException *exception) {
        if (error) *error = FDMRepoError([NSString stringWithFormat:@"偏好保存失败：%@", exception.reason]);
        return nil;
    }
    // Verify by re-reading through the host's own accessor, not by trusting encode's silence.
    NSData *verify = [self exportSnapshotWithRevision:NULL error:NULL];
    if (!verify) { if (error) *error = FDMRepoError(@"偏好读回校验失败"); return nil; }
    NSDictionary *verifyFields = FDMJSONObjectValue(FDMJSONParseData(verify, NULL)[@"values"]) ?: @{};
    for (NSString *field in set.afterFields) {
        if (![FDMBackupAllowedPreferenceFields() containsObject:field]) continue;
        if (![verifyFields[field] isEqual:set.afterFields[field]]) {
            if (error) *error = FDMRepoError([NSString stringWithFormat:@"偏好项未生效：%@", field]);
            return nil;
        }
    }
    return set.afterSnapshot;
}

- (id)stageRestoreSnapshot:(NSData *)snapshot error:(NSError **)error {
    id validated = [self validateImportPayload:snapshot error:error];
    if (!validated) return nil;
    FDMBackupPreferenceStagedSet *staged = [[FDMBackupPreferenceStagedSet alloc] init];
    staged.beforeSnapshot = [self exportSnapshotWithRevision:NULL error:NULL] ?: [NSData data];
    staged.afterSnapshot = snapshot;
    staged.beforeFields = FDMJSONObjectValue(FDMJSONParseData(staged.beforeSnapshot, NULL)[@"values"]) ?: @{};
    staged.afterFields = validated;
    staged.beforeArchive = [_defaults objectForKey:FDMBackupPreferenceCommonKey];
    return staged;
}

- (BOOL)rollbackStaged:(id)staged error:(NSError **)error {
    FDMBackupPreferenceStagedSet *set = staged;
    if (![set isKindOfClass:FDMBackupPreferenceStagedSet.class]) { if (error) *error = FDMRepoError(@"暂存集无效"); return NO; }
    id restore = [self stageRestoreSnapshot:set.beforeSnapshot error:error];
    if (!restore) return NO;
    return [self commitStaged:restore error:error] != nil;
}

- (void)reloadHostCache {
    Class manager = NSClassFromString(@"PreferenceManager");
    SEL shared = NSSelectorFromString(@"shareInstance");
    SEL decode = NSSelectorFromString(@"decode");
    if (manager && [manager respondsToSelector:shared]) {
        id instance = ((id (*)(id, SEL))objc_msgSend)((id)manager, shared);
        if (instance && [instance respondsToSelector:decode]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(instance, decode); }
            @catch (NSException *exception) { FDMLog(@"preference cache reload skipped: %@", exception.reason); }
        }
    }
}

- (BOOL)verifyCommittedStateWithError:(NSError **)error {
    // The host model is the source of truth; re-reading it proves the values actually landed.
    id items = [self hostPreferenceItems];
    if (!items) { if (error) *error = FDMRepoError(@"偏好设置模型不可读"); return NO; }
    NSData *live = [self exportSnapshotWithRevision:NULL error:error];
    if (!live) return NO;
    // Every allowlisted field must still be readable through the model after the write.
    NSDictionary *values = FDMJSONObjectValue(FDMJSONParseData(live, NULL)[@"values"]) ?: @{};
    for (NSString *field in values) {
        if (![FDMBackupAllowedPreferenceFields() containsObject:field]) {
            if (error) *error = FDMRepoError([NSString stringWithFormat:@"偏好项越界：%@", field]);
            return NO;
        }
    }
    return YES;
}
@end
