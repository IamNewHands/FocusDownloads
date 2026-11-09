#import "FDMCommon.h"

NS_ASSUME_NONNULL_BEGIN

@interface FDMEngine : NSObject <NSURLSessionDownloadDelegate>
+ (instancetype)shared;
@property (nonatomic, readonly) BOOL restoring;
// 1...6, default 3. Only replayable GETs are throttled.
@property (nonatomic) NSUInteger concurrencyLimit;
- (NSArray<NSDictionary *> *)items;
- (BOOL)canResumeKey:(NSString *)key;
- (BOOL)isRemovedKey:(NSString *)key;
#ifdef FDM_TESTING
- (instancetype)initForTestingWithSessionFactory:(NSURLSession * (^)(id<NSURLSessionDelegate>, NSOperationQueue *))factory;
- (void)drainForTesting;
#endif
- (nullable NSString *)startURL:(NSString *)url name:(nullable NSString *)name error:(NSError **)error;
// Queues a replayable GET; the scheduler starts it when a slot frees up.
- (nullable NSString *)enqueueURL:(NSString *)url name:(nullable NSString *)name error:(NSError **)error;
// Takes an immutable intent, keeps its own request context, and starts the typed transport.
- (nullable NSString *)startIntent:(id)intent request:(NSURLRequest *)request error:(NSError **)error;

// WebKit downloads. The engine owns their rows; FDMWebKitDownloads only translates callbacks.
// Returns the row key, or nil when the intent cannot be adopted (deleted, restoring, completed).
- (nullable NSString *)registerWebKitDownload:(id)download intent:(nullable id)intent tabID:(nullable NSString *)tabID;
// A unique destination inside the task directory; never an existing file.
- (nullable NSString *)destinationForWebKitDownloadKey:(NSString *)key
                                    suggestedFilename:(nullable NSString *)filename
                                             response:(nullable NSURLResponse *)response;
- (void)webKitDownloadDidFinishKey:(NSString *)key;
- (void)webKitDownloadKey:(NSString *)key failedWithMessage:(NSString *)message deleted:(BOOL)deleted;
- (void)applyWebKitProgressKey:(NSString *)key received:(long long)received total:(long long)total;

- (void)pauseKey:(NSString *)key;
- (void)resumeKey:(NSString *)key;
- (void)restartKey:(NSString *)key;
- (void)removeKey:(NSString *)key deleteFile:(BOOL)deleteFile completion:(void (^)(NSError * _Nullable error))completion;
- (void)setBackgroundCompletion:(void (^)(void))completion;
@end
NS_ASSUME_NONNULL_END
