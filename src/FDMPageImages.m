#import "FDMPageImages.h"
#import "FDMNavigation.h"
#import "FDMIntent.h"
#import "FDMWebKitDownloads.h"
#import "FDMDownloadsViewController.h"
#import "FDMPolicy.h"

void FDMStartSelectedPageImages(WKWebView *webView, NSArray<NSString *> *urls, unsigned long long generation,
    void (^completion)(NSUInteger, NSError *)) {
    NSCAssert(NSThread.isMainThread, @"Page download initiation belongs on main");
    if (@available(iOS 14.5, *)) {
        if (!webView || !urls.count || urls.count > FDMBatchPreviewLimit || FDMNavigationGeneration(webView) != generation) {
            completion(0, FDMError(@"来源页面已改变或图片数量超限，请重新选择")); return;
        }
        NSMutableArray *requests = [NSMutableArray array];
        for (id text in urls) {
            NSURL *url = [text isKindOfClass:NSString.class] ? FDMValidatedURL(text, NULL) : nil;
            if (!url) { completion(0, FDMError(@"含不支持的图片链接；仅支持可单独下载的 HTTP(S) 图片")); return; }
            [requests addObject:[NSURLRequest requestWithURL:url]];
        }
        NSString *tabID = FDMNavigationTabID(webView), *origin = FDMNavigationOrigin(webView);
        __weak WKWebView *weakWebView = webView;
        __block NSUInteger remaining = requests.count, started = 0; __block NSError *failure = nil;
        for (NSURLRequest *request in requests) {
            FDMDownloadIntent *intent = [[FDMDownloadIntent alloc] initWithRequest:request tabID:tabID generation:generation
                sourceOrigin:origin transport:FDMTransportWebKitDownload dataStore:webView.configuration.websiteDataStore
                userInitiated:YES policyRevision:FDMSitePolicyStore.shared.revision];
            // This is a new image selection requested by the user. WebKit, not a copied Cookie header,
            // owns credentials and data-store semantics. An existing response uses didBecomeDownload.
            [webView startDownloadUsingRequest:request completionHandler:^(WKDownload *download) {
                WKWebView *source = weakWebView;
                if (!source || FDMNavigationGeneration(source) != generation || ![FDMNavigationTabID(source) isEqual:tabID]) {
                    [download cancel:nil]; failure = FDMError(@"来源标签已关闭或导航改变；迟到的图片下载已取消");
                } else if (download && [FDMWebKitDownloads.shared adoptDownload:download intent:intent tabID:tabID]) started++;
                else failure = FDMError(@"WebKit 或下载记录无法接管此图片，未计为已开始");
                if (--remaining == 0) completion(started, failure);
            }];
        }
    } else completion(0, FDMError(@"本页图片需要 iOS 14.5+ 的原网页下载能力；未创建匿名替代请求"));
}

@interface FDMPageImagesViewController : UITableViewController
@property (nonatomic, weak) WKWebView *source;
@property (nonatomic) unsigned long long generation;
@property (nonatomic, copy) NSArray<NSString *> *urls;
@property (nonatomic, strong) NSMutableIndexSet *selected;
@end
@implementation FDMPageImagesViewController
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"选择本页图片"; self.urls = @[]; self.selected = [NSMutableIndexSet indexSet];
    self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 64;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"下载所选" style:UIBarButtonItemStyleDone target:self action:@selector(confirm)];
    self.navigationItem.rightBarButtonItem.enabled = NO;
    __weak typeof(self) weakSelf = self;
    NSString *script = @"(function(){var out=[],seen=new Set();for(var image of document.images){var u=image.currentSrc||image.src;if(!u||seen.has(u))continue;try{var x=new URL(u,document.baseURI);if(x.protocol!=='http:'&&x.protocol!=='https:')continue;seen.add(x.href);out.push(x.href);if(out.length===100)break;}catch(e){}}return out;})()";
    [self.source evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        typeof(self) owner = weakSelf; if (!owner) return;
        if (!owner.source || FDMNavigationGeneration(owner.source) != owner.generation) { [owner message:@"来源页面已改变，请重新打开图片选择"]; return; }
        if (error || ![result isKindOfClass:NSArray.class]) { [owner message:@"本页不允许读取图片列表，未创建下载任务"]; return; }
        NSMutableArray *urls = [NSMutableArray array]; for (id text in result) if ([text isKindOfClass:NSString.class] && FDMValidatedURL(text, NULL) && urls.count < FDMBatchPreviewLimit) [urls addObject:text];
        owner.urls = urls; [owner.tableView reloadData];
        if (!urls.count) [owner message:@"没有可单独下载的 HTTP(S) 图片。Blob、MSE 或受保护资源不转成匿名下载。"];
    }];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.urls.count; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"最多列出本页已加载的 100 张 HTTP(S) 图片。按需逐项选择；确认后通过原标签的 WebKit 会话发起新 GET。WebKit 图片不受匿名 GET 并发队列控制，关闭来源页会丢失续传上下文。";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"page-image"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"page-image"];
    NSURL *url = [NSURL URLWithString:self.urls[path.row]];
    cell.textLabel.text = url.lastPathComponent.length ? url.lastPathComponent : @"图片";
    // URL query can be a token; preview never prints it in the table or logs.
    cell.detailTextLabel.text = FDMOriginForURL(url); cell.textLabel.numberOfLines = 0;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; cell.textLabel.adjustsFontForContentSizeCategory = YES;
    BOOL selected = [self.selected containsIndex:path.row]; cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.accessibilityTraits = UIAccessibilityTraitButton | (selected ? UIAccessibilityTraitSelected : 0);
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if ([self.selected containsIndex:path.row]) [self.selected removeIndex:path.row]; else [self.selected addIndex:path.row];
    self.navigationItem.rightBarButtonItem.enabled = self.selected.count != 0;
    [tableView reloadRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationNone];
}
- (void)confirm {
    NSMutableArray *urls = [NSMutableArray array]; [self.selected enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) { [urls addObject:self.urls[index]]; }];
    if (!urls.count) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"开始图片下载？" message:[NSString stringWithFormat:@"已选择 %lu 张图片。将使用本页登录会话；来源页面变化时取消尚未接管的任务。", (unsigned long)urls.count] preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"开始下载" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        self.navigationItem.rightBarButtonItem.enabled = NO;
        FDMStartSelectedPageImages(self.source, urls, self.generation, ^(NSUInteger started, NSError *error) {
            self.navigationItem.rightBarButtonItem.enabled = YES;
            if (!started || error) { [self message:error.localizedDescription ?: @"未能开始下载"]; return; }
            FDMDownloadsViewController *page = [[FDMDownloadsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
            [self.navigationController pushViewController:page animated:YES];
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)message:(NSString *)text {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:text preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:alert animated:YES completion:nil];
}
@end
void FDMOpenPageImages(UIViewController *host) {
    id selected = FDMValue(FDMValue(host, @"tabManager"), @"selectedTab"); WKWebView *source = FDMValue(selected, @"webView");
    if (!source || !FDMOriginForURL(source.URL)) return;
    FDMPageImagesViewController *page = [[FDMPageImagesViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    page.source = source; page.generation = FDMNavigationGeneration(source);
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:page];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen; [host presentViewController:navigation animated:YES completion:nil];
}
