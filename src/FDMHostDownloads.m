#import "FDMHostDownloads.h"
#import "FDMStore.h"

static const void *FDMHostTaskKey = &FDMHostTaskKey;

FDMState FDMHostProjectedState(NSInteger status, BOOL pauseIntent) {
    if (status == 6) return FDMStateCompleted;
    if (pauseIntent && status != 5 && status != 9) return FDMStatePaused;
    switch (status) {
        case 0: case 1: case 7: return FDMStateDownloading;
        case 2: return FDMStatePaused;
        case 3: case 4: return FDMStateFailed;
        case 8: return FDMStateInterrupted;
        default: return FDMStateInterrupted;
    }
}

static BOOL FDMHostValuesEqual(id a, id b) { return a == b || [a isEqual:b]; }

static BOOL FDMHostIdentityMatches(NSDictionary *expected, NSDictionary *current) {
    return expected && current && [expected[@"device"] isEqual:current[@"device"]] &&
        [expected[@"inode"] isEqual:current[@"inode"]] && [expected[@"size"] isEqual:current[@"size"]];
}

NSDictionary *FDMHostProjectTask(id task, NSString *key, BOOL pauseIntent, NSDictionary *previous) {
    NSMutableDictionary *row = [NSMutableDictionary dictionary];
    row[@"schema"] = @2;
    row[@"source"] = @1;
    row[@"key"] = key;
    row[@"time"] = previous[@"time"] ?: @(NSDate.date.timeIntervalSince1970);
    row[@"url"] = FDMString(FDMValue(task, @"url")) ?: FDMString(previous[@"url"]) ?: @"";
    NSString *name = FDMString(FDMValue(task, @"fileName"));
    row[@"name"] = name.length ? name : (FDMString(previous[@"name"]) ?: @"未命名文件");
    id raw = FDMValue(task, @"status");
    NSInteger status = [raw isKindOfClass:NSNumber.class] ? [raw integerValue] : -1;
    row[@"hostStatus"] = @(status);
    row[@"state"] = @(FDMHostProjectedState(status, pauseIntent));
    row[@"canResume"] = @NO;
    row[@"pauseIntent"] = @(pauseIntent);
    row[@"pausing"] = @((pauseIntent && (status == 0 || status == 1 || status == 7 || status == 8)) || status == 8 || status == 9);
    if (!pauseIntent && status == 8) row[@"statusDetail"] = @"宿主正在取消，请等待最终结果";
    row[@"speed"] = @(MAX(0, FDMDouble(task, @"speed")));
    row[@"progress"] = @(FDMProgressOfTask(task));
    NSProgress *progress = FDMValue(task, @"progress");
    long long received = [progress isKindOfClass:NSProgress.class] ? MAX(0, progress.completedUnitCount) : 0;
    long long total = [progress isKindOfClass:NSProgress.class] ? MAX(0, progress.totalUnitCount) : 0;
    NSURLResponse *response = FDMValue(task, @"response");
    if (!total && [response isKindOfClass:NSURLResponse.class] && response.expectedContentLength > 0) total = response.expectedContentLength;
    row[@"received"] = @(received);
    row[@"total"] = @(total);
    NSString *path = FDMString(FDMValue(task, @"filePath"));
    if (!path.length) path = FDMString(previous[@"path"]);
    if (path.length) {
        row[@"path"] = path;
        NSString *relative = FDMRelativeDocumentPath(path);
        if (relative) row[@"relativePath"] = relative;
    }
    NSError *taskError = FDMValue(task, @"error");
    if ([taskError isKindOfClass:NSError.class] && !pauseIntent) row[@"error"] = taskError.localizedDescription;
    if (status == 6) {
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        NSDictionary *identity = path.length ? FDMFileIdentity(path) : nil;
        NSDictionary *expected = [previous[@"fileIdentity"] isKindOfClass:NSDictionary.class] ? previous[@"fileIdentity"] : nil;
        BOOL samePath = [FDMResolveDocumentPath(previous ?: @{}) isEqual:FDMResolveDocumentPath(row)];
        BOOL previouslyVerified = [previous[@"completionEvidence"] isEqual:@"host-status-http-file"];
        BOOL validFile = identity && (!previouslyVerified || (samePath && FDMHostIdentityMatches(expected, identity)));
        if (http && http.statusCode >= 200 && http.statusCode < 300 && validFile) {
            row[@"fileIdentity"] = identity;
            row[@"size"] = identity[@"size"];
            row[@"received"] = identity[@"size"];
            row[@"progress"] = @1;
            row[@"speed"] = @0;
            row[@"pausing"] = @NO;
            row[@"pauseIntent"] = @NO;
            row[@"completedAt"] = previous[@"completedAt"] ?: @(NSDate.date.timeIntervalSince1970);
            row[@"completionEvidence"] = @"host-status-http-file";
            [row removeObjectForKey:@"error"];
        } else {
            row[@"state"] = @(FDMStateInterrupted);
            row[@"speed"] = @0;
            if (http && (http.statusCode < 200 || http.statusCode >= 300)) row[@"error"] = [NSString stringWithFormat:@"HTTP %ld：响应不是成功下载", (long)http.statusCode];
            else if (!http) row[@"error"] = @"宿主任务已结束，但无法确认 HTTP 成功响应";
            else if (previouslyVerified) row[@"error"] = @"已保存的文件缺失或已被替换；未重新认领该文件";
            else row[@"error"] = @"宿主任务已结束，文件尚未完成保存或保存位置无法确认";
            if (expected) row[@"fileIdentity"] = expected;
            if (previouslyVerified) row[@"completionEvidence"] = previous[@"completionEvidence"];
        }
    } else if (pauseIntent) {
        row[@"speed"] = @0;
        row[@"statusDetail"] = [row[@"pausing"] boolValue] ? @"正在停止宿主下载" : @"宿主下载不支持断点续传；需要重新下载";
    } else if (status == 2) row[@"statusDetail"] = @"宿主已暂停；本页恢复将重新下载";
    else if (status == 3 && !row[@"error"]) row[@"error"] = @"宿主下载已取消";
    else if (status == 4 && !row[@"error"]) row[@"error"] = @"宿主下载失败";
    else if (status == 5 || status == 9) row[@"error"] = @"宿主已移除任务；本页只能重新下载";
    else if (status < 0 || status > 9) row[@"error"] = @"无法识别宿主下载状态；未推断为完成";
    return FDMImmutableRecord(row);
}

@implementation FDMHostDownloads {
    NSMutableDictionary<NSString *, NSDictionary *> *_entries;
    NSMapTable<NSString *, id> *_tasks;
    NSMutableSet<NSString *> *_paused;
    NSMutableSet<NSString *> *_suppressed;
    NSMutableDictionary<NSString *, NSNumber *> *_lastWrites;
    NSMutableArray *_observations;
    NSString *_journal;
    BOOL _writable;
    BOOL _refreshing;
}

+ (instancetype)shared {
    static FDMHostDownloads *adapter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ adapter = [[self alloc] init]; });
    return adapter;
}

- (instancetype)init {
    if ((self = [super init])) {
        _entries = [NSMutableDictionary dictionary];
        _tasks = [NSMapTable strongToWeakObjectsMapTable];
        _paused = [NSMutableSet set];
        _suppressed = [NSMutableSet set];
        _lastWrites = [NSMutableDictionary dictionary];
        _journal = [FDMDirectory(@"FocusDM") stringByAppendingPathComponent:@"host-removed-task-ids.json"];
        id root = FDMReadJSON(_journal, nil);
        _writable = ![[NSFileManager defaultManager] fileExistsAtPath:_journal] || [root isKindOfClass:NSArray.class];
        for (id key in [root isKindOfClass:NSArray.class] ? root : @[]) {
            if ([key isKindOfClass:NSString.class]) [_suppressed addObject:key];
            else _writable = NO;
        }
        if (!_writable) FDMLog(@"host removal journal unreadable; destructive actions disabled");
        _observations = [NSMutableArray array];
        __weak typeof(self) weakSelf = self;
        for (NSString *name in @[@"kTaskProgressNotification", @"kTaskSuccessNotification", @"kTaskFailureNotification"]) {
            id token = [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *event) {
                if (!event.object) return;
                // FileManager posts success before removing its wrapper; consume synchronously on main.
                if (NSThread.isMainThread) [weakSelf observeTask:event.object];
                else dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf observeTask:event.object]; });
            }];
            [_observations addObject:token];
        }
    }
    return self;
}

- (void)dealloc {
    for (id token in _observations) [NSNotificationCenter.defaultCenter removeObserver:token];
}

- (void)stopSuppressedTask:(id)task {
    NSNumber *raw = FDMValue(task, @"status");
    NSInteger status = [raw respondsToSelector:@selector(integerValue)] ? raw.integerValue : -1;
    if (status == 3 || status == 4 || status == 5 || status == 6 || status == 8 || status == 9) return;
    id manager = FDMSharedFileManager();
    SEL cancel = NSSelectorFromString(@"cancelTask:");
    if ([manager respondsToSelector:cancel]) {
        @try { ((void (*)(id, SEL, id))objc_msgSend)(manager, cancel, task); }
        @catch (NSException *exception) { FDMLog(@"host suppressed task could not stop: %@", exception.reason); }
    }
}

- (void)observeTask:(id)task {
    if (![task respondsToSelector:NSSelectorFromString(@"status")] || ![task respondsToSelector:NSSelectorFromString(@"url")]) return;
    NSString *key = [self keyForTask:task];
    if ([_suppressed containsObject:key]) { [self stopSuppressedTask:task]; return; }
    [_tasks setObject:task forKey:key];
    NSDictionary *previous = _entries[key] ?: [FDMStore.shared recordForKey:key];
    NSNumber *status = FDMValue(task, @"status");
    if ([previous[@"state"] integerValue] == FDMStateCompleted && status.integerValue != 6) return;
    NSDictionary *row = FDMHostProjectTask(task, key, [_paused containsObject:key] || [previous[@"pauseIntent"] boolValue], previous);
    _entries[key] = row;
    [self saveRow:row];
    FDMNotifyRecordsChanged();
}

- (NSString *)keyForTask:(id)task {
    NSString *key = objc_getAssociatedObject(task, FDMHostTaskKey);
    if (!key) {
        key = [@"host-" stringByAppendingString:NSUUID.UUID.UUIDString];
        objc_setAssociatedObject(task, FDMHostTaskKey, key, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    return key;
}

- (NSDictionary *)persistentRow:(NSDictionary *)row {
    NSMutableDictionary *copy = [row mutableCopy];
    [copy removeObjectForKey:@"speed"];
    [copy removeObjectForKey:@"pausing"];
    [copy removeObjectForKey:@"actionError"];
    return FDMImmutableRecord(copy);
}

- (void)saveRow:(NSDictionary *)row {
    NSString *key = row[@"key"];
    if ([_suppressed containsObject:key]) return;
    NSDictionary *candidate = [self persistentRow:row];
    NSDictionary *old = [FDMStore.shared recordForKey:key];
    if ([old isEqual:candidate]) return;
    BOOL transition = !old || !FDMHostValuesEqual(old[@"state"], candidate[@"state"]) || !FDMHostValuesEqual(old[@"hostStatus"], candidate[@"hostStatus"]) || !FDMHostValuesEqual(old[@"error"], candidate[@"error"]) || !FDMHostValuesEqual(old[@"completionEvidence"], candidate[@"completionEvidence"]);
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (!transition && now - [_lastWrites[key] doubleValue] < 3) return;
    NSError *error = nil;
    if ([FDMStore.shared upsertRecord:candidate error:&error]) _lastWrites[key] = @(now);
    else {
        NSMutableDictionary *failed = [row mutableCopy];
        failed[@"actionError"] = error.localizedDescription ?: @"历史记录保存失败";
        _entries[key] = FDMImmutableRecord(failed);
        FDMLog(@"host history save failed id=%@: %@", key, error.localizedDescription);
    }
}

- (void)refresh {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; }); return; }
    if (_refreshing) return;
    _refreshing = YES;
    // One refresh can persist dozens of rows; a single notification at the end keeps the
    // list from reloading once per task.
    [FDMStore.shared beginBatch];
    for (NSString *key in _suppressed) {
        if ([FDMStore.shared recordForKey:key]) {
            NSError *cleanup = nil;
            if (![FDMStore.shared dropKey:key error:&cleanup]) FDMLog(@"host deletion committed; history cleanup pending id=%@", key);
        }
    }
    id manager = FDMSharedFileManager();
    NSArray *live = FDMValue(manager, @"allTasks");
    id session = FDMValue(manager, @"sessionManager");
    NSArray *completed = FDMValue(session, @"completedTasks");
    NSHashTable *seenTasks = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    NSMutableSet *seenKeys = [NSMutableSet set];
    for (NSArray *list in @[[live isKindOfClass:NSArray.class] ? live : @[], [completed isKindOfClass:NSArray.class] ? completed : @[]]) {
        for (id task in list) {
            if ([seenTasks containsObject:task]) continue;
            [seenTasks addObject:task];
            NSString *key = [self keyForTask:task];
            if ([_suppressed containsObject:key]) { [self stopSuppressedTask:task]; continue; }
            [seenKeys addObject:key];
            [_tasks setObject:task forKey:key];
            NSDictionary *prior = _entries[key] ?: [FDMStore.shared recordForKey:key];
            NSNumber *rawStatus = FDMValue(task, @"status");
            NSInteger observedStatus = [rawStatus respondsToSelector:@selector(integerValue)] ? rawStatus.integerValue : -1;
            if ([prior[@"state"] integerValue] == FDMStateCompleted && observedStatus != 6) continue;
            BOOL paused = [_paused containsObject:key] || [prior[@"pauseIntent"] boolValue];
            NSDictionary *row = FDMHostProjectTask(task, key, paused, prior);
            _entries[key] = row;
            [self saveRow:row];
        }
    }
    for (NSString *key in [_entries.allKeys copy]) {
        if ([_suppressed containsObject:key]) { [_entries removeObjectForKey:key]; continue; }
        if ([seenKeys containsObject:key]) continue;
        NSDictionary *old = _entries[key];
        if ([old[@"state"] integerValue] != FDMStateDownloading && ![old[@"pausing"] boolValue]) continue;
        NSMutableDictionary *row = [old mutableCopy];
        row[@"state"] = @([old[@"pauseIntent"] boolValue] ? FDMStatePaused : FDMStateInterrupted);
        row[@"pausing"] = @NO;
        row[@"speed"] = @0;
        row[@"statusDetail"] = @"宿主任务已离开内存；只能重新下载";
        _entries[key] = FDMImmutableRecord(row);
        [self saveRow:row];
    }
    [FDMStore.shared endBatch];
    _refreshing = NO;
}

- (NSArray<NSDictionary *> *)rows {
    if (!NSThread.isMainThread) {
        __block NSArray *snapshot;
        dispatch_sync(dispatch_get_main_queue(), ^{ snapshot = [self rows]; });
        return snapshot;
    }
    return [_entries.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"time"] compare:a[@"time"]]; }];
}

- (BOOL)isSuppressedKey:(NSString *)key {
    if (NSThread.isMainThread) return [_suppressed containsObject:key];
    __block BOOL value;
    dispatch_sync(dispatch_get_main_queue(), ^{ value = [self isSuppressedKey:key]; });
    return value;
}

- (BOOL)pauseKey:(NSString *)key error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"Host actions belong to the main-thread adapter");
    NSDictionary *old = _entries[key];
    id task = [_tasks objectForKey:key];
    id manager = FDMSharedFileManager();
    SEL cancel = NSSelectorFromString(@"cancelTask:");
    if (!old || !task || ![manager respondsToSelector:cancel] || [old[@"state"] integerValue] != FDMStateDownloading) {
        if (error) *error = FDMError(@"宿主下载当前不能暂停");
        return NO;
    }
    NSMutableDictionary *intent = [old mutableCopy];
    intent[@"pauseIntent"] = @YES;
    intent[@"state"] = @(FDMStatePaused);
    intent[@"speed"] = @0;
    if (![FDMStore.shared upsertRecord:[self persistentRow:intent] error:error]) return NO;
    [_paused addObject:key];
    intent[@"pausing"] = @YES;
    _entries[key] = FDMImmutableRecord(intent);
    _lastWrites[key] = @(NSDate.date.timeIntervalSince1970);
    @try { ((void (*)(id, SEL, id))objc_msgSend)(manager, cancel, task); }
    @catch (NSException *exception) {
        [_paused removeObject:key];
        _entries[key] = old;
        [FDMStore.shared upsertRecord:[self persistentRow:old] error:nil];
        if (error) *error = FDMError([NSString stringWithFormat:@"宿主暂停失败：%@", exception.reason]);
        return NO;
    }
    FDMNotifyRecordsChanged();
    return YES;
}

- (void)removeKey:(NSString *)key deleteFile:(BOOL)deleteFile completion:(void (^)(NSError *))completion {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self removeKey:key deleteFile:deleteFile completion:completion]; }); return; }
    NSError *error = nil;
    NSDictionary *row = _entries[key] ?: [FDMStore.shared recordForKey:key];
    NSString *ownedPath = row ? FDMResolveDocumentPath(row) : nil;
    BOOL fileWasPresent = ownedPath.length && [[NSFileManager defaultManager] fileExistsAtPath:ownedPath];
    if (!_writable) error = FDMError(@"宿主删除记录文件不可写；未删除任务或文件");
    else if (deleteFile && (!row || !FDMRemoveOwnedFile(row, &error))) {
        if (!error) error = FDMError(@"无法确认文件归属；请选择仅删除记录");
    }
    if (!error) {
        NSMutableSet *removed = [_suppressed mutableCopy];
        [removed addObject:key];
        if (FDMWriteJSON(removed.allObjects, _journal, &error)) {
            _suppressed = removed;
            id task = [_tasks objectForKey:key];
            NSNumber *raw = FDMValue(task, @"status");
            NSInteger status = [raw respondsToSelector:@selector(integerValue)] ? raw.integerValue : -1;
            id manager = FDMSharedFileManager();
            SEL cancel = NSSelectorFromString(@"cancelTask:");
            if (task && status != 6 && [manager respondsToSelector:cancel]) {
                @try { ((void (*)(id, SEL, id))objc_msgSend)(manager, cancel, task); }
                @catch (NSException *exception) { error = FDMError(@"记录已移除，但宿主停止任务失败；请检查浏览器下载状态"); }
            }
            [_entries removeObjectForKey:key];
            [_tasks removeObjectForKey:key];
            [_paused removeObject:key];
            NSError *historyError = nil;
            if (![FDMStore.shared dropKey:key error:&historyError] && !error) error = FDMError([NSString stringWithFormat:@"删除已提交，历史文件清理待重试：%@", historyError.localizedDescription]);
            FDMNotifyRecordsChanged();
        } else if (deleteFile && fileWasPresent && ![[NSFileManager defaultManager] fileExistsAtPath:ownedPath]) {
            error = FDMError([NSString stringWithFormat:@"所属文件已删除，但记录删除未提交：%@", error.localizedDescription]);
        }
    }
    if (completion) completion(error);
}
@end
