#import "FDMCommon.h"

NS_ASSUME_NONNULL_BEGIN
@interface FDMStore : NSObject
+ (instancetype)shared;
- (NSArray<NSDictionary *> *)records;
- (nullable NSDictionary *)recordForKey:(NSString *)key;
- (BOOL)upsertRecord:(NSDictionary *)record error:(NSError **)error;
- (BOOL)dropKey:(NSString *)key error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
