#import "FDMCommon.h"

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT BOOL FDMRequestCanUseAnonymousBackground(NSURLRequest *request);
FOUNDATION_EXPORT NSString *FDMDownloadPublicURL(NSURL * _Nullable url);
FOUNDATION_EXPORT NSError * _Nullable FDMRedirectRefusal(NSURLRequest *original, NSURLRequest *redirect);

// Immutable intent; url is a public origin display, never the replay recipe.
@interface FDMDownloadIntent : NSObject
@property (nonatomic, readonly, copy) NSString *intentID;
@property (nonatomic, readonly, copy) NSString *tabID;
@property (nonatomic, readonly) unsigned long long navigationGeneration;
@property (nonatomic, readonly, copy, nullable) NSString *sourceOrigin;
@property (nonatomic, readonly, copy, nullable) NSString *targetOrigin;
@property (nonatomic, readonly, copy) NSString *method;
@property (nonatomic, readonly) BOOL replayable;
@property (nonatomic, readonly, copy) NSString *url;
@property (nonatomic, readonly, copy, nullable) NSString *suggestedFilename;
@property (nonatomic, readonly, copy, nullable) NSString *mime;
@property (nonatomic, readonly) long long expectedLength;
@property (nonatomic, readonly) BOOL userInitiated;
@property (nonatomic, readonly) NSTimeInterval captureTime;
@property (nonatomic, readonly) unsigned long long policyRevision;
@property (nonatomic, readonly) FDMTransportKind transport;
@property (nonatomic, readonly) BOOL persistentContext;
@property (nonatomic, readonly, copy, nullable) NSString *transportRefusal;
- (instancetype)initWithRequest:(NSURLRequest *)request tabID:(NSString *)tabID
    generation:(unsigned long long)generation sourceOrigin:(nullable NSString *)sourceOrigin
    transport:(FDMTransportKind)transport dataStore:(nullable id)dataStore
    userInitiated:(BOOL)userInitiated policyRevision:(unsigned long long)policyRevision;
- (instancetype)init NS_UNAVAILABLE;
@end

// Only unclaimed navigation intent belongs here. Once adopted, the transport owns a copied recipe.
@interface FDMIntentRegistry : NSObject
+ (instancetype)shared;
- (FDMDownloadIntent *)registerRequest:(NSURLRequest *)request tabID:(NSString *)tabID
    navigationGeneration:(unsigned long long)generation sourceOrigin:(nullable NSString *)sourceOrigin
    suggestedFilename:(nullable NSString *)filename dataStore:(nullable id)dataStore userInitiated:(BOOL)userInitiated;
- (nullable FDMDownloadIntent *)intentForTabID:(NSString *)tabID generation:(unsigned long long)generation;
- (nullable NSURLRequest *)requestForIntent:(NSString *)intentID;
- (BOOL)claimIntent:(NSString *)intentID tabID:(NSString *)tabID generation:(unsigned long long)generation;
- (void)invalidateTab:(NSString *)tabID;
- (void)invalidateAll;
- (NSUInteger)count;
@end
NS_ASSUME_NONNULL_END
