#import "FDMDownloadsViewController.h"
#import "FDMEngine.h"
#import "FDMStore.h"
#import "FDMHostDownloads.h"
#import "FDMPageNavigation.h"
#import <QuickLook/QuickLook.h>

static NSString *FDMRowStateText(NSDictionary *row) {
    if ([row[@"pausing"] boolValue]) {
        if (![row[@"pauseIntent"] boolValue] && [row[@"hostStatus"] isEqual:@8]) return @"取消中";
        if ([row[@"hostStatus"] isEqual:@9]) return @"移除中";
        return @"暂停中";
    }
    NSInteger scheduler = [row[@"schedulerStatus"] integerValue];
    if (row[@"schedulerStatus"] && scheduler == FDMSchedulerWaiting) return @"等待中";
    if (row[@"schedulerStatus"] && scheduler == FDMSchedulerNeedsContext && [row[@"state"] integerValue] == FDMStateInterrupted) return @"已中断";
    switch ([row[@"state"] integerValue]) {
        case FDMStateDownloading: return [row[@"hostStatus"] isEqual:@0] ? @"等待连接" : @"下载中";
        case FDMStatePaused: return @"已暂停";
        case FDMStateCompleted: return @"已完成";
        case FDMStateFailed: return @"失败";
        default: return @"已中断";
    }
}

static NSString *FDMRowTransportText(NSDictionary *row) {
    NSInteger transport = [row[@"transport"] integerValue];
    if (transport == FDMTransportWebKitDownload) return @"网页原请求";
    if (transport == FDMTransportCredentialedSession) return @"登录上下文";
    return @"匿名后台";
}

static NSString *FDMRowDetail(NSDictionary *row) {
    NSMutableArray *parts = [NSMutableArray array];
    NSInteger state = [row[@"state"] integerValue];
    long long received = [row[@"received"] longLongValue];
    long long total = [row[@"total"] longLongValue];
    if (state == FDMStateCompleted) {
        [parts addObject:FDMHumanSize([row[@"size"] doubleValue])];
        NSString *path = FDMResolveDocumentPath(row);
        if (path.length) [parts addObject:[@"保存于：" stringByAppendingString:FDMRelativeDocumentPath(path) ?: path.lastPathComponent]];
        else [parts addObject:@"保存位置未确认"];
    } else {
        [parts addObject:[NSString stringWithFormat:@"已下 %@ / %@", FDMHumanSize(MAX(0, received)), total > 0 ? FDMHumanSize(total) : @"总大小未知"]];
        if (total > 0 && state == FDMStateDownloading) [parts addObject:[NSString stringWithFormat:@"%.1f%%", MIN(1.0, MAX(0.0, (double)received / total)) * 100]];
        double speed = [row[@"speed"] doubleValue];
        if (speed > 0 && state == FDMStateDownloading) [parts addObject:[FDMHumanSize(speed) stringByAppendingString:@"/s"]];
    }
    NSString *error = FDMString(row[@"actionError"]) ?: FDMString(row[@"error"]);
    if (error.length) [parts addObject:error];
    else if (FDMString(row[@"statusDetail"]).length) [parts addObject:row[@"statusDetail"]];
    else if (FDMString(row[@"waitReason"]).length) [parts addObject:row[@"waitReason"]];
    else if (state == FDMStatePaused || state == FDMStateInterrupted) [parts addObject:[row[@"canResume"] boolValue] ? @"可尝试断点继续" : @"原上下文或续传数据不可用，请重新发起"];
    NSString *source = FDMString(row[@"sourceOrigin"]);
    if (source.length && ![source isEqual:FDMString(row[@"targetOrigin"])]) [parts addObject:[@"来源 " stringByAppendingString:source]];
    [parts addObject:FDMRowTransportText(row)];
    return [parts componentsJoinedByString:@" · "];
}

@interface FDMDownloadCell : UITableViewCell
- (void)render:(NSDictionary *)row;
@end
@implementation FDMDownloadCell {
    UILabel *_name;
    UILabel *_state;
    UILabel *_detail;
    UIProgressView *_progress;
}
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier])) {
        _name = [[UILabel alloc] init];
        _name.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        _name.numberOfLines = 2;
        _name.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _state = [[UILabel alloc] init];
        _state.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        _state.textColor = UIColor.secondaryLabelColor;
        _state.numberOfLines = 0;
        _detail = [[UILabel alloc] init];
        _detail.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        _detail.textColor = UIColor.secondaryLabelColor;
        _detail.numberOfLines = 0;
        for (UILabel *label in @[_name, _state, _detail]) label.adjustsFontForContentSizeCategory = YES;
        _progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_name, _state, _detail, _progress]];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 6;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:stack];
        UILayoutGuide *guide = self.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[[stack.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor], [stack.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor], [stack.topAnchor constraintEqualToAnchor:guide.topAnchor], [stack.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor]]];
        self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
    }
    return self;
}
- (void)render:(NSDictionary *)row {
    _name.text = FDMString(row[@"name"]).length ? row[@"name"] : @"未命名文件";
    _state.text = FDMRowStateText(row);
    _detail.text = FDMRowDetail(row);
    _progress.hidden = [row[@"state"] integerValue] != FDMStateDownloading || [row[@"total"] longLongValue] <= 0;
    _progress.progress = MIN(1, MAX(0, [row[@"progress"] floatValue]));
    self.accessibilityLabel = [NSString stringWithFormat:@"%@，%@，%@", _name.text, _state.text, _detail.text];
    self.accessibilityHint = @"双击查看下载操作";
}
@end

@interface FDMURLInputController : UIViewController <UITextFieldDelegate, UITextViewDelegate>
@property (nonatomic, copy) NSString *initialURL;
@property (nonatomic, copy) BOOL (^submitURL)(NSString *, NSError **);
// Batch submission: returns the number queued, or 0 with an error.
@property (nonatomic, copy, nullable) NSUInteger (^submitBatch)(NSArray<NSString *> *, NSError **);
@end
@implementation FDMURLInputController {
    UITextView *_address;
    UILabel *_error;
    UILabel *_hint;
    BOOL _submitted;
    BOOL _batch;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"新增下载";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    FDMPrepareOwnedPage(self);
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain target:self action:@selector(cancel)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"下载" style:UIBarButtonItemStyleDone target:self action:@selector(submit)];
    UILabel *label = [[UILabel alloc] init];
    label.text = @"输入 http/https 文件直链；每行一个地址可批量加入队列";
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    label.adjustsFontForContentSizeCategory = YES;
    label.numberOfLines = 0;
    _address = [[UITextView alloc] init];
    _address.text = self.initialURL;
    _address.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _address.adjustsFontForContentSizeCategory = YES;
    _address.keyboardType = UIKeyboardTypeURL;
    _address.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _address.autocorrectionType = UITextAutocorrectionTypeNo;
    _address.accessibilityLabel = @"下载地址";
    _address.delegate = self;
    _address.layer.borderColor = UIColor.separatorColor.CGColor;
    _address.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    _address.layer.cornerRadius = 8;
    _address.textContainerInset = UIEdgeInsetsMake(10, 8, 10, 8);
    _hint = [[UILabel alloc] init];
    _hint.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _hint.textColor = UIColor.secondaryLabelColor;
    _hint.adjustsFontForContentSizeCategory = YES;
    _hint.numberOfLines = 0;
    _hint.text = [NSString stringWithFormat:@"最多一次加入 %lu 个地址；同一地址重复提交会新建任务，不会合并。", (unsigned long)FDMBatchPreviewLimit];
    _error = [[UILabel alloc] init];
    _error.textColor = UIColor.systemRedColor;
    _error.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _error.adjustsFontForContentSizeCategory = YES;
    _error.numberOfLines = 0;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[label, _address, _hint, _error]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[[stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20], [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20], [stack.topAnchor constraintEqualToAnchor:safe.topAnchor constant:24], [_address.heightAnchor constraintGreaterThanOrEqualToConstant:120]]];
}
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; [_address becomeFirstResponder]; }
- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSArray<NSString *> *)lines {
    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *line in [_address.text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (trimmed.length) [lines addObject:trimmed];
    }
    return lines;
}
- (void)submit {
    if (_submitted) return;
    NSArray *lines = [self lines];
    NSError *error = nil;
    if (!lines.count) { _error.text = @"请输入下载地址"; return; }
    _batch = lines.count > 1 && self.submitBatch != nil;
    if (_batch && lines.count > FDMBatchPreviewLimit) {
        _error.text = [NSString stringWithFormat:@"一次最多加入 %lu 个地址，当前 %lu 个", (unsigned long)FDMBatchPreviewLimit, (unsigned long)lines.count];
        return;
    }
    if (_batch) {
        for (NSString *url in lines) if (!FDMValidatedURL(url, &error)) { _error.text = error.localizedDescription; return; }
        UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"批量下载预览"
            message:[NSString stringWithFormat:@"共%lu个直链，将加入等待队列；可重放GET并发上限为%lu。", (unsigned long)lines.count, (unsigned long)FDMEngine.shared.concurrencyLimit]
            preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [confirm addAction:[UIAlertAction actionWithTitle:@"开始下载" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self commitLines:lines batch:YES];
        }]];
        [self presentViewController:confirm animated:YES completion:nil]; return;
    }
    [self commitLines:lines batch:NO];
}
- (void)commitLines:(NSArray<NSString *> *)lines batch:(BOOL)batch {
    if (_submitted) return;
    NSError *error = nil;
    _submitted = YES;
    self.navigationItem.rightBarButtonItem.enabled = NO;
    if (batch) {
        NSUInteger queued = self.submitBatch(lines, &error);
        if (queued > 0) { [self dismissViewControllerAnimated:YES completion:nil]; return; }
    } else if (self.submitURL && self.submitURL(lines.firstObject, &error)) {
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    _submitted = NO;
    self.navigationItem.rightBarButtonItem.enabled = YES;
    _error.text = error.localizedDescription ?: @"无法开始下载，请检查地址";
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, _error.text);
}
- (BOOL)textFieldShouldReturn:(UITextField *)field { [self submit]; return NO; }
@end

@interface FDMDownloadsViewController () <QLPreviewControllerDataSource, UISearchResultsUpdating>
@end
@implementation FDMDownloadsViewController {
    NSArray<NSDictionary *> *_active;
    NSArray<NSDictionary *> *_finished;
    NSString *_signature;
    NSTimer *_timer;
    NSMutableArray *_observers;
    UIBarButtonItem *_addButton;
    UIBarButtonItem *_allButton;
    UILabel *_restoringLabel;
    NSURL *_previewURL;
    UISearchController *_search;
    NSString *_query;
    NSInteger _filter;
    BOOL _refreshReady;
    BOOL _refreshScheduled;
    BOOL _refreshPending;
    BOOL _refreshing;
    BOOL _scrolling;
    NSUInteger _refreshGeneration;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"下载管理";
    _active = @[];
    _finished = @[];
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    FDMPrepareOwnedPage(self);
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 116;
    [self.tableView registerClass:FDMDownloadCell.class forCellReuseIdentifier:@"download"];
    _addButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addDownload)];
    _addButton.accessibilityLabel = @"新增下载";
    _allButton = [[UIBarButtonItem alloc] initWithTitle:@"全部暂停" style:UIBarButtonItemStylePlain target:self action:@selector(toggleAll)];
    _addButton.enabled = NO;
    _allButton.enabled = NO;
    UIBarButtonItem *more = [[UIBarButtonItem alloc] initWithTitle:@"更多" style:UIBarButtonItemStylePlain target:self action:@selector(showMore)];
    self.navigationItem.rightBarButtonItems = @[_addButton, _allButton, more];
    _filter = -1;
    _query = @"";
    _search = [[UISearchController alloc] initWithSearchResultsController:nil];
    _search.obscuresBackgroundDuringPresentation = NO;
    _search.searchResultsUpdater = self;
    _search.searchBar.scopeButtonTitles = @[@"全部", @"进行中", @"等待", @"已暂停", @"已完成", @"失败"];
    _search.searchBar.delegate = (id)self;
    self.navigationItem.searchController = _search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    if (self.navigationController.presentingViewController && self.navigationController.viewControllers.firstObject == self) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain target:self action:@selector(closePage)];
    }
    _restoringLabel = [[UILabel alloc] init];
    _restoringLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    _restoringLabel.adjustsFontForContentSizeCategory = YES;
    _restoringLabel.textAlignment = NSTextAlignmentCenter;
    _restoringLabel.numberOfLines = 0;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    FDMPrepareOwnedPage(self);
    [self.navigationController setNavigationBarHidden:NO animated:animated];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    _refreshReady = YES;
    _scrolling = NO;
    [self startObserving];
    [self refresh];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopObserving];
}
- (void)viewDidDisappear:(BOOL)animated { [super viewDidDisappear:animated]; [self stopObserving]; }
- (void)dealloc { [self stopObserving]; }
- (void)closePage { [self stopObserving]; [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)startObserving {
    if (_timer) return;
    __weak typeof(self) weakSelf = self;
    _timer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) { [weakSelf refresh]; }];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSDefaultRunLoopMode];
    _observers = [NSMutableArray array];
    for (NSString *name in @[FDMRecordsDidChangeNotification, UIApplicationDidBecomeActiveNotification, UIContentSizeCategoryDidChangeNotification]) {
        id token = [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { [weakSelf refresh]; }];
        [_observers addObject:token];
    }
}
- (void)stopObserving {
    _refreshReady = NO;
    _refreshScheduled = NO;
    _refreshGeneration++;
    [_timer invalidate];
    _timer = nil;
    for (id token in _observers) [NSNotificationCenter.defaultCenter removeObserver:token];
    [_observers removeAllObjects];
}
- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView { _scrolling = YES; }
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (!decelerate) { _scrolling = NO; if (_refreshPending) [self refresh]; }
}
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    _scrolling = NO;
    if (_refreshPending) [self refresh];
}

- (NSDictionary *)displayRow:(NSDictionary *)record adapter:(NSString *)adapter live:(BOOL)live {
    NSMutableDictionary *row = [record mutableCopy];
    row[@"adapter"] = adapter;
    row[@"live"] = @(live);
    BOOL resumable = NO;
    if ([row[@"state"] integerValue] != FDMStateCompleted && ![adapter isEqual:@"host"]) {
        resumable = live && [adapter isEqual:@"engine"] ? [record[@"canResume"] boolValue] : [FDMEngine.shared canResumeKey:row[@"key"]];
    }
    if ([adapter isEqual:@"legacy"] && resumable && [row[@"state"] integerValue] != FDMStateCompleted) { adapter = @"engine"; row[@"adapter"] = adapter; }
    row[@"canResume"] = @([adapter isEqual:@"engine"] && resumable);
    if (!live && [row[@"state"] integerValue] == FDMStateDownloading) {
        row[@"state"] = @(FDMStateInterrupted);
        row[@"statusDetail"] = [adapter isEqual:@"engine"] && resumable ? @"上次下载已中断；可断点继续" : @"上次宿主下载已离开内存；只能重新下载";
        row[@"speed"] = @0;
        row[@"pausing"] = @NO;
    }
    return row;
}
- (void)refresh {
    if (!self.isViewLoaded || _refreshing) return;
    _refreshPending = YES;
    if (!_refreshReady || _refreshScheduled || _scrolling) return;
    _refreshScheduled = YES;
    NSUInteger generation = _refreshGeneration;
    __weak typeof(self) weakSelf = self;
    // Default-mode work waits for scrolling; one snapshot absorbs synchronous store notifications.
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopDefaultMode, ^{
        typeof(self) self = weakSelf;
        if (!self || self->_refreshGeneration != generation) return;
        self->_refreshScheduled = NO;
        if (!self->_refreshReady || self->_scrolling) return;
        self->_refreshPending = NO;
        self->_refreshing = YES;
        @try { [self refreshSnapshot]; }
        @finally { self->_refreshing = NO; }
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());
}
- (void)refreshSnapshot {
    [FDMHostDownloads.shared refresh];
    NSArray *history = [FDMStore.shared records];
    NSMutableDictionary<NSString *, NSDictionary *> *historyByKey = [NSMutableDictionary dictionaryWithCapacity:history.count];
    for (NSDictionary *record in history) {
        NSString *key = FDMString(record[@"key"]);
        if (key.length) historyByKey[key] = record;
    }
    NSMutableDictionary<NSString *, NSDictionary *> *byKey = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *legacyAliases = [NSMutableSet set];
    for (NSDictionary *record in [FDMEngine.shared items]) {
        NSString *key = FDMString(record[@"key"]);
        NSString *legacy = FDMString(record[@"legacyKey"]);
        if (FDMLegacyAliasMatches(record, legacy ? historyByKey[legacy] : nil)) [legacyAliases addObject:legacy];
        if (key.length && ![FDMEngine.shared isRemovedKey:key]) byKey[key] = [self displayRow:record adapter:@"engine" live:YES];
    }
    for (NSDictionary *record in [FDMHostDownloads.shared rows]) {
        NSString *key = FDMString(record[@"key"]);
        if (key.length && ![FDMHostDownloads.shared isSuppressedKey:key] && !byKey[key]) byKey[key] = [self displayRow:record adapter:@"host" live:YES];
    }
    for (NSDictionary *record in history) {
        NSString *legacy = FDMString(record[@"legacyKey"]);
        if ([record[@"schema"] integerValue] == 2 && FDMLegacyAliasMatches(record, legacy ? historyByKey[legacy] : nil)) [legacyAliases addObject:legacy];
    }
    for (NSDictionary *record in history) {
        NSString *key = FDMString(record[@"key"]);
        if (!key.length || byKey[key] || ([record[@"schema"] integerValue] != 2 && [legacyAliases containsObject:key]) || [FDMEngine.shared isRemovedKey:key] || [FDMHostDownloads.shared isSuppressedKey:key]) continue;
        BOOL modern = [record[@"schema"] integerValue] == 2;
        NSString *adapter = modern && [record[@"source"] integerValue] == 0 ? @"engine" : (modern && [record[@"source"] integerValue] == 1 ? @"host" : @"legacy");
        byKey[key] = [self displayRow:record adapter:adapter live:NO];
    }
    NSArray *ordered = [byKey.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult result = [(b[@"time"] ?: @0) compare:(a[@"time"] ?: @0)];
        return result == NSOrderedSame ? [a[@"key"] compare:b[@"key"]] : result;
    }];
    NSMutableArray *active = [NSMutableArray array];
    NSMutableArray *finished = [NSMutableArray array];
    NSMutableString *signature = [NSMutableString string];
    for (NSDictionary *row in ordered) {
        if (![self rowMatchesFilter:row]) continue;
        NSInteger state = [row[@"state"] integerValue];
        BOOL running = state == FDMStateDownloading || state == FDMStatePaused || (state == FDMStateInterrupted && [row[@"canResume"] boolValue]);
        [(running ? active : finished) addObject:row];
        [signature appendFormat:@"%@:%@:%ld:%d:%ld|", running ? @"A" : @"F", row[@"key"], (long)state, [row[@"pausing"] boolValue], (long)[row[@"schedulerStatus"] integerValue]];
    }
    _active = active;
    _finished = finished;
    if (![_signature isEqual:signature]) { _signature = [signature copy]; [self.tableView reloadData]; }
    else for (NSIndexPath *path in self.tableView.indexPathsForVisibleRows) {
        NSDictionary *row = [self rowAt:path];
        FDMDownloadCell *cell = (FDMDownloadCell *)[self.tableView cellForRowAtIndexPath:path];
        if (row && [cell isKindOfClass:FDMDownloadCell.class]) [cell render:row];
    }
    BOOL restoring = FDMEngine.shared.restoring;
    _addButton.enabled = !restoring;
    BOOL canPause = NO, canResume = NO;
    for (NSDictionary *row in _active) { canPause |= [self canPause:row]; canResume |= [self canResume:row]; }
    _allButton.title = canPause ? @"全部暂停" : @"全部继续";
    _allButton.enabled = !restoring && (canPause || canResume);
    if (restoring) {
        _restoringLabel.text = @"正在恢复系统下载任务，请稍后操作";
        _restoringLabel.frame = CGRectMake(0, 0, self.tableView.bounds.size.width, 60);
        if (self.tableView.tableHeaderView != _restoringLabel) self.tableView.tableHeaderView = _restoringLabel;
    } else if (self.tableView.tableHeaderView) self.tableView.tableHeaderView = nil;
}

// Scope index 0 is 全部 and -1 means no scope selected; both accept every row.
- (BOOL)rowMatchesFilter:(NSDictionary *)row {
    if (_filter > 0) {
        NSInteger state = [row[@"state"] integerValue];
        NSInteger scheduler = [row[@"schedulerStatus"] integerValue];
        switch (_filter) {
            case 1: if (state != FDMStateDownloading) return NO; break;
            case 2: if (!row[@"schedulerStatus"] || scheduler != FDMSchedulerWaiting) return NO; break;
            case 3: if (state != FDMStatePaused || (row[@"schedulerStatus"] && scheduler == FDMSchedulerWaiting)) return NO; break;
            case 4: if (state != FDMStateCompleted) return NO; break;
            case 5: if (state != FDMStateFailed && state != FDMStateInterrupted) return NO; break;
            default: break;
        }
    }
    if (!_query.length) return YES;
    NSString *name = FDMString(row[@"name"]) ?: @"";
    NSString *source = FDMString(row[@"sourceOrigin"]) ?: FDMString(row[@"targetOrigin"]) ?: FDMString(row[@"url"]) ?: @"";
    return [name rangeOfString:_query options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [source rangeOfString:_query options:NSCaseInsensitiveSearch].location != NSNotFound;
}

- (void)updateSearchResultsForSearchController:(UISearchController *)controller {
    _query = [controller.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    [self refresh];
}

- (void)searchBar:(UISearchBar *)searchBar selectedScopeButtonIndexDidChange:(NSInteger)selectedScope {
    _filter = selectedScope;
    [self refresh];
}

- (BOOL)canPause:(NSDictionary *)row { return [row[@"state"] integerValue] == FDMStateDownloading && ![row[@"pausing"] boolValue] && [row[@"live"] boolValue]; }
- (BOOL)canResume:(NSDictionary *)row {
    NSInteger state = [row[@"state"] integerValue];
    return [row[@"adapter"] isEqual:@"engine"] && [row[@"canResume"] boolValue] && ![row[@"pausing"] boolValue] && (state == FDMStatePaused || state == FDMStateInterrupted);
}
- (void)performAction:(NSString *)action row:(NSDictionary *)row {
    if (FDMEngine.shared.restoring) { [self showError:FDMError(@"系统下载任务正在恢复，请稍后操作")]; return; }
    NSString *key = row[@"key"];
    NSDictionary *latest = nil;
    NSString *adapter = row[@"adapter"];
    if ([adapter isEqual:@"host"]) {
        [FDMHostDownloads.shared refresh];
        for (NSDictionary *candidate in FDMHostDownloads.shared.rows) if ([candidate[@"key"] isEqual:key]) { latest = candidate; break; }
    } else if ([adapter isEqual:@"engine"]) {
        for (NSDictionary *candidate in FDMEngine.shared.items) if ([candidate[@"key"] isEqual:key]) { latest = candidate; break; }
    }
    latest = latest ?: [FDMStore.shared recordForKey:key];
    if (!latest || [FDMEngine.shared isRemovedKey:key] || [FDMHostDownloads.shared isSuppressedKey:key]) { [self refresh]; return; }
    row = [self displayRow:latest adapter:adapter live:[row[@"live"] boolValue]];
    NSError *error = nil;
    if ([action isEqual:@"pause"]) {
        if ([adapter isEqual:@"engine"]) [FDMEngine.shared pauseKey:key];
        else if (![FDMHostDownloads.shared pauseKey:key error:&error]) [self showError:error];
    } else if ([action isEqual:@"resume"]) [FDMEngine.shared resumeKey:key];
    else if ([action isEqual:@"restart"]) {
        if ([adapter isEqual:@"engine"] && [row[@"transport"] integerValue] == FDMTransportWebKitDownload) {
            [self showError:FDMError(@"网页原请求不能重放，请返回来源网页重新发起下载")]; return;
        }
        if ([adapter isEqual:@"engine"] && [row[@"state"] integerValue] != FDMStateCompleted) [FDMEngine.shared restartKey:key];
        else {
            if ([row[@"publicSchema"] boolValue]) {
                [self showError:FDMError(@"历史中不保存登录或签名地址。请使用＋重新输入直链，或返回来源网页下载")]; return;
            }
            NSString *newKey = [FDMEngine.shared startURL:FDMString(row[@"url"]) ?: key name:FDMString(row[@"name"]) error:&error];
            if (!newKey.length) { [self showError:error]; return; }
            if ([row[@"state"] integerValue] != FDMStateCompleted) {
                if ([adapter isEqual:@"host"]) [FDMHostDownloads.shared removeKey:key deleteFile:NO completion:^(NSError *failure) { if (failure) [self showError:failure]; }];
                else if (![FDMStore.shared dropKey:key error:&error]) [self showError:error];
            }
        }
    }
    [self refresh];
}
- (BOOL)canRestart:(NSDictionary *)row {
    return [row[@"state"] integerValue] != FDMStateDownloading &&
        !([row[@"publicSchema"] boolValue] && [row[@"state"] integerValue] == FDMStateCompleted) &&
        [row[@"transport"] integerValue] != FDMTransportWebKitDownload;
}
- (void)toggleAll {
    if (FDMEngine.shared.restoring) return;
    BOOL pause = NO;
    for (NSDictionary *row in _active) if ([self canPause:row]) { pause = YES; break; }
    for (NSDictionary *row in [_active copy]) {
        if ((pause && [self canPause:row]) || (!pause && [self canResume:row])) [self performAction:pause ? @"pause" : @"resume" row:row];
    }
}

- (void)addDownload {
    FDMURLInputController *form = [[FDMURLInputController alloc] init];
    form.initialURL = @"";
    __weak typeof(self) weakSelf = self;
    form.submitURL = ^BOOL(NSString *input, NSError **error) {
        NSString *key = [FDMEngine.shared enqueueURL:input name:nil error:error];
        if (key.length) [weakSelf refresh];
        return key.length > 0;
    };
    form.submitBatch = ^NSUInteger(NSArray<NSString *> *urls, NSError **error) {
        BOOL committed = [FDMEngine.shared enqueueURLs:urls error:error];
        [weakSelf refresh];
        return committed ? urls.count : 0;
    };
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:form];
    [self presentController:navigation];
}
- (void)afterCurrentPresentation:(dispatch_block_t)action {
    UIViewController *current = self.presentedViewController;
    if (!current) { action(); return; }
    id<UIViewControllerTransitionCoordinator> transition = current.transitionCoordinator;
    if (current.isBeingDismissed && transition) {
        BOOL registered = [transition animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) { if (!context.isCancelled) action(); }];
        if (registered) return;
    }
    [self dismissViewControllerAnimated:YES completion:action];
}
- (void)presentController:(UIViewController *)controller {
    [self afterCurrentPresentation:^{ [self presentViewController:controller animated:YES completion:nil]; }];
}
- (void)showError:(NSError *)error { [self showError:error completion:nil]; }
- (void)showError:(NSError *)error completion:(void (^)(void))completion {
    if (!error) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"操作未完成" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        if (completion) [weakSelf afterCurrentPresentation:completion];
    }]];
    UIViewController *presenter = self;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    if ([presenter isKindOfClass:UIAlertController.class]) {
        UIViewController *parent = presenter.presentingViewController;
        if (parent && parent != self) {
            [presenter dismissViewControllerAnimated:YES completion:^{ [parent presentViewController:alert animated:YES completion:nil]; }];
            return;
        }
    }
    if (presenter != self && ![presenter isKindOfClass:UIAlertController.class]) {
        // An async engine error must not dismiss a URL form, preview or share controller.
        [presenter presentViewController:alert animated:YES completion:nil];
    } else [self presentController:alert];
}
- (void)anchorSheet:(UIAlertController *)sheet path:(NSIndexPath *)path {
    sheet.popoverPresentationController.sourceView = self.tableView;
    sheet.popoverPresentationController.sourceRect = path ? [self.tableView rectForRowAtIndexPath:path] : CGRectMake(self.tableView.bounds.size.width / 2, self.tableView.contentOffset.y + 24, 1, 1);
}
- (void)deleteRow:(NSDictionary *)row deleteFile:(BOOL)deleteFile {
    __weak typeof(self) weakSelf = self;
    void (^done)(NSError *) = ^(NSError *error) { if (error) [weakSelf showError:error]; [weakSelf refresh]; };
    NSString *adapter = row[@"adapter"];
    if ([adapter isEqual:@"engine"]) [FDMEngine.shared removeKey:row[@"key"] deleteFile:deleteFile completion:done];
    else if ([adapter isEqual:@"host"]) [FDMHostDownloads.shared removeKey:row[@"key"] deleteFile:deleteFile completion:done];
    else {
        NSError *error = nil;
        NSString *path = FDMResolveDocumentPath(row);
        BOOL existed = path.length && [[NSFileManager defaultManager] fileExistsAtPath:path];
        if (!deleteFile || FDMRemoveOwnedFile(row, &error)) {
            if (![FDMStore.shared dropKey:row[@"key"] error:&error] && deleteFile && existed && ![[NSFileManager defaultManager] fileExistsAtPath:path]) error = FDMError([NSString stringWithFormat:@"所属文件已删除，但历史记录仍保留：%@", error.localizedDescription]);
        }
        done(error);
    }
}
- (void)confirmDelete:(NSDictionary *)row path:(NSIndexPath *)path {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"删除下载记录" message:@"仅删除记录会停止此任务，但保留已保存文件和续传数据。" preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"仅删除记录（保留文件）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [self deleteRow:row deleteFile:NO]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"删除记录和所属文件" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) { [self deleteRow:row deleteFile:YES]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self anchorSheet:sheet path:path];
    [self presentController:sheet];
}
- (NSURL *)fileURLForRow:(NSDictionary *)row {
    NSString *path = FDMResolveDocumentPath(row);
    NSDictionary *identity = path.length ? FDMFileIdentity(path) : nil;
    NSDictionary *expected = row[@"fileIdentity"];
    if (!identity || (expected && ![expected isEqual:identity])) { [self showError:FDMError(@"文件缺失、保存位置未确认或文件已被替换，请在“文件”中检查")]; return nil; }
    return [NSURL fileURLWithPath:path];
}
- (void)openRow:(NSDictionary *)row {
    NSURL *url = [self fileURLForRow:row];
    if (!url) return;
    if (![QLPreviewController canPreviewItem:url]) { [self shareRow:row path:nil]; return; }
    _previewURL = url;
    QLPreviewController *preview = [[QLPreviewController alloc] init];
    preview.dataSource = self;
    [self presentController:preview];
}
- (void)shareRow:(NSDictionary *)row path:(NSIndexPath *)path {
    NSURL *url = [self fileURLForRow:row];
    if (!url) return;
    UIActivityViewController *controller = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    controller.popoverPresentationController.sourceView = self.tableView;
    controller.popoverPresentationController.sourceRect = path ? [self.tableView rectForRowAtIndexPath:path] : self.tableView.bounds;
    [self presentController:controller];
}
- (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)controller { return _previewURL ? 1 : 0; }
- (id<QLPreviewItem>)previewController:(QLPreviewController *)controller previewItemAtIndex:(NSInteger)index { return _previewURL; }

- (void)showMore {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"下载管理" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"GET并发上限" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        UIAlertController *choices = [UIAlertController alertControllerWithTitle:@"可重放GET并发" message:@"网页原导航下载已在途中，不受这个等待队列上限控制。" preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSUInteger count = 1; count <= 6; count++) {
            [choices addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%lu个%@", (unsigned long)count,
                count == FDMEngine.shared.concurrencyLimit ? @"（当前）" : @""] style:UIAlertActionStyleDefault handler:^(UIAlertAction *choice) {
                FDMEngine.shared.concurrencyLimit = count;
            }]];
        }
        [choices addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [self anchorSheet:choices path:nil]; [self presentController:choices];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"保存位置与使用说明" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *text = @"自建下载保存在“文件 → 我的 iPhone → Focus → FocusDM → downloads”。宿主下载请看每条记录的保存路径。\n\n已完成记录可点开预览或分享，使用系统分享菜单存储到其他位置。宿主下载不支持断点续传，本页会明确显示重新下载。";
        UIAlertController *help = [UIAlertController alertControllerWithTitle:@"保存位置" message:text preferredStyle:UIAlertControllerStyleAlert];
        [help addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentController:help];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self anchorSheet:sheet path:nil];
    [self presentController:sheet];
}
- (NSDictionary *)rowAt:(NSIndexPath *)path {
    NSArray *rows = path.section == 0 ? _active : _finished;
    return path.row >= 0 && path.row < (NSInteger)rows.count ? rows[path.row] : nil;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section == 0 ? MAX(1, _active.count) : _finished.count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return [NSString stringWithFormat:section == 0 ? @"进行中（%lu）" : @"已结束（%lu）", (unsigned long)(section == 0 ? _active.count : _finished.count)]; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    NSDictionary *row = [self rowAt:path];
    if (!row) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"empty"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"empty"];
        cell.textLabel.text = @"暂无进行中的下载";
        cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        cell.textLabel.adjustsFontForContentSizeCategory = YES;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    FDMDownloadCell *cell = [tableView dequeueReusableCellWithIdentifier:@"download" forIndexPath:path];
    [cell render:row];
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    NSDictionary *row = [self rowAt:path];
    if (!row) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:row[@"name"] message:FDMRowDetail(row) preferredStyle:UIAlertControllerStyleActionSheet];
    if ([row[@"state"] integerValue] == FDMStateCompleted) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"打开文件" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [self openRow:row]; }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"分享或另存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [self shareRow:row path:path]; }]];
    }
    if (!FDMEngine.shared.restoring && ![row[@"pausing"] boolValue]) {
        if ([self canPause:row]) [sheet addAction:[UIAlertAction actionWithTitle:@"暂停" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [self performAction:@"pause" row:row]; }]];
        else if ([self canResume:row]) [sheet addAction:[UIAlertAction actionWithTitle:@"断点继续" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [self performAction:@"resume" row:row]; }]];
        else if ([self canRestart:row]) [sheet addAction:[UIAlertAction actionWithTitle:[row[@"state"] integerValue] == FDMStateCompleted ? @"再次下载（保留原记录）" : @"重新下载" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [self performAction:@"restart" row:row]; }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"删除…" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) { [self confirmDelete:row path:path]; }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self anchorSheet:sheet path:path];
    [self presentController:sheet];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)path {
    NSDictionary *row = [self rowAt:path];
    if (!row || FDMEngine.shared.restoring || [row[@"pausing"] boolValue]) return nil;
    NSMutableArray *actions = [NSMutableArray array];
    NSString *action = [self canPause:row] ? @"pause" : ([self canResume:row] ? @"resume" : ([self canRestart:row] && [row[@"state"] integerValue] != FDMStateCompleted ? @"restart" : nil));
    if (action) {
        NSString *title = [action isEqual:@"pause"] ? @"暂停" : ([action isEqual:@"resume"] ? @"继续" : @"重下");
        [actions addObject:[UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:title handler:^(UIContextualAction *item, UIView *view, void (^done)(BOOL)) { [self performAction:action row:row]; done(YES); }]];
    }
    [actions addObject:[UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"删除" handler:^(UIContextualAction *item, UIView *view, void (^done)(BOOL)) { [self confirmDelete:row path:path]; done(NO); }]];
    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:actions];
    configuration.performsFirstActionWithFullSwipe = NO;
    return configuration;
}
@end
