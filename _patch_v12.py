# -*- coding: utf-8 -*-
"""v12: 右滑推入动画 / 图标缓存真正跨启动 / 任务持久化 + 可恢复下载引擎"""
import io, sys

P = 'src/FocusDM.m'
s = io.open(P, encoding='utf-8').read()

def rep(old, new, n=1):
    global s
    c = s.count(old)
    assert c == n, 'anchor count %d != %d: %r' % (c, n, old[:80])
    s = s.replace(old, new)

# ---------- 1. 状态枚举 ----------
rep("""    FDMStateFailed      = 3,
};""",
"""    FDMStateFailed      = 3,
    FDMStateInterrupted = 4,
};""")

# ---------- 2. 行模型加字段 ----------
rep("""@property (nonatomic, strong) id task;              // 进行中的任务对象，历史行是 nil
@end""",
"""@property (nonatomic, strong) id task;              // 进行中的任务对象，历史行是 nil
@property (nonatomic, assign) NSInteger source;     // 0=自建引擎 1=宿主引擎 2=历史记录
@property (nonatomic, copy) NSString *url;          // 原始下载地址（续传 / 重试用）
@end""")

# ---------- 3. 可恢复引擎 ----------
ENGINE = r'''@implementation FDMRow
@end

#pragma mark - 可恢复下载引擎（自建后台 NSURLSession，跨启动续传）

// 宿主自己的下载引擎是 Swift 的 TRSessionManager：任务只存在内存里，
// 重启后 allTasks 为空，也没有 resumeData 概念。这里自建一套：
//   · 任务清单落 Documents/FocusDM/tasks.json（跨启动可见）
//   · 暂停用 cancelByProducingResumeData: 存续传数据到 resume/<key>.resume
//   · 继续用 downloadTaskWithResumeData: 从断点接着下
//   · 后台会话 identifier FocusDM.resumable

static NSString *FDMTasksFilePath(void) {
    NSString *dir = [FDMDocumentsPath() stringByAppendingPathComponent:@"FocusDM"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return [dir stringByAppendingPathComponent:@"tasks.json"];
}

static NSString *FDMResumeDirectory(void) {
    NSString *dir = [FDMDocumentsPath() stringByAppendingPathComponent:@"FocusDM/resume"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return dir;
}

static NSString *FDMDownloadDirectory(void) {
    NSString *dir = [FDMDocumentsPath() stringByAppendingPathComponent:@"FocusDM/downloads"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return dir;
}

static NSString *FDMHashKey(NSString *s) {
    if (!s.length) return nil;
    const char *p = s.UTF8String;
    if (!p) return nil;
    uint64_t h = 1469598103934665603ULL;
    while (*p) { h ^= (unsigned char)(*p++); h *= 1099511628211ULL; }
    return [NSString stringWithFormat:@"%016llx", (unsigned long long)h];
}

static NSString *FDMResumePathForKey(NSString *key) {
    NSString *h = FDMHashKey(key);
    return h ? [FDMResumeDirectory() stringByAppendingPathComponent:[h stringByAppendingString:@".resume"]] : nil;
}

@interface FDMEngine : NSObject <NSURLSessionDownloadDelegate>
+ (instancetype)shared;
- (NSArray *)items;
- (NSMutableDictionary *)itemForKey:(NSString *)key;
- (BOOL)hasResumeDataForKey:(NSString *)key;
- (void)startURL:(NSString *)url name:(NSString *)name;
- (void)pauseKey:(NSString *)key;
- (void)resumeKey:(NSString *)key;
- (void)cancelKey:(NSString *)key deleteFile:(BOOL)deleteFile;
- (void)forgetKey:(NSString *)key;
@end

@implementation FDMEngine {
    NSMutableArray *_items;
    NSMutableDictionary *_taskMap;
    NSMutableDictionary *_samples;
    NSURLSession *_session;
    NSTimeInterval _lastSave;
}

+ (instancetype)shared {
    static FDMEngine *one = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ one = [[FDMEngine alloc] init]; });
    return one;
}

- (instancetype)init {
    if ((self = [super init])) {
        _items = [NSMutableArray array];
        _taskMap = [NSMutableDictionary dictionary];
        _samples = [NSMutableDictionary dictionary];
        [self loadTasks];

        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:@"FocusDM.resumable"];
        cfg.sessionSendsLaunchEvents = YES;
        cfg.discretionary = NO;
        _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
        FDMLog(@"engine: ready, persisted=%lu", (unsigned long)_items.count);
    }
    return self;
}

- (void)loadTasks {
    NSData *data = [NSData dataWithContentsOfFile:FDMTasksFilePath()];
    if (!data.length) return;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![json isKindOfClass:[NSArray class]]) return;
    for (id entry in (NSArray *)json) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSMutableDictionary *d = [entry mutableCopy];
        NSInteger st = [d[@"state"] integerValue];
        if (st == FDMStateDownloading) st = FDMStateInterrupted;   // 上次被杀时还在下
        d[@"state"] = @(st);
        d[@"speed"] = @0;
        [_items addObject:d];
    }
}

- (void)persist {
    @synchronized (self) {
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:_items.count];
        for (NSMutableDictionary *d in _items) {
            NSMutableDictionary *copy = [d mutableCopy];
            [copy removeObjectForKey:@"task"];
            [out addObject:copy];
        }
        NSData *data = [NSJSONSerialization dataWithJSONObject:out options:0 error:NULL];
        if (data) [data writeToFile:FDMTasksFilePath() atomically:YES];
        _lastSave = [[NSDate date] timeIntervalSince1970];
    }
}

- (NSArray *)items {
    @synchronized (self) { return [_items copy]; }
}

- (NSMutableDictionary *)itemForKey:(NSString *)key {
    if (!key.length) return nil;
    @synchronized (self) {
        for (NSMutableDictionary *d in _items) {
            if ([d[@"key"] isEqual:key]) return d;
        }
    }
    return nil;
}

- (BOOL)hasResumeDataForKey:(NSString *)key {
    NSString *path = FDMResumePathForKey(key);
    if (!path) return NO;
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

- (void)forgetKey:(NSString *)key {
    NSMutableDictionary *item = [self itemForKey:key];
    if (!item) return;
    @synchronized (self) { [_items removeObject:item]; }
    [self persist];
}

- (void)startURL:(NSString *)url name:(NSString *)name {
    if (!url.length) return;
    if ([self itemForKey:url]) { [self resumeKey:url]; return; }

    NSMutableDictionary *item = [NSMutableDictionary dictionary];
    item[@"key"] = url;
    item[@"url"] = url;
    NSString *shortName = [[url lastPathComponent] stringByRemovingPercentEncoding];
    item[@"name"] = name.length ? name : (shortName.length ? shortName : url);
    item[@"state"] = @(FDMStateDownloading);
    item[@"received"] = @0;
    item[@"total"] = @0;
    item[@"speed"] = @0;
    item[@"time"] = @([[NSDate date] timeIntervalSince1970]);
    @synchronized (self) { [_items insertObject:item atIndex:0]; }
    [self startTaskForItem:item useResume:NO];
    [self persist];
}

- (void)startTaskForItem:(NSMutableDictionary *)item useResume:(BOOL)useResume {
    NSString *key = item[@"key"];
    NSURLSessionDownloadTask *task = nil;
    if (useResume) {
        NSData *resume = [NSData dataWithContentsOfFile:FDMResumePathForKey(key)];
        if (resume.length) task = [_session downloadTaskWithResumeData:resume];
    }
    if (!task) {
        NSURL *u = [NSURL URLWithString:item[@"url"]];
        if (!u) {
            item[@"state"] = @(FDMStateFailed);
            item[@"error"] = @"地址无效";
            [self persist];
            return;
        }
        task = [_session downloadTaskWithURL:u];
    }
    task.taskDescription = key;
    @synchronized (self) {
        _taskMap[key] = task;
        _samples[key] = @[@(0), @([[NSDate date] timeIntervalSince1970])];
    }
    item[@"state"] = @(FDMStateDownloading);
    [task resume];
    FDMLog(@"engine: start %@ resume=%d", key, (int)useResume);
}

- (void)pauseKey:(NSString *)key {
    NSURLSessionDownloadTask *task = nil;
    @synchronized (self) { task = _taskMap[key]; }
    NSMutableDictionary *item = [self itemForKey:key];
    if (!task) {
        if (item) { item[@"state"] = @(FDMStatePaused); [self persist]; }
        return;
    }
    NSString *path = FDMResumePathForKey(key);
    [task cancelByProducingResumeData:^(NSData *data) {
        if (data.length && path) [data writeToFile:path atomically:YES];
        item[@"state"] = @(FDMStatePaused);
        item[@"speed"] = @0;
        @synchronized (self) { [_taskMap removeObjectForKey:key]; }
        [self persist];
        FDMLog(@"engine: paused %@ resumeBytes=%lu", key, (unsigned long)data.length);
    }];
}

- (void)resumeKey:(NSString *)key {
    NSMutableDictionary *item = [self itemForKey:key];
    if (!item) return;
    @synchronized (self) { if (_taskMap[key]) return; }
    [self startTaskForItem:item useResume:[self hasResumeDataForKey:key]];
    [self persist];
}

- (void)cancelKey:(NSString *)key deleteFile:(BOOL)deleteFile {
    NSURLSessionDownloadTask *task = nil;
    @synchronized (self) { task = _taskMap[key]; [_taskMap removeObjectForKey:key]; }
    if (task) [task cancel];
    NSMutableDictionary *item = [self itemForKey:key];
    if (deleteFile) {
        NSString *path = item[@"path"];
        if (path.length) [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        NSString *resume = FDMResumePathForKey(key);
        if (resume) [[NSFileManager defaultManager] removeItemAtPath:resume error:NULL];
        if (item) @synchronized (self) { [_items removeObject:item]; }
    } else if (item) {
        item[@"state"] = @(FDMStatePaused);
        item[@"speed"] = @0;
    }
    [self persist];
}

#pragma mark 引擎回调

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)task
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    NSString *key = task.taskDescription;
    if (!key.length) return;
    NSMutableDictionary *item = [self itemForKey:key];
    if (!item) return;

    item[@"received"] = @(totalBytesWritten);
    if (totalBytesExpectedToWrite > 0) item[@"total"] = @(totalBytesExpectedToWrite);

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSArray *prev = nil;
    @synchronized (self) { prev = _samples[key]; }
    if (prev) {
        double dt = now - [prev[1] doubleValue];
        if (dt > 0.4) {
            double db = (double)(totalBytesWritten - [prev[0] longLongValue]);
            item[@"speed"] = @(db / dt);
            @synchronized (self) { _samples[key] = @[@(totalBytesWritten), @(now)]; }
        }
    } else {
        @synchronized (self) { _samples[key] = @[@(totalBytesWritten), @(now)]; }
    }

    if (now - _lastSave > 1.5) [self persist];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)location {
    NSString *key = task.taskDescription;
    NSMutableDictionary *item = [self itemForKey:key];
    if (!item || !location.path) return;

    NSString *name = nil;
    @try {
        name = [task.response suggestedFilename];
    } @catch (NSException *e) { (void)e; }
    if (!name.length) name = item[@"name"];
    if (!name.length) name = @"download";

    NSString *dir = FDMDownloadDirectory();
    NSString *dest = [dir stringByAppendingPathComponent:name];
    NSString *base = [name stringByDeletingPathExtension];
    NSString *ext = [name pathExtension];
    int i = 1;
    while ([[NSFileManager defaultManager] fileExistsAtPath:dest] && i < 500) {
        NSString *candidate = ext.length ? [NSString stringWithFormat:@"%@-%d.%@", base, i, ext]
                                         : [NSString stringWithFormat:@"%@-%d", base, i];
        dest = [dir stringByAppendingPathComponent:candidate];
        i++;
    }
    [[NSFileManager defaultManager] removeItemAtPath:dest error:NULL];

    NSError *error = nil;
    if ([[NSFileManager defaultManager] moveItemAtPath:location.path toPath:dest error:&error]) {
        unsigned long long size = 0;
        @try {
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:dest error:NULL];
            size = [attrs[NSFileSize] unsignedLongLongValue];
        } @catch (NSException *e) { (void)e; }
        item[@"path"] = dest;
        item[@"size"] = @(size);
        item[@"state"] = @(FDMStateCompleted);
        item[@"speed"] = @0;
        NSString *resume = FDMResumePathForKey(key);
        if (resume) [[NSFileManager defaultManager] removeItemAtPath:resume error:NULL];
        FDMLog(@"engine: finished %@ -> %@ (%llu)", key, dest, size);
    } else {
        item[@"state"] = @(FDMStateFailed);
        item[@"error"] = error.localizedDescription ?: @"保存失败";
        FDMLog(@"engine: move failed %@", error.localizedDescription);
    }
    [self persist];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSString *key = task.taskDescription;
    if (!key.length) return;
    @synchronized (self) { [_taskMap removeObjectForKey:key]; [_samples removeObjectForKey:key]; }
    if (!error) return;

    NSData *resume = error.userInfo[NSURLSessionDownloadTaskResumeData];
    NSMutableDictionary *item = [self itemForKey:key];
    NSString *path = FDMResumePathForKey(key);
    if ([resume isKindOfClass:[NSData class]] && resume.length && path) {
        [resume writeToFile:path atomically:YES];
        if (item) { item[@"state"] = @(FDMStateInterrupted); item[@"speed"] = @0; }
    } else if (!(error.code == NSURLErrorCancelled && [error.domain isEqualToString:NSURLErrorDomain])) {
        if (item) {
            item[@"state"] = @(FDMStateFailed);
            item[@"speed"] = @0;
            item[@"error"] = error.localizedDescription ?: @"下载失败";
        }
    }
    [self persist];
    FDMLog(@"engine: complete %@ err=%@", key, error.localizedDescription);
}

@end
'''

rep("""@implementation FDMRow
@end""", ENGINE, 1)

# ---------- 4. 单元格状态文案 ----------
rep("""        case FDMStateCompleted:
            _stateLabel.text = @"已完成";
            _stateLabel.textColor = [UIColor systemGreenColor];
            break;""",
"""        case FDMStateCompleted:
            _stateLabel.text = @"已完成";
            _stateLabel.textColor = [UIColor systemGreenColor];
            break;
        case FDMStateInterrupted:
            _stateLabel.text = @"已中断";
            _stateLabel.textColor = [UIColor systemOrangeColor];
            break;""")

# ---------- 5. 历史记录：source / url / 中断态 ----------
rep("""- (FDMRow *)rowFromRecord:(NSDictionary *)record {
    FDMRow *row = [[FDMRow alloc] init];
    row.key = record[@"key"] ?: @"";
    row.name = record[@"name"] ?: @"";
    row.path = record[@"path"] ?: @"";
    row.size = [record[@"size"] unsignedLongLongValue];
    row.state = [record[@"state"] integerValue];
    row.progress = 1.0;""",
"""- (FDMRow *)rowFromRecord:(NSDictionary *)record {
    FDMRow *row = [[FDMRow alloc] init];
    row.source = 2;
    row.key = record[@"key"] ?: @"";
    row.url = record[@"url"] ?: row.key;
    row.name = record[@"name"] ?: @"";
    row.path = record[@"path"] ?: @"";
    row.size = [record[@"size"] unsignedLongLongValue];
    row.state = [record[@"state"] integerValue];
    if (row.state == FDMStateDownloading || row.state == FDMStatePaused) row.state = FDMStateInterrupted;
    row.progress = (row.state == FDMStateCompleted) ? 1.0 : [record[@"progress"] doubleValue];""")

rep("""    [bits addObject:row.state == FDMStateCompleted ? @"已完成" : @"失败"];""",
"""    if (row.state == FDMStateCompleted) [bits addObject:@"已完成"];
    else if (row.state == FDMStateInterrupted) [bits addObject:@"已中断 · 可继续"];
    else [bits addObject:@"失败"];""")

# ---------- 6. refresh 合并三方任务 ----------
OLD_REFRESH = """    NSMutableArray *active = [NSMutableArray arrayWithCapacity:tasks.count];
    NSMutableSet *nowKeys = [NSMutableSet set];

    for (id task in tasks) {
        FDMRow *row = [self rowFromTask:task];
        if (!row.key.length) continue;
        [nowKeys addObject:row.key];
        if (row.state == FDMStateCompleted) {
            // 完成的任务从引擎里落一条历史，避免下次消失后丢记录（已存在则不重复写盘）
            if (![[FDMStore shared] recordForKey:row.key]) [self recordForRow:row state:FDMStateCompleted];
        } else {
            [active addObject:row];
        }
    }

    // 上一轮存在、这一轮不见了的任务：判定为已完成或失败
    if (_loaded) {
        for (NSString *key in _seen) {
            if ([nowKeys containsObject:key]) continue;
            NSMutableDictionary *rec = [[FDMStore shared] recordForKey:key];
            if (rec) continue;
            NSMutableDictionary *record = [NSMutableDictionary dictionary];
            record[@"key"] = key;
            record[@"name"] = [[key lastPathComponent] stringByRemovingPercentEncoding] ?: key;
            record[@"state"] = @(FDMStateFailed);
            record[@"time"] = @([[NSDate date] timeIntervalSince1970]);
            [[FDMStore shared] upsertRecord:record];
        }
    }
    [_seen removeAllObjects];
    [_seen unionSet:nowKeys];
    _loaded = YES;"""

NEW_REFRESH = """    NSMutableArray *active = [NSMutableArray array];
    NSMutableSet *nowKeys = [NSMutableSet set];

    // 1) 自建引擎的任务：跨启动可见、可续传
    for (NSDictionary *item in [[FDMEngine shared] items]) {
        FDMRow *row = [self rowFromEngineItem:item];
        if (!row.key.length) continue;
        if (row.state == FDMStateCompleted) {
            if (![[FDMStore shared] recordForKey:row.key]) [self recordForRow:row state:FDMStateCompleted];
            [[FDMEngine shared] forgetKey:row.key];
            continue;
        }
        [active addObject:row];
        [nowKeys addObject:row.key];
    }

    // 2) 宿主引擎的任务：只活在内存里，重启后消失，只能重下
    for (id task in tasks) {
        FDMRow *row = [self rowFromTask:task];
        if (!row.key.length) continue;
        row.source = 1;
        row.url = row.key;
        if ([nowKeys containsObject:row.key]) continue;
        [nowKeys addObject:row.key];
        if (row.state == FDMStateCompleted) {
            if (![[FDMStore shared] recordForKey:row.key]) [self recordForRow:row state:FDMStateCompleted];
        } else {
            [active addObject:row];
            // 顺手把进度写进历史，App 被杀后至少能看到「已中断」
            NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
            snapshot[@"key"] = row.key;
            snapshot[@"url"] = row.url ?: row.key;
            snapshot[@"name"] = row.name ?: row.key;
            snapshot[@"state"] = @(FDMStateInterrupted);
            snapshot[@"progress"] = @(row.progress);
            snapshot[@"time"] = @([[NSDate date] timeIntervalSince1970]);
            [[FDMStore shared] upsertRecord:snapshot];
        }
    }
    _loaded = YES;"""

rep(OLD_REFRESH, NEW_REFRESH, 1)

# ---------- 7. rowFromEngineItem ----------
rep("""- (void)refresh {""",
"""- (FDMRow *)rowFromEngineItem:(NSDictionary *)item {
    FDMRow *row = [[FDMRow alloc] init];
    row.source = 0;
    row.key = item[@"key"] ?: @"";
    row.url = item[@"url"] ?: row.key;
    row.name = item[@"name"] ?: row.key;
    row.path = item[@"path"] ?: @"";
    row.state = [item[@"state"] integerValue];
    row.speed = [item[@"speed"] doubleValue];
    unsigned long long received = [item[@"received"] unsignedLongLongValue];
    unsigned long long total = [item[@"total"] unsignedLongLongValue];
    row.size = [item[@"size"] unsignedLongLongValue] ? [item[@"size"] unsignedLongLongValue] : received;
    row.progress = total > 0 ? MIN(1.0, (double)received / (double)total) : 0.0;
    if (row.state == FDMStateCompleted) row.progress = 1.0;

    NSMutableArray *bits = [NSMutableArray array];
    if (row.state == FDMStateCompleted) {
        if (row.size) [bits addObject:FDMHumanSize((double)row.size)];
        [bits addObject:row.path.length ? [row.path lastPathComponent] : @"已保存"];
    } else if (row.state == FDMStateFailed) {
        [bits addObject:item[@"error"] ?: @"下载失败"];
    } else {
        [bits addObject:[NSString stringWithFormat:@"%.1f%%", row.progress * 100.0]];
        if (row.state == FDMStateDownloading && row.speed > 0) {
            [bits addObject:[NSString stringWithFormat:@"%@/s", FDMHumanSize(row.speed)]];
        }
        if (received) [bits addObject:[NSString stringWithFormat:@"已下 %@", FDMHumanSize((double)received)]];
        if (total > received) [bits addObject:[NSString stringWithFormat:@"共 %@", FDMHumanSize((double)total)]];
        if (row.state == FDMStateInterrupted) [bits addObject:@"可继续"];
    }
    row.meta = [bits componentsJoinedByString:@" · "];
    return row;
}

- (void)refresh {""")

# ---------- 8. 新增下载走自建引擎 ----------
rep("""        id fm = FDMSharedFileManager();
        if ([fm respondsToSelector:@selector(downloadWithUrl:title:)]) {
            NSString *name = [[trimmed lastPathComponent] stringByRemovingPercentEncoding];
            [fm downloadWithUrl:trimmed title:name.length ? name : @"下载文件"];
        }""",
"""        // 走自建可恢复引擎：暂停 / 杀 App / 重启都能续传
        NSString *name = [[trimmed lastPathComponent] stringByRemovingPercentEncoding];
        [[FDMEngine shared] startURL:trimmed name:name.length ? name : nil];""")

# ---------- 9. 操作：全部 / 单行 / 删除 ----------
OPS_OLD_START = """- (void)toggleAll {"""
OPS_NEW = """- (void)restartRow:(FDMRow *)row {
    NSString *url = row.url.length ? row.url : row.key;
    if (url.length) [[FDMEngine shared] startURL:url name:row.name];
}

- (void)toggleAll {
    id fm = FDMSharedFileManager();
    BOOL pause = NO;
    for (FDMRow *row in _active) {
        if (row.state == FDMStateDownloading) { pause = YES; break; }
    }
    for (FDMRow *row in _active) {
        if (row.source == 0) {
            if (pause) [[FDMEngine shared] pauseKey:row.key];
            else [[FDMEngine shared] resumeKey:row.key];
        } else if (row.source == 1) {
            if (pause) { if ([fm respondsToSelector:@selector(suspendTask:)]) [fm suspendTask:row.task]; }
            else { if ([fm respondsToSelector:@selector(startTask:)]) [fm startTask:row.task]; }
        }
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refresh];
    });
}

- (void)toggleRow:(FDMRow *)row {
    if (row.source == 0) {
        if (row.state == FDMStateDownloading) [[FDMEngine shared] pauseKey:row.key];
        else [[FDMEngine shared] resumeKey:row.key];
    } else if (row.source == 1) {
        id fm = FDMSharedFileManager();
        if (row.state == FDMStateDownloading) {
            if ([fm respondsToSelector:@selector(suspendTask:)]) [fm suspendTask:row.task];
        } else {
            if ([fm respondsToSelector:@selector(startTask:)]) [fm startTask:row.task];
        }
    } else {
        [self restartRow:row];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refresh];
    });
}

- (void)deleteRow:(FDMRow *)row {
    id fm = FDMSharedFileManager();
    if (row.source == 0) {
        [[FDMEngine shared] cancelKey:row.key deleteFile:YES];
    } else {
        if (row.task) {
            if ([fm respondsToSelector:@selector(cancelTask:)]) [fm cancelTask:row.task];
            id sm = [fm respondsToSelector:@selector(sessionManager)] ? [fm sessionManager] : nil;
            if (sm && [sm respondsToSelector:@selector(removeWithUrl:completely:)]) {
                [sm removeWithUrl:row.key completely:YES];
            }
        }
        [[FDMEngine shared] cancelKey:row.key deleteFile:YES];
        if (row.path.length) [[NSFileManager defaultManager] removeItemAtPath:row.path error:NULL];
    }
    [[FDMStore shared] dropKey:row.key];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refresh];
    });
}
"""

# 替换从 - (void)toggleAll 起到 deleteRow 结束（到 "#pragma mark 表格" 之前）
i = s.index(OPS_OLD_START)
j = s.index('#pragma mark 表格')
s = s[:i] + OPS_NEW + '\n' + s[j:]

# ---------- 10. 侧滑动作条件 ----------
rep("""    if (row.task && (row.state == FDMStateDownloading || row.state == FDMStatePaused)) {
        NSString *title = (row.state == FDMStateDownloading) ? @"暂停" : @"继续";""",
"""    BOOL canToggle = (row.state == FDMStateDownloading || row.state == FDMStatePaused || row.state == FDMStateInterrupted);
    if (canToggle) {
        NSString *title = @"继续";
        if (row.state == FDMStateDownloading) title = @"暂停";
        else if (row.source == 2) title = @"重试";""")

# ---------- 11. 图标：先跑原生，再把缓存图盖上去 + 延迟抓取 ----------
ICON_OLD_START = """static void FDMSetupLogoForModel(id self, SEL _cmd, id model) {"""
ICON_NEW = """static NSMutableSet *g_iconTouched = nil;

static void FDMApplyCachedIcon(id cell, UIImage *image) {
    @try {
        UIImageView *iv = [cell valueForKey:@"logoImage"];
        if ([iv isKindOfClass:[UIImageView class]]) {
            iv.image = image;
            iv.hidden = NO;
            iv.contentMode = UIViewContentModeScaleAspectFit;
        }
        UIView *text = [cell valueForKey:@"logoText"];
        if ([text isKindOfClass:[UIView class]]) text.hidden = YES;
    } @catch (NSException *e) { (void)e; }
}

static UIImage *FDMCurrentLogoImage(id cell) {
    UIImage *img = nil;
    @try {
        UIImageView *iv = [cell valueForKey:@"logoImage"];
        if ([iv isKindOfClass:[UIImageView class]]) img = iv.image;
    } @catch (NSException *e) { (void)e; }
    return img;
}

static void FDMSetupLogoForModel(id self, SEL _cmd, id model) {"""

i = s.index(ICON_OLD_START)
# 找到该函数结束（下一个 "#pragma mark - 设置页插入"）
j = s.index("#pragma mark - 设置页插入")
ICON_BODY = """static void FDMSetupLogoForModel(id self, SEL _cmd, id model) {
    NSString *iconURL = FDMIconURLForModel(model);

    // 先跑原生实现：它会清空/起一个异步请求，之后我们再把自己的磁盘缓存图盖上去，
    // 这样每次进主页都是立刻有图，而不是「先空白 → 再闪一下」
    if (g_origSetupLogo) ((void (*)(id, SEL, id))g_origSetupLogo)(self, _cmd, model);
    if (!iconURL.length) return;

    UIImage *cached = [[FDMImageCache shared] cachedImageForURL:iconURL];
    if (cached) {
        FDMApplyCachedIcon(self, cached);
        return;
    }

    if (![[FDMImageCache shared] isPending:iconURL]) [[FDMImageCache shared] prefetchURL:iconURL];

    // 原生异步加载完成后把图抓下来存盘（只抓一次，避免重复写）
    __weak id weakCell = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id cell = weakCell;
        if (!cell) return;
        UIImage *now = FDMCurrentLogoImage(cell);
        if (!now || [[FDMImageCache shared] cachedImageForURL:iconURL]) return;
        [[FDMImageCache shared] storeImage:now forURL:iconURL];
        static NSInteger stored = 0;
        stored++;
        FDMLog(@"icon: stored %@ (total %ld)", [iconURL lastPathComponent], (long)stored);
    });
}

"""
s = s[:i] + ICON_BODY + s[j:]

# ---------- 12. 打开页面：push（先修宿主导航的断言）+ 模态兜底 ----------
NAV_SWIZZLE = """static IMP g_origApplyNavState = NULL;

// 宿主 BaseNavigationController 的 applyNavigationBarStateForViewController:animated:
// 里断言 vc 必须是 BaseViewController 子类，否则 raise。我们只让它对自己人跑，其余跳过。
static void FDMApplyNavState(id self, SEL _cmd, id vc, BOOL animated) {
    Class base = NSClassFromString(@"BaseViewController");
    if (base && vc && ![vc isKindOfClass:base]) {
        FDMLog(@"nav: skip bar-state for %@", NSStringFromClass([vc class]));
        return;
    }
    if (g_origApplyNavState) ((void (*)(id, SEL, id, BOOL))g_origApplyNavState)(self, _cmd, vc, animated);
}

static void FDMOpenDownloads(UIViewController *host) {
    FDMLog(@"stage: open downloads");
    @try {
        FDMViewController *vc = [[FDMViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        if (host.navigationController) {
            // 走原生 push：右进右出的动画、边缘返回手势都和其他菜单一致
            [host.navigationController pushViewController:vc animated:YES];
            FDMLog(@"stage: pushed");
        } else {
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
            nav.modalPresentationStyle = UIModalPresentationFullScreen;
            [host presentViewController:nav animated:YES completion:nil];
            FDMLog(@"stage: presented modal");
        }
    } @catch (NSException *e) {
        FDMLog(@"*** open downloads threw %@: %@", e.name, e.reason);
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"下载管理打开失败"
                                                                      message:[NSString stringWithFormat:@"%@: %@", e.name, e.reason]
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [host presentViewController:alert animated:YES completion:nil];
    }
}

"""

i = s.index("static void FDMOpenDownloads(UIViewController *host) {")
j = s.index("static IMP g_origWillAppear = NULL;")
s = s[:i] + NAV_SWIZZLE + s[j:]

# ---------- 13. 注册导航 hook ----------
rep("""        if (cell) FDMInstallHook(cell, @selector(setupLogoForModel:), (IMP)FDMSetupLogoForModel, &g_origSetupLogo);""",
"""        if (cell) FDMInstallHook(cell, @selector(setupLogoForModel:), (IMP)FDMSetupLogoForModel, &g_origSetupLogo);

        Class navCls = NSClassFromString(@"BaseNavigationController");
        if (navCls) {
            FDMInstallHook(navCls, @selector(applyNavigationBarStateForViewController:animated:),
                           (IMP)FDMApplyNavState, &g_origApplyNavState);
        }""")

# ---------- 14. 记录里带上 url / progress ----------
rep("""    record[@"key"] = row.key ?: @"";
    record[@"name"] = row.name ?: @"";""",
"""    record[@"key"] = row.key ?: @"";
    record[@"url"] = row.url.length ? row.url : (row.key ?: @"");
    record[@"progress"] = @(row.progress);
    record[@"name"] = row.name ?: @"";""")

io.open(P, 'w', encoding='utf-8', newline='\n').write(s)
print('v12 patches applied, lines=%d' % s.count('\n'))
