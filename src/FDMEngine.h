#import "FDMCommon.h"
@class FDMDownloadIntent;
NS_ASSUME_NONNULL_BEGIN
@interface FDMEngine : NSObject <NSURLSessionDownloadDelegate>
+ (instancetype)shared;
@property (nonatomic, readonly) BOOL restoring;
@property (nonatomic) NSUInteger concurrencyLimit;
- (NSArray<NSDictionary *> *)items;
- (BOOL)canResumeKey:(NSString *)key;
- (BOOL)isRemovedKey:(NSString *)key;
#ifdef FDM_TESTING
- (instancetype)initForTestingWithSessionFactory:(NSURLSession * (^)(id<NSURLSessionDelegate>, NSOperationQueue *))factory;
- (void)drainForTesting;
#endif
- (nullable NSString *)startURL:(NSString *)url name:(nullable NSString *)name error:(NSError **)error;
- (nullable NSString *)enqueueURL:(NSString *)url name:(nullable NSString *)name error:(NSError **)error;
- (BOOL)enqueueURLs:(NSArray<NSString *> *)urls error:(NSError **)error;
- (nullable NSString *)startIntent:(FDMDownloadIntent *)intent request:(NSURLRequest *)request error:(NSError **)error;
- (nullable NSString *)registerWebKitDownload:(id)download intent:(nullable FDMDownloadIntent *)intent tabID:(nullable NSString *)tabID;
// All WebKit execution occurs on main. The engine invokes these copied blocks asynchronously.
- (void)bindWebKitKey:(NSString *)key transportIdentity:(NSString *)identity
    cancel:(void (^)(void (^)(NSData * _Nullable)))cancel
    resume:(void (^)(NSData *, NSString *, void (^)(BOOL)))resume;
- (nullable NSString *)destinationForWebKitDownloadKey:(NSString *)key transportIdentity:(NSString *)identity
    suggestedFilename:(nullable NSString *)filename response:(nullable NSURLResponse *)response;
- (void)webKitDownloadDidFinishKey:(NSString *)key transportIdentity:(NSString *)identity;
- (void)webKitDownloadKey:(NSString *)key transportIdentity:(NSString *)identity
    failedWithMessage:(NSString *)message resumeData:(nullable NSData *)data;
- (void)applyWebKitProgressKey:(NSString *)key transportIdentity:(NSString *)identity received:(long long)received total:(long long)total;
- (void)invalidateWebKitContextForTabID:(NSString *)tabID;
- (void)pauseKey:(NSString *)key;
- (void)resumeKey:(NSString *)key;
- (void)restartKey:(NSString *)key;
- (void)removeKey:(NSString *)key deleteFile:(BOOL)deleteFile completion:(void (^)(NSError * _Nullable error))completion;
- (void)setBackgroundCompletion:(void (^)(void))completion;
@end
NS_ASSUME_NONNULL_END
