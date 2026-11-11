#import "FDMAdBlockUpdater.h"
#import "FDMCommon.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

NSString *const FDMAdBlockAutoUpdateEnabledKey = @"FDMAdBlockAutoUpdateEnabled";
NSString *const FDMAdBlockLastSuccessDateKey = @"FDMAdBlockLastSuccessDate";
NSString *const FDMAdBlockLastAttemptDateKey = @"FDMAdBlockLastAttemptDate";
NSString *const FDMAdBlockDidUpdateNotification = @"FDMAdBlockDidUpdateNotification";

static const NSInteger FDMAdBlockSwitchTag = 0x46444D41; // 'FDMA'
static const NSTimeInterval FDMAdBlockFailureBackoffInterval = 900.0; // 15 minutes

static BOOL _fdmAdBlockUpdating = NO;
static IMP FDMOriginalAdBlockHomeUpdateWithModel;
static IMP FDMOriginalAdBlockHomeApplyTheme;
static IMP FDMOriginalAdBlockViewUpdateItems;
static IMP FDMOriginalAdBlockViewControllerViewDidLoad;

static BOOL FDMAdBlockInstallHook(Class cls, SEL selector, IMP replacement, IMP *original) {
    if (!cls || !selector) return NO;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        FDMLog(@"adblock hook missing %@ %@", NSStringFromClass(cls), NSStringFromSelector(selector));
        return NO;
    }
    IMP previous = method_getImplementation(method);
    if (previous == replacement) return YES;
    if (original) *original = previous;
    if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) {
        method_setImplementation(method, replacement);
    }
    return YES;
}

@implementation FDMAdBlockUpdater

+ (BOOL)isAutoUpdateEnabled {
    id val = [NSUserDefaults.standardUserDefaults objectForKey:FDMAdBlockAutoUpdateEnabledKey];
    if (val == nil) return YES; // Default enabled
    return [val boolValue];
}

+ (void)setAutoUpdateEnabled:(BOOL)enabled {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:FDMAdBlockAutoUpdateEnabledKey];
    [NSUserDefaults.standardUserDefaults synchronize];
}

+ (BOOL)isUpdating {
    return _fdmAdBlockUpdating;
}

+ (NSDate *)lastSuccessDate {
    id date = [NSUserDefaults.standardUserDefaults objectForKey:FDMAdBlockLastSuccessDateKey];
    return [date isKindOfClass:NSDate.class] ? (NSDate *)date : nil;
}

+ (NSString *)lastSuccessDateString {
    NSDate *date = [self lastSuccessDate];
    if (!date) return nil;
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = NSLocale.currentLocale;
    if ([calendar isDateInToday:date]) {
        fmt.dateFormat = @"HH:mm";
        return [NSString stringWithFormat:@"今天 %@", [fmt stringFromDate:date]];
    } else if ([calendar isDateInYesterday:date]) {
        fmt.dateFormat = @"HH:mm";
        return [NSString stringWithFormat:@"昨天 %@", [fmt stringFromDate:date]];
    } else {
        fmt.dateFormat = @"yyyy-MM-dd HH:mm";
        return [fmt stringFromDate:date];
    }
}

+ (void)recordUpdateSuccessNow {
    [NSUserDefaults.standardUserDefaults setObject:[NSDate date] forKey:FDMAdBlockLastSuccessDateKey];
    [NSUserDefaults.standardUserDefaults synchronize];
}

+ (BOOL)shouldPerformDailyUpdate {
    if (![self isAutoUpdateEnabled]) {
        return NO;
    }
    if (_fdmAdBlockUpdating) {
        return NO;
    }
    NSDate *lastSuccess = [self lastSuccessDate];
    if (lastSuccess && [NSCalendar.currentCalendar isDateInToday:lastSuccess]) {
        return NO;
    }
    NSDate *lastAttempt = [NSUserDefaults.standardUserDefaults objectForKey:FDMAdBlockLastAttemptDateKey];
    if ([lastAttempt isKindOfClass:NSDate.class]) {
        if ([[NSDate date] timeIntervalSinceDate:lastAttempt] < FDMAdBlockFailureBackoffInterval) {
            return NO;
        }
    }
    return YES;
}

+ (void)checkAndTriggerDailyUpdateIfNeeded {
    if (![self shouldPerformDailyUpdate]) {
        return;
    }
    [self performUpdateWithCompletion:nil];
}

+ (void)performUpdateWithCompletion:(void (^)(BOOL success, NSUInteger updatedCount))completion {
    if (_fdmAdBlockUpdating) {
        if (completion) completion(NO, 0);
        return;
    }
    
    // Check if ad blocking is turned off completely in Focus preference
    Class pmClass = NSClassFromString(@"PreferenceManager");
    if (pmClass && [pmClass respondsToSelector:NSSelectorFromString(@"shareInstance")]) {
        id pm = [pmClass performSelector:NSSelectorFromString(@"shareInstance")];
        if ([pm respondsToSelector:NSSelectorFromString(@"items")]) {
            id items = [pm performSelector:NSSelectorFromString(@"items")];
            if ([items respondsToSelector:NSSelectorFromString(@"enabledAdblock")]) {
                id enabledVal = [items performSelector:NSSelectorFromString(@"enabledAdblock")];
                if ([enabledVal respondsToSelector:@selector(boolValue)] && ![enabledVal boolValue]) {
                    FDMLog(@"adblock updater: ad blocking disabled in preferences, skipping auto update");
                    if (completion) completion(NO, 0);
                    return;
                }
            }
        }
    }
    
    Class dbUnitClass = NSClassFromString(@"DatabaseUnit");
    Class dbUtilClass = NSClassFromString(@"DatabaseUtil");
    Class adBlockMgrClass = NSClassFromString(@"AdBlockManager");
    Class adBlockModelClass = NSClassFromString(@"AdBlockModel");
    
    if (!dbUnitClass || !dbUtilClass || !adBlockMgrClass) {
        FDMLog(@"adblock updater: host adblock classes missing");
        if (completion) completion(NO, 0);
        return;
    }
    
    SEL querySel = NSSelectorFromString(@"queryAllAdblocks");
    if (![dbUnitClass respondsToSelector:querySel]) {
        FDMLog(@"adblock updater: queryAllAdblocks selector missing");
        if (completion) completion(NO, 0);
        return;
    }
    
    [NSUserDefaults.standardUserDefaults setObject:[NSDate date] forKey:FDMAdBlockLastAttemptDateKey];
    [NSUserDefaults.standardUserDefaults synchronize];
    _fdmAdBlockUpdating = YES;
    
    id queryUnit = ((id (*)(id, SEL))objc_msgSend)(dbUnitClass, querySel);
    SEL setCompleteSel = NSSelectorFromString(@"setCompleteBlock:");
    if (![queryUnit respondsToSelector:setCompleteSel]) {
        _fdmAdBlockUpdating = NO;
        if (completion) completion(NO, 0);
        return;
    }
    
    void (^queryComplete)(id, BOOL) = ^(id result, BOOL success) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!success || ![result isKindOfClass:NSArray.class]) {
                _fdmAdBlockUpdating = NO;
                FDMLog(@"adblock updater: rule query failed or non-array result");
                if (completion) completion(NO, 0);
                return;
            }
            
            NSArray *models = (NSArray *)result;
            NSMutableArray<NSString *> *urls = [NSMutableArray array];
            NSMutableArray *activeModels = [NSMutableArray array];
            
            // Built-in EasyList China URL
            if (adBlockModelClass && [adBlockModelClass respondsToSelector:NSSelectorFromString(@"easylistChinaUrl")]) {
                NSString *china = [adBlockModelClass performSelector:NSSelectorFromString(@"easylistChinaUrl")];
                if (china.length > 0) [urls addObject:china];
            }
            
            for (id model in models) {
                BOOL isActive = NO;
                @try { isActive = [[model valueForKey:@"isActive"] boolValue]; }
                @catch (NSException *e) {}
                if (isActive) {
                    NSString *u = FDMString([model valueForKey:@"url"]);
                    if (u.length > 0) {
                        if (![urls containsObject:u]) [urls addObject:u];
                        [activeModels addObject:model];
                    }
                }
            }
            
            if (urls.count == 0) {
                _fdmAdBlockUpdating = NO;
                [self recordUpdateSuccessNow];
                if (completion) completion(YES, 0);
                return;
            }
            
            id mgr = [adBlockMgrClass performSelector:NSSelectorFromString(@"shareInstance")];
            for (NSString *u in urls) {
                @try {
                    ((void (*)(id, SEL, id))objc_msgSend)(mgr, NSSelectorFromString(@"removeRulesForUrl:"), u);
                } @catch (NSException *e) {
                    FDMLog(@"adblock updater: removeRulesForUrl failed: %@", e);
                }
            }
            
            dispatch_group_t group = dispatch_group_create();
            __block NSInteger successCount = 0;
            
            for (NSString *u in urls) {
                dispatch_group_enter(group);
                void (^ruleComp)(BOOL) = ^(BOOL ok) {
                    if (ok) {
                        @synchronized(urls) { successCount++; }
                    }
                    dispatch_group_leave(group);
                };
                @try {
                    ((void (*)(id, SEL, id, id))objc_msgSend)(mgr, NSSelectorFromString(@"addRulesFromUrl:completion:"), u, ruleComp);
                } @catch (NSException *e) {
                    FDMLog(@"adblock updater: addRulesFromUrl exception: %@", e);
                    dispatch_group_leave(group);
                }
            }
            
            // Update database updateTime for active models
            SEL updateUnitSel = NSSelectorFromString(@"updateAdblockWithId:");
            SEL execUnitSel = NSSelectorFromString(@"executeUnit:");
            id dbUtil = [dbUtilClass performSelector:NSSelectorFromString(@"shareInstance")];
            for (id model in activeModels) {
                NSString *uuid = FDMString([model valueForKey:@"uuid"]);
                if (uuid.length > 0 && [dbUnitClass respondsToSelector:updateUnitSel]) {
                    @try {
                        id updateUnit = ((id (*)(id, SEL, id))objc_msgSend)(dbUnitClass, updateUnitSel, uuid);
                        if (updateUnit && [dbUtil respondsToSelector:execUnitSel]) {
                            ((void (*)(id, SEL, id))objc_msgSend)(dbUtil, execUnitSel, updateUnit);
                        }
                    } @catch (NSException *e) {
                        FDMLog(@"adblock updater: updateAdblockWithId exception: %@", e);
                    }
                }
            }
            
            dispatch_group_notify(group, dispatch_get_main_queue(), ^{
                _fdmAdBlockUpdating = NO;
                BOOL anyOk = (successCount > 0);
                if (anyOk) {
                    [self recordUpdateSuccessNow];
                    FDMLog(@"adblock updater: auto-updated %ld/%lu rule(s) successfully", (long)successCount, (unsigned long)urls.count);
                    [NSNotificationCenter.defaultCenter postNotificationName:@"kReloadAllWebViewNotification" object:nil];
                    [NSNotificationCenter.defaultCenter postNotificationName:FDMAdBlockDidUpdateNotification object:nil];
                } else {
                    FDMLog(@"adblock updater: all rules failed to update");
                }
                if (completion) completion(anyOk, (NSUInteger)successCount);
            });
        });
    };
    
    ((void (*)(id, SEL, id))objc_msgSend)(queryUnit, setCompleteSel, queryComplete);
    
    id dbUtil = [dbUtilClass performSelector:NSSelectorFromString(@"shareInstance")];
    SEL execSel = NSSelectorFromString(@"executeUnit:");
    if ([dbUtil respondsToSelector:execSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(dbUtil, execSel, queryUnit);
    } else {
        _fdmAdBlockUpdating = NO;
        if (completion) completion(NO, 0);
    }
}

+ (void)updateSwitchView:(UIView *)view {
    if (!view) return;
    NSString *detail = [self lastSuccessDateString];
    NSString *detailText = detail ? [NSString stringWithFormat:@"每天首次进入浏览器时自动更新（上次更新：%@）", detail] : @"每天首次进入浏览器时自动更新";
    SEL updateSel = NSSelectorFromString(@"updateWithTitle:detail:isOn:");
    if ([view respondsToSelector:updateSel]) {
        ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(view, updateSel, @"自动更新规则", detailText, [self isAutoUpdateEnabled]);
    }
}

+ (void)ensureAutoUpdateSwitchInController:(UIViewController *)controller {
    @try {
        UIStackView *stackView = FDMValue(controller, @"stackView");
        if (![stackView isKindOfClass:UIStackView.class]) return;
        
        UIView *existing = [stackView viewWithTag:FDMAdBlockSwitchTag];
        if (existing) {
            [self updateSwitchView:existing];
            return;
        }
        
        Class switchClass = NSClassFromString(@"SettingSwitchAndTextView");
        if (!switchClass) return;
        
        id row = nil;
        SEL initSel = NSSelectorFromString(@"initWithShowLine:needCheckVip:");
        if ([switchClass instancesRespondToSelector:initSel]) {
            row = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)([switchClass alloc], initSel, YES, NO);
        } else {
            row = [[switchClass alloc] init];
        }
        if (![row isKindOfClass:UIView.class]) return;
        
        UIView *switchRow = (UIView *)row;
        switchRow.tag = FDMAdBlockSwitchTag;
        
        [self updateSwitchView:switchRow];
        
        SEL actionSel = NSSelectorFromString(@"setDidSwithAction:");
        if ([switchRow respondsToSelector:actionSel]) {
            __weak UIView *weakRow = switchRow;
            void (^actionBlock)(BOOL) = ^(BOOL isOn) {
                [FDMAdBlockUpdater setAutoUpdateEnabled:isOn];
                [FDMAdBlockUpdater updateSwitchView:weakRow];
                if (isOn) {
                    [FDMAdBlockUpdater checkAndTriggerDailyUpdateIfNeeded];
                }
            };
            ((void (*)(id, SEL, id))objc_msgSend)(switchRow, actionSel, actionBlock);
        }
        
        UIView *fixupView = FDMValue(controller, @"enabledFixupAdblockView");
        NSUInteger targetIndex = 2;
        if ([fixupView isKindOfClass:UIView.class] && [stackView.arrangedSubviews containsObject:fixupView]) {
            targetIndex = [stackView.arrangedSubviews indexOfObject:fixupView] + 1;
        }
        if (targetIndex <= stackView.arrangedSubviews.count) {
            [stackView insertArrangedSubview:switchRow atIndex:targetIndex];
        } else {
            [stackView addArrangedSubview:switchRow];
        }
    } @catch (NSException *e) {
        FDMLog(@"adblock updater: ensure switch exception: %@", e);
    }
}

#pragma mark - Hook callbacks

static void FDMAdBlockHomeUpdateWithModel(id self, SEL selector) {
    if (FDMOriginalAdBlockHomeUpdateWithModel) {
        ((void (*)(id, SEL))FDMOriginalAdBlockHomeUpdateWithModel)(self, selector);
    }
    [FDMAdBlockUpdater ensureAutoUpdateSwitchInController:self];
}

static void FDMAdBlockHomeApplyTheme(id self, SEL selector) {
    if (FDMOriginalAdBlockHomeApplyTheme) {
        ((void (*)(id, SEL))FDMOriginalAdBlockHomeApplyTheme)(self, selector);
    }
    @try {
        UIStackView *stack = FDMValue(self, @"stackView");
        UIView *row = [stack viewWithTag:FDMAdBlockSwitchTag];
        if (row && [row respondsToSelector:NSSelectorFromString(@"applyTheme")]) {
            ((void (*)(id, SEL))objc_msgSend)(row, NSSelectorFromString(@"applyTheme"));
        }
    } @catch (NSException *e) {}
}

static void FDMAdBlockViewUpdateItems(id self, SEL selector, id array) {
    if (FDMOriginalAdBlockViewUpdateItems) {
        ((void (*)(id, SEL, id))FDMOriginalAdBlockViewUpdateItems)(self, selector, array);
    }
    [FDMAdBlockUpdater recordUpdateSuccessNow];
}

static void FDMAdBlockViewControllerViewDidLoad(id self, SEL selector) {
    if (FDMOriginalAdBlockViewControllerViewDidLoad) {
        ((void (*)(id, SEL))FDMOriginalAdBlockViewControllerViewDidLoad)(self, selector);
    }
    __weak id weakSelf = self;
    [NSNotificationCenter.defaultCenter addObserverForName:FDMAdBlockDidUpdateNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification * _Nonnull note) {
        id blockView = FDMValue(weakSelf, @"adBlockView");
        if ([blockView respondsToSelector:NSSelectorFromString(@"reloadData")]) {
            ((void (*)(id, SEL))objc_msgSend)(blockView, NSSelectorFromString(@"reloadData"));
        }
    }];
}

+ (void)installHooks {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class homeClass = NSClassFromString(@"AdBlockHomeController");
        if (homeClass) {
            FDMAdBlockInstallHook(homeClass, NSSelectorFromString(@"updateWithModel"), (IMP)FDMAdBlockHomeUpdateWithModel, &FDMOriginalAdBlockHomeUpdateWithModel);
            FDMAdBlockInstallHook(homeClass, NSSelectorFromString(@"applyTheme"), (IMP)FDMAdBlockHomeApplyTheme, &FDMOriginalAdBlockHomeApplyTheme);
        }
        
        Class vcClass = NSClassFromString(@"AdBlockViewController");
        if (vcClass) {
            FDMAdBlockInstallHook(vcClass, NSSelectorFromString(@"_updateItemsWithArray:"), (IMP)FDMAdBlockViewUpdateItems, &FDMOriginalAdBlockViewUpdateItems);
            FDMAdBlockInstallHook(vcClass, @selector(viewDidLoad), (IMP)FDMAdBlockViewControllerViewDidLoad, &FDMOriginalAdBlockViewControllerViewDidLoad);
        }
        
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification * _Nonnull note) {
            [FDMAdBlockUpdater checkAndTriggerDailyUpdateIfNeeded];
        }];
    });
}

@end
