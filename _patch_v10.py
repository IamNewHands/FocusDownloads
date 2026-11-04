import io, re, sys

p = r'src/FocusDM.m'
s = io.open(p, encoding='utf-8').read()

# ---------- 1. 日志辅助函数 ----------
helpers = r'''#pragma mark - 诊断日志（崩溃时留下最后一步）

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

'''
anchor = 'static double FDMNumber(id task, NSString *key) {'
assert s.count(anchor) == 1
s = s.replace(anchor, helpers + anchor)

# ---------- 2. viewDidLoad 包护栏 + 步骤日志 ----------
old_vdl = '''- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"下载管理";'''
new_vdl = '''- (void)viewDidLoad {
    [super viewDidLoad];
    FDMLog(@"--- download page viewDidLoad");
    @try {
    self.title = @"下载管理";'''
assert s.count(old_vdl) == 1
s = s.replace(old_vdl, new_vdl)

old_vdl_end = '''    _seen = [NSMutableSet set];
    [self refresh];
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
}'''
new_vdl_end = '''    _seen = [NSMutableSet set];
    FDMLog(@"stage: before first refresh");
    [self refresh];
    FDMLog(@"stage: after first refresh");
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
    } @catch (NSException *e) {
        FDMLog(@"*** viewDidLoad threw %@: %@\\n%@", e.name, e.reason,
               [e.callStackSymbols componentsJoinedByString:@"\\n"]);
        self.title = @"下载管理（初始化异常）";
    }
}'''
assert s.count(old_vdl_end) == 1
s = s.replace(old_vdl_end, new_vdl_end)

# ---------- 3. refresh 包护栏 ----------
old_ref = '''- (void)refresh {
    id fm = FDMSharedFileManager();'''
new_ref = '''- (void)refresh {
    @try {
    id fm = FDMSharedFileManager();
    FDMLog(@"stage: refresh fm=%@", fm ? NSStringFromClass([fm class]) : @"nil");'''
assert s.count(old_ref) == 1
s = s.replace(old_ref, new_ref)

old_ref_end = '''    BOOL anyActive = active.count > 0;
    UIBarButtonItem *allBtn = self.navigationItem.rightBarButtonItems.lastObject;
    allBtn.enabled = anyActive;
}'''
new_ref_end = '''    BOOL anyActive = active.count > 0;
    UIBarButtonItem *allBtn = self.navigationItem.rightBarButtonItems.lastObject;
    allBtn.enabled = anyActive;
    FDMLog(@"stage: refresh done active=%lu finished=%lu", (unsigned long)active.count, (unsigned long)finished.count);
    } @catch (NSException *e) {
        FDMLog(@"*** refresh threw %@: %@\\n%@", e.name, e.reason,
               [e.callStackSymbols componentsJoinedByString:@"\\n"]);
    }
}'''
assert s.count(old_ref_end) == 1
s = s.replace(old_ref_end, new_ref_end)

# ---------- 4. 替换设置页注入实现 ----------
tail_marker = '#pragma mark - 设置页插入「下载管理」行'
idx = s.index(tail_marker)
s = s[:idx]

s += r'''#pragma mark - 设置页插入「下载管理」行（直接改数据源，复用原生 cell）

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
        [vc.view setNeedsLayout];
    } @catch (NSException *e) {
        FDMLog(@"*** FDMEnsureRow threw %@: %@", e.name, e.reason);
    }
}

static void FDMOpenDownloads(UIViewController *host) {
    FDMLog(@"stage: open downloads");
    @try {
        FDMViewController *vc = [[FDMViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        if (host.navigationController) {
            [host.navigationController pushViewController:vc animated:YES];
        } else {
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
            [host presentViewController:nav animated:YES completion:nil];
        }
        FDMLog(@"stage: pushed");
    } @catch (NSException *e) {
        FDMLog(@"*** open downloads threw %@: %@\n%@", e.name, e.reason,
               [e.callStackSymbols componentsJoinedByString:@"\n"]);
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
        [[FDMStore shared] loadFromDisk];
        FDMLog(@"init: done, FileManager=%@", FDMSharedFileManager() ? NSStringFromClass([FDMSharedFileManager() class]) : @"nil");
    });
}
'''

io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('rewritten, length', len(s))
