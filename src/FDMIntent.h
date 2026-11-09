#import "FDMCommon.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *FDMTransportName(FDMTransportKind kind);

// Immutable description of one user download intent. Secret material (cookies, auth headers,
// request bodies) lives only in the in-memory FDMIntentRegistry and never in this DTO.
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
// Why this intent cannot use the preferred transport, or nil when it can.
@property (nonatomic, readonly, copy, nullable) NSString *transportRefusal;
@end

// Process-local store for the secret half of an intent. Entries are bound to intentID + attempt
// and are dropped when the owning tab navigates, closes, or the app is backgrounded for long.
@interface FDMIntentRegistry : NSObject
+ (instancetype)shared;
- (void)registerRequest:(NSURLRequest *)request
                tabID:(NSString *)tabID
   navigationGeneration:(unsigned long long)generation
           sourceOrigin:(NSString *)sourceOrigin
        suggestedFilename:(nullable NSString *)filename
              dataStore:(nullable id)dataStore
           userInitiated:(BOOL)userInitiated;
// The most recent intent whose URL matches, or nil. Never invents a request context.
- (nullable FDMDownloadIntent *)takeIntentMatchingURL:(NSURL *)url;
- (nullable NSURLRequest *)requestForIntent:(NSString *)intentID;
// Cookies for the intent's own data store only, restricted to hosts the target accepts.
- (void)cookiesForIntent:(NSString *)intentID completion:(void (^)(NSArray<NSHTTPCookie *> *cookies))completion;
- (void)invalidateTab:(NSString *)tabID;
- (void)invalidateAll;
- (NSUInteger)count;
@end

// Redirect policy for credentialed transports. Returns nil when the redirect may proceed.
FOUNDATION_EXPORT NSError * _Nullable FDMRedirectRefusal(NSURLRequest *original, NSURLRequest *redirect);
// A header name whose value must never reach a log or a persisted record.
FOUNDATION_EXPORT BOOL FDMIsSecretHeader(NSString *name);
FOUNDATION_EXPORT NSString *FDMRedactedHeaderNames(NSDictionary<NSString *, NSString *> *headers);

// Credentialed GET download. One ephemeral session per intent; no cookie sharing with the host.
@interface FDMCredentialedTransport : NSObject
- (instancetype)initWithIntent:(nullable FDMDownloadIntent *)intent
                       request:(NSURLRequest *)request
                         queue:(dispatch_queue_t)queue;
- (void)startWithProgress:(void (^)(int64_t received, int64_t total))progress
               completion:(void (^)(NSURL * _Nullable location, NSHTTPURLResponse * _Nullable response, NSError * _Nullable error))completion;
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
