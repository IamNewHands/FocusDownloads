// UIKit lifecycle and scheduler fixtures; no real Focus runtime or network is used.
#import <UIKit/UIKit.h>
#import "FDMDownloadsViewController.h"
#import "FDMCommon.h"

@interface FDMDownloadsViewController (FDMRefreshFixture)
- (void)refresh;
- (void)refreshSnapshot;
@end

@interface FDMRefreshFixtureController : FDMDownloadsViewController
@property (nonatomic) NSUInteger snapshotCount;
@property (nonatomic) NSUInteger snapshotDepth;
@property (nonatomic) NSUInteger maximumDepth;
@end
@implementation FDMRefreshFixtureController
- (void)refreshSnapshot {
    self.snapshotCount++;
    self.snapshotDepth++;
    self.maximumDepth = MAX(self.maximumDepth, self.snapshotDepth);
    [NSNotificationCenter.defaultCenter postNotificationName:FDMRecordsDidChangeNotification object:nil];
    [self refresh];
    self.snapshotDepth--;
}
@end

static void FDMDrainRefreshWork(void) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);
}

static UIView *FDMFirstViewWithIdentifier(UIView *root, NSString *identifier) {
    if ([root.accessibilityIdentifier isEqualToString:identifier]) return root;
    for (UIView *child in root.subviews) {
        UIView *hit = FDMFirstViewWithIdentifier(child, identifier);
        if (hit) return hit;
    }
    return nil;
}

static void FDMAssertOpaqueAppearance(UINavigationBarAppearance *appearance) {
    NSCAssert(appearance && !appearance.backgroundEffect, @"download navigation has no translucent effect");
    UIColor *color = [appearance.backgroundColor resolvedColorWithTraitCollection:[UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleLight]];
    NSCAssert(CGColorGetAlpha(color.CGColor) == 1, @"download navigation background is opaque");
}

void FDMRunDownloadUIRegressionTests(void) {
    NSCAssert(NSThread.isMainThread, @"download UI fixture belongs to main");
    FDMRefreshFixtureController *page = [[FDMRefreshFixtureController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    UIViewController *host = [UIViewController new];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:host];
    UINavigationBarAppearance *hostAppearance = [[UINavigationBarAppearance alloc] init];
    [hostAppearance configureWithTransparentBackground];
    navigation.navigationBar.standardAppearance = hostAppearance;
    [navigation pushViewController:page animated:NO];
    [page loadViewIfNeeded];
    FDMAssertOpaqueAppearance(page.navigationItem.standardAppearance);
    FDMAssertOpaqueAppearance(page.navigationItem.scrollEdgeAppearance);
    FDMAssertOpaqueAppearance(page.navigationItem.compactAppearance);
    if (@available(iOS 15.0, *)) FDMAssertOpaqueAppearance(page.navigationItem.compactScrollEdgeAppearance);
    NSCAssert(!page.navigationItem.searchController, @"download page keeps no navigation search controller (the host search container rendered as a clipped band)");
    page.view.frame = CGRectMake(0, 0, 390, 844);
    [page.view layoutIfNeeded];
    UITextField *searchField = (UITextField *)FDMFirstViewWithIdentifier(page.view, @"FDMDownloadSearchField");
    UIButton *filterButton = (UIButton *)FDMFirstViewWithIdentifier(page.view, @"FDMDownloadFilterButton");
    NSCAssert(searchField && [searchField isKindOfClass:UITextField.class], @"download page owns an in-page search field");
    NSCAssert(searchField.placeholder.length > 0 && searchField.delegate == (id)page, @"in-page search field is wired to the page");
    NSCAssert(filterButton && [filterButton isKindOfClass:UIButton.class] && filterButton.menu, @"filter entry exposes a menu");
    NSCAssert(filterButton.menu.children.count == 6, @"filter menu lists every state");
    NSCAssert(page.tableView.tableHeaderView && CGRectGetHeight(page.tableView.tableHeaderView.frame) > 0, @"search header is the table header, not the navigation bar");
    NSCAssert(navigation.navigationBar.standardAppearance.backgroundColor == hostAppearance.backgroundColor, @"download appearance does not mutate shared host navigation");
    NSCAssert(page.snapshotCount == 0, @"loading the page does no synchronous host/store snapshot");

    [page viewWillAppear:YES];
    [page refresh];
    FDMDrainRefreshWork();
    NSCAssert(page.snapshotCount == 0 && ![page valueForKey:@"timer"], @"push animation has no timer or snapshot work");
    [page viewDidAppear:YES];
    [page refresh];
    [page refresh];
    FDMDrainRefreshWork();
    NSCAssert(page.snapshotCount == 1 && page.maximumDepth == 1, @"appearance and notifications coalesce, including notifications emitted inside snapshot");

    [page scrollViewWillBeginDragging:page.tableView];
    [page refresh];
    [NSNotificationCenter.defaultCenter postNotificationName:FDMRecordsDidChangeNotification object:nil];
    FDMDrainRefreshWork();
    NSCAssert(page.snapshotCount == 1, @"dragging defers snapshot and store work");
    [page scrollViewDidEndDragging:page.tableView willDecelerate:YES];
    FDMDrainRefreshWork();
    NSCAssert(page.snapshotCount == 1, @"deceleration also defers snapshot");
    [page scrollViewDidEndDecelerating:page.tableView];
    FDMDrainRefreshWork();
    NSCAssert(page.snapshotCount == 2, @"one current snapshot follows scrolling");

    [page refresh];
    [page viewWillDisappear:YES];
    FDMDrainRefreshWork();
    NSCAssert(page.snapshotCount == 2 && ![page valueForKey:@"timer"], @"leaving cancels pending snapshot and timer before transition");
    [page viewDidAppear:YES];
    FDMDrainRefreshWork();
    NSCAssert(page.snapshotCount == 3 && [page valueForKey:@"timer"], @"cancelled interactive pop resumes live updates");
    [page viewWillDisappear:NO];
    [page viewDidDisappear:NO];
    NSLog(@"download UI regression PASS (UIKit fixture; not Focus device animation profiling)");
}
