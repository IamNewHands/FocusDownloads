#import "FDMUserScriptUpdater.h"
#import "FDMCommon.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>

NSString *const FDMUserScriptAutoUpdateEnabledKey  = @"FDMUserScriptAutoUpdateEnabledKey";
NSString *const FDMUserScriptLastSuccessDateKey    = @"FDMUserScriptLastSuccessDateKey";
NSString *const FDMUserScriptLastAttemptDateKey    = @"FDMUserScriptLastAttemptDateKey";
NSString *const FDMUserScriptDidUpdateNotification = @"FDMUserScriptDidUpdateNotification";

static const NSTimeInterval FDMUserScriptFailureBackoffInterval = 900.0; // 15 minutes
static const NSInteger FDMUserScriptHeaderTag = 920501;
static const NSInteger FDMUserScriptSwitchTag = 920502;
static const NSInteger FDMUserScriptDetailTag = 920503;

static BOOL _fdmUserScriptUpdating = NO;

// Original swizzled function pointers
static void (*orig_UserScriptController_viewWillAppear)(id, SEL, BOOL);
static void (*orig_UserScriptController_updateAllUserscripts)(id, SEL);
static void (*orig_UserScriptController_reloadData)(id, SEL);

@implementation FDMUserScriptUpdater

+ (BOOL)isAutoUpdateEnabled {
    id val = [NSUserDefaults.standardUserDefaults objectForKey:FDMUserScriptAutoUpdateEnabledKey];
    if (val == nil) {
        return YES; // Default enabled
    }
    return [val boolValue];
}

+ (void)setAutoUpdateEnabled:(BOOL)enabled {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:FDMUserScriptAutoUpdateEnabledKey];
    [NSUserDefaults.standardUserDefaults synchronize];
    FDMLog(@"userscript updater: auto update enabled set to %d", enabled);
    [NSNotificationCenter.defaultCenter postNotificationName:FDMUserScriptDidUpdateNotification object:nil];
}

+ (BOOL)isUpdating {
    return _fdmUserScriptUpdating;
}

+ (NSDate *)lastSuccessDate {
    return [NSUserDefaults.standardUserDefaults objectForKey:FDMUserScriptLastSuccessDateKey];
}

+ (NSString *)lastSuccessDateString {
    NSDate *date = [self lastSuccessDate];
    if (!date) return nil;
    
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    
    if ([calendar isDateInToday:date]) {
        fmt.dateFormat = @"HH:mm";
        return [NSString stringWithFormat:@"今天 %@", [fmt stringFromDate:date]];
    }
    if ([calendar isDateInYesterday:date]) {
        fmt.dateFormat = @"HH:mm";
        return [NSString stringWithFormat:@"昨天 %@", [fmt stringFromDate:date]];
    }
    fmt.dateFormat = @"yyyy-MM-dd HH:mm";
    return [fmt stringFromDate:date];
}

+ (BOOL)shouldPerformDailyUpdate {
    if (![self isAutoUpdateEnabled]) {
        return NO;
    }
    if (_fdmUserScriptUpdating) {
        return NO;
    }
    
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSDate *lastSuccess = [self lastSuccessDate];
    if (lastSuccess && [calendar isDateInToday:lastSuccess]) {
        return NO; // Already updated today
    }
    
    NSDate *lastAttempt = [NSUserDefaults.standardUserDefaults objectForKey:FDMUserScriptLastAttemptDateKey];
    if (lastAttempt && [[NSDate date] timeIntervalSinceDate:lastAttempt] < FDMUserScriptFailureBackoffInterval) {
        return NO; // Failure backoff
    }
    
    return YES;
}

+ (void)checkAndTriggerDailyUpdateIfNeeded {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self checkAndTriggerDailyUpdateIfNeeded];
        });
        return;
    }
    
    if (![self shouldPerformDailyUpdate]) {
        return;
    }
    
    FDMLog(@"userscript updater: triggering daily script auto-update");
    [self performUpdateWithCompletion:nil];
}

+ (void)recordUpdateSuccessNow {
    NSDate *now = [NSDate date];
    [NSUserDefaults.standardUserDefaults setObject:now forKey:FDMUserScriptLastSuccessDateKey];
    [NSUserDefaults.standardUserDefaults setObject:now forKey:FDMUserScriptLastAttemptDateKey];
    [NSUserDefaults.standardUserDefaults synchronize];
    FDMLog(@"userscript updater: recorded update success timestamp: %@", now);
    [NSNotificationCenter.defaultCenter postNotificationName:FDMUserScriptDidUpdateNotification object:nil];
}

+ (void)performUpdateWithCompletion:(void (^ _Nullable)(BOOL success))completion {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self performUpdateWithCompletion:completion];
        });
        return;
    }
    
    Class updateMgrClass = NSClassFromString(@"UserScriptUpdateManager");
    if (!updateMgrClass) {
        FDMLog(@"userscript updater: UserScriptUpdateManager class missing");
        if (completion) completion(NO);
        return;
    }
    
    SEL shareInstanceSel = NSSelectorFromString(@"shareInstance");
    SEL updateScriptsSel = NSSelectorFromString(@"updateUserScripts");
    if (![updateMgrClass respondsToSelector:shareInstanceSel]) {
        FDMLog(@"userscript updater: shareInstance missing on UserScriptUpdateManager");
        if (completion) completion(NO);
        return;
    }
    
    id updateMgr = [updateMgrClass performSelector:shareInstanceSel];
    if (!updateMgr || ![updateMgr respondsToSelector:updateScriptsSel]) {
        FDMLog(@"userscript updater: updateUserScripts selector missing on manager");
        if (completion) completion(NO);
        return;
    }
    
    [NSUserDefaults.standardUserDefaults setObject:[NSDate date] forKey:FDMUserScriptLastAttemptDateKey];
    [NSUserDefaults.standardUserDefaults synchronize];
    _fdmUserScriptUpdating = YES;
    
    FDMLog(@"userscript updater: executing updateUserScripts on UserScriptUpdateManager");
    @try {
        ((void (*)(id, SEL))objc_msgSend)(updateMgr, updateScriptsSel);
        [self recordUpdateSuccessNow];
        _fdmUserScriptUpdating = NO;
        if (completion) completion(YES);
    } @catch (NSException *e) {
        _fdmUserScriptUpdating = NO;
        FDMLog(@"userscript updater: exception in updateUserScripts: %@", e);
        if (completion) completion(NO);
    }
}

#pragma mark - Custom Header View

@interface FDMUserScriptHeaderView : UIView
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UIView *iconView;
@property (nonatomic, strong) UIImageView *iconImg;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UISwitch *sw;
@end

@implementation FDMUserScriptHeaderView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.tag = FDMUserScriptHeaderTag;
        self.backgroundColor = [UIColor clearColor];
        
        _card = [[UIView alloc] initWithFrame:CGRectZero];
        _card.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
            if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
                return [UIColor colorWithRed:0.11 green:0.11 blue:0.12 alpha:1.0];
            }
            return [UIColor whiteColor];
        }];
        _card.layer.cornerRadius = 12.0;
        _card.layer.masksToBounds = YES;
        [self addSubview:_card];
        
        _iconView = [[UIView alloc] initWithFrame:CGRectZero];
        _iconView.layer.cornerRadius = 8.0;
        _iconView.layer.masksToBounds = YES;
        _iconView.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
            if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
                return [UIColor colorWithRed:0.18 green:0.30 blue:0.22 alpha:1.0];
            }
            return [UIColor colorWithRed:0.90 green:0.96 blue:0.92 alpha:1.0];
        }];
        [_card addSubview:_iconView];
        
        _iconImg = [[UIImageView alloc] initWithFrame:CGRectZero];
        _iconImg.contentMode = UIViewContentModeScaleAspectFit;
        _iconImg.tintColor = [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0];
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
            _iconImg.image = [UIImage systemImageNamed:@"arrow.triangle.2.circlepath" withConfiguration:cfg];
        }
        [_iconView addSubview:_iconImg];
        
        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.text = @"脚本每日自动更新";
        _titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        _titleLabel.textColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
            return (tc.userInterfaceStyle == UIUserInterfaceStyleDark) ? UIColor.whiteColor : UIColor.blackColor;
        }];
        [_card addSubview:_titleLabel];
        
        _detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _detailLabel.tag = FDMUserScriptDetailTag;
        _detailLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        _detailLabel.textColor = UIColor.secondaryLabelColor;
        _detailLabel.adjustsFontSizeToFitWidth = YES;
        _detailLabel.minimumScaleFactor = 0.85;
        [_card addSubview:_detailLabel];
        
        _sw = [[UISwitch alloc] init];
        _sw.tag = FDMUserScriptSwitchTag;
        _sw.onTintColor = [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0];
        [_card addSubview:_sw];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width;
    if (width <= 0) return;
    
    CGFloat cardMargin = 16.0;
    CGFloat cardWidth = width - 32.0;
    const CGFloat cardHeight = 76.0;
    
    // Look up lower cells to match horizontal alignment precisely
    UIView *cellSwitch = nil;
    UIView *cellLogo = nil;
    if ([self.superview isKindOfClass:UITableView.class]) {
        UITableView *tv = (UITableView *)self.superview;
        for (UITableViewCell *c in tv.visibleCells) {
            UIView *s = [c valueForKey:@"switchView"];
            if ([s isKindOfClass:UIView.class] && s.bounds.size.width > 0) {
                if (c.frame.size.width > 0) {
                    cardMargin = c.frame.origin.x;
                    cardWidth = c.frame.size.width;
                }
                cellSwitch = s;
                cellLogo = [c valueForKey:@"logo"];
                break;
            }
        }
    }
    
    self.card.frame = CGRectMake(cardMargin, 6.0, cardWidth, cardHeight);
    
    // Icon alignment
    CGFloat iconSize = 36.0;
    CGFloat iconX = 14.0;
    if (cellLogo && [cellLogo isKindOfClass:UIView.class]) {
        CGPoint logoInCard = [cellLogo.superview convertPoint:cellLogo.frame.origin toView:self.card];
        if (logoInCard.x > 0 && logoInCard.x < cardWidth / 2.0) {
            iconX = logoInCard.x;
            iconSize = cellLogo.frame.size.width > 0 ? cellLogo.frame.size.width : 36.0;
        }
    }
    self.iconView.frame = CGRectMake(iconX, (cardHeight - iconSize) / 2.0, iconSize, iconSize);
    self.iconImg.frame = CGRectMake((iconSize - 22.0) / 2.0, (iconSize - 22.0) / 2.0, 22.0, 22.0);
    
    // Switch alignment: perfectly align with cell switch!
    CGSize swSize = self.sw.bounds.size;
    if (swSize.width <= 0) swSize = CGSizeMake(51.0, 31.0);
    CGFloat swX = cardWidth - swSize.width - 12.0;
    if (cellSwitch) {
        CGPoint swInCard = [cellSwitch.superview convertPoint:cellSwitch.frame.origin toView:self.card];
        if (swInCard.x > iconX + iconSize + 20.0 && swInCard.x + swSize.width <= cardWidth + 5.0) {
            swX = swInCard.x;
        }
    }
    self.sw.frame = CGRectMake(swX, (cardHeight - swSize.height) / 2.0, swSize.width, swSize.height);
    
    // Middle text area
    CGFloat textX = iconX + iconSize + 12.0;
    CGFloat textRight = swX - 8.0;
    CGFloat textWidth = textRight - textX;
    if (textWidth < 100.0) textWidth = 100.0;
    
    self.titleLabel.frame = CGRectMake(textX, 16.0, textWidth, 20.0);
    self.detailLabel.frame = CGRectMake(textX, 40.0, textWidth, 18.0);
}

@end

#pragma mark - UI Integration

+ (void)updateHeaderView:(UIView *)headerView {
    if (!headerView) return;
    UILabel *detailLabel = (UILabel *)[headerView viewWithTag:FDMUserScriptDetailTag];
    UISwitch *sw = (UISwitch *)[headerView viewWithTag:FDMUserScriptSwitchTag];
    if (sw) {
        sw.on = [self isAutoUpdateEnabled];
    }
    if (detailLabel) {
        NSString *last = [self lastSuccessDateString];
        if (last) {
            detailLabel.text = [NSString stringWithFormat:@"每天首次启动自动检查（上次：%@）", last];
        } else {
            detailLabel.text = @"每天首次进入浏览器时自动检查更新";
        }
    }
}

+ (void)ensureHeaderInController:(UIViewController *)controller {
    @try {
        UITableView *tableView = FDMValue(controller, @"tableView");
        if (![tableView isKindOfClass:UITableView.class]) return;
        
        UIView *header = tableView.tableHeaderView;
        if ([header isKindOfClass:[FDMUserScriptHeaderView class]]) {
            [self updateHeaderView:header];
            [header setNeedsLayout];
            return;
        }
        
        CGFloat width = tableView.bounds.size.width;
        if (width <= 0) width = UIScreen.mainScreen.bounds.size.width;
        
        FDMUserScriptHeaderView *headerView = [[FDMUserScriptHeaderView alloc] initWithFrame:CGRectMake(0, 0, width, 88.0)];
        headerView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [headerView.sw addTarget:self action:@selector(handleSwitchToggled:) forControlEvents:UIControlEventValueChanged];
        [self updateHeaderView:headerView];
        
        tableView.tableHeaderView = headerView;
    } @catch (NSException *e) {
        FDMLog(@"userscript updater: exception ensuring header: %@", e);
    }
}

+ (void)handleSwitchToggled:(UISwitch *)sw {
    [self setAutoUpdateEnabled:sw.isOn];
}

#pragma mark - Hooking

static void fdm_UserScriptController_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (orig_UserScriptController_viewWillAppear) {
        orig_UserScriptController_viewWillAppear(self, _cmd, animated);
    }
    [FDMUserScriptUpdater ensureHeaderInController:self];
}

static void fdm_UserScriptController_reloadData(id self, SEL _cmd) {
    if (orig_UserScriptController_reloadData) {
        orig_UserScriptController_reloadData(self, _cmd);
    }
    @try {
        UITableView *tv = FDMValue(self, @"tableView");
        if ([tv.tableHeaderView isKindOfClass:[FDMUserScriptHeaderView class]]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [tv.tableHeaderView setNeedsLayout];
                [tv.tableHeaderView layoutIfNeeded];
            });
        }
    } @catch (NSException *e) {
    }
}

static void fdm_UserScriptController_updateAllUserscripts(id self, SEL _cmd) {
    if (orig_UserScriptController_updateAllUserscripts) {
        orig_UserScriptController_updateAllUserscripts(self, _cmd);
    }
    [FDMUserScriptUpdater recordUpdateSuccessNow];
}

+ (void)installHooks {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class ctrlClass = NSClassFromString(@"UserScriptController");
        if (ctrlClass) {
            // Swizzle viewWillAppear:
            SEL appearSel = @selector(viewWillAppear:);
            Method appearMethod = class_getInstanceMethod(ctrlClass, appearSel);
            if (appearMethod) {
                orig_UserScriptController_viewWillAppear = (void (*)(id, SEL, BOOL))method_getImplementation(appearMethod);
                method_setImplementation(appearMethod, (IMP)fdm_UserScriptController_viewWillAppear);
                FDMLog(@"userscript updater: hooked UserScriptController viewWillAppear:");
            }
            
            // Swizzle reloadData
            SEL reloadSel = NSSelectorFromString(@"reloadData");
            Method reloadMethod = class_getInstanceMethod(ctrlClass, reloadSel);
            if (reloadMethod) {
                orig_UserScriptController_reloadData = (void (*)(id, SEL))method_getImplementation(reloadMethod);
                method_setImplementation(reloadMethod, (IMP)fdm_UserScriptController_reloadData);
                FDMLog(@"userscript updater: hooked UserScriptController reloadData");
            }
            
            // Swizzle _updateAllUserscripts
            SEL updateAllSel = NSSelectorFromString(@"_updateAllUserscripts");
            Method updateAllMethod = class_getInstanceMethod(ctrlClass, updateAllSel);
            if (updateAllMethod) {
                orig_UserScriptController_updateAllUserscripts = (void (*)(id, SEL))method_getImplementation(updateAllMethod);
                method_setImplementation(updateAllMethod, (IMP)fdm_UserScriptController_updateAllUserscripts);
                FDMLog(@"userscript updater: hooked UserScriptController _updateAllUserscripts");
            }
        }
    });
}

@end
