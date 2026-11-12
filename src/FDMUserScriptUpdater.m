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
        if (header && header.tag == FDMUserScriptHeaderTag) {
            [self updateHeaderView:header];
            return;
        }
        
        CGFloat width = tableView.bounds.size.width;
        if (width <= 0) width = UIScreen.mainScreen.bounds.size.width;
        
        const CGFloat cardHeight = 76.0;
        const CGFloat containerHeight = 88.0;
        
        UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, containerHeight)];
        container.tag = FDMUserScriptHeaderTag;
        container.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        container.backgroundColor = [UIColor clearColor];
        
        UIView *card = [[UIView alloc] initWithFrame:CGRectMake(16, 6, width - 32, cardHeight)];
        card.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        card.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
            if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
                return [UIColor colorWithRed:0.11 green:0.11 blue:0.12 alpha:1.0]; // #1C1C1E
            }
            return [UIColor whiteColor];
        }];
        card.layer.cornerRadius = 12;
        card.layer.masksToBounds = YES;
        
        // 1. Left Icon: 36x36 rounded square with sync/update symbol matching lower cards
        UIView *iconView = [[UIView alloc] initWithFrame:CGRectMake(14, (cardHeight - 36) / 2.0, 36, 36)];
        iconView.layer.cornerRadius = 8;
        iconView.layer.masksToBounds = YES;
        iconView.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
            if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
                return [UIColor colorWithRed:0.18 green:0.30 blue:0.22 alpha:1.0];
            }
            return [UIColor colorWithRed:0.90 green:0.96 blue:0.92 alpha:1.0];
        }];
        
        UIImageView *iconImg = [[UIImageView alloc] initWithFrame:CGRectMake(7, 7, 22, 22)];
        iconImg.contentMode = UIViewContentModeScaleAspectFit;
        iconImg.tintColor = [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0]; // System green
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
            iconImg.image = [UIImage systemImageNamed:@"arrow.triangle.2.circlepath" withConfiguration:cfg];
        }
        [iconView addSubview:iconImg];
        [card addSubview:iconView];
        
        // 2. Switch on Right with matching green onTintColor
        UISwitch *sw = [[UISwitch alloc] init];
        sw.tag = FDMUserScriptSwitchTag;
        sw.on = [self isAutoUpdateEnabled];
        sw.onTintColor = [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0];
        CGFloat swWidth = sw.bounds.size.width;
        CGFloat swHeight = sw.bounds.size.height;
        CGFloat swX = (width - 32) - swWidth - 14;
        CGFloat swY = (cardHeight - swHeight) / 2.0;
        sw.frame = CGRectMake(swX, swY, swWidth, swHeight);
        sw.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
        [sw addTarget:self action:@selector(handleSwitchToggled:) forControlEvents:UIControlEventValueChanged];
        [card addSubview:sw];
        
        // 3. Middle Text Content: strictly bounded between icon and switch (never overlaps!)
        CGFloat textLeft = 14 + 36 + 12; // 62
        CGFloat textRightReserve = 14 + swWidth + 12; // Reserves space for switch + padding
        CGFloat textWidth = (width - 32) - textLeft - textRightReserve;
        if (textWidth < 120) textWidth = 120;
        
        UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(textLeft, 16, textWidth, 20)];
        titleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        titleLabel.text = @"脚本每日自动更新";
        titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        titleLabel.textColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
            return (tc.userInterfaceStyle == UIUserInterfaceStyleDark) ? UIColor.whiteColor : UIColor.blackColor;
        }];
        [card addSubview:titleLabel];
        
        UILabel *detailLabel = [[UILabel alloc] initWithFrame:CGRectMake(textLeft, 40, textWidth, 18)];
        detailLabel.tag = FDMUserScriptDetailTag;
        detailLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        detailLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        detailLabel.textColor = UIColor.secondaryLabelColor;
        detailLabel.adjustsFontSizeToFitWidth = YES;
        detailLabel.minimumScaleFactor = 0.85;
        NSString *last = [self lastSuccessDateString];
        detailLabel.text = last ? [NSString stringWithFormat:@"每天首次启动自动检查（上次：%@）", last] : @"每天首次进入浏览器时自动检查更新";
        [card addSubview:detailLabel];
        
        [container addSubview:card];
        tableView.tableHeaderView = container;
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
