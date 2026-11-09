#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// 全局“网站规则”列表：搜索、逐站重置。入口放在设置页。
@interface FDMSitePoliciesViewController : UITableViewController
@end

@class WKWebView;
// 单个 origin 的策略编辑页。当前页菜单“网站设置”进入。
@interface FDMSitePolicyEditViewController : UITableViewController
- (instancetype)initWithOrigin:(NSString *)origin;
@property (nonatomic, weak, nullable) WKWebView *webView;
// 保存后回调，用于“保存并重载”。
@property (nonatomic, copy, nullable) void (^didChangePolicy)(BOOL reload);
@end

// 数据备份与恢复页：类别选择、导出、导入预览。
@interface FDMBackupViewController : UITableViewController
@end

NS_ASSUME_NONNULL_END
