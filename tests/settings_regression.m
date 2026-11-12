// Host stand-ins mirror the verified Focus 2.9.7 row-type routing.
#import <UIKit/UIKit.h>
#import "FDMDownloadsViewController.h"
#import "FDMNativePages.h"

void FDMTestInstallSettingsHooks(void);

@interface SettingModel : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *link;
@property (nonatomic, copy) NSString *content;
@property (nonatomic, copy) NSString *imageName;
@property (nonatomic, copy) NSString *imageBackgroundColor;
@property (nonatomic) int type;
@property (nonatomic) BOOL isFirstInSection;
@property (nonatomic) BOOL isLastInSection;
@end
@implementation SettingModel
@end

@interface FDMSettingsTableFixture : UITableView
@property (nonatomic) NSUInteger reloadCount;
@end
@implementation FDMSettingsTableFixture
- (void)reloadData { self.reloadCount++; [super reloadData]; }
@end

static SettingModel *FDMSettingsFixtureRow(NSString *title, int type, NSString *link) {
    SettingModel *row = [SettingModel new];
    row.title = title; row.type = type; row.link = link;
    row.imageName = @"fixture-icon"; row.imageBackgroundColor = @"#66BB66";
    return row;
}

@interface SettingViewController : UIViewController
@property (nonatomic, strong) NSMutableArray *model;
@property (nonatomic, strong) NSMutableArray *sectionHeaderModel;
@property (nonatomic, strong) FDMSettingsTableFixture *tableView;
@property (nonatomic) NSUInteger originalAppearCount;
@property (nonatomic) NSUInteger originalSelectionCount;
- (void)updateWithModel;
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path;
@end
@implementation SettingViewController
- (void)updateWithModel {
    SettingModel *vip = FDMSettingsFixtureRow(@"Pro", 0, @"focus://vip");
    SettingModel *ordinary = FDMSettingsFixtureRow(@"iCloud", 12, nil);
    ordinary.isFirstInSection = YES; ordinary.isLastInSection = YES;
    SettingModel *recommend = FDMSettingsFixtureRow(@"Other", 17, @"https://fixture.invalid");
    self.model = [NSMutableArray arrayWithArray:@[@[vip], @[ordinary], @[recommend]]];
    self.sectionHeaderModel = [NSMutableArray arrayWithArray:@[@"", @"进阶功能", @"其它作品"]];
    [self.tableView reloadData];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; self.originalAppearCount++; }
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path { self.originalSelectionCount++; }
@end

@interface FDMSettingsNavigationFixture : UINavigationController
@property (nonatomic) BOOL capturePush;
@property (nonatomic) BOOL lastAnimated;
@property (nonatomic, strong) UIViewController *lastPage;
@end
@implementation FDMSettingsNavigationFixture
- (void)pushViewController:(UIViewController *)page animated:(BOOL)animated {
    if (!self.capturePush) { [super pushViewController:page animated:animated]; return; }
    self.lastPage = page; self.lastAnimated = animated;
}
@end

static void FDMAssertSettingsEntries(SettingViewController *settings) {
    NSArray *rows = settings.model[1];
    NSCAssert(rows.count == 4, @"one ordinary host row plus exactly three additions");
    NSArray *titles = @[@"下载管理", @"网站规则", @"数据备份"];
    NSArray *links = @[@"focusdm://downloads", @"focusdm://site-policies", @"focusdm://backup"];
    for (NSUInteger index = 0; index < rows.count; index++) {
        SettingModel *row = rows[index];
        NSCAssert(row.isFirstInSection == (index == 0) && row.isLastInSection == (index + 1 == rows.count), @"native section corners reflect final positions");
        if (!index) continue;
        NSCAssert(row.type != 0 && row.type != 17, @"new rows take the native SettingCell branch, never VIP/recommendation");
        NSCAssert([row.title isEqual:titles[index - 1]] && [row.link isEqual:links[index - 1]], @"all three visible titles route independently");
        NSCAssert([row.imageName isEqual:@"fixture-icon"] && [row.imageBackgroundColor isEqual:@"#66BB66"], @"ordinary row with no link supplies native icon styling");
        NSCAssert(!row.content.length, @"no stale native setting value is copied");
    }
    NSCAssert([settings.model[0] count] == 1, @"native VIP row remains untouched");
    NSCAssert([settings.model count] == 2, @"recommendation section was stripped");
}

void FDMRunSettingsRegressionTests(void) {
    FDMTestInstallSettingsHooks();
    FDMTestInstallSettingsHooks();
    SettingViewController *settings = [SettingViewController new];
    settings.tableView = [[FDMSettingsTableFixture alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    [settings updateWithModel];
    FDMAssertSettingsEntries(settings);
    NSUInteger count = settings.tableView.reloadCount;
    [settings viewWillAppear:NO];
    [settings viewWillAppear:YES];
    FDMAssertSettingsEntries(settings);
    NSCAssert(settings.originalAppearCount == 2 && settings.tableView.reloadCount == count, @"repeat appearance preserves original once and causes no redundant reload");

    SettingModel *broken = settings.model[1][1];
    broken.type = 0; broken.title = @"Pro"; broken.content = @"stale";
    SettingModel *privacy = FDMSettingsFixtureRow(@"隐私协议", 1, nil);
    privacy.imageName = @"setting_lock";
    SettingModel *aboutUs = FDMSettingsFixtureRow(@"关于我们", 1, nil);
    aboutUs.imageName = @"setting_info";
    SettingModel *help = FDMSettingsFixtureRow(@"使用帮助", 1, nil);
    help.imageName = @"setting_question";
    SettingModel *dup = FDMSettingsFixtureRow(@"Pro", 0, @"focusdm://downloads");
    NSMutableArray *unwanted = [NSMutableArray arrayWithObjects:privacy, aboutUs, help, dup, nil];
    [settings.model addObject:unwanted];
    [settings.sectionHeaderModel addObject:@"关于"];
    [settings viewWillAppear:NO];
    FDMAssertSettingsEntries(settings);
    NSCAssert(settings.tableView.reloadCount == count + 1, @"all repairs and duplicate removal use one reload");
    [settings updateWithModel];
    FDMAssertSettingsEntries(settings);

    FDMSettingsNavigationFixture *navigation = [[FDMSettingsNavigationFixture alloc] initWithRootViewController:settings];
    navigation.capturePush = YES;
    NSArray *pageClasses = @[FDMDownloadsViewController.class, FDMSitePoliciesViewController.class, FDMBackupViewController.class];
    for (NSUInteger index = 0; index < 3; index++) {
        [settings tableView:settings.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:index + 1 inSection:1]];
        NSCAssert([navigation.lastPage isKindOfClass:pageClasses[index]] && navigation.lastAnimated, @"each injected row keeps native animated push");
    }
    NSCAssert(settings.originalSelectionCount == 0, @"owned links do not invoke the wrong host menu action");
    [settings tableView:settings.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:1]];
    NSCAssert(settings.originalSelectionCount == 1, @"ordinary host selection still forwards once");
    NSLog(@"settings regression PASS (verified host-routing fixture, not Focus device rendering)");
}
