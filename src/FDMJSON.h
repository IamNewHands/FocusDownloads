#import "FDMCommon.h"

NS_ASSUME_NONNULL_BEGIN

// Strict JSON for persisted configuration and backup containers. NSJSONSerialization silently
// accepts duplicate object members (last wins) and cannot bound nesting, so it is not used for
// any input that becomes durable state.
FOUNDATION_EXPORT NSUInteger const FDMJSONMaxDepth;
FOUNDATION_EXPORT NSUInteger const FDMJSONMaxBytes;

FOUNDATION_EXPORT id _Nullable FDMJSONParseData(NSData *data, NSError **error);
FOUNDATION_EXPORT id _Nullable FDMJSONParseDataBounded(NSData *data, NSUInteger maxDepth, NSUInteger maxBytes, NSError **error);
FOUNDATION_EXPORT NSData * _Nullable FDMJSONCanonicalData(id object, NSError **error);

FOUNDATION_EXPORT BOOL FDMJSONIsFiniteNumber(id _Nullable value);
// Non-boolean, finite, integral, non-negative and within [0, max].
FOUNDATION_EXPORT BOOL FDMJSONNonNegativeInteger(id _Nullable value, unsigned long long maximum, unsigned long long * _Nullable out);
FOUNDATION_EXPORT BOOL FDMJSONFiniteDouble(id _Nullable value, double * _Nullable out);
FOUNDATION_EXPORT NSString * _Nullable FDMJSONStringValue(id _Nullable value);
FOUNDATION_EXPORT NSArray * _Nullable FDMJSONArrayValue(id _Nullable value);
FOUNDATION_EXPORT NSDictionary * _Nullable FDMJSONObjectValue(id _Nullable value);

NS_ASSUME_NONNULL_END
