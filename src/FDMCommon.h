#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, FDMState) {
    FDMStateDownloading = 0,
    FDMStatePaused = 1,
    FDMStateCompleted = 2,
    FDMStateFailed = 3,
    FDMStateInterrupted = 4,
};

// Which network owner executes one download. The value is persisted so a restored task never
// silently changes transport: a WebKit-only intent can never be retried as an anonymous GET.
typedef NS_ENUM(NSInteger, FDMTransportKind) {
    FDMTransportAnonymousBackground = 0,
    FDMTransportCredentialedSession = 1,
    FDMTransportWebKitDownload = 2,
};

// Scheduler state for replayable GETs only. A WKDownload that already started keeps its own
// lifecycle and is counted separately from this queue.
typedef NS_ENUM(NSInteger, FDMSchedulerStatus) {
    FDMSchedulerWaiting = 0,
    FDMSchedulerRunning = 1,
    FDMSchedulerUserPaused = 2,
    FDMSchedulerNeedsContext = 3,
};

FOUNDATION_EXPORT NSUInteger const FDMQueueLimit;
FOUNDATION_EXPORT NSUInteger const FDMBatchPreviewLimit;
FOUNDATION_EXPORT NSString *FDMTransportName(FDMTransportKind kind);
FOUNDATION_EXPORT NSString *FDMSchedulerStatusName(FDMSchedulerStatus status);

FOUNDATION_EXPORT NSString *const FDMRecordsDidChangeNotification;
FOUNDATION_EXPORT NSString *const FDMBackgroundSessionIdentifier;
FOUNDATION_EXPORT NSString *FDMPatchVersion(void);
FOUNDATION_EXPORT NSString *FDMBuildRevision(void);
FOUNDATION_EXPORT void FDMLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
FOUNDATION_EXPORT void FDMInstallCrashHandlers(void);
FOUNDATION_EXPORT void FDMNotifyRecordsChanged(void);
FOUNDATION_EXPORT id _Nullable FDMSharedFileManager(void);
FOUNDATION_EXPORT id _Nullable FDMValue(id _Nullable object, NSString *key);
FOUNDATION_EXPORT NSString * _Nullable FDMString(id _Nullable object);
FOUNDATION_EXPORT NSString *FDMHumanSize(double bytes);
FOUNDATION_EXPORT NSString * _Nullable FDMHumanETA(double seconds);
FOUNDATION_EXPORT double FDMDouble(id _Nullable object, NSString *key);
FOUNDATION_EXPORT double FDMProgressOfTask(id _Nullable task);
FOUNDATION_EXPORT NSString *FDMDocumentsPath(void);
FOUNDATION_EXPORT NSString *FDMDirectory(NSString *relative);
FOUNDATION_EXPORT NSString *FDMLegacyHash(NSString *text);
FOUNDATION_EXPORT NSURL * _Nullable FDMValidatedURL(NSString *text, NSError **error);
FOUNDATION_EXPORT NSString *FDMRedactedURL(NSString * _Nullable text);
FOUNDATION_EXPORT NSString *FDMSafeFilename(NSString * _Nullable name);
FOUNDATION_EXPORT NSError *FDMError(NSString *message);
FOUNDATION_EXPORT NSDictionary * _Nullable FDMFileIdentity(NSString *path);
FOUNDATION_EXPORT NSString * _Nullable FDMRelativeDocumentPath(NSString *path);
FOUNDATION_EXPORT NSString * _Nullable FDMResolveDocumentPath(NSDictionary *record);
FOUNDATION_EXPORT BOOL FDMRemoveOwnedFile(NSDictionary *record, NSError **error);
FOUNDATION_EXPORT BOOL FDMWriteJSON(id object, NSString *path, NSError **error);
FOUNDATION_EXPORT id _Nullable FDMReadJSON(NSString *path, NSError **error);
FOUNDATION_EXPORT NSDictionary *FDMImmutableRecord(NSDictionary *record);
FOUNDATION_EXPORT BOOL FDMLegacyAliasMatches(NSDictionary *canonical, NSDictionary * _Nullable legacyRecord);
FOUNDATION_EXPORT BOOL FDMValidStoredRecord(id value);

// Secret-bearing header names are never logged and never persisted.
FOUNDATION_EXPORT BOOL FDMIsSecretHeader(NSString *name);
FOUNDATION_EXPORT NSString *FDMRedactedHeaderNames(NSDictionary<NSString *, NSString *> *headers);

NS_ASSUME_NONNULL_END
