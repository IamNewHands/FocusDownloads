#import "FDMBackupRecovery.h"
#import "FDMBackupSQL.h"
#import "FDMJSON.h"
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <stdio.h>

NSData *FDMReadBoundedFile(NSURL *url, NSUInteger maximum, NSError **error) {
    if (!url.isFileURL || !maximum) { if (error) *error = FDMError(@"请选择本地普通文件"); return nil; }
    int descriptor = open(url.path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (descriptor < 0) { if (error) *error = FDMError(@"文件不可读，请重新选择文件"); return nil; }
    struct stat identity;
    if (fstat(descriptor, &identity) || !S_ISREG(identity.st_mode) || identity.st_size < 0 || (uint64_t)identity.st_size > maximum) {
        close(descriptor); if (error) *error = FDMError(@"文件类型无效或超过大小限制，未读取内容"); return nil;
    }
    NSMutableData *data = [NSMutableData data]; uint8_t buffer[16384]; BOOL ok = YES;
    while (YES) {
        ssize_t count = read(descriptor, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { ok = NO; break; }
        if (!count) break;
        if (data.length + (NSUInteger)count > maximum) { ok = NO; break; }
        [data appendBytes:buffer length:(NSUInteger)count];
    }
    close(descriptor);
    if (!ok) { if (error) *error = FDMError(@"读取失败或文件在读取时超过大小限制"); return nil; }
    return [data copy];
}
BOOL FDMWriteDurableJSON(id object, NSString *path, NSError **error) {
    NSData *bytes = FDMJSONCanonicalData(object, error);
    if (!bytes) return NO;
    NSString *stage = [path stringByAppendingFormat:@".stage-%@", NSUUID.UUID.UUIDString];
    int descriptor = open(stage.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (descriptor < 0) { if (error) *error = FDMError(@"恢复记录暂存不可写"); return NO; }
    NSUInteger offset = 0; BOOL ok = YES;
    while (offset < bytes.length) {
        ssize_t count = write(descriptor, (const uint8_t *)bytes.bytes + offset, bytes.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { ok = NO; break; }
        offset += (NSUInteger)count;
    }
    if (ok && fsync(descriptor)) ok = NO;
    close(descriptor);
    if (ok && rename(stage.fileSystemRepresentation, path.fileSystemRepresentation)) ok = NO;
    if (!ok) { unlink(stage.fileSystemRepresentation); if (error) *error = FDMError(@"恢复记录未能持久提交，配置未发布"); return NO; }
    int directory = open(path.stringByDeletingLastPathComponent.fileSystemRepresentation, O_RDONLY);
    if (directory >= 0) { fsync(directory); close(directory); }
    NSData *readBack = FDMReadBoundedFile([NSURL fileURLWithPath:path], MAX((NSUInteger)1, bytes.length), error);
    if (![readBack isEqual:bytes]) { if (error) *error = FDMError(@"恢复记录读回不一致"); return NO; }
    return YES;
}
static BOOL FDMRecoveryTableAllowed(NSString *table) {
    return [@[@"t_bookmark", @"t_hometags", @"t_userscript"] containsObject:table];
}
NSData *FDMRecoverySQLSnapshot(id<FDMBackupSQLDatabase> database, NSString *table, NSArray<NSString *> *allowed, NSError **error) {
    if (!FDMRecoveryTableAllowed(table)) { if (error) *error = FDMError(@"恢复类别无效"); return nil; }
    __block NSArray *rows = nil; __block NSError *failure = nil; __block NSArray *columns = nil;
    [database inDatabase:^(id<FDMBackupSQLExecutor> executor) {
        NSSet *actual = nil; if (!FDMBackupTableColumns(executor, table, &actual, &failure)) return;
        NSMutableArray *selected = [NSMutableArray array];
        for (NSString *column in allowed) if ([actual containsObject:column]) [selected addObject:column];
        if (selected.count != actual.count) { failure = FDMError(@"数据库有本版本未知列，不能保证完整回滚；未进行恢复"); return; }
        columns = [selected copy];
        NSString *identifier = [table isEqual:@"t_bookmark"] ? @"bookmarkId" : @"uuid";
        rows = [executor query:[NSString stringWithFormat:@"SELECT %@ FROM %@ ORDER BY %@", [columns componentsJoinedByString:@","], table, identifier] parameters:nil error:&failure];
    }];
    if (!rows || failure) { if (error) *error = failure ?: FDMError(@"原数据快照不可读"); return nil; }
    return FDMJSONCanonicalData(@{@"recoverySchema": @1, @"table": table, @"columns": columns, @"rows": rows}, error);
}
BOOL FDMRecoverySQLRestore(id<FDMBackupSQLDatabase> database, NSData *snapshot, NSString *table, NSArray<NSString *> *allowed, NSError **error) {
    NSDictionary *root = FDMJSONObjectValue(FDMJSONParseDataBounded(snapshot, 32, 32 * 1024 * 1024, error));
    NSArray *columns = FDMJSONArrayValue(root[@"columns"]), *rows = FDMJSONArrayValue(root[@"rows"]);
    if (![root[@"recoverySchema"] isEqual:@1] || ![root[@"table"] isEqual:table] || !FDMRecoveryTableAllowed(table) || !columns.count || !rows ||
        columns.count != [NSSet setWithArray:columns].count) { if (error) *error = FDMError(@"本地前像结构无效，已保留恢复保护"); return NO; }
    for (id column in columns) if (![column isKindOfClass:NSString.class] || ![allowed containsObject:column]) { if (error) *error = FDMError(@"前像列无效"); return NO; }
    for (id row in rows) {
        if (![row isKindOfClass:NSDictionary.class] || [row count] != columns.count) { if (error) *error = FDMError(@"前像行结构无效"); return NO; }
        for (NSString *column in columns) if (!row[column]) { if (error) *error = FDMError(@"前像字段缺失"); return NO; }
    }
    __block NSError *failure = nil;
    BOOL ok = [database inTransaction:^BOOL(id<FDMBackupSQLExecutor> executor) {
        NSSet *actual = nil; if (!FDMBackupTableColumns(executor, table, &actual, &failure) || ![actual isEqual:[NSSet setWithArray:columns]]) return NO;
        if (![executor update:[NSString stringWithFormat:@"DELETE FROM %@", table] parameters:nil error:&failure]) return NO;
        NSMutableArray *marks = [NSMutableArray array]; for (NSUInteger i=0;i<columns.count;i++) [marks addObject:@"?"];
        NSString *sql = [NSString stringWithFormat:@"INSERT INTO %@ (%@) VALUES (%@)", table, [columns componentsJoinedByString:@","], [marks componentsJoinedByString:@","]];
        for (NSDictionary *row in rows) {
            NSMutableArray *values = [NSMutableArray array]; for (NSString *column in columns) [values addObject:row[column]];
            if (![executor update:sql parameters:values error:&failure]) return NO;
        }
        return YES;
    } error:&failure];
    if (!ok && error) *error = failure; return ok;
}
