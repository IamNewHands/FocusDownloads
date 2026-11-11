#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FDMAdBlockAutoUpdateEnabledKey;
FOUNDATION_EXPORT NSString *const FDMAdBlockLastSuccessDateKey;
FOUNDATION_EXPORT NSString *const FDMAdBlockLastAttemptDateKey;
FOUNDATION_EXPORT NSString *const FDMAdBlockDidUpdateNotification;

@interface FDMAdBlockUpdater : NSObject

/// Whether daily auto-update of ad blocking rules is enabled (defaults to YES)
+ (BOOL)isAutoUpdateEnabled;
+ (void)setAutoUpdateEnabled:(BOOL)enabled;

/// Whether an update network operation is currently in progress
+ (BOOL)isUpdating;

/// Timestamp of the last successful rules update
+ (NSDate * _Nullable)lastSuccessDate;

/// Formatted string for last update timestamp (e.g. @"今天 10:30" or @"2026-11-11 10:30")
+ (NSString * _Nullable)lastSuccessDateString;

/// Evaluates if the daily auto-update should run right now:
/// - Must be enabled
/// - Not already running
/// - Not already successfully completed today (per device local calendar)
/// - Not attempted in the last 15 minutes (failure throttle)
+ (BOOL)shouldPerformDailyUpdate;

/// Evaluates conditions and triggers update in background if eligible
+ (void)checkAndTriggerDailyUpdateIfNeeded;

/// Performs the update immediately: queries active rules from database,
/// downloads latest rules from their URLs via AdBlockManager, updates database updateTime,
/// records today's success date, and posts kReloadAllWebViewNotification.
+ (void)performUpdateWithCompletion:(void (^ _Nullable)(BOOL success, NSUInteger updatedCount))completion;

/// Marks the current moment as a successful update (called also when user triggers manual update)
+ (void)recordUpdateSuccessNow;

/// Installs UI & lifecycle hooks for AdBlock settings and controllers
+ (void)installHooks;

@end

NS_ASSUME_NONNULL_END
