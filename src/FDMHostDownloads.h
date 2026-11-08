#import "FDMCommon.h"

NS_ASSUME_NONNULL_BEGIN
// Values below are bound to the verified Focus 2.9.7 TRStatus enum, not NSURLSessionTaskState.
FOUNDATION_EXPORT FDMState FDMHostProjectedState(NSInteger status, BOOL pauseIntent);
FOUNDATION_EXPORT NSDictionary *FDMHostProjectTask(id task, NSString *key, BOOL pauseIntent, NSDictionary * _Nullable previous);

@interface FDMHostDownloads : NSObject
+ (instancetype)shared;
- (void)refresh;
- (NSArray<NSDictionary *> *)rows;
- (BOOL)isSuppressedKey:(NSString *)key;
- (BOOL)pauseKey:(NSString *)key error:(NSError **)error;
- (void)removeKey:(NSString *)key deleteFile:(BOOL)deleteFile completion:(void (^)(NSError * _Nullable error))completion;
@end
NS_ASSUME_NONNULL_END
