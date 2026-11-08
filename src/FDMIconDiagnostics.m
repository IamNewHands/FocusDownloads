#import "FDMIcons.h"
#import "FDMCommon.h"

@interface FDMIconDiagnosticsViewController : UITableViewController
@property (nonatomic, copy) NSArray<NSDictionary *> *entries;
@property (nonatomic, strong) id observer;
@end

@implementation FDMIconDiagnosticsViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"图标缓存诊断";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 96;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"复制诊断" style:UIBarButtonItemStylePlain target:self action:@selector(copyReport)];
    self.tableView.backgroundView = nil;
    [self refreshEntries];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:NO animated:animated];
    __weak typeof(self) weakSelf = self;
    if (!self.observer) self.observer = [NSNotificationCenter.defaultCenter addObserverForName:FDMIconCacheDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { [weakSelf refreshEntries]; }];
    [self refreshEntries];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.observer) { [NSNotificationCenter.defaultCenter removeObserver:self.observer]; self.observer = nil; }
}
- (void)dealloc { if (_observer) [NSNotificationCenter.defaultCenter removeObserver:_observer]; }
- (void)refreshEntries {
    self.entries = FDMIconDiagnosticEntries();
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return MAX(1, self.entries.count); }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"icon-entry"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"icon-entry"];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0;
    cell.accessoryType = UITableViewCellAccessoryNone;
    if (!self.entries.count) {
        cell.textLabel.text = @"尚无新格式图标缓存";
        cell.detailTextLabel.text = @"查看首页或书签后记录状态。旧整块快照保留在文件中，不当作可信原图。";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    NSDictionary *entry = self.entries[indexPath.row];
    cell.textLabel.text = entry[@"url"];
    NSString *kind = [entry[@"kind"] isEqual:@"bitmap"] ? @"图标位图" : @"稳定文字占位";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · 来源 %@\n已应用 %@ · 写盘 %@ · %@\n%@",
                                kind, entry[@"source"] ?: @"unknown", [entry[@"applied"] boolValue] ? @"是" : @"尚未确认",
                                [entry[@"diskCommitted"] boolValue] ? @"成功" : @"未提交", entry[@"version"] ?: @"unknown", entry[@"error"] ?: @""];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!self.entries.count || indexPath.row >= self.entries.count) return;
    NSDictionary *entry = self.entries[indexPath.row];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"刷新此站图标" message:@"仅将此站的新格式图标标记为需重取；不删除旧缓存、书签或下载文件。已展示的控件会重新准备，其他控件下次进入时准备。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"刷新" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { FDMRefreshIcon(entry[@"key"]); }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)copyReport {
    NSMutableString *text = [NSMutableString stringWithFormat:@"FocusDM %@ revision=%@\n图标缓存诊断（地址已脱敏）\n", FDMPatchVersion(), FDMBuildRevision()];
    for (NSDictionary *entry in self.entries) [text appendFormat:@"%@ key=%@ kind=%@ source=%@ applied=%@ disk=%@ error=%@\n", entry[@"url"], entry[@"key"], entry[@"kind"], entry[@"source"], entry[@"applied"], entry[@"diskCommitted"], entry[@"error"] ?: @""];
    UIPasteboard.generalPasteboard.string = text;
    self.navigationItem.rightBarButtonItem.title = @"已复制";
}
@end

UIViewController *FDMCreateIconDiagnosticsViewController(void) {
    return [[FDMIconDiagnosticsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
}
