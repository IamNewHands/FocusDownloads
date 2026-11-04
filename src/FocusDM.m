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
@end

@implementation FDMRow
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

    _seen = [NSMutableSet set];
    [self refresh];
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
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
    row.key = record[@"key"] ?: @"";
    row.name = record[@"name"] ?: @"";
    row.path = record[@"path"] ?: @"";
    row.size = [record[@"size"] unsignedLongLongValue];
    row.state = [record[@"state"] integerValue];
    row.progress = 1.0;

    NSMutableArray *bits = [NSMutableArray array];
    if (row.size) [bits addObject:FDMHumanSize((double)row.size)];
    NSNumber *ts = record[@"time"];
    if ([ts isKindOfClass:[NSNumber class]]) {
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"MM-dd HH:mm";
        [bits addObject:[fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:ts.doubleValue]]];
    }
    [bits addObject:row.state == FDMStateCompleted ? @"已完成" : @"失败"];
    row.meta = [bits componentsJoinedByString:@" · "];
    return row;
}

- (void)refresh {
    id fm = FDMSharedFileManager();
    NSArray *tasks = [fm respondsToSelector:@selector(allTasks)] ? [fm allTasks] : nil;
    if (![tasks isKindOfClass:[NSArray class]]) tasks = @[];

    NSMutableArray *active = [NSMutableArray arrayWithCapacity:tasks.count];
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
}

- (void)recordForRow:(FDMRow *)row state:(NSInteger)state {
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"key"] = row.key ?: @"";
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
        id fm = FDMSharedFileManager();
        if ([fm respondsToSelector:@selector(downloadWithUrl:title:)]) {
            NSString *name = [[trimmed lastPathComponent] stringByRemovingPercentEncoding];
            [fm downloadWithUrl:trimmed title:name.length ? name : @"下载文件"];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf refresh];
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)toggleAll {
    id fm = FDMSharedFileManager();
    BOOL pause = _active.count > 0;
    for (FDMRow *row in _active) {
        if (!row.task) continue;
        if (pause) {
            if ([fm respondsToSelector:@selector(suspendTask:)]) [fm suspendTask:row.task];
        } else {
            if ([fm respondsToSelector:@selector(startTask:)]) [fm startTask:row.task];
        }
    }
    if (!pause) {
        // 已暂停的历史行没有任务对象，无法从列表续传；这里只恢复仍在引擎里的任务
        for (FDMRow *row in _active) {
            if (row.task && [fm respondsToSelector:@selector(startTask:)]) [fm startTask:row.task];
        }
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refresh];
    });
}

- (void)toggleRow:(FDMRow *)row {
    id fm = FDMSharedFileManager();
    if (row.state == FDMStateDownloading) {
        if ([fm respondsToSelector:@selector(suspendTask:)]) [fm suspendTask:row.task];
    } else if (row.state == FDMStatePaused) {
        if ([fm respondsToSelector:@selector(startTask:)]) [fm startTask:row.task];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refresh];
    });
}

- (void)deleteRow:(FDMRow *)row {
    id fm = FDMSharedFileManager();
    if (row.task) {
        if ([fm respondsToSelector:@selector(cancelTask:)]) [fm cancelTask:row.task];
        id sm = [fm respondsToSelector:@selector(sessionManager)] ? [fm sessionManager] : nil;
        if (sm && [sm respondsToSelector:@selector(removeWithUrl:completely:)]) {
            [sm removeWithUrl:row.key completely:YES];
        }
    }
    if (row.path.length) [[NSFileManager defaultManager] removeItemAtPath:row.path error:NULL];
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

    if (row.task && (row.state == FDMStateDownloading || row.state == FDMStatePaused)) {
        NSString *title = (row.state == FDMStateDownloading) ? @"暂停" : @"继续";
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

#pragma mark - 设置页插入「下载管理」行

static IMP g_origRows = NULL;
static IMP g_origCell = NULL;
static IMP g_origSelect = NULL;
static IMP g_origHeight = NULL;

static Class FDMSettingsClass(void) {
    static Class cls = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cls = NSClassFromString(@"SettingViewController"); });
    return cls;
}

static NSInteger FDMIsEntryRow(UITableView *tv, NSInteger section, NSInteger row, NSInteger baseCount) {
    NSInteger sections = [tv numberOfSections];
    if (section != sections - 1) return 0;
    return row == baseCount ? 1 : 0;
}

static NSInteger FDMNumberOfRows(id self, SEL _cmd, UITableView *tv, NSInteger section) {
    NSInteger n = ((NSInteger (*)(id, SEL, UITableView *, NSInteger))g_origRows)(self, _cmd, tv, section);
    NSInteger sections = [tv numberOfSections];
    if (section == sections - 1) return n + 1;
    return n;
}

static UITableViewCell *FDMCellForRow(id self, SEL _cmd, UITableView *tv, NSIndexPath *indexPath) {
    NSInteger sections = [tv numberOfSections];
    if (indexPath.section == sections - 1) {
        NSInteger base = ((NSInteger (*)(id, SEL, UITableView *, NSInteger))g_origRows)(self, _cmd, tv, indexPath.section);
        if (indexPath.row == base) {
            static NSString *reuse = @"fdm-entry";
            UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:reuse];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuse];
                cell.textLabel.text = @"下载管理";
                cell.textLabel.font = [UIFont systemFontOfSize:16];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                if (@available(iOS 13.0, *)) cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
            }
            return cell;
        }
    }
    return ((UITableViewCell * (*)(id, SEL, UITableView *, NSIndexPath *))g_origCell)(self, _cmd, tv, indexPath);
}

static void FDMDidSelectRow(id self, SEL _cmd, UITableView *tv, NSIndexPath *indexPath) {
    NSInteger sections = [tv numberOfSections];
    if (indexPath.section == sections - 1) {
        NSInteger base = ((NSInteger (*)(id, SEL, UITableView *, NSInteger))g_origRows)(self, _cmd, tv, indexPath.section);
        if (indexPath.row == base) {
            [tv deselectRowAtIndexPath:indexPath animated:YES];
            FDMViewController *vc = [[FDMViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
            UIViewController *host = (UIViewController *)self;
            if (host.navigationController) [host.navigationController pushViewController:vc animated:YES];
            else [host presentViewController:[[UINavigationController alloc] initWithRootViewController:vc] animated:YES completion:nil];
            return;
        }
    }
    ((void (*)(id, SEL, UITableView *, NSIndexPath *))g_origSelect)(self, _cmd, tv, indexPath);
}

static CGFloat FDMHeightForRow(id self, SEL _cmd, UITableView *tv, NSIndexPath *indexPath) {
    NSInteger sections = [tv numberOfSections];
    if (indexPath.section == sections - 1) {
        NSInteger base = ((NSInteger (*)(id, SEL, UITableView *, NSInteger))g_origRows)(self, _cmd, tv, indexPath.section);
        if (indexPath.row == base) return 52.0;
    }
    return ((CGFloat (*)(id, SEL, UITableView *, NSIndexPath *))g_origHeight)(self, _cmd, tv, indexPath);
}

static void FDMInstallHook(Class cls, SEL sel, IMP newImp, IMP *store) {
    if (!cls || !sel) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP old = method_getImplementation(m);
    if (store) *store = old;
    if (!class_addMethod(cls, sel, newImp, method_getTypeEncoding(m))) {
        method_setImplementation(m, newImp);
    }
}

__attribute__((constructor))
static void FDMInitialize(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        Class cls = FDMSettingsClass();
        if (!cls) return;
        FDMInstallHook(cls, @selector(tableView:numberOfRowsInSection:), (IMP)FDMNumberOfRows, &g_origRows);
        FDMInstallHook(cls, @selector(tableView:cellForRowAtIndexPath:), (IMP)FDMCellForRow, &g_origCell);
        FDMInstallHook(cls, @selector(tableView:didSelectRowAtIndexPath:), (IMP)FDMDidSelectRow, &g_origSelect);
        FDMInstallHook(cls, @selector(tableView:heightForRowAtIndexPath:), (IMP)FDMHeightForRow, &g_origHeight);
        [[FDMStore shared] loadFromDisk];
        NSLog(@"[FocusDM] installed, FileManager=%@", FDMSharedFileManager());
    });
}
