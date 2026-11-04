# -*- coding: utf-8 -*-
"""v16: 进度/大小取数修正、删除分两种、图标走 SDWebImage 全量缓存"""
import io, sys

P = 'src/FocusDM.m'
s = io.open(P, encoding='utf-8').read()
n0 = len(s)

def rep(old, new, label):
    global s
    if old not in s:
        print('MISS:', label); sys.exit(1)
    if s.count(old) != 1:
        print('DUP(%d):' % s.count(old), label); sys.exit(1)
    s = s.replace(old, new)
    print('ok:', label)

# ---------- A. 数值取值：兼容 NSNumber / NSProgress / 字符串 ----------
rep("""static id FDMValue(id task, NSString *key) {""",
"""static double FDMDouble(id task, NSString *key) {
    @try {
        id v = [task valueForKey:key];
        if ([v isKindOfClass:[NSNumber class]]) return [v doubleValue];
        if ([v respondsToSelector:@selector(doubleValue)]) return [v doubleValue];   // NSString
        if ([v isKindOfClass:NSClassFromString(@"NSProgress")] || [v respondsToSelector:@selector(fractionCompleted)]) {
            return [v fractionCompleted];                                            // NSProgress
        }
    } @catch (NSException *e) { (void)e; }
    return 0;
}

static double FDMProgressOfTask(id task) {
    static NSArray *keys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[ @"progress", @"progressValue", @"fractionCompleted", @"percent", @"_progress" ];
    });
    for (NSString *k in keys) {
        double v = FDMDouble(task, k);
        if (v > 0.0) return (v > 1.0 && v <= 100.0) ? v / 100.0 : MIN(1.0, v);
    }
    return 0;
}

static id FDMValue(id task, NSString *key) {""", 'FDMDouble helper')

rep("""    row.progress = FDMNumber(task, @"progress");
    row.speed = FDMNumber(task, @"speed");""",
"""    row.progress = FDMProgressOfTask(task);
    row.speed = FDMNumber(task, @"speed");""", 'use FDMProgressOfTask')

# ---------- B. 宿主任务 meta：总大小已知时按比例算已下 ----------
rep("""        if (total > 0) {
            [bits addObject:[NSString stringWithFormat:@"已下 %@ / %@",
                             FDMHumanSize(total * row.progress), FDMHumanSize(total)]];
        } else if (row.size) {
            [bits addObject:[NSString stringWithFormat:@"已下 %@", FDMHumanSize((double)row.size)]];
        }""",
"""        if (total > 0) {
            double received2 = total * row.progress;
            if (row.progress <= 0.0) received2 = (double)row.size;
            [bits addObject:[NSString stringWithFormat:@"%@ / %@",
                             FDMHumanSize(received2), FDMHumanSize(total)]];
        } else if (row.size) {
            [bits addObject:FDMHumanSize((double)row.size)];
        }""", 'host size meta simplify')

# ---------- C. 删除：仅记录 / 记录+文件 ----------
rep("""- (void)deleteRow:(FDMRow *)row {""",
"""- (void)deleteRow:(FDMRow *)row {
    [self deleteRow:row deleteFile:YES];
}

- (NSArray *)candidatePathsForRow:(FDMRow *)row {
    NSMutableArray *paths = [NSMutableArray array];
    if (row.path.length) [paths addObject:row.path];

    id fm = FDMSharedFileManager();
    id sm = [fm respondsToSelector:@selector(sessionManager)] ? [fm sessionManager] : nil;
    if (sm) {
        NSString *dir = FDMString(FDMValue(sm, @"downloadPath"));
        if (dir.length && row.name.length) {
            [paths addObject:[dir stringByAppendingPathComponent:row.name]];
        }
    }
    NSString *docs = FDMDocumentsPath();
    if (docs.length && row.name.length) {
        [paths addObject:[docs stringByAppendingPathComponent:row.name]];
        [paths addObject:[[docs stringByAppendingPathComponent:@"Download"] stringByAppendingPathComponent:row.name]];
        [paths addObject:[[docs stringByAppendingPathComponent:@"Downloads"] stringByAppendingPathComponent:row.name]];
    }
    return paths;
}

- (BOOL)removeFilesForRow:(FDMRow *)row {
    BOOL removed = NO;
    for (NSString *p in [self candidatePathsForRow:row]) {
        if (!p.length) continue;
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) {
            if ([[NSFileManager defaultManager] removeItemAtPath:p error:NULL]) {
                removed = YES;
                FDMLog(@"delete: removed %@", p);
            } else {
                FDMLog(@"delete: failed %@", p);
            }
        }
    }
    return removed;
}

- (void)deleteRow:(FDMRow *)row deleteFile:(BOOL)deleteFile {""", 'deleteRow overload')

rep("""        [[FDMEngine shared] cancelKey:row.key deleteFile:YES];
        if (row.path.length) [[NSFileManager defaultManager] removeItemAtPath:row.path error:NULL];
    }
    [[FDMStore shared] dropKey:row.key];""",
"""        [[FDMEngine shared] cancelKey:row.key deleteFile:deleteFile];
        if (deleteFile) [self removeFilesForRow:row];
    }
    [[FDMStore shared] dropKey:row.key];""", 'deleteRow honours flag')

# 侧滑删除改成两种选择
rep("""        UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"删除这条记录？"
                                                                        message:@"同时删除已下载的文件"
                                                                 preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { done(NO); }]];
        [confirm addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            [self deleteRow:row];
            done(YES);
        }]];""",
"""        UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"删除"
                                                                        message:@"选择删除方式"
                                                                 preferredStyle:UIAlertControllerStyleActionSheet];
        [confirm addAction:[UIAlertAction actionWithTitle:@"仅删除记录（保留本地文件）"
                                                    style:UIAlertActionStyleDefault
                                                  handler:^(UIAlertAction *x) {
            [self deleteRow:row deleteFile:NO];
            done(YES);
        }]];
        [confirm addAction:[UIAlertAction actionWithTitle:@"删除记录和本地文件"
                                                    style:UIAlertActionStyleDestructive
                                                  handler:^(UIAlertAction *x) {
            [self deleteRow:row deleteFile:YES];
            done(YES);
        }]];
        [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { done(NO); }]];""", 'delete action sheet')

io.open(P, 'w', encoding='utf-8', newline='\n').write(s)
print('bytes %d -> %d' % (n0, len(s)))
