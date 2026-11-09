#import "FDMCommon.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FDMSitePolicyDidChangeNotification;

// Field keys of one origin entry. Every value is either an explicit setting or FDMPolicyInherit.
FOUNDATION_EXPORT NSString *const FDMPolicyContentMode;     // desktop | mobile
FOUNDATION_EXPORT NSString *const FDMPolicyUserAgent;       // NSNull removes the site override
FOUNDATION_EXPORT NSString *const FDMPolicyPageZoom;        // 0.5 ... 3.0
FOUNDATION_EXPORT NSString *const FDMPolicyReader;          // auto | off
FOUNDATION_EXPORT NSString *const FDMPolicyContentBlocking; // on | off
FOUNDATION_EXPORT NSString *const FDMPolicyPageJavaScript;  // on | off
FOUNDATION_EXPORT NSString *const FDMPolicyUserScripts;     // on | off
FOUNDATION_EXPORT NSString *const FDMPolicyExternalApps;    // ask | allow | deny
FOUNDATION_EXPORT NSString *const FDMPolicyCamera;          // ask | allow | deny
FOUNDATION_EXPORT NSString *const FDMPolicyMicrophone;      // ask | allow | deny
FOUNDATION_EXPORT NSString *const FDMPolicyInherit;
FOUNDATION_EXPORT NSArray<NSString *> *FDMPolicyFieldKeys(void);

// scheme://host:effectivePort with lowercase scheme/host and the default port made explicit.
// Only http and https qualify; userinfo, empty host and unknown schemes are rejected.
FOUNDATION_EXPORT NSString * _Nullable FDMNormalizedOrigin(NSString * _Nullable urlOrOrigin);
FOUNDATION_EXPORT NSString * _Nullable FDMOriginForURL(NSURL * _Nullable url);

// Whole-document validation. Returns an immutable normalized snapshot
// (@{@"schemaVersion", @"revision", @"origins"}) or nil with a reason.
FOUNDATION_EXPORT NSDictionary * _Nullable FDMSitePolicyValidateDocument(id _Nullable payload, NSError **error);
// One origin entry: absent/inherit fields are dropped; NSNull survives for userAgent.
FOUNDATION_EXPORT NSDictionary * _Nullable FDMSitePolicyValidateEntry(id _Nullable payload, NSError **error);
FOUNDATION_EXPORT NSDictionary *FDMSitePolicyEmptyDocument(void);

// Effective value resolution. A nil override means "use the global baseline".
FOUNDATION_EXPORT NSDictionary *FDMPolicyGlobalBaseline(void);
FOUNDATION_EXPORT NSString * _Nullable FDMPolicyEffectiveValue(NSDictionary * _Nullable entry, NSString *field, NSDictionary *global);
FOUNDATION_EXPORT NSDictionary *FDMPolicyEffectiveSnapshot(NSDictionary * _Nullable entry, NSDictionary *global);
// Fields whose site entry actually overrides the global baseline.
FOUNDATION_EXPORT NSArray<NSString *> *FDMPolicyOverriddenFields(NSDictionary * _Nullable entry);

@interface FDMSitePolicyStore : NSObject
+ (instancetype)shared;
// Immutable snapshot: {schemaVersion, revision, origins}. Never returns nil.
- (NSDictionary *)snapshot;
- (unsigned long long)revision;
- (nullable NSDictionary *)entryForOrigin:(NSString *)origin;
- (BOOL)setEntry:(nullable NSDictionary *)entry origin:(NSString *)origin error:(NSError **)error;
- (BOOL)resetOrigin:(NSString *)origin error:(NSError **)error;
- (BOOL)replaceDocument:(NSDictionary *)validatedDocument expectedRevision:(unsigned long long)expected error:(NSError **)error;
// Internal backup transaction: restore an exact trusted local snapshot without import normalization.
- (BOOL)restoreDocument:(NSDictionary *)validatedDocument publish:(BOOL)publish error:(NSError **)error;
// Set when the on-disk file could not be understood; writes are refused so the file survives.
- (BOOL)writable;
@end

// Per-WebView "仅本次关闭增强" state. Keyed weakly so a closed tab forgets it.
@interface FDMTemporaryEnhancementOff : NSObject
+ (instancetype)shared;
- (void)setOff:(BOOL)off forObject:(id)object;
- (BOOL)isOffForObject:(id _Nullable)object;
- (void)clearForObject:(id)object;
@end

NS_ASSUME_NONNULL_END
