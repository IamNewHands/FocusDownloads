#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSNotificationName const FDMIconCacheDidChangeNotification;
FOUNDATION_EXPORT void FDMInstallIconHooks(void);
FOUNDATION_EXPORT void FDMFlushIconWrites(void);
FOUNDATION_EXPORT NSArray<NSDictionary *> *FDMIconDiagnosticEntries(void);
FOUNDATION_EXPORT void FDMRefreshIcon(NSString *entryKey);
FOUNDATION_EXPORT UIViewController *FDMCreateIconDiagnosticsViewController(void);
#ifdef FDM_TESTING
FOUNDATION_EXPORT void FDMReloadIconStoreForTesting(void);
FOUNDATION_EXPORT NSString *FDMIconEntryKeyForTesting(id owner);
FOUNDATION_EXPORT void FDMReplayStaleIconWriteForTesting(id owner);
#endif
NS_ASSUME_NONNULL_END
