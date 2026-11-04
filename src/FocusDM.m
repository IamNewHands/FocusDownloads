// FocusDM.m — Focus 浏览器「统一下载管理」
//
// 注入式 dylib。只使用 ObjC runtime 调用宿主已有能力：
//   +[FileManager shareInstance] / -allTasks / -suspendTask: / -startTask: / -cancelTask:
//   -downloadWithUrl:title: / -sessionManager
//   任务对象 _TtC9PPBrowser14TRDownloadTask 的 KVC 属性
// 不在编译期链接任何 Swift 符号，也不引用宿主头文件。
//
// 功能：
//   设置页最后一段追加一行「下载管理」→ 任务列表（进行中 / 已完成）
//   行内操作：暂停 / 继续 / 删除（可连同文件）
//   导航栏 ＋：输入 URL 新增下载
//   导航栏 全部暂停 / 全部继续
//   已完成与失败记录永久保留（Documents/FocusDM/history.json）

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <unistd.h>
#import <fcntl.h>
#import <signal.h>
#import <string.h>
#import <stdarg.h>

#pragma mark - 宿主接口（仅编译期声明）

@protocol FDMFileManager <NSObject>
- (NSArray *)allTasks;
- (void)suspendTask:(id)task;
- (void)startTask:(id)task;
- (void)cancelTask:(id)task;
- (void)downloadWithUrl:(id)url title:(NSString *)title;
- (id)sessionManager;
@end

@protocol FDMSessionManager <NSObject>
- (void)removeWithUrl:(id)url completely:(BOOL)completely;
@end

enum {
    FDMStateDownloading = 0,
    FDMStatePaused      = 1,
    FDMStateCompleted   = 2,
    FDMStateFailed      = 3,
    FDMStateInterrupted = 4,
};

#pragma mark - 工具

static id FDMSharedFileManager(void) {
    static id shared = nil;
    static BOOL resolved = NO;
    if (resolved) return shared;
    resolved = YES;
    Class cls = NSClassFromString(@"FileManager");
    SEL sel = NSSelectorFromString(@"shareInstance");
    if (!cls || ![cls respondsToSelector:sel]) return nil;
    shared = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel);
    return shared;
}

static NSString *FDMString(id obj) {
    if (!obj) return nil;
    if ([obj isKindOfClass:[NSString class]]) return obj;
    if ([obj isKindOfClass:[NSURL class]]) return [(NSURL *)obj absoluteString];
    if ([obj respondsToSelector:@selector(absoluteString)]) return [obj performSelector:@selector(absoluteString)];
    if ([obj respondsToSelector:@selector(description)]) return [obj description];
    return nil;
}

static NSString *FDMHumanSize(double bytes) {
    if (bytes <= 0) return @"—";
    static NSString *units[] = { @"B", @"KB", @"MB", @"GB", @"TB" };
    int idx = 0;
    while (bytes >= 1024.0 && idx < 4) { bytes /= 1024.0; idx++; }
    return [NSString stringWithFormat:(idx == 0 ? @"%.0f %@" : @"%.1f %@"), bytes, units[idx]];
}

static NSString *FDMHumanETA(double seconds) {
    if (!(seconds > 0) || seconds > 359999) return nil;
    int s = (int)seconds;
    return [NSString stringWithFormat:@"%02d:%02d", s / 60, s % 60];
}

static unsigned long long FDMFileSizeAtPath(NSString *path) {
    if (!path.length) return 0;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    if (!attrs) return 0;
    return [attrs[NSFileSize] unsignedLongLongValue];
}

static NSString *FDMDocumentsPath(void) {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
}

static NSString *FDMHistoryPath(void) {
    NSString *dir = [FDMDocumentsPath() stringByAppendingPathComponent:@"FocusDM"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return [dir stringByAppendingPathComponent:@"history.json"];
}

#pragma mark - 诊断日志（崩溃时留下最后一步）

static char g_logPath[1024];

static void FDMPrepareLogPath(void) {
    NSString *dir = [FDMDocumentsPath() stringByAppendingPathComponent:@"FocusDM"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *path = [dir stringByAppendingPathComponent:@"crash.log"];
    const char *utf8 = path.fileSystemRepresentation;
    if (!utf8) return;
    strncpy(g_logPath, utf8, sizeof(g_logPath) - 1);
    g_logPath[sizeof(g_logPath) - 1] = '\0';
}

// 主线程使用：格式化后追加写并立即 close，异常退出也能留下记录
static void FDMLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSDateFormatter *tf = [[NSDateFormatter alloc] init];
    tf.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [tf stringFromDate:[NSDate date]], msg];
    if (!g_logPath[0]) FDMPrepareLogPath();

    const char *utf8 = line.UTF8String;
    if (!utf8) return;
    int fd = open(g_logPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    size_t len = strlen(utf8), done = 0;
    while (done < len) {
        ssize_t n = write(fd, utf8 + done, len - done);
        if (n <= 0) break;
        done += (size_t)n;
    }
    close(fd);
}

static void FDMExceptionHandler(NSException *e) {
    FDMLog(@"*** UNCAUGHT %@: %@\n%@", e.name, e.reason,
           [e.callStackSymbols componentsJoinedByString:@"\n"]);
}

static void FDMSignalHandler(int sig) {
    char buf[128];
    int n = snprintf(buf, sizeof(buf), "\n*** CRASH SIGNAL %d ***\n", sig);
    if (g_logPath[0] && n > 0) {
        int fd = open(g_logPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            ssize_t ignored = write(fd, buf, (size_t)n);
            (void)ignored;
            close(fd);
        }
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

static void FDMInstallCrashHandlers(void) {
    FDMPrepareLogPath();
    NSSetUncaughtExceptionHandler(&FDMExceptionHandler);
    signal(SIGABRT, FDMSignalHandler);
    signal(SIGSEGV, FDMSignalHandler);
    signal(SIGBUS, FDMSignalHandler);
    signal(SIGILL, FDMSignalHandler);
    signal(SIGFPE, FDMSignalHandler);
}

static double FDMNumber(id task, NSString *key) {
    @try {
        id v = [task valueForKey:key];
        if ([v isKindOfClass:[NSNumber class]]) return [v doubleValue];
    } @catch (NSException *e) { (void)e; }
    return 0;
}

static id FDMValue(id task, NSString *key) {
    @try { return [task valueForKey:key]; } @catch (NSException *e) { return nil; }
}

#pragma mark - 记录存储

@interface FDMStore : NSObject
@property (nonatomic, strong) NSMutableArray *records;   // 已完成 / 失败，永久保留
+ (instancetype)shared;
- (void)loadFromDisk;
- (void)saveToDisk;
- (NSMutableDictionary *)recordForKey:(NSString *)key;
- (void)upsertRecord:(NSMutableDictionary *)record;
- (void)dropKey:(NSString *)key;
@end

@implementation FDMStore

+ (instancetype)shared {
    static FDMStore *store = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        store = [[FDMStore alloc] init];
        [store loadFromDisk];
    });
    return store;
}

- (instancetype)init {
    if ((self = [super init])) _records = [NSMutableArray array];
    return self;
}

- (void)loadFromDisk {
    NSString *path = FDMHistoryPath();
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) return;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if ([json isKindOfClass:[NSArray class]]) {
        [self.records removeAllObjects];
        for (id entry in (NSArray *)json) {
            if ([entry isKindOfClass:[NSDictionary class]]) [self.records addObject:[entry mutableCopy]];
        }
    }
}

- (void)saveToDisk {
    @try {
        NSData *data = [NSJSONSerialization dataWithJSONObject:self.records options:0 error:NULL];
        if (data) [data writeToFile:FDMHistoryPath() atomically:YES];
    } @catch (NSException *e) { (void)e; }
}

- (NSMutableDictionary *)recordForKey:(NSString *)key {
    if (!key.length) return nil;
    for (NSMutableDictionary *r in self.records) {
        if ([r[@"key"] isEqual:key]) return r;
    }
    return nil;
}

- (void)upsertRecord:(NSMutableDictionary *)record {
    if (!record[@"key"]) return;
    NSMutableDictionary *old = [self recordForKey:record[@"key"]];
    if (old) [self.records removeObject:old];
    [self.records insertObject:record atIndex:0];
    [self saveToDisk];
}

- (void)dropKey:(NSString *)key {
    NSMutableDictionary *old = [self recordForKey:key];
    if (old) { [self.records removeObject:old]; [self saveToDisk]; }
}

@end

#pragma mark - 行模型

@interface FDMRow : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *meta;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, assign) double progress;
@property (nonatomic, assign) double speed;
@property (nonatomic, assign) double eta;
@property (nonatomic, assign) unsigned long long size;
@property (nonatomic, assign) NSInteger state;
@property (nonatomic, strong) id task;              // 进行中的任务对象，历史行是 nil
@property (nonatomic, assign) NSInteger source;     // 0=自建引擎 1=宿主引擎 2=历史记录
@property (nonatomic, copy) NSString *url;          // 原始下载地址（续传 / 重试用）
@end

@implementation FDMRow
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


#pragma mark - 单元格

@interface FDMCell : UITableViewCell
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *metaLabel;
@property (nonatomic, strong) UIProgressView *bar;
@property (nonatomic, strong) UILabel *stateLabel;
- (void)renderRow:(FDMRow *)row;
@end

@implementation FDMCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier])) {
        _nameLabel = [[UILabel alloc] init];
        _nameLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        _nameLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [self.contentView addSubview:_nameLabel];

        _metaLabel = [[UILabel alloc] init];
        _metaLabel.font = [UIFont systemFontOfSize:12];
        _metaLabel.textColor = [UIColor secondaryLabelColor];
        _metaLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.contentView addSubview:_metaLabel];

        _bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
        _bar.progressTintColor = self.tintColor;
        [self.contentView addSubview:_bar];

        _stateLabel = [[UILabel alloc] init];
        _stateLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        _stateLabel.textAlignment = NSTextAlignmentRight;
        [self.contentView addSubview:_stateLabel];

        self.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat h = self.contentView.bounds.size.height;
    CGFloat pad = 16.0;

    _stateLabel.frame = CGRectMake(w - pad - 56.0, pad - 2.0, 56.0, 16.0);
    _nameLabel.frame = CGRectMake(pad, pad - 3.0, w - pad * 2 - 60.0, 20.0);
    _metaLabel.frame = CGRectMake(pad, pad + 17.0, w - pad * 2, 16.0);
    _bar.frame = CGRectMake(pad, h - 8.0, w - pad * 2, 2.0);
}

- (void)renderRow:(FDMRow *)row {
    _nameLabel.text = row.name.length ? row.name : row.key;
    _metaLabel.text = row.meta;
    _bar.hidden = (row.state == FDMStateCompleted || row.state == FDMStateFailed);
    _bar.progress = (float)MAX(0.0, MIN(1.0, row.progress));

    switch (row.state) {
        case FDMStateDownloading:
            _stateLabel.text = @"下载中";
            _stateLabel.textColor = [UIColor systemBlueColor];
            break;
        case FDMStatePaused:
            _stateLabel.text = @"已暂停";
            _stateLabel.textColor = [UIColor systemOrangeColor];
            break;
        case FDMStateCompleted:
            _stateLabel.text = @"已完成";
            _stateLabel.textColor = [UIColor systemGreenColor];
            break;
        case FDMStateInterrupted:
            _stateLabel.text = @"已中断";
            _stateLabel.textColor = [UIColor systemOrangeColor];
            break;
        default:
            _stateLabel.text = @"失败";
            _stateLabel.textColor = [UIColor systemRedColor];
            break;
    }
}

@end

#pragma mark - 下载管理页

@interface FDMViewController : UITableViewController
@end

@implementation FDMViewController {
    NSArray *_active;      // FDMRow，进行中
    NSArray *_finished;    // FDMRow，已完成/失败
    NSMutableSet *_seen;   // 上一轮出现过的 key，用来检测任务消失
    BOOL _loaded;
    NSTimer *_timer;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    FDMLog(@"--- download page viewDidLoad");
    @try {
    self.title = @"下载管理";
    self.tableView.rowHeight = 62.0;
    [self.tableView registerClass:[FDMCell class] forCellReuseIdentifier:@"row"];

    UIBarButtonItem *add = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                        target:self
                                                                        action:@selector(addDownload)];
    UIBarButtonItem *all = [[UIBarButtonItem alloc] initWithTitle:@"全部暂停"
                                                            style:UIBarButtonItemStylePlain
                                                           target:self
                                                           action:@selector(toggleAll)];
    self.navigationItem.rightBarButtonItems = @[ add, all ];

    // push 进来时用系统自带的返回箭头（和其他菜单一致）；只有模态兜底才需要手动关闭
    if (self.navigationController.presentingViewController) {
        UIBarButtonItem *close = [[UIBarButtonItem alloc] initWithTitle:@"关闭"
                                                                 style:UIBarButtonItemStylePlain
                                                                target:self
                                                                action:@selector(closePage)];
        self.navigationItem.leftBarButtonItem = close;
    }

    _seen = [NSMutableSet set];
    FDMLog(@"stage: before first refresh");
    [self refresh];
    FDMLog(@"stage: after first refresh");
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
    } @catch (NSException *e) {
        FDMLog(@"*** viewDidLoad threw %@: %@\n%@", e.name, e.reason,
               [e.callStackSymbols componentsJoinedByString:@"\n"]);
        self.title = @"下载管理（初始化异常）";
    }
}

- (void)closePage {
    [_timer invalidate];
    _timer = nil;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (animated && self.isMovingFromParentViewController) {
        [_timer invalidate];
        _timer = nil;
    }
}

- (void)dealloc {
    [_timer invalidate];
}

#pragma mark 数据

- (FDMRow *)rowFromTask:(id)task {
    FDMRow *row = [[FDMRow alloc] init];
    row.task = task;

    NSString *urlString = FDMString(FDMValue(task, @"url"));
    NSString *name = FDMString(FDMValue(task, @"fileName"));
    row.path = FDMString(FDMValue(task, @"filePath"));
    if (!name.length && urlString.length) name = [[urlString lastPathComponent] stringByRemovingPercentEncoding];
    row.name = name;
    row.key = urlString.length ? urlString : (row.path.length ? row.path : name);

    row.progress = FDMNumber(task, @"progress");
    row.speed = FDMNumber(task, @"speed");
    row.eta = FDMNumber(task, @"timeRemaining");
    row.size = FDMFileSizeAtPath(row.path);

    BOOL hasError = (FDMValue(task, @"error") != nil);
    if (hasError) {
        row.state = FDMStateFailed;
    } else if (row.progress >= 0.999) {
        row.state = FDMStateCompleted;
    } else if (row.speed > 0.5) {
        row.state = FDMStateDownloading;
    } else {
        row.state = FDMStatePaused;
    }

    NSMutableArray *bits = [NSMutableArray array];
    if (row.state == FDMStateDownloading || row.state == FDMStatePaused) {
        [bits addObject:[NSString stringWithFormat:@"%.1f%%", row.progress * 100.0]];
        if (row.state == FDMStateDownloading && row.speed > 0) {
            [bits addObject:[NSString stringWithFormat:@"%@/s", FDMHumanSize(row.speed)]];
        }
        NSString *eta = FDMHumanETA(row.eta);
        if (eta && row.state == FDMStateDownloading) [bits addObject:[NSString stringWithFormat:@"剩余 %@", eta]];
        if (row.size) [bits addObject:[NSString stringWithFormat:@"已下 %@", FDMHumanSize((double)row.size)]];
    } else if (row.state == FDMStateCompleted) {
        if (row.size) [bits addObject:FDMHumanSize((double)row.size)];
        [bits addObject:row.path.length ? [row.path lastPathComponent] : @"已保存"];
    } else {
        [bits addObject:@"下载失败"];
    }
    row.meta = [bits componentsJoinedByString:@" · "];
    return row;
}

- (FDMRow *)rowFromRecord:(NSDictionary *)record {
    FDMRow *row = [[FDMRow alloc] init];
    row.source = 2;
    row.key = record[@"key"] ?: @"";
    row.url = record[@"url"] ?: row.key;
    row.name = record[@"name"] ?: @"";
    row.path = record[@"path"] ?: @"";
    row.size = [record[@"size"] unsignedLongLongValue];
    row.state = [record[@"state"] integerValue];
    if (row.state == FDMStateDownloading || row.state == FDMStatePaused) row.state = FDMStateInterrupted;
    row.progress = (row.state == FDMStateCompleted) ? 1.0 : [record[@"progress"] doubleValue];

    NSMutableArray *bits = [NSMutableArray array];
    if (row.size) [bits addObject:FDMHumanSize((double)row.size)];
    NSNumber *ts = record[@"time"];
    if ([ts isKindOfClass:[NSNumber class]]) {
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"MM-dd HH:mm";
        [bits addObject:[fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:ts.doubleValue]]];
    }
    if (row.state == FDMStateCompleted) [bits addObject:@"已完成"];
    else if (row.state == FDMStateInterrupted) [bits addObject:@"已中断 · 可继续"];
    else [bits addObject:@"失败"];
    row.meta = [bits componentsJoinedByString:@" · "];
    return row;
}

- (FDMRow *)rowFromEngineItem:(NSDictionary *)item {
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

- (void)refresh {
    @try {
    id fm = FDMSharedFileManager();
    FDMLog(@"stage: refresh fm=%@", fm ? NSStringFromClass([fm class]) : @"nil");
    NSArray *tasks = [fm respondsToSelector:@selector(allTasks)] ? [fm allTasks] : nil;
    if (![tasks isKindOfClass:[NSArray class]]) tasks = @[];

    NSMutableArray *active = [NSMutableArray array];
    NSMutableSet *nowKeys = [NSMutableSet set];

    // 1) 自建引擎的任务：跨启动可见、可续传
    for (NSDictionary *item in [[FDMEngine shared] items]) {
        FDMRow *row = [self rowFromEngineItem:item];
        if (!row.key.length) continue;
        if (row.state == FDMStateCompleted) {
            NSMutableDictionary *old = [[FDMStore shared] recordForKey:row.key];
            if (!old || [old[@"state"] integerValue] != FDMStateCompleted) {
                [self recordForRow:row state:FDMStateCompleted];
            }
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
        NSMutableDictionary *old = [[FDMStore shared] recordForKey:row.key];
        if (row.state == FDMStateCompleted) {
            // 关键：之前可能写过一条「已中断」快照，这里必须把它改写成已完成，
            // 否则历史里会留着「已中断」而真正的完成记录被跳过
            if (!old || [old[@"state"] integerValue] != FDMStateCompleted) {
                [self recordForRow:row state:FDMStateCompleted];
            }
        } else {
            [active addObject:row];
            if (row.state == FDMStateDownloading || row.state == FDMStatePaused) {
                if (!old || [old[@"state"] integerValue] != FDMStateCompleted) {
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
        }
    }
    _loaded = YES;

    NSMutableArray *finished = [NSMutableArray array];
    for (NSDictionary *record in [[FDMStore shared] records]) {
        [finished addObject:[self rowFromRecord:record]];
    }

    _active = active;
    _finished = finished;
    [self.tableView reloadData];

    BOOL anyActive = active.count > 0;
    UIBarButtonItem *allBtn = self.navigationItem.rightBarButtonItems.lastObject;
    allBtn.enabled = anyActive;
    FDMLog(@"stage: refresh done active=%lu finished=%lu", (unsigned long)active.count, (unsigned long)finished.count);
    } @catch (NSException *e) {
        FDMLog(@"*** refresh threw %@: %@\n%@", e.name, e.reason,
               [e.callStackSymbols componentsJoinedByString:@"\n"]);
    }
}

- (void)recordForRow:(FDMRow *)row state:(NSInteger)state {
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"key"] = row.key ?: @"";
    record[@"url"] = row.url.length ? row.url : (row.key ?: @"");
    record[@"progress"] = @(row.progress);
    record[@"name"] = row.name ?: @"";
    record[@"path"] = row.path ?: @"";
    record[@"size"] = @(row.size);
    record[@"state"] = @(state);
    if (![[FDMStore shared] recordForKey:row.key]) {
        record[@"time"] = @([[NSDate date] timeIntervalSince1970]);
    } else {
        NSNumber *old = [[FDMStore shared] recordForKey:row.key][@"time"];
        record[@"time"] = old ?: @([[NSDate date] timeIntervalSince1970]);
    }
    [[FDMStore shared] upsertRecord:record];
}

#pragma mark 操作

- (void)addDownload {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"新增下载"
                                                                   message:@"输入文件直链"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"https://";
        tf.keyboardType = UIKeyboardTypeURL;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"下载" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *text = alert.textFields.firstObject.text;
        NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length < 8) return;
        // 走自建可恢复引擎：暂停 / 杀 App / 重启都能续传
        NSString *name = [[trimmed lastPathComponent] stringByRemovingPercentEncoding];
        [[FDMEngine shared] startURL:trimmed name:name.length ? name : nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf refresh];
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)restartRow:(FDMRow *)row {
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

#pragma mark 表格

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return _active.count ? [NSString stringWithFormat:@"进行中（%lu）", (unsigned long)_active.count] : nil;
    return _finished.count ? [NSString stringWithFormat:@"已结束（%lu）", (unsigned long)_finished.count] : nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0 && _active.count == 0 && _finished.count == 0) return 1;   // 空态
    return section == 0 ? _active.count : _finished.count;
}

- (FDMRow *)rowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        if (indexPath.row < _active.count) return _active[indexPath.row];
        return nil;
    }
    if (indexPath.row < _finished.count) return _finished[indexPath.row];
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    FDMRow *row = [self rowAtIndexPath:indexPath];
    if (!row) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"empty"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"empty"];
        cell.textLabel.text = @"暂无下载任务";
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    FDMCell *cell = [tableView dequeueReusableCellWithIdentifier:@"row" forIndexPath:indexPath];
    [cell renderRow:row];
    return cell;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    FDMRow *row = [self rowAtIndexPath:indexPath];
    if (!row) return nil;

    NSMutableArray *actions = [NSMutableArray array];

    BOOL canToggle = (row.state == FDMStateDownloading || row.state == FDMStatePaused || row.state == FDMStateInterrupted);
    if (canToggle) {
        NSString *title = @"继续";
        if (row.state == FDMStateDownloading) title = @"暂停";
        else if (row.source == 2) title = @"重试";
        UIContextualAction *toggle = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                            title:title
                                                                          handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            [self toggleRow:row];
            done(YES);
        }];
        toggle.backgroundColor = (row.state == FDMStateDownloading) ? [UIColor systemOrangeColor] : [UIColor systemBlueColor];
        [actions addObject:toggle];
    }

    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                     title:@"删除"
                                                                   handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"删除这条记录？"
                                                                        message:@"同时删除已下载的文件"
                                                                 preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { done(NO); }]];
        [confirm addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            [self deleteRow:row];
            done(YES);
        }]];
        [[self topPresenter] presentViewController:confirm animated:YES completion:nil];
    }];
    [actions addObject:del];

    UISwipeActionsConfiguration *config = [UISwipeActionsConfiguration configurationWithActions:actions];
    config.performsFirstActionWithFullSwipe = NO;
    return config;
}

- (UIViewController *)topPresenter {
    UIViewController *vc = self;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

@end

#pragma mark - 主页书签图标磁盘缓存

// 目的：主页书签/收藏的图标原本每次进页面都从空白开始重新拉取，
// 这里做一层自己的磁盘缓存：命中就直接同步填图，未命中后台下载并落盘。

static NSString *FDMIconKey(NSString *url) {
    if (!url.length) return nil;
    const char *p = url.UTF8String;
    if (!p) return nil;
    uint64_t h = 1469598103934665603ULL;
    while (*p) { h ^= (unsigned char)(*p++); h *= 1099511628211ULL; }
    return [NSString stringWithFormat:@"%016llx", h];
}

@interface FDMImageCache : NSObject
+ (instancetype)shared;
- (UIImage *)cachedImageForURL:(NSString *)url;
- (void)storeImage:(UIImage *)image forURL:(NSString *)url;
- (void)prefetchURL:(NSString *)url;
- (BOOL)isPending:(NSString *)url;
@end

@implementation FDMImageCache {
    NSCache *_memory;
    NSMutableSet *_pending;
    NSString *_dir;
    dispatch_queue_t _ioQueue;
}

+ (instancetype)shared {
    static FDMImageCache *one = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ one = [[FDMImageCache alloc] init]; });
    return one;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _memory = [[NSCache alloc] init];
        _memory.countLimit = 512;
        _pending = [NSMutableSet set];
        _ioQueue = dispatch_queue_create("com.focusdm.icons", DISPATCH_QUEUE_SERIAL);
        _dir = [FDMDocumentsPath() stringByAppendingPathComponent:@"FocusDM/icons"];
        [[NSFileManager defaultManager] createDirectoryAtPath:_dir
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:NULL];
        FDMLog(@"icon cache dir ready");
    }
    return self;
}

- (NSString *)pathForURL:(NSString *)url {
    NSString *key = FDMIconKey(url);
    return key ? [_dir stringByAppendingPathComponent:key] : nil;
}

- (UIImage *)cachedImageForURL:(NSString *)url {
    if (!url.length) return nil;
    UIImage *hit = [_memory objectForKey:url];
    if (hit) return hit;
    NSString *path = [self pathForURL:url];
    if (!path) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) return nil;
    UIImage *img = [UIImage imageWithData:data];
    if (!img) return nil;
    [_memory setObject:img forKey:url];
    return img;
}

- (void)storeImage:(UIImage *)image forURL:(NSString *)url {
    if (!image || !url.length) return;
    [_memory setObject:image forKey:url];
    NSString *path = [self pathForURL:url];
    if (!path) return;
    NSData *data = UIImagePNGRepresentation(image);
    if (!data.length) return;
    dispatch_async(_ioQueue, ^{
        [data writeToFile:path atomically:YES];
    });
}

- (BOOL)isPending:(NSString *)url {
    if (!url.length) return NO;
    @synchronized (self) { return [_pending containsObject:url]; }
}

- (void)prefetchURL:(NSString *)url {
    if (!url.length) return;
    if ([self cachedImageForURL:url]) return;
    @synchronized (self) {
        if ([_pending containsObject:url]) return;
        [_pending addObject:url];
    }

    NSURL *u = [NSURL URLWithString:url];
    if (!u) { @synchronized (self) { [_pending removeObject:url]; } return; }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
    req.timeoutInterval = 12.0;

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
                                                                completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2) return;
        UIImage *img = nil;
        if (data.length && !err) img = [UIImage imageWithData:data];
        if (img) {
            [self2 storeImage:img forURL:url];
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:@"FDMIconCached"
                                                                    object:nil
                                                                  userInfo:@{ @"url": url }];
            });
        }
        @synchronized (self2) { [_pending removeObject:url]; }
    }];
    [task resume];
}

@end

static NSString *FDMIconURLForModel(id model) {
    if (!model) return nil;
    NSString *icon = nil;
    @try {
        id v = [model valueForKey:@"iconUrl"];
        if ([v isKindOfClass:[NSString class]]) icon = v;
    } @catch (NSException *e) { (void)e; }
    if (icon.length) return icon;

    NSString *page = nil;
    @try {
        id v = [model valueForKey:@"url"];
        if ([v isKindOfClass:[NSString class]]) page = v;
    } @catch (NSException *e) { (void)e; }
    if (!page.length) return nil;

    NSString *host = [NSURL URLWithString:page].host;
    if (!host.length) return nil;
    return [NSString stringWithFormat:@"https://%@/favicon.ico", host];
}

static IMP g_origSetupLogo = NULL;

static NSMutableSet *g_iconTouched = nil;

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

static void FDMSetupLogoForModel(id self, SEL _cmd, id model) {
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

#pragma mark - 设置页插入「下载管理」行（直接改数据源，复用原生 cell）

static NSString *const FDMLinkMarker = @"focusdm://downloads";
static id g_ourRow = nil;

static NSString *FDMTextOfHeader(id header) {
    if (!header) return nil;
    if ([header isKindOfClass:[NSString class]]) return header;
    @try {
        id t = [header valueForKey:@"title"];
        if ([t isKindOfClass:[NSString class]]) return t;
    } @catch (NSException *e) { (void)e; }
    if ([header respondsToSelector:@selector(description)]) return [header description];
    return nil;
}

static NSMutableArray *FDMWritableSection(NSMutableArray *sections, NSInteger idx) {
    if (idx < 0 || idx >= (NSInteger)sections.count) return nil;
    id row = sections[(NSUInteger)idx];
    if ([row isKindOfClass:[NSMutableArray class]]) return row;
    NSMutableArray *copy = [NSMutableArray arrayWithArray:(NSArray *)row ?: @[]];
    sections[(NSUInteger)idx] = copy;
    return copy;
}

static BOOL FDMRowIsOurs(id model) {
    if (!model) return NO;
    @try {
        id link = [model valueForKey:@"link"];
        return [link isKindOfClass:[NSString class]] && [(NSString *)link isEqualToString:FDMLinkMarker];
    } @catch (NSException *e) { return NO; }
}

// 目标段：标题含「进阶」的那一段；找不到就退到最后一个有内容的段
static NSInteger FDMTargetSection(NSArray *sections, NSArray *headers) {
    NSInteger count = (NSInteger)MIN(sections.count, headers.count);
    for (NSInteger i = 0; i < count; i++) {
        NSString *t = FDMTextOfHeader(headers[(NSUInteger)i]);
        if (t.length && [t containsString:@"进阶"]) return i;
    }
    for (NSInteger i = (NSInteger)sections.count - 1; i >= 0; i--) {
        id rows = sections[(NSUInteger)i];
        if ([rows isKindOfClass:[NSArray class]] && [(NSArray *)rows count]) return i;
    }
    return -1;
}

static void FDMEnsureRow(UIViewController *vc) {
    @try {
        NSMutableArray *sections = [vc valueForKey:@"model"];
        NSArray *headers = [vc valueForKey:@"sectionHeaderModel"];
        if (![sections isKindOfClass:[NSMutableArray class]]) return;

        NSInteger idx = FDMTargetSection(sections, headers);
        if (idx < 0) { FDMLog(@"row: no target section"); return; }
        NSMutableArray *rows = FDMWritableSection(sections, idx);
        if (!rows) return;

        for (id row in rows) if (FDMRowIsOurs(row)) { FDMLog(@"row: already present in section %ld", (long)idx); return; }

        Class modelClass = NSClassFromString(@"SettingModel");
        if (!modelClass) { FDMLog(@"row: SettingModel missing"); return; }
        id model = [[modelClass alloc] init];

        // 找一个「带跳转的箭头行」当模板，抄它的图标与类型，样式就和同段其他行一致
        id template = nil;
        for (id row in [rows reverseObjectEnumerator]) {
            @try {
                id link = [row valueForKey:@"link"];
                if ([link isKindOfClass:[NSString class]] && [(NSString *)link length]) { template = row; break; }
            } @catch (NSException *e) { (void)e; }
        }
        if (!template && rows.count) template = rows.lastObject;

        @try {
            [model setValue:@"下载管理" forKey:@"title"];
            [model setValue:FDMLinkMarker forKey:@"link"];
            if (template) {
                for (NSString *key in @[ @"imageName", @"imageBackgroundColor", @"type", @"content" ]) {
                    @try {
                        id v = [template valueForKey:key];
                        if (v) [model setValue:v forKey:key];
                    } @catch (NSException *e) { (void)e; }
                }
            }
            id last = rows.lastObject;
            [model setValue:@(YES) forKey:@"isLastInSection"];
            if (last) @try { [last setValue:@(NO) forKey:@"isLastInSection"]; } @catch (NSException *e) { (void)e; }
        } @catch (NSException *e) {
            FDMLog(@"row: configure threw %@: %@", e.name, e.reason);
            return;
        }

        [rows addObject:model];
        g_ourRow = model;
        FDMLog(@"row: inserted at section %ld row %lu (template=%@)", (long)idx,
               (unsigned long)(rows.count - 1), template ? NSStringFromClass([template class]) : @"none");
        @try {
            id tv = [vc valueForKey:@"tableView"];
            if ([tv isKindOfClass:[UITableView class]]) [tv performSelectorOnMainThread:@selector(reloadData) withObject:nil waitUntilDone:NO];
        } @catch (NSException *e) { (void)e; }
        [vc.view setNeedsLayout];
    } @catch (NSException *e) {
        FDMLog(@"*** FDMEnsureRow threw %@: %@", e.name, e.reason);
    }
}

static IMP g_origApplyNavState = NULL;

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

static void FDMOpenDownloads(UIViewController *host);

static UIViewController *FDMTopViewController(void) {
    UIWindow *key = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow) { key = w; break; }
    }
    if (!key) key = [UIApplication sharedApplication].windows.firstObject;
    UIViewController *vc = key.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:[UINavigationController class]]) vc = ((UINavigationController *)vc).topViewController;
    if ([vc isKindOfClass:[UITabBarController class]]) vc = ((UITabBarController *)vc).selectedViewController;
    return vc;
}

// 浏览器里点了「下载」之后，浮一个「查看下载」的小胶囊，点一下直接进下载管理
static void FDMShowDownloadPill(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *key = nil;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) { key = w; break; }
        }
        if (!key) return;
        if ([key viewWithTag:0x46444D50]) return;

        UIButton *pill = [UIButton buttonWithType:UIButtonTypeSystem];
        pill.tag = 0x46444D50;
        [pill setTitle:@"查看下载" forState:UIControlStateNormal];
        pill.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        [pill setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        pill.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.92];
        pill.layer.cornerRadius = 18.0;
        pill.layer.masksToBounds = YES;

        CGFloat w = 104.0, h = 36.0;
        CGFloat safeBottom = key.safeAreaInsets.bottom;
        pill.frame = CGRectMake((key.bounds.size.width - w) / 2.0,
                                key.bounds.size.height - safeBottom - h - 68.0, w, h);
        pill.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;

        [pill addAction:[UIAction actionWithHandler:^(UIAction *action) {
            UIViewController *top = FDMTopViewController();
            [pill removeFromSuperview];
            if (top) FDMOpenDownloads(top);
        }] forControlEvents:UIControlEventTouchUpInside];

        [key addSubview:pill];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(9.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.25 animations:^{ pill.alpha = 0; } completion:^(BOOL done) {
                [pill removeFromSuperview];
            }];
        });
        FDMLog(@"pill: shown after host download");
    });
}

static IMP g_origFileDownload = NULL;
static void FDMFileDownloadWithUrl(id self, SEL _cmd, id url, id title) {
    if (g_origFileDownload) ((void (*)(id, SEL, id, id))g_origFileDownload)(self, _cmd, url, title);
    FDMShowDownloadPill();
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

static IMP g_origWillAppear = NULL;
static IMP g_origSelect = NULL;

static void FDMSettingsWillAppear(id self, SEL _cmd, BOOL animated) {
    ((void (*)(id, SEL, BOOL))g_origWillAppear)(self, _cmd, animated);
    FDMEnsureRow((UIViewController *)self);
}

static void FDMSettingsDidSelect(id self, SEL _cmd, UITableView *tv, NSIndexPath *indexPath) {
    @try {
        NSArray *sections = [(UIViewController *)self valueForKey:@"model"];
        if (indexPath.section < (NSInteger)sections.count) {
            id rows = sections[(NSUInteger)indexPath.section];
            if ([rows isKindOfClass:[NSArray class]] && indexPath.row < (NSInteger)[(NSArray *)rows count]) {
                id model = ((NSArray *)rows)[(NSUInteger)indexPath.row];
                if (FDMRowIsOurs(model)) {
                    [tv deselectRowAtIndexPath:indexPath animated:YES];
                    FDMOpenDownloads((UIViewController *)self);
                    return;
                }
            }
        }
    } @catch (NSException *e) {
        FDMLog(@"*** didSelect inspect threw %@: %@", e.name, e.reason);
    }
    if (g_origSelect) ((void (*)(id, SEL, UITableView *, NSIndexPath *))g_origSelect)(self, _cmd, tv, indexPath);
}

static void FDMInstallHook(Class cls, SEL sel, IMP newImp, IMP *store) {
    if (!cls || !sel) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { FDMLog(@"hook: %@ missing", NSStringFromSelector(sel)); return; }
    IMP old = method_getImplementation(m);
    if (store) *store = old;
    if (!class_addMethod(cls, sel, newImp, method_getTypeEncoding(m))) {
        method_setImplementation(m, newImp);
    }
    FDMLog(@"hook: %@ installed", NSStringFromSelector(sel));
}

__attribute__((constructor))
static void FDMInitialize(void) {
    FDMInstallCrashHandlers();
    FDMLog(@"=== FocusDM loaded ===");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        Class cls = NSClassFromString(@"SettingViewController");
        if (!cls) { FDMLog(@"init: SettingViewController missing"); return; }
        FDMInstallHook(cls, @selector(viewWillAppear:), (IMP)FDMSettingsWillAppear, &g_origWillAppear);
        FDMInstallHook(cls, @selector(tableView:didSelectRowAtIndexPath:), (IMP)FDMSettingsDidSelect, &g_origSelect);
        Class cell = NSClassFromString(@"BookMarkCell");
        if (cell) FDMInstallHook(cell, @selector(setupLogoForModel:), (IMP)FDMSetupLogoForModel, &g_origSetupLogo);

        Class fmCls = NSClassFromString(@"FileManager");
        if (fmCls) {
            FDMInstallHook(fmCls, @selector(downloadWithUrl:title:), (IMP)FDMFileDownloadWithUrl, &g_origFileDownload);
        }

        Class navCls = NSClassFromString(@"BaseNavigationController");
        if (navCls) {
            FDMInstallHook(navCls, @selector(applyNavigationBarStateForViewController:animated:),
                           (IMP)FDMApplyNavState, &g_origApplyNavState);
        }
        [[FDMStore shared] loadFromDisk];
        FDMLog(@"init: done, FileManager=%@", FDMSharedFileManager() ? NSStringFromClass([FDMSharedFileManager() class]) : @"nil");
    });
}
