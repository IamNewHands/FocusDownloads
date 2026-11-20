#import "FDMCommon.h"

NS_ASSUME_NONNULL_BEGIN
@interface FDMStore : NSObject
+ (instancetype)shared;
- (NSArray<NSDictionary *> *)records;
- (nullable NSDictionary *)recordForKey:(NSString *)key;
- (BOOL)upsertRecord:(NSDictionary *)record error:(NSError **)error;
- (BOOL)dropKey:(NSString *)key error:(NSError **)error;
// Coalesce several writes into one change notification. Batches nest; the
// notification fires once when the outermost batch ends.
- (void)beginBatch;
- (void)endBatch;
@end
NS_ASSUME_NONNULL_END
