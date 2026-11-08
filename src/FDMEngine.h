#import "FDMCommon.h"

NS_ASSUME_NONNULL_BEGIN
@interface FDMEngine : NSObject <NSURLSessionDownloadDelegate>
+ (instancetype)shared;
@property (nonatomic, readonly) BOOL restoring;
- (NSArray<NSDictionary *> *)items;
- (BOOL)canResumeKey:(NSString *)key;
- (BOOL)isRemovedKey:(NSString *)key;
#ifdef FDM_TESTING
- (instancetype)initForTestingWithSessionFactory:(NSURLSession * (^)(id<NSURLSessionDelegate>, NSOperationQueue *))factory;
- (void)drainForTesting;
#endif
- (nullable NSString *)startURL:(NSString *)url name:(nullable NSString *)name error:(NSError **)error;
- (void)pauseKey:(NSString *)key;
- (void)resumeKey:(NSString *)key;
- (void)restartKey:(NSString *)key;
- (void)removeKey:(NSString *)key deleteFile:(BOOL)deleteFile completion:(void (^)(NSError * _Nullable error))completion;
- (void)setBackgroundCompletion:(void (^)(void))completion;
@end
NS_ASSUME_NONNULL_END
