#import "FDMBackupSQL.h"
#import <objc/runtime.h>
#import <objc/message.h>

static NSError *FDMBackupSQLError(NSString *message) {
    return [NSError errorWithDomain:@"FocusDM.Backup.SQL" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

// While a batch transaction is held, every statement on that queue must run on the already-open
// connection. A repository that calls inDatabase: inside the batch would otherwise deadlock on
// FMDB's serial queue. The active executor is therefore published per thread and reused.
static NSString *const FDMBackupActiveExecutorKey = @"FocusDM.backup.activeExecutor";

static void FDMBackupSetActiveExecutor(id<FDMBackupSQLExecutor> executor) {
    NSMutableDictionary *thread = NSThread.currentThread.threadDictionary;
    if (executor) thread[FDMBackupActiveExecutorKey] = executor;
    else [thread removeObjectForKey:FDMBackupActiveExecutorKey];
}

static id<FDMBackupSQLExecutor> FDMBackupActiveExecutor(void) {
    return NSThread.currentThread.threadDictionary[FDMBackupActiveExecutorKey];
}

BOOL FDMBackupTableColumns(id<FDMBackupSQLExecutor> executor,
                           NSString *table,
                           NSSet<NSString *> **columns,
                           NSError **error) {
    if (!table.length) { if (error) *error = FDMBackupSQLError(@"表名无效"); return NO; }
    // PRAGMA is used instead of assuming the CREATE TABLE text, because the host migrates columns
    // with ALTER TABLE and an older user database may genuinely lack a newer column.
    NSArray *rows = [executor query:[NSString stringWithFormat:@"PRAGMA table_info(%@)", table]
                         parameters:nil
                              error:error];
    if (!rows) return NO;
    NSMutableSet *names = [NSMutableSet set];
    for (NSDictionary *row in rows) {
        NSString *name = row[@"name"];
        if ([name isKindOfClass:NSString.class] && name.length) [names addObject:name];
    }
    if (!names.count) {
        if (error) *error = FDMBackupSQLError([NSString stringWithFormat:@"表不存在或没有列：%@", table]);
        return NO;
    }
    if (columns) *columns = [names copy];
    return YES;
}

#pragma mark - host queue bridge

// The host executor wraps one FMDatabase instance handed to the inDatabase: block.
@interface FDMHostSQLExecutor : NSObject <FDMBackupSQLExecutor>
- (instancetype)initWithDatabase:(id)database;
@end

@implementation FDMHostSQLExecutor {
    id _database;
}

- (instancetype)initWithDatabase:(id)database {
    if ((self = [super init])) _database = database;
    return self;
}

// Rows are converted from FMResultSet into plain dictionaries so repository code never depends on
// FMDB types, and so a caller cannot mutate the live result set.
- (NSArray<NSDictionary *> *)query:(NSString *)sql parameters:(NSArray *)parameters error:(NSError **)error {
    SEL selector = NSSelectorFromString(@"executeQuery:withArgumentsInArray:");
    if (!_database || ![_database respondsToSelector:selector]) {
        if (error) *error = FDMBackupSQLError(@"数据库连接不可用");
        return nil;
    }
    id resultSet = ((id (*)(id, SEL, id, id))objc_msgSend)(_database, selector, sql, parameters ?: @[]);
    if (!resultSet) {
        if (error) *error = FDMBackupSQLError(@"查询失败");
        return nil;
    }
    NSMutableArray *rows = [NSMutableArray array];
    @try {
        SEL next = NSSelectorFromString(@"next");
        SEL dictionary = NSSelectorFromString(@"resultDictionary");
        while (((BOOL (*)(id, SEL))objc_msgSend)(resultSet, next)) {
            id row = ((id (*)(id, SEL))objc_msgSend)(resultSet, dictionary);
            if ([row isKindOfClass:NSDictionary.class]) [rows addObject:row];
        }
        SEL close = NSSelectorFromString(@"close");
        if ([resultSet respondsToSelector:close]) ((void (*)(id, SEL))objc_msgSend)(resultSet, close);
    } @catch (NSException *exception) {
        if (error) *error = FDMBackupSQLError([NSString stringWithFormat:@"读取结果失败：%@", exception.reason]);
        return nil;
    }
    return rows;
}

- (BOOL)update:(NSString *)sql parameters:(NSArray *)parameters error:(NSError **)error {
    SEL selector = NSSelectorFromString(@"executeUpdate:withArgumentsInArray:");
    if (!_database || ![_database respondsToSelector:selector]) {
        if (error) *error = FDMBackupSQLError(@"数据库连接不可用");
        return NO;
    }
    BOOL ok = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(_database, selector, sql, parameters ?: @[]);
    if (!ok && error) {
        SEL lastError = NSSelectorFromString(@"lastErrorMessage");
        NSString *message = [_database respondsToSelector:lastError]
            ? ((id (*)(id, SEL))objc_msgSend)(_database, lastError) : nil;
        *error = FDMBackupSQLError(message.length ? message : @"写入失败");
    }
    return ok;
}
@end

#pragma mark - atomic batch

// One held connection for a whole restore batch.
@interface FDMHostAtomicAccess : NSObject <FDMBackupSQLAtomicAccess>
- (instancetype)initWithExecutor:(FDMHostSQLExecutor *)executor;
@end

@implementation FDMHostAtomicAccess {
    FDMHostSQLExecutor *_executor;
    BOOL _finished;
    BOOL _committed;
}
- (instancetype)initWithExecutor:(FDMHostSQLExecutor *)executor {
    if ((self = [super init])) _executor = executor;
    return self;
}
- (id<FDMBackupSQLExecutor>)executor { return _executor; }
// Idempotent on purpose: the caller block may commit, and performAtomicBatch: then commits again.
// A second commit on an already-committed batch must report the truth (success), not fail.
- (BOOL)commitWithError:(NSError **)error {
    if (_finished) {
        if (_committed) return YES;
        if (error) *error = FDMBackupSQLError(@"事务已回滚");
        return NO;
    }
    _finished = YES;
    _committed = [_executor update:@"COMMIT" parameters:nil error:error];
    return _committed;
}
- (void)rollback {
    if (_finished) return;
    _finished = YES;
    [_executor update:@"ROLLBACK" parameters:nil error:NULL];
}
@end

@implementation FDMHostDatabaseQueue {
    id _queue;
}

// Enters FMDB's serialized queue exactly once, so every statement in the batch runs on the same
// connection inside one transaction. This is what prevents a database reader from observing a
// half-applied multi-category restore.
- (BOOL)performExclusiveAccess:(BOOL (^)(void))block error:(NSError **)error {
    if (FDMBackupActiveExecutor()) return block();
    SEL selector = NSSelectorFromString(@"inDatabase:");
    if (![_queue respondsToSelector:selector]) { if (error) *error = FDMBackupSQLError(@"数据库不可用"); return NO; }
    __block BOOL result = NO; __block NSError *failure = nil;
    ((void (*)(id, SEL, void (^)(id)))objc_msgSend)(_queue, selector, ^(id database) {
        id<FDMBackupSQLExecutor> executor = [[FDMHostSQLExecutor alloc] initWithDatabase:database];
        FDMBackupSetActiveExecutor(executor);
        @try { result = block(); }
        @catch (NSException *exception) { failure = FDMBackupSQLError(@"配置批次发生异常，保留恢复保护"); }
        @finally { FDMBackupSetActiveExecutor(nil); }
    });
    if (!result && error && failure) *error = failure; return result;
}
- (BOOL)performAtomicBatch:(void (^)(id<FDMBackupSQLAtomicAccess>))block error:(NSError **)error {
    __block BOOL result = NO; __block NSError *failure = nil;
    [self performExclusiveAccess:^BOOL {
        id<FDMBackupSQLExecutor> executor = FDMBackupActiveExecutor();
        if (![executor update:@"BEGIN IMMEDIATE" parameters:nil error:&failure]) return NO;
        FDMHostAtomicAccess *access = [[FDMHostAtomicAccess alloc] initWithExecutor:executor];
        @try { block(access); result = [access commitWithError:&failure]; }
        @catch (NSException *exception) { result = NO; failure = FDMBackupSQLError(@"数据库批次异常"); }
        if (!result) [executor update:@"ROLLBACK" parameters:nil error:NULL];
        return result;
    } error:&failure];
    if (!result && error) *error = failure; return result;
}

+ (instancetype)hostQueueWithError:(NSError **)error {
    Class util = NSClassFromString(@"DatabaseUtil");
    SEL shared = NSSelectorFromString(@"shareInstance");
    if (!util || ![util respondsToSelector:shared]) {
        if (error) *error = FDMBackupSQLError(@"宿主数据库不可用");
        return nil;
    }
    id instance = ((id (*)(id, SEL))objc_msgSend)((id)util, shared);
    SEL queueSelector = NSSelectorFromString(@"queue");
    id queue = (instance && [instance respondsToSelector:queueSelector])
        ? ((id (*)(id, SEL))objc_msgSend)(instance, queueSelector) : nil;
    if (!queue) {
        if (error) *error = FDMBackupSQLError(@"宿主数据库队列不可用");
        return nil;
    }
    return [[self alloc] initWithQueue:queue];
}

- (instancetype)initWithQueue:(id)queue {
    if ((self = [super init])) _queue = queue;
    return self;
}

- (void)inDatabase:(void (^)(id<FDMBackupSQLExecutor>))block {
    if (!block) return;
    // Inside a held batch, reuse the already-open connection instead of re-entering the queue
    // (re-entering FMDB's serial queue from its own block would deadlock).
    id<FDMBackupSQLExecutor> active = FDMBackupActiveExecutor();
    if (active) { block(active); return; }
    SEL selector = NSSelectorFromString(@"inDatabase:");
    if (!_queue || ![_queue respondsToSelector:selector]) return;
    ((void (*)(id, SEL, void (^)(id)))objc_msgSend)(_queue, selector, ^(id database) {
        FDMHostSQLExecutor *executor = [[FDMHostSQLExecutor alloc] initWithDatabase:database];
        block(executor);
    });
}

- (BOOL)inTransaction:(BOOL (^)(id<FDMBackupSQLExecutor>))block error:(NSError **)error {
    if (!block) { if (error) *error = FDMBackupSQLError(@"事务块为空"); return NO; }
    __block BOOL ok = NO;
    __block NSError *inner = nil;
    BOOL entered = [self performAtomicBatch:^(id<FDMBackupSQLAtomicAccess> access) {
        BOOL result = NO;
        @try { result = block([access executor]); }
        @catch (NSException *exception) {
            inner = FDMBackupSQLError([NSString stringWithFormat:@"事务中止：%@", exception.reason]);
            result = NO;
        }
        if (!result) { [access rollback]; inner = inner ?: FDMBackupSQLError(@"事务已回滚"); return; }
        ok = YES;
    } error:&inner];
    if (!entered) { if (error) *error = inner; return NO; }
    if (!ok) { if (error) *error = inner ?: FDMBackupSQLError(@"事务未提交"); return NO; }
    return YES;
}
@end

#ifdef FDM_TESTING

#import <sqlite3.h>

@interface FDMSQLiteFixtureExecutor : NSObject <FDMBackupSQLExecutor>
- (instancetype)initWithHandle:(sqlite3 *)handle;
@end

@implementation FDMSQLiteFixtureExecutor {
    sqlite3 *_handle;
}

- (instancetype)initWithHandle:(sqlite3 *)handle {
    if ((self = [super init])) _handle = handle;
    return self;
}

static void FDMFixtureBind(sqlite3_stmt *statement, NSArray *parameters) {
    for (NSUInteger index = 0; index < parameters.count; index++) {
        id value = parameters[index];
        int position = (int)(index + 1);
        if (!value || value == NSNull.null) sqlite3_bind_null(statement, position);
        else if ([value isKindOfClass:NSNumber.class]) {
            if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
                sqlite3_bind_int(statement, position, [value boolValue] ? 1 : 0);
            } else {
                double raw = [value doubleValue];
                if (raw == floor(raw) && fabs(raw) < 9.0e15) sqlite3_bind_int64(statement, position, (sqlite3_int64)raw);
                else sqlite3_bind_double(statement, position, raw);
            }
        } else if ([value isKindOfClass:NSString.class]) {
            sqlite3_bind_text(statement, position, [value UTF8String], -1, SQLITE_TRANSIENT);
        } else if ([value isKindOfClass:NSData.class]) {
            NSData *data = value;
            sqlite3_bind_blob(statement, position, data.bytes, (int)data.length, SQLITE_TRANSIENT);
        } else {
            sqlite3_bind_text(statement, position, [[value description] UTF8String], -1, SQLITE_TRANSIENT);
        }
    }
}

- (NSArray<NSDictionary *> *)query:(NSString *)sql parameters:(NSArray *)parameters error:(NSError **)error {
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_handle, [sql UTF8String], -1, &statement, NULL) != SQLITE_OK) {
        if (error) *error = FDMBackupSQLError([NSString stringWithFormat:@"准备查询失败：%s", sqlite3_errmsg(_handle)]);
        return nil;
    }
    FDMFixtureBind(statement, parameters);
    NSMutableArray *rows = [NSMutableArray array];
    while (sqlite3_step(statement) == SQLITE_ROW) {
        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        int count = sqlite3_column_count(statement);
        for (int i = 0; i < count; i++) {
            const char *name = sqlite3_column_name(statement, i);
            if (!name) continue;
            NSString *key = [NSString stringWithUTF8String:name];
            switch (sqlite3_column_type(statement, i)) {
                case SQLITE_INTEGER:
                    row[key] = @(sqlite3_column_int64(statement, i));
                    break;
                case SQLITE_FLOAT:
                    row[key] = @(sqlite3_column_double(statement, i));
                    break;
                case SQLITE_TEXT:
                    row[key] = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(statement, i)] ?: @"";
                    break;
                case SQLITE_BLOB: {
                    const void *bytes = sqlite3_column_blob(statement, i);
                    int length = sqlite3_column_bytes(statement, i);
                    row[key] = bytes ? [NSData dataWithBytes:bytes length:(NSUInteger)length] : [NSData data];
                    break;
                }
                default:
                    row[key] = NSNull.null;
                    break;
            }
        }
        [rows addObject:row];
    }
    sqlite3_finalize(statement);
    return rows;
}

- (BOOL)update:(NSString *)sql parameters:(NSArray *)parameters error:(NSError **)error {
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_handle, [sql UTF8String], -1, &statement, NULL) != SQLITE_OK) {
        if (error) *error = FDMBackupSQLError([NSString stringWithFormat:@"准备写入失败：%s", sqlite3_errmsg(_handle)]);
        return NO;
    }
    FDMFixtureBind(statement, parameters);
    int step = sqlite3_step(statement);
    sqlite3_finalize(statement);
    if (step != SQLITE_DONE && step != SQLITE_ROW) {
        if (error) *error = FDMBackupSQLError([NSString stringWithFormat:@"写入失败：%s", sqlite3_errmsg(_handle)]);
        return NO;
    }
    return YES;
}
@end

@interface FDMSQLiteFixtureAccess : NSObject <FDMBackupSQLAtomicAccess>
- (instancetype)initWithExecutor:(FDMSQLiteFixtureExecutor *)executor handle:(sqlite3 *)handle;
@end

@implementation FDMSQLiteFixtureDatabase {
    sqlite3 *_handle;
    dispatch_queue_t _queue;
}

- (instancetype)initWithPath:(NSString *)path error:(NSError **)error {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("FocusDM.backup.fixture-db", DISPATCH_QUEUE_SERIAL);
        if (sqlite3_open([path UTF8String], &_handle) != SQLITE_OK) {
            if (error) *error = FDMBackupSQLError(@"无法打开测试数据库");
            return nil;
        }
        // Enforce foreign keys so a fixture can catch dangling parents.
        sqlite3_exec(_handle, "PRAGMA foreign_keys=ON", NULL, NULL, NULL);
    }
    return self;
}

- (BOOL)close {
    if (!_handle) return YES;
    BOOL ok = sqlite3_close(_handle) == SQLITE_OK;
    _handle = NULL;
    return ok;
}

- (BOOL)performExclusiveAccess:(BOOL (^)(void))block error:(NSError **)error {
    if (FDMBackupActiveExecutor()) return block();
    __block BOOL ok = NO; __block NSError *failure = nil;
    dispatch_sync(_queue, ^{
        FDMBackupSetActiveExecutor([[FDMSQLiteFixtureExecutor alloc] initWithHandle:_handle]);
        @try { ok = block(); } @catch (NSException *exception) { failure = FDMBackupSQLError(@"夹具批次异常"); }
        @finally { FDMBackupSetActiveExecutor(nil); }
    });
    if (!ok && error && failure) *error = failure; return ok;
}
- (void)inDatabase:(void (^)(id<FDMBackupSQLExecutor>))block {
    [self performExclusiveAccess:^BOOL { block(FDMBackupActiveExecutor()); return YES; } error:NULL];
}
- (BOOL)inTransaction:(BOOL (^)(id<FDMBackupSQLExecutor>))block error:(NSError **)error {
    __block BOOL ok = NO; __block NSError *failure = nil;
    [self performExclusiveAccess:^BOOL {
        id<FDMBackupSQLExecutor> executor = FDMBackupActiveExecutor();
        if (![executor update:@"BEGIN IMMEDIATE" parameters:nil error:&failure]) return NO;
        @try { ok = block(executor); } @catch (NSException *exception) { ok = NO; failure = FDMBackupSQLError(@"事务异常"); }
        if (ok) ok = [executor update:@"COMMIT" parameters:nil error:&failure];
        if (!ok) [executor update:@"ROLLBACK" parameters:nil error:NULL];
        return ok;
    } error:&failure];
    if (!ok && error) *error = failure ?: FDMBackupSQLError(@"事务已回滚"); return ok;
}
- (BOOL)performAtomicBatch:(void (^)(id<FDMBackupSQLAtomicAccess>))block error:(NSError **)error {
    __block BOOL ok = NO; __block NSError *failure = nil;
    [self performExclusiveAccess:^BOOL {
        id<FDMBackupSQLExecutor> executor = FDMBackupActiveExecutor();
        if (![executor update:@"BEGIN IMMEDIATE" parameters:nil error:&failure]) return NO;
        FDMSQLiteFixtureAccess *access = [[FDMSQLiteFixtureAccess alloc] initWithExecutor:(id)executor handle:_handle];
        @try { block(access); ok = [access commitWithError:&failure]; }
        @catch (NSException *exception) { ok = NO; failure = FDMBackupSQLError(@"事务异常"); }
        if (!ok) [executor update:@"ROLLBACK" parameters:nil error:NULL];
        return ok;
    } error:&failure];
    if (!ok && error) *error = failure; return ok;
}

@end

// Fixture counterpart of the host atomic access holder.
@implementation FDMSQLiteFixtureAccess {
    FDMSQLiteFixtureExecutor *_executor;
    sqlite3 *_handle;
    BOOL _finished;
    BOOL _committed;
}
- (instancetype)initWithExecutor:(FDMSQLiteFixtureExecutor *)executor handle:(sqlite3 *)handle {
    if ((self = [super init])) { _executor = executor; _handle = handle; }
    return self;
}
- (id<FDMBackupSQLExecutor>)executor { return _executor; }
// Same idempotence rule as the host access holder.
- (BOOL)commitWithError:(NSError **)error {
    if (_finished) {
        if (_committed) return YES;
        if (error) *error = FDMBackupSQLError(@"事务已回滚");
        return NO;
    }
    _finished = YES;
    if (sqlite3_exec(_handle, "COMMIT", NULL, NULL, NULL) != SQLITE_OK) {
        if (error) *error = FDMBackupSQLError(@"提交失败");
        return NO;
    }
    _committed = YES;
    return YES;
}
- (void)rollback {
    if (_finished) return;
    _finished = YES;
    sqlite3_exec(_handle, "ROLLBACK", NULL, NULL, NULL);
}
@end

#endif
