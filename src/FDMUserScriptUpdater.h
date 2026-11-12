#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FDMUserScriptAutoUpdateEnabledKey;
FOUNDATION_EXPORT NSString *const FDMUserScriptLastSuccessDateKey;
FOUNDATION_EXPORT NSString *const FDMUserScriptLastAttemptDateKey;
FOUNDATION_EXPORT NSString *const FDMUserScriptDidUpdateNotification;

@interface FDMUserScriptUpdater : NSObject

/// Whether daily auto-update of user scripts is enabled (defaults to YES)
+ (BOOL)isAutoUpdateEnabled;
+ (void)setAutoUpdateEnabled:(BOOL)enabled;

/// Whether an update operation is currently in progress
+ (BOOL)isUpdating;

/// Timestamp of the last successful scripts update
+ (NSDate * _Nullable)lastSuccessDate;

/// Formatted string for last update timestamp (e.g. @"今天 10:30" or @"2026-11-12 10:30")
+ (NSString * _Nullable)lastSuccessDateString;

/// Evaluates if the daily auto-update should run right now:
/// - Must be enabled
/// - Not already running
/// - Not already successfully completed today (per device local calendar)
/// - Not attempted in the last 15 minutes (failure throttle)
+ (BOOL)shouldPerformDailyUpdate;

/// Evaluates conditions and triggers update in background if eligible
+ (void)checkAndTriggerDailyUpdateIfNeeded;

/// Performs the update immediately by invoking [UserScriptUpdateManager.shareInstance updateUserScripts]
+ (void)performUpdateWithCompletion:(void (^ _Nullable)(BOOL success))completion;

/// Marks the current moment as a successful update (called also when user triggers manual update)
+ (void)recordUpdateSuccessNow;

/// Installs UI & lifecycle hooks for UserScriptController
+ (void)installHooks;

@end

NS_ASSUME_NONNULL_END
