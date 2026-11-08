#import "FDMStore.h"

@implementation FDMStore {
    dispatch_queue_t _queue;
    NSMutableArray<NSDictionary *> *_records;
    NSString *_path;
    BOOL _writable;
}

+ (instancetype)shared {
    static FDMStore *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ store = [[self alloc] init]; });
    return store;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("FocusDM.history", DISPATCH_QUEUE_SERIAL);
        _path = [FDMDirectory(@"FocusDM") stringByAppendingPathComponent:@"history.json"];
        _records = [NSMutableArray array];
        _writable = YES;
        NSError *error = nil;
        id root = FDMReadJSON(_path, &error);
        NSArray *rows = [root isKindOfClass:NSArray.class] ? root : ([root isKindOfClass:NSDictionary.class] ? root[@"records"] : nil);
        if (root && ![rows isKindOfClass:NSArray.class]) {
            _writable = NO;
            FDMLog(@"history unsupported format; original data preserved");
        } else if (!root && [[NSFileManager defaultManager] fileExistsAtPath:_path]) {
            _writable = NO;
            FDMLog(@"history unreadable; original data preserved: %@", error.localizedDescription);
        }
        for (id row in [rows isKindOfClass:NSArray.class] ? rows : @[]) {
            if (!FDMValidStoredRecord(row)) { _writable = NO; continue; }
            [_records addObject:FDMImmutableRecord(row)];
        }
    }
    return self;
}

- (NSArray<NSDictionary *> *)records {
    __block NSArray *result;
    dispatch_sync(_queue, ^{ result = [_records copy]; });
    return result;
}

- (NSDictionary *)recordForKey:(NSString *)key {
    if (!key.length) return nil;
    __block NSDictionary *result;
    dispatch_sync(_queue, ^{
        for (NSDictionary *row in _records) if ([row[@"key"] isEqual:key]) { result = row; break; }
    });
    return result;
}

- (BOOL)writeRecords:(NSArray *)records error:(NSError **)error {
    if (!_writable) {
        if (error) *error = FDMError(@"历史文件格式未知或损坏；原文件保留，暂不写入");
        return NO;
    }
    // Keep the legacy array container; v19 fields are additive.
    return FDMWriteJSON(records, _path, error);
}

- (BOOL)upsertRecord:(NSDictionary *)record error:(NSError **)error {
    if (!FDMValidStoredRecord(record)) { if (error) *error = FDMError(@"记录字段类型无效，未写入历史"); return NO; }
    NSString *key = FDMString(record[@"key"]);
    if (!key.length) { if (error) *error = FDMError(@"记录缺少任务身份"); return NO; }
    NSDictionary *immutable = FDMImmutableRecord(record);
    __block BOOL ok = YES;
    __block BOOL changed = NO;
    __block NSError *failure;
    dispatch_sync(_queue, ^{
        NSUInteger oldIndex = [_records indexOfObjectPassingTest:^BOOL(NSDictionary *row, NSUInteger index, BOOL *stop) { return [row[@"key"] isEqual:key]; }];
        if (oldIndex != NSNotFound && [_records[oldIndex] isEqual:immutable]) return;
        NSMutableArray *next = [_records mutableCopy];
        if (oldIndex != NSNotFound) [next removeObjectAtIndex:oldIndex];
        [next insertObject:immutable atIndex:0];
        ok = [self writeRecords:next error:&failure];
        if (ok) { _records = next; changed = YES; }
    });
    if (!ok && error) *error = failure;
    if (changed) FDMNotifyRecordsChanged();
    return ok;
}

- (BOOL)dropKey:(NSString *)key error:(NSError **)error {
    if (!key.length) return YES;
    __block BOOL ok = YES;
    __block BOOL changed = NO;
    __block NSError *failure;
    dispatch_sync(_queue, ^{
        NSMutableArray *next = [_records mutableCopy];
        NSIndexSet *matches = [next indexesOfObjectsPassingTest:^BOOL(NSDictionary *row, NSUInteger index, BOOL *stop) { return [row[@"key"] isEqual:key]; }];
        if (!matches.count) return;
        [next removeObjectsAtIndexes:matches];
        ok = [self writeRecords:next error:&failure];
        if (ok) { _records = next; changed = YES; }
    });
    if (!ok && error) *error = failure;
    if (changed) FDMNotifyRecordsChanged();
    return ok;
}
@end
