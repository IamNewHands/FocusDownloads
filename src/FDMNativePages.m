#import "FDMNativePages.h"
#import "FDMPolicy.h"
#import "FDMBackup.h"
#import "FDMCommon.h"
#import "FDMNavigation.h"
#import <math.h>
#import <objc/message.h>

static NSString *FDMPolicyFieldTitle(NSString *field) {
    NSDictionary *titles = @{FDMPolicyContentMode: @"桌面/移动版本",
                             FDMPolicyUserAgent: @"自定义 User-Agent",
                             FDMPolicyPageZoom: @"页面缩放",
                             FDMPolicyReader: @"自动进入阅读模式",
                             FDMPolicyContentBlocking: @"内容拦截",
                             FDMPolicyPageJavaScript: @"网页 JavaScript",
                             FDMPolicyUserScripts: @"用户脚本",
                             FDMPolicyExternalApps: @"打开外部 App",
                             FDMPolicyCamera: @"摄像头",
                             FDMPolicyMicrophone: @"麦克风"};
    return titles[field] ?: field;
}

static NSString *FDMPolicyValueTitle(NSString *field, id value) {
    if (!value || value == NSNull.null) return @"继承";
    if ([field isEqual:FDMPolicyPageZoom]) return [NSString stringWithFormat:@"%.2f×", [value doubleValue]];
    if ([field isEqual:FDMPolicyUserAgent]) return value;
    NSDictionary *labels = @{@"desktop": @"桌面版", @"mobile": @"移动版", @"auto": @"自动", @"off": @"关闭",
                             @"on": @"开启", @"ask": @"询问", @"allow": @"允许", @"deny": @"拒绝"};
    return labels[value] ?: [value description];
}

static NSArray<NSString *> *FDMPolicyOptionsForField(NSString *field) {
    NSDictionary *options = @{FDMPolicyContentMode: @[FDMPolicyInherit, @"mobile", @"desktop"],
                              FDMPolicyReader: @[FDMPolicyInherit, @"auto", @"off"],
                              FDMPolicyContentBlocking: @[FDMPolicyInherit, @"on", @"off"],
                              FDMPolicyPageJavaScript: @[FDMPolicyInherit, @"on", @"off"],
                              FDMPolicyUserScripts: @[FDMPolicyInherit, @"on", @"off"],
                              FDMPolicyExternalApps: @[FDMPolicyInherit, @"ask", @"allow", @"deny"],
                              FDMPolicyCamera: @[FDMPolicyInherit, @"ask", @"allow", @"deny"],
                              FDMPolicyMicrophone: @[FDMPolicyInherit, @"ask", @"allow", @"deny"]};
    return options[field] ?: @[];
}

#pragma mark - site rules list

@implementation FDMSitePoliciesViewController {
    NSArray<NSString *> *_origins;
    UISearchController *_search;
    NSString *_query;
    id _observer;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"网站规则";
    _origins = @[];
    _search = [[UISearchController alloc] initWithSearchResultsController:nil];
    _search.obscuresBackgroundDuringPresentation = NO;
    _search.searchResultsUpdater = (id)self;
    self.navigationItem.searchController = _search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    __weak typeof(self) weakSelf = self;
    _observer = [NSNotificationCenter.defaultCenter addObserverForName:FDMSitePolicyDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { [weakSelf reload]; }];
    [self reload];
}

- (void)dealloc {
    if (_observer) [NSNotificationCenter.defaultCenter removeObserver:_observer];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)controller {
    _query = controller.searchBar.text;
    [self reload];
}

- (void)reload {
    NSDictionary *origins = FDMSitePolicyStore.shared.snapshot[@"origins"] ?: @{};
    NSArray *all = [origins.allKeys sortedArrayUsingSelector:@selector(compare:)];
    if (_query.length) {
        NSMutableArray *filtered = [NSMutableArray array];
        for (NSString *origin in all) if ([origin rangeOfString:_query options:NSCaseInsensitiveSearch].location != NSNotFound) [filtered addObject:origin];
        _origins = filtered;
    } else _origins = all;
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return MAX(1, (NSInteger)_origins.count);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (!FDMSitePolicyStore.shared.writable) return @"站点规则文件格式未知，已保留原文件且暂停写入";
    return [NSString stringWithFormat:@"已保存的站点（%lu）", (unsigned long)_origins.count];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"规则只匹配精确 origin（协议 + 主机 + 端口）。未列出的站点沿用全局设置，行为与之前完全一致。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"origin"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"origin"];
    if (indexPath.row >= (NSInteger)_origins.count) {
        cell.textLabel.text = _query.length ? @"没有匹配的站点" : @"还没有站点规则";
        cell.detailTextLabel.text = _query.length ? nil : @"浏览网页时从菜单进入“网站设置”即可添加";
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    NSString *origin = _origins[indexPath.row];
    NSDictionary *entry = [FDMSitePolicyStore.shared entryForOrigin:origin];
    NSArray *fields = FDMPolicyOverriddenFields(entry);
    cell.textLabel.text = origin;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.text = fields.count ? [NSString stringWithFormat:@"已覆盖 %lu 项：%@", (unsigned long)fields.count,
        [[fields valueForKey:@"description"] componentsJoinedByString:@"、"]] : @"无覆盖项";
    cell.detailTextLabel.numberOfLines = 0;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= (NSInteger)_origins.count) return;
    FDMSitePolicyEditViewController *page = [[FDMSitePolicyEditViewController alloc] initWithOrigin:_origins[indexPath.row]];
    [self.navigationController pushViewController:page animated:YES];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= (NSInteger)_origins.count) return nil;
    NSString *origin = _origins[indexPath.row];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *reset = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"重置"
                                                                       handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
        NSError *error = nil;
        if (![FDMSitePolicyStore.shared resetOrigin:origin error:&error]) [weakSelf showError:error];
        done(YES);
        [weakSelf reload];
    }];
    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[reset]];
    configuration.performsFirstActionWithFullSwipe = NO;
    return configuration;
}

- (void)showError:(NSError *)error {
    if (!error) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"操作未完成" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end

#pragma mark - single origin editor

@implementation FDMSitePolicyEditViewController {
    NSString *_origin;
    NSMutableDictionary *_draft;
    NSDictionary *_baseline;
    BOOL _dirty;
}

- (instancetype)initWithOrigin:(NSString *)origin {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _origin = [origin copy];
        _draft = [([FDMSitePolicyStore.shared entryForOrigin:origin] ?: @{}) mutableCopy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = _origin;
    _baseline = FDMPolicyGlobalBaseline();
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStyleDone target:self action:@selector(save)];
    self.tableView.allowsMultipleSelectionDuringEditing = NO;
}

- (void)save {
    NSError *error = nil;
    if (![FDMSitePolicyStore.shared setEntry:_draft.count ? _draft : nil origin:_origin error:&error]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"保存失败" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    _dirty = YES;
    __weak typeof(self) weakSelf = self;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"已保存" message:@"规则对下一次导航生效。" preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"保存并重载当前页" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        if (weakSelf.didChangePolicy) weakSelf.didChangePolicy(YES);
        [weakSelf.navigationController popViewControllerAnimated:YES];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"稍后重载" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        if (weakSelf.didChangePolicy) weakSelf.didChangePolicy(NO);
        [weakSelf.navigationController popViewControllerAnimated:YES];
    }]];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? (NSInteger)FDMPolicyFieldKeys().count : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"本站设置" : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"选择“继承”即沿用全局设置。设置值保存后立即写入规则文件，当前生效值会随全局设置变化。";
    return @"仅本次关闭增强：只关闭用户脚本、自动阅读与可选拦截，保留 TLS、登录边界与系统权限；不影响其他标签或站点配置。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"policy"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"policy"];
    cell.detailTextLabel.numberOfLines = 0;
    if (indexPath.section == 1) {
        cell.textLabel.text = @"本次关闭增强";
        cell.detailTextLabel.text = @"只对当前标签页生效，直到重新载入";
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.textLabel.textColor = UIColor.systemBlueColor;
        return cell;
    }
    NSString *field = FDMPolicyFieldKeys()[indexPath.row];
    id saved = _draft[field];
    id effective = saved ?: _baseline[field];
    cell.textLabel.text = FDMPolicyFieldTitle(field);
    cell.detailTextLabel.text = [NSString stringWithFormat:@"设置：%@ · 生效：%@", FDMPolicyValueTitle(field, saved), FDMPolicyValueTitle(field, effective)];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.textLabel.textColor = UIColor.labelColor;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) { [self closeEnhancementForNow]; return; }
    NSString *field = FDMPolicyFieldKeys()[indexPath.row];
    if ([field isEqual:FDMPolicyPageZoom]) { [self promptZoom:field]; return; }
    if ([field isEqual:FDMPolicyUserAgent]) { [self promptUserAgent:field]; return; }
    NSArray *options = FDMPolicyOptionsForField(field);
    if (!options.count) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:FDMPolicyFieldTitle(field) message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *option in options) {
        BOOL selected = [option isEqual:FDMPolicyInherit] ? _draft[field] == nil : [_draft[field] isEqual:option];
        NSString *title = selected ? ([option isEqual:FDMPolicyInherit] ? @"✓ 继承全局" : [NSString stringWithFormat:@"✓ %@", FDMPolicyValueTitle(field, option)])
            : ([option isEqual:FDMPolicyInherit] ? @"继承全局" : FDMPolicyValueTitle(field, option));
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            if ([option isEqual:FDMPolicyInherit]) [self->_draft removeObjectForKey:field];
            else self->_draft[field] = option;
            [self.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = tableView;
    sheet.popoverPresentationController.sourceRect = [tableView rectForRowAtIndexPath:indexPath];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)promptZoom:(NSString *)field {
    NSNumber *current = _draft[field];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"页面缩放" message:@"0.50 到 3.00 之间" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.keyboardType = UIKeyboardTypeDecimalPad;
        textField.text = current ? [NSString stringWithFormat:@"%.2f", [current doubleValue]] : @"1.00";
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *text = alert.textFields.firstObject.text ?: @"";
        double value = text.doubleValue;
        if (text.length && isfinite(value) && value >= 0.5 && value <= 3.0) {
            weakSelf->_draft[field] = @(value);
            [weakSelf.tableView reloadData];
        }
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"继承全局" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [weakSelf->_draft removeObjectForKey:field];
        [weakSelf.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)promptUserAgent:(NSString *)field {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"自定义 User-Agent" message:@"留空表示移除本站覆盖，回到全局 UA 基线。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        id current = self->_draft[field];
        textField.text = [current isKindOfClass:NSString.class] ? current : @"";
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *text = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (text.length) weakSelf->_draft[field] = text;
        else [weakSelf->_draft removeObjectForKey:field];
        [weakSelf.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)closeEnhancementForNow {
    WKWebView *webView = self.webView;
    if (!webView || ![FDMOriginForURL(webView.URL) isEqual:_origin]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"原网页已经关闭或切换站点"
            message:@"请返回原网页重新打开网站设置；不会操作其他标签。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil]; return;
    }
    FDMConfirmPolicyReload(self, webView, YES);
}
@end
#pragma mark - backup page

@implementation FDMBackupViewController {
    NSArray<NSString *> *_categories;
    NSMutableSet<NSString *> *_selected;
    NSURL *_pendingURL;
    FDMBackupContainer *_pendingContainer;
    FDMBackupImportPlan *_pendingPlan;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"数据备份";
    _categories = FDMBackupCoordinator.shared.availableCategories;
    _selected = [NSMutableSet set];
    for (NSString *category in _categories) if (FDMBackupCategorySelectedByDefault(category)) [_selected addObject:category];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"导出" style:UIBarButtonItemStyleDone target:self action:@selector(exportBackup)];
    self.tableView.allowsMultipleSelection = NO;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? (NSInteger)_categories.count : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"选择要备份的类别" : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"始终不包含：Cookie、密码、钥匙串、Authorization、下载请求/续传数据、浏览历史、缓存与无痕数据。用户脚本可能包含密钥，默认不选。备份文件不加密，请妥善保存。";
    return @"导入前会完整校验并显示差异预览；默认合并并保留本地冲突项。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"backup"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"backup"];
    cell.detailTextLabel.numberOfLines = 0;
    if (indexPath.section == 1) {
        cell.textLabel.text = @"从文件导入…";
        cell.detailTextLabel.text = @"选择 .browserbackup 文件";
        cell.textLabel.textColor = UIColor.systemBlueColor;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    NSString *category = _categories[indexPath.row];
    cell.textLabel.text = FDMBackupCategoryTitle(category);
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.text = [category isEqual:FDMBackupCategoryScripts] ? @"可能包含密钥；导入后默认禁用" : nil;
    cell.accessoryType = [_selected containsObject:category] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) { [self pickBackupFile]; return; }
    NSString *category = _categories[indexPath.row];
    if ([_selected containsObject:category]) [_selected removeObject:category];
    else [_selected addObject:category];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)exportBackup {
    NSArray *ordered = [FDMBackupCategoryOrder() filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *category, NSDictionary *bindings) { return [self->_selected containsObject:category]; }]];
    if (!ordered.count) { [self showMessage:@"请至少选择一个类别"]; return; }
    if ([ordered containsObject:FDMBackupCategoryScripts]) {
        UIAlertController *warn = [UIAlertController alertControllerWithTitle:@"包含用户脚本" message:@"脚本原文可能包含 API 密钥或私有地址，备份文件不加密。确认继续？" preferredStyle:UIAlertControllerStyleAlert];
        __weak typeof(self) weakSelf = self;
        [warn addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [warn addAction:[UIAlertAction actionWithTitle:@"继续导出" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) { [weakSelf writeAndShare:ordered]; }]];
        [self presentViewController:warn animated:YES completion:nil];
        return;
    }
    [self writeAndShare:ordered];
}

- (void)writeAndShare:(NSArray<NSString *> *)categories {
    NSError *error = nil;
    NSData *payload = [FDMBackupCoordinator.shared exportCategories:categories error:&error];
    if (!payload.length) { [self showMessage:error.localizedDescription ?: @"导出失败"]; return; }
    FDMBackupContainer *verifiedContainer = FDMBackupDecode(payload, &error);
    if (!verifiedContainer) { [self showMessage:@"导出内容校验未完成"]; return; }
    [self confirmExport:payload container:verifiedContainer];
}
- (void)confirmExport:(NSData *)payload container:(FDMBackupContainer *)container {
    NSMutableString *summary = [NSMutableString stringWithFormat:@"备份大小：%@\n此文件没有加密。书签URL和脚本可能含私有地址或令牌，请只保存在可信位置。\n", FDMHumanSize(payload.length)];
    for (NSString *category in FDMBackupCategoryOrder()) if (container.categories[category])
        [summary appendFormat:@"%@：%lu项\n", FDMBackupCategoryTitle(category), (unsigned long)container.categories[category].itemCount];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"导出预览" message:summary preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"继续保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self shareVerifiedPayload:payload]; });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)shareVerifiedPayload:(NSData *)payload {
    NSError *error = nil;
    NSString *name = [NSString stringWithFormat:@"Focus-备份-%@.browserbackup", NSUUID.UUID.UUIDString];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    if (![payload writeToFile:path options:NSDataWritingAtomic error:&error]) { [self showMessage:error.localizedDescription ?: @"写入失败"]; return; }
    // Read back before sharing so a truncated file is never offered to the user.
    NSData *verify = [NSData dataWithContentsOfFile:path];
    if (![verify isEqualToData:payload]) { [self showMessage:@"导出文件校验失败"]; return; }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    share.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    share.completionWithItemsHandler = ^(UIActivityType type, BOOL completed, NSArray *items, NSError *activityError) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    };
    [self presentViewController:share animated:YES completion:nil];
}

- (void)pickBackupFile {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.data"] inMode:UIDocumentPickerModeImport];
    picker.delegate = (id)self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSError *error = nil;
    FDMBackupContainer *container = [FDMBackupCoordinator.shared openBackupAtURL:url error:&error];
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!container) { [self showMessage:error.localizedDescription ?: @"无法读取备份文件"]; return; }
    NSMutableArray *usable = [NSMutableArray array];
    for (NSString *category in FDMBackupCategoryOrder()) if (container.categories[category]) [usable addObject:category];
    FDMBackupImportPlan *plan = [FDMBackupCoordinator.shared previewContainer:container categories:usable replace:NO error:&error];
    if (!plan) { [self showMessage:error.localizedDescription ?: @"无法预览备份内容"]; return; }
    _pendingContainer = container;
    _pendingPlan = plan;
    [self showPreview:plan.countsByCategory container:container categories:plan.categories];
}

- (void)showPreview:(NSDictionary<NSString *, NSDictionary *> *)preview container:(FDMBackupContainer *)container categories:(NSArray<NSString *> *)categories {
    NSMutableString *text = [NSMutableString string];
    if (container.unsupportedCategories.count) [text appendFormat:@"不支持的类别：%@\n", [container.unsupportedCategories componentsJoinedByString:@"、"]];
    for (NSString *category in categories) {
        NSDictionary *counts = preview[category];
        if (!counts) { [text appendFormat:@"%@：本版本不支持\n", FDMBackupCategoryTitle(category)]; continue; }
        [text appendFormat:@"%@：新增 %@，相同 %@，冲突 %@", FDMBackupCategoryTitle(category),
            counts[@"added"], counts[@"identical"], counts[@"conflict"]];
        if ([counts[@"downgraded"] integerValue] > 0) [text appendFormat:@"，权限降为询问 %@", counts[@"downgraded"]];
        if ([counts[@"disabled"] integerValue] > 0) [text appendFormat:@"，默认禁用 %@", counts[@"disabled"]];
        [text appendString:@"\n"];
    }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"导入预览" message:text preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"合并并保留本地冲突项" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf applyCategories:categories replace:NO];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"替换所选类别…" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [weakSelf confirmReplace:categories];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.tableView;
    sheet.popoverPresentationController.sourceRect = self.tableView.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)confirmReplace:(NSArray<NSString *> *)categories {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"替换所选类别" message:@"只影响选中的类别，不清除下载文件、浏览数据或其他配置。此操作需要二次确认。" preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确认替换" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) { [weakSelf applyCategories:categories replace:YES]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)applyCategories:(NSArray<NSString *> *)categories replace:(BOOL)replace {
    NSError *error = nil;
    FDMBackupImportPlan *plan = _pendingPlan;
    if (replace) plan = [FDMBackupCoordinator.shared previewContainer:_pendingContainer categories:categories replace:YES error:&error];
    if (!plan || ![FDMBackupCoordinator.shared applyPlan:plan error:&error]) {
        [self showMessage:error.localizedDescription ?: @"导入失败"];
        return;
    }
    [self showMessage:@"导入完成。站点规则与脚本已按预览生效。"];
}

- (void)showMessage:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
