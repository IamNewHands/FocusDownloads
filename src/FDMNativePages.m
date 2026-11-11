#import "FDMNativePages.h"
#import "FDMPolicy.h"
#import "FDMBackup.h"
#import "FDMCommon.h"
#import "FDMNavigation.h"
#import "FDMPageNavigation.h"
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

@interface FDMSitePoliciesViewController () <UITextFieldDelegate>
@end

@implementation FDMSitePoliciesViewController {
    NSArray<NSString *> *_origins;
    UIView *_headerView;
    UITextField *_searchField;
    CGSize _headerSize;
    NSString *_query;
    id _observer;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"网站规则";
    FDMPrepareOwnedPage(self);
    _origins = @[];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self buildHeaderView];
    __weak typeof(self) weakSelf = self;
    _observer = [NSNotificationCenter.defaultCenter addObserverForName:FDMSitePolicyDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { [weakSelf reload]; }];
    [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    FDMPrepareOwnedPage(self);
    [self.navigationController setNavigationBarHidden:NO animated:animated];
}
- (void)dealloc {
    if (_observer) [NSNotificationCenter.defaultCenter removeObserver:_observer];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutHeaderView];
}

- (void)buildHeaderView {
    if (_headerView) return;
    _headerView = [[UIView alloc] init];
    _headerView.backgroundColor = UIColor.clearColor;

    UIView *iconBox = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 34, 36)];
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"magnifyingglass"]];
    icon.frame = CGRectMake(12, 9, 18, 18);
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tintColor = UIColor.secondaryLabelColor;
    [iconBox addSubview:icon];

    _searchField = [[UITextField alloc] init];
    _searchField.placeholder = @"搜索站点地址";
    _searchField.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _searchField.adjustsFontForContentSizeCategory = YES;
    _searchField.textColor = UIColor.labelColor;
    _searchField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _searchField.returnKeyType = UIReturnKeySearch;
    _searchField.autocorrectionType = UITextAutocorrectionTypeNo;
    _searchField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _searchField.leftView = iconBox;
    _searchField.leftViewMode = UITextFieldViewModeAlways;
    _searchField.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    _searchField.layer.cornerRadius = 10;
    _searchField.layer.cornerCurve = kCACornerCurveContinuous;
    _searchField.accessibilityIdentifier = @"FDMSitePolicySearchField";
    _searchField.accessibilityLabel = @"搜索站点";
    _searchField.delegate = self;
    [_searchField addTarget:self action:@selector(searchFieldChanged) forControlEvents:UIControlEventEditingChanged];
    [_headerView addSubview:_searchField];
}

- (void)layoutHeaderView {
    if (!_headerView) return;
    CGFloat width = self.tableView.bounds.size.width;
    if (width <= 0) return;
    CGFloat inset = 16, rowHeight = 36, padding = 8;
    _searchField.frame = CGRectMake(inset, padding, MAX(80, width - inset * 2), rowHeight);
    _headerView.frame = CGRectMake(0, 0, width, padding + rowHeight + padding);
    if (!CGSizeEqualToSize(_headerSize, _headerView.frame.size)) {
        _headerSize = _headerView.frame.size;
        self.tableView.tableHeaderView = _headerView;
    }
}

- (void)searchFieldChanged {
    NSString *text = [_searchField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if ([text isEqualToString:_query ?: @""]) return;
    _query = text;
    [self reload];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (BOOL)textFieldShouldClear:(UITextField *)textField {
    if (_query.length) {
        _query = @"";
        [self reload];
    }
    return YES;
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
    FDMShowOwnedPage(self, page);
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
    FDMPrepareOwnedPage(self);
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
        typeof(self) owner = weakSelf;
        if (!owner) return;
        NSString *text = alert.textFields.firstObject.text ?: @"";
        double value = text.doubleValue;
        if (text.length && isfinite(value) && value >= 0.5 && value <= 3.0) {
            owner->_draft[field] = @(value);
            [owner.tableView reloadData];
        }
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"继承全局" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        typeof(self) owner = weakSelf;
        if (!owner) return;
        [owner->_draft removeObjectForKey:field];
        [owner.tableView reloadData];
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
        typeof(self) owner = weakSelf;
        if (!owner) return;
        NSString *text = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (text.length) owner->_draft[field] = text;
        else [owner->_draft removeObjectForKey:field];
        [owner.tableView reloadData];
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
    NSSet<NSString *> *_exportSelection;
    BOOL _importMode;
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
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? (NSInteger)_categories.count : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? (_importMode ? @"选择要恢复的类别（文件内容）" : @"选择要备份的类别") : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        if (_importMode) return @"只恢复勾选的类别；不支持的类别不可选。用户脚本可能包含密钥，默认不选；新增或改变的脚本导入后禁用。点“下一步：预览”查看差异，不会立即写入。";
        return @"始终不包含：Cookie、密码、钥匙串、Authorization、下载请求/续传数据、浏览历史、缓存与无痕数据。用户脚本可能包含密钥，默认不选。备份文件不加密，请妥善保存。";
    }
    return _importMode ? @"取消会返回导出页面，不修改本地数据或原备份文件。" : @"导入前会完整校验并显示差异预览；默认合并并保留本地冲突项。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"backup"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"backup"];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessibilityTraits = UIAccessibilityTraitButton;
    cell.accessibilityValue = nil;
    if (indexPath.section == 1) {
        cell.textLabel.text = _importMode ? @"取消导入" : @"从文件导入…";
        cell.detailTextLabel.text = _importMode ? @"返回导出页面，不改动任何数据" : @"选择 .browserbackup 文件";
        cell.textLabel.textColor = UIColor.systemBlueColor;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    NSString *category = _categories[indexPath.row];
    BOOL available = !_importMode || ([_pendingContainer.categories objectForKey:category] && [FDMBackupCoordinator.shared.availableCategories containsObject:category]);
    BOOL selected = available && [_selected containsObject:category];
    cell.textLabel.text = FDMBackupCategoryTitle(category);
    cell.textLabel.textColor = available ? UIColor.labelColor : UIColor.secondaryLabelColor;
    NSString *scriptNotice = [category isEqual:FDMBackupCategoryScripts] ? @"可能包含密钥；默认不选，新增或改变的脚本导入后禁用" : nil;
    if (_importMode) {
        FDMBackupCategory *entry = _pendingContainer.categories[category];
        NSString *contents = entry ? [NSString stringWithFormat:@"文件包含 %lu 项", (unsigned long)entry.itemCount] : @"文件包含此类别";
        cell.detailTextLabel.text = !available ? [contents stringByAppendingString:@"；本版本或当前环境不支持，不会恢复"] : (scriptNotice ? [contents stringByAppendingFormat:@"；%@", scriptNotice] : contents);
    } else cell.detailTextLabel.text = scriptNotice;
    cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.accessibilityValue = available ? (selected ? @"已选择" : @"未选择") : @"不支持，不会恢复";
    cell.accessibilityTraits = available ? (UIAccessibilityTraitButton | (selected ? UIAccessibilityTraitSelected : 0)) : UIAccessibilityTraitNotEnabled;
    if (!available) cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) {
        if (_importMode) [self cancelImport]; else [self pickBackupFile];
        return;
    }
    NSString *category = _categories[indexPath.row];
    if (_importMode && (!_pendingContainer.categories[category] || ![FDMBackupCoordinator.shared.availableCategories containsObject:category])) return;
    if ([_selected containsObject:category]) [_selected removeObject:category];
    else [_selected addObject:category];
    _pendingPlan = nil;
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)cancelImport {
    NSSet *selection = _exportSelection ?: [_selected copy];
    _importMode = NO;
    _pendingContainer = nil;
    _pendingPlan = nil;
    _exportSelection = nil;
    _categories = FDMBackupCoordinator.shared.availableCategories;
    _selected = [NSMutableSet set];
    for (NSString *category in _categories) if ([selection containsObject:category]) [_selected addObject:category];
    self.title = @"数据备份";
    self.navigationItem.leftBarButtonItem = nil;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"导出" style:UIBarButtonItemStyleDone target:self action:@selector(exportBackup)];
    [self.tableView reloadData];
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

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    [self cancelImport];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) { [self cancelImport]; return; }
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSError *error = nil;
    FDMBackupContainer *container = [FDMBackupCoordinator.shared openBackupAtURL:url error:&error];
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!container) { [self cancelImport]; [self showMessage:error.localizedDescription ?: @"无法读取备份文件"]; return; }
    if (!_importMode) _exportSelection = [_selected copy];
    _importMode = YES;
    _pendingContainer = container;
    _pendingPlan = nil;
    NSMutableArray *contents = [NSMutableArray array];
    NSArray *available = FDMBackupCoordinator.shared.availableCategories;
    _selected = [NSMutableSet set];
    for (NSString *category in FDMBackupCategoryOrder()) if (container.categories[category]) {
        [contents addObject:category];
        if ([available containsObject:category] && FDMBackupCategorySelectedByDefault(category)) [_selected addObject:category];
    }
    [contents addObjectsFromArray:container.unsupportedCategories];
    _categories = [contents copy];
    self.title = @"恢复备份";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain target:self action:@selector(cancelImport)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"下一步：预览" style:UIBarButtonItemStyleDone target:self action:@selector(previewImport)];
    [self.tableView reloadData];
}

- (void)previewImport {
    if (!_importMode || !_pendingContainer) return;
    NSArray *ordered = [FDMBackupCategoryOrder() filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *category, NSDictionary *bindings) { return [self->_selected containsObject:category]; }]];
    if (!ordered.count) { [self showMessage:@"请至少选择一个可恢复的类别"]; return; }
    NSError *error = nil;
    _pendingPlan = nil;
    FDMBackupImportPlan *plan = [FDMBackupCoordinator.shared previewContainer:_pendingContainer categories:ordered replace:NO error:&error];
    if (!plan) { [self showMessage:error.localizedDescription ?: @"无法预览备份内容"]; return; }
    _pendingPlan = plan;
    [self showPreview:plan];
}

- (void)showPreview:(FDMBackupImportPlan *)plan {
    NSMutableString *text = [NSMutableString stringWithString:plan.replace ? @"替换仅作用于下列所选类别：同 ID 冲突使用备份内容，备份中缺失的本地项会删除。不会清除下载文件、浏览数据或未选类别。\n\n" : @"合并仅作用于下列所选类别；同 ID 冲突保留本地内容。\n\n"];
    if (plan.unsupportedCategories.count) [text appendFormat:@"不支持的类别（不会恢复）：%@\n", [plan.unsupportedCategories componentsJoinedByString:@"、"]];
    for (NSString *category in plan.categories) {
        NSDictionary *counts = plan.countsByCategory[category];
        [text appendFormat:@"%@：新增 %@，相同 %@，冲突 %@，不支持 %@，权限降为询问 %@，脚本禁用 %@\n", FDMBackupCategoryTitle(category),
            counts[FDMBackupCountAdded] ?: @0, counts[FDMBackupCountIdentical] ?: @0, counts[FDMBackupCountConflict] ?: @0,
            counts[FDMBackupCountUnsupported] ?: @0, counts[FDMBackupCountDowngraded] ?: @0, counts[FDMBackupCountDisabled] ?: @0];
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:plan.replace ? @"替换预览 · 二次确认" : @"导入差异预览" message:text preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:plan.replace ? @"确认替换所选类别" : @"合并并保留本地冲突项" style:plan.replace ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        typeof(self) owner = weakSelf;
        if (!owner || owner->_pendingPlan != plan) return;
        [owner applyCategories:plan.categories replace:plan.replace];
    }]];
    if (!plan.replace) [alert addAction:[UIAlertAction actionWithTitle:@"替换所选类别…" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        typeof(self) owner = weakSelf;
        if (!owner || owner->_pendingPlan != plan) return;
        dispatch_async(dispatch_get_main_queue(), ^{ [owner confirmReplace:plan.categories]; });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"返回类别选择" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        typeof(self) owner = weakSelf;
        if (owner && owner->_pendingPlan == plan) owner->_pendingPlan = nil;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消导入" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { [weakSelf cancelImport]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmReplace:(NSArray<NSString *> *)categories {
    FDMBackupImportPlan *original = _pendingPlan;
    if (!original || original.replace || ![original.categories isEqualToArray:categories]) { [self showMessage:@"请重新预览所选类别"]; return; }
    NSError *error = nil;
    FDMBackupImportPlan *replacement = [FDMBackupCoordinator.shared previewContainer:_pendingContainer categories:original.categories replace:YES error:&error];
    if (!replacement) { _pendingPlan = nil; [self showMessage:error.localizedDescription ?: @"无法预览替换内容，请重新预览"]; return; }
    if (![replacement.categories isEqualToArray:original.categories] || ![replacement.revisionByCategory isEqualToDictionary:original.revisionByCategory]) {
        _pendingPlan = nil;
        [self showMessage:@"配置或可用类别在首次预览后已改变，尚未导入。请点“下一步：预览”重新查看差异。"];
        return;
    }
    _pendingPlan = replacement;
    [self showPreview:replacement];
}

- (void)applyCategories:(NSArray<NSString *> *)categories replace:(BOOL)replace {
    FDMBackupImportPlan *plan = _pendingPlan;
    if (!plan || plan.replace != replace || ![plan.categories isEqualToArray:categories]) { [self showMessage:@"计划与已展示的预览不一致，请重新预览"]; return; }
    // Consume exactly the displayed immutable plan. The coordinator checks its original revisions.
    _pendingPlan = nil;
    NSError *error = nil;
    if (![FDMBackupCoordinator.shared applyPlan:plan error:&error]) {
        [self showMessage:[NSString stringWithFormat:@"%@\n请点“下一步：预览”重新查看差异。", error.localizedDescription ?: @"导入失败"]];
        return;
    }
    [self cancelImport];
    [self showMessage:@"所选类别已恢复；未选类别未改动。新增或改变的脚本保持禁用，新配置用于后续导航。"];
}

- (void)showMessage:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
