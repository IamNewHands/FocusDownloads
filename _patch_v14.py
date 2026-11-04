# -*- coding: utf-8 -*-
"""v14: 侧滑不回弹 / 同一任务不再同时出现在两段 / 顶部导航栏强制显示"""
import io, sys

P = 'src/FocusDM.m'
s = io.open(P, encoding='utf-8').read()
orig = s

def rep(old, new, label):
    global s
    if old not in s:
        print('MISS:', label); sys.exit(1)
    if s.count(old) != 1:
        print('DUP(%d):' % s.count(old), label); sys.exit(1)
    s = s.replace(old, new)
    print('ok:', label)

# 1) ivars
rep("""    BOOL _loaded;
    NSTimer *_timer;
}""",
"""    BOOL _loaded;
    NSTimer *_timer;
    NSString *_lastSignature;       // 上一条数据快照，用于判断是否需要整表刷新
    BOOL _navBarHiddenBefore;
    BOOL _navBarStateCaptured;
}""", 'ivars')

# 2) rowsSignature + 生命周期
rep("""- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];""",
"""- (NSString *)rowsSignature {
    NSMutableString *sig = [NSMutableString string];
    for (FDMRow *r in _active) [sig appendFormat:@"A|%@|%ld|", r.key, (long)r.state];
    for (FDMRow *r in _finished) [sig appendFormat:@"F|%@|%ld|", r.key, (long)r.state];
    return sig;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 浏览器/其他页面可能隐藏了导航栏，进本页必须强制显示，否则返回、全部暂停、加号都看不到
    UINavigationController *nav = self.navigationController;
    if (nav) {
        if (!_navBarStateCaptured) {
            _navBarHiddenBefore = nav.navigationBarHidden;
            _navBarStateCaptured = YES;
        }
        [nav setNavigationBarHidden:NO animated:animated];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    UINavigationController *nav = self.navigationController;
    if (nav && _navBarStateCaptured) {
        [nav setNavigationBarHidden:_navBarHiddenBefore animated:animated];
    }""", 'viewWillAppear + rowsSignature')

# 3) 已结束段过滤掉仍在进行中的 key
rep("""    NSMutableArray *finished = [NSMutableArray array];
    for (NSDictionary *record in [[FDMStore shared] records]) {
        [finished addObject:[self rowFromRecord:record]];
    }""",
"""    NSMutableArray *finished = [NSMutableArray array];
    for (NSDictionary *record in [[FDMStore shared] records]) {
        NSString *recordKey = record[@"key"];
        // 同一任务还在下载时，历史里的「已中断」快照不能再单列一条，否则两段里各出现一次
        if (recordKey.length && [nowKeys containsObject:recordKey]) continue;
        [finished addObject:[self rowFromRecord:record]];
    }""", 'finished dedupe')

# 4) refresh 尾部：只在结构变化时 reloadData，避免每秒刷新把侧滑按钮收回去
rep("""    _active = active;
    _finished = finished;
    [self.tableView reloadData];""",
"""    _active = active;
    _finished = finished;

    NSString *sig = [self rowsSignature];
    if (!_lastSignature || ![sig isEqualToString:_lastSignature]) {
        _lastSignature = sig;
        [self.tableView reloadData];
    } else {
        // 只有进度/速度在变：就地更新可见行，不重建表格，侧滑出来的按钮就不会被弹回去
        for (NSIndexPath *ip in [self.tableView indexPathsForVisibleRows]) {
            FDMRow *row = [self rowAtIndexPath:ip];
            UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:ip];
            if (row && [cell isKindOfClass:[FDMCell class]]) [(FDMCell *)cell renderRow:row];
        }
    }""", 'conditional reload')

io.open(P, 'w', encoding='utf-8', newline='\n').write(s)
print('bytes %d -> %d' % (len(orig), len(s)))
