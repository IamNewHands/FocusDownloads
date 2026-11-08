// Run inside an iOS simulator UIApplication host, on the main thread, with FDM_TESTING=1.
// Compile with FDMCommon.m/FDMIcons.m/FDMIconDiagnostics.m; this file supplies no main and no network.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>
#import "../src/FDMCommon.h"
#import "../src/FDMIcons.h"

static void FDMIconAssert(BOOL passed, NSString *message) {
    if (!passed) [NSException raise:@"FDMIconRegressionFailure" format:@"%@", message];
}

typedef void (^FakeUICompletion)(UIImage *, NSError *, NSInteger, NSURL *);
typedef void (^FakeInternalCompletion)(UIImage *, NSData *, NSError *, NSInteger, BOOL, NSURL *);
typedef void (^FakeSetter)(UIImage *, NSData *, NSInteger, NSURL *);
static NSMutableArray<NSDictionary *> *FakeRequests;
static NSInteger FakeLoadCount;

@interface UIImageView (FDMFakeSDK)
- (void)sd_setImageWithURL:(NSURL *)url placeholderImage:(UIImage *)placeholder options:(NSUInteger)options context:(NSDictionary *)context progress:(id)progress completed:(FakeUICompletion)completed;
- (id)sd_internalSetImageWithURL:(NSURL *)url placeholderImage:(UIImage *)placeholder options:(NSUInteger)options context:(NSDictionary *)context setImageBlock:(FakeSetter)setter progress:(id)progress completed:(FakeInternalCompletion)completed;
- (void)sd_cancelCurrentImageLoad;
@end
@implementation UIImageView (FDMFakeSDK)
- (void)sd_cancelCurrentImageLoad { /* Queued completion intentionally survives, exercising generation guards. */ }
- (void)sd_setImageWithURL:(NSURL *)url placeholderImage:(UIImage *)placeholder options:(NSUInteger)options context:(NSDictionary *)context progress:(id)progress completed:(FakeUICompletion)completed {
    FakeLoadCount++;
    __weak UIImageView *weak = self;
    FakeSetter setter = ^(UIImage *image, NSData *data, NSInteger type, NSURL *imageURL) { weak.image = image; };
    FakeInternalCompletion inner = ^(UIImage *image, NSData *data, NSError *error, NSInteger type, BOOL finished, NSURL *imageURL) {
        if (completed) completed(image, error, type, imageURL);
    };
    [self sd_internalSetImageWithURL:url placeholderImage:placeholder options:options context:context setImageBlock:setter progress:progress completed:inner];
}
- (id)sd_internalSetImageWithURL:(NSURL *)url placeholderImage:(UIImage *)placeholder options:(NSUInteger)options context:(NSDictionary *)context setImageBlock:(FakeSetter)setter progress:(id)progress completed:(FakeInternalCompletion)completed {
    [FakeRequests addObject:@{ @"setter": [setter copy] ?: [NSNull null], @"completed": [completed copy] ?: [NSNull null],
                              @"url": url ?: [NSURL URLWithString:@"https://fixture.invalid"], @"context": context ?: @{} }];
    return nil;
}
@end

@interface FDMFakeIconOwner : UIView
@property (nonatomic, strong) NSMutableDictionary *model;
@property (nonatomic, strong) UIImageView *logo;
@property (nonatomic, strong) UILabel *logoLabel;
@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;
@property (nonatomic, strong) UIImage *fixtureNativeImage;
@property (nonatomic) BOOL dark;
@property (nonatomic) NSInteger themeCount;
@property (nonatomic, copy) NSString *protectionCacheKey;
@property (nonatomic) BOOL shouldProtectDarkLogo;
- (void)setupLogoForModel:(id)model;
- (void)updateWithModel:(id)model;
- (void)prepareForReuse;
@end
@implementation FDMFakeIconOwner
- (instancetype)init {
    if ((self = [super initWithFrame:CGRectMake(0, 0, 100, 100)])) {
        _logo = [[UIImageView alloc] initWithFrame:CGRectMake(7, 9, 42, 31)];
        _logo.contentMode = UIViewContentModeScaleAspectFit;
        _logoLabel = [UILabel new];
        _activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [self addSubview:_logo]; [self addSubview:_logoLabel]; [self addSubview:_activityIndicator];
    }
    return self;
}
- (BOOL)isDarkTheme { return self.dark; }
- (void)applyTheme { self.themeCount++; }
- (void)setupTextLogo { self.logoLabel.text = @"T"; self.logo.hidden = YES; self.logoLabel.hidden = NO; }
- (void)updateWithModel:(id)model {
    self.model = [model mutableCopy];
    if ([self.model[@"type"] integerValue] == 99) {
        self.logo.image = nil; self.logoLabel.hidden = YES; self.logo.hidden = NO;
        return; // Native built-in types do not call setupLogo; update invalidation must still run.
    }
    [self setupLogoForModel:self.model];
}
- (void)setupLogoForModel:(id)model {
    self.model = [model mutableCopy]; self.logoLabel.hidden = YES; self.logo.hidden = YES;
    [self.activityIndicator startAnimating]; self.activityIndicator.hidden = NO;
    if ([self.model[@"type"] integerValue] == 98 && self.fixtureNativeImage) {
        self.logo.image = self.fixtureNativeImage; self.logo.hidden = NO; self.logoLabel.hidden = YES;
        [self.activityIndicator stopAnimating]; self.activityIndicator.hidden = YES;
        return; // Native special-domain/local logo is synchronously ready without SD.
    }
    NSString *resource = self.model[@"iconUrl"];
    if (!resource.length) { [self setupTextLogo]; [self.activityIndicator stopAnimating]; self.activityIndicator.hidden = YES; return; }
    CGFloat scale = self.logo.traitCollection.displayScale ?: UIScreen.mainScreen.scale;
    NSDictionary *context = @{ @"imageThumbnailPixelSize": [NSValue valueWithCGSize:CGSizeMake(42 * scale, 31 * scale)] };
    __weak typeof(self) weak = self;
    [self.logo sd_setImageWithURL:[NSURL URLWithString:resource] placeholderImage:nil options:0 context:context progress:nil completed:^(UIImage *image, NSError *error, NSInteger cacheType, NSURL *url) {
        if (image && !error) { weak.logo.image = image; weak.logo.hidden = NO; weak.logoLabel.hidden = YES; }
        else [weak setupTextLogo];
        [weak.activityIndicator stopAnimating]; weak.activityIndicator.hidden = YES; [weak applyTheme];
    }];
}
- (void)prepareForReuse { self.model = nil; }
@end

// Exact production names are fixtures registered in the simulator host, not real Focus classes.
@interface CustomTagCell : FDMFakeIconOwner @end
@implementation CustomTagCell @end
@interface ContextMenuController : FDMFakeIconOwner @end
@implementation ContextMenuController @end
@interface BookMarkCell : FDMFakeIconOwner
@property (nonatomic, readonly) UIImageView *logoImage;
@property (nonatomic, readonly) UILabel *logoText;
- (void)updateWithModel:(id)model batchOperation:(NSInteger)operation;
@end
@implementation BookMarkCell
- (UIImageView *)logoImage { return self.logo; }
- (UILabel *)logoText { return self.logoLabel; }
- (void)updateWithModel:(id)model batchOperation:(NSInteger)operation { [super updateWithModel:model]; }
@end
@interface HistoryCell : FDMFakeIconOwner
@property (nonatomic, readonly) UIImageView *logoImage;
@property (nonatomic, readonly) UILabel *logoText;
@end
@implementation HistoryCell
- (UIImageView *)logoImage { return self.logo; }
- (UILabel *)logoText { return self.logoLabel; }
@end

@interface IconCacheManager : NSObject
+ (instancetype)sharedInstance;
- (void)setupTextLogoWithTitle:(NSString *)title logoLabel:(UILabel *)label url:(NSString *)url;
- (void)resolveDarkModeProtectionForImage:(UIImage *)image cacheKey:(NSString *)key completion:(void (^)(BOOL))completion;
@end
@implementation IconCacheManager
+ (instancetype)sharedInstance { static IconCacheManager *manager; if (!manager) manager = [self new]; return manager; }
- (void)setupTextLogoWithTitle:(NSString *)title logoLabel:(UILabel *)label url:(NSString *)url { label.text = @"T"; }
- (void)resolveDarkModeProtectionForImage:(UIImage *)image cacheKey:(NSString *)key completion:(void (^)(BOOL))completion { if (completion) completion(NO); }
@end

@interface FDMFakeCyclicError : NSError
@property (nonatomic, weak) NSError *fixtureUnderlying;
@end
@implementation FDMFakeCyclicError
- (NSDictionary *)userInfo { return self.fixtureUnderlying ? @{NSUnderlyingErrorKey: self.fixtureUnderlying} : @{}; }
@end

static NSString *FakeImageDigest(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *result = [NSMutableString stringWithCapacity:64];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [result appendFormat:@"%02x", digest[i]];
    return result;
}

static UIImage *FakeIcon(UIColor *color) {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(32, 24)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) { [color setFill]; UIRectFill(CGRectMake(0, 0, 32, 24)); }];
}
static void FakeFinish(NSDictionary *request, UIImage *image, NSError *error) {
    if (image && request[@"setter"] != NSNull.null) ((FakeSetter)request[@"setter"])(image, nil, 0, request[@"url"]);
    if (request[@"completed"] != NSNull.null) ((FakeInternalCompletion)request[@"completed"])(image, nil, error, 0, YES, request[@"url"]);
}
static NSMutableDictionary *FakeModel(NSString *page, NSString *resource, BOOL bookmark) {
    return [@{ (bookmark ? @"url" : @"targetUrl"): page, @"iconUrl": resource, @"title": @"Fixture", @"type": @1 } mutableCopy];
}

void FDMRunIconRegressionTests(void) {
    FDMIconAssert(NSThread.isMainThread, @"Run icon regression on UIApplication main thread");
    FakeRequests = [NSMutableArray new]; FakeLoadCount = 0;
    FDMInstallIconHooks(); FDMInstallIconHooks();
    NSString *unique = NSUUID.UUID.UUIDString;
    NSString *page = [NSString stringWithFormat:@"https://fixture.invalid/%@", unique];
    NSString *resource = [page stringByAppendingString:@"/favicon.png"];
    UIImage *red = FakeIcon(UIColor.redColor), *blue = FakeIcon(UIColor.blueColor);
    CustomTagCell *cell = [CustomTagCell new];
    CGRect geometry = cell.logo.frame;
    [cell updateWithModel:FakeModel(page, resource, NO)];
    FDMIconAssert(FakeLoadCount == 1 && FakeRequests.count == 1, @"CustomTag targetUrl binds to one true miss");
    FakeFinish(FakeRequests.lastObject, red, nil); FDMFlushIconWrites();
    FDMIconAssert(cell.logo.image && !cell.logo.hidden && cell.logoLabel.hidden && !cell.activityIndicator.isAnimating, @"successful bitmap applies complete visible state");
    FDMIconAssert(CGRectEqualToRect(geometry, cell.logo.frame) && cell.logo.contentMode == UIViewContentModeScaleAspectFit, @"native geometry/contentMode survives cache pipeline");
    NSString *key = FDMIconEntryKeyForTesting(cell);
    NSArray *entries = FDMIconDiagnosticEntries();
    NSDictionary *written = nil;
    for (NSDictionary *entry in entries) if ([entry[@"key"] isEqual:key]) written = entry;
    FDMIconAssert([written[@"diskCommitted"] boolValue] && [written[@"applied"] boolValue], @"producer write and actual applied are separately confirmed");
    FDMReloadIconStoreForTesting();
    CustomTagCell *reopened = [CustomTagCell new];
    [reopened updateWithModel:FakeModel(page, resource, NO)]; FDMFlushIconWrites();
    FDMIconAssert(FakeLoadCount == 1 && reopened.logo.image && !reopened.activityIndicator.isAnimating, @"new store cold disk hit skips request and spinner");
    NSDictionary *cold = nil;
    for (NSDictionary *entry in FDMIconDiagnosticEntries()) if ([entry[@"key"] isEqual:key]) cold = entry;
    FDMIconAssert([cold[@"source"] isEqual:@"disk"] && [cold[@"applied"] boolValue], @"cold diagnostics reports disk/applied rather than queued write");

    // Corrupt only this run's produced v19 blob in the simulator's isolated fixture root.
    NSString *fixtureRoot = NSProcessInfo.processInfo.environment[@"FDM_TEST_DOCUMENTS"];
    FDMIconAssert(fixtureRoot.length > 0, @"corruption fixture requires explicitly isolated FDM_TEST_DOCUMENTS");
    NSString *cacheDirectory = [fixtureRoot stringByAppendingPathComponent:@"FocusDM/icons-v19"];
    NSString *metadataPath = [cacheDirectory stringByAppendingPathComponent:[key stringByAppendingPathExtension:@"json"]];
    NSDictionary *metadata = FDMReadJSON(metadataPath, nil);
    NSString *imageDigest = FDMString(metadata[@"imageDigest"]);
    FDMIconAssert(imageDigest.length == 64, @"produced bitmap metadata names content-addressed blob");
    NSString *imagePath = [cacheDirectory stringByAppendingPathComponent:[imageDigest stringByAppendingPathExtension:@"image"]];
    NSData *originalBlob = [NSData dataWithContentsOfFile:imagePath];
    FDMIconAssert([FakeImageDigest(originalBlob) isEqual:imageDigest], @"fixture starts with verified real content bytes");
    NSError *fixtureError = nil;
    FDMIconAssert([[@"corrupt-v19-fixture" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:imagePath options:NSDataWritingAtomic error:&fixtureError], @"fixture corruption write succeeds");
    FDMIconAssert(![FakeImageDigest([NSData dataWithContentsOfFile:imagePath]) isEqual:imageDigest], @"fixture genuinely corrupts same content address");
    FDMReloadIconStoreForTesting();
    NSInteger beforeRepair = FakeLoadCount;
    CustomTagCell *repair = [CustomTagCell new];
    [repair updateWithModel:FakeModel(page, resource, NO)];
    FDMIconAssert(FakeLoadCount == beforeRepair + 1, @"corrupt cold blob triggers one native re-fetch");
    FakeFinish(FakeRequests.lastObject, red, nil); FDMFlushIconWrites();
    NSDictionary *repairedMetadata = FDMReadJSON(metadataPath, nil);
    FDMIconAssert([repairedMetadata[@"imageDigest"] isEqual:imageDigest], @"same-image repair exercises the existing content address");
    FDMIconAssert([FakeImageDigest([NSData dataWithContentsOfFile:imagePath]) isEqual:imageDigest], @"existing corrupt derived blob is atomically rewritten to valid content");
    NSDictionary *repairDiagnostic = nil;
    for (NSDictionary *entry in FDMIconDiagnosticEntries()) if ([entry[@"key"] isEqual:key]) repairDiagnostic = entry;
    FDMIconAssert([repairDiagnostic[@"diskCommitted"] boolValue], @"diskCommitted is true only after valid blob and metadata commit");
    FDMReloadIconStoreForTesting();
    NSInteger beforeReopen = FakeLoadCount;
    CustomTagCell *afterRepair = [CustomTagCell new];
    [afterRepair updateWithModel:FakeModel(page, resource, NO)]; FDMFlushIconWrites();
    FDMIconAssert(FakeLoadCount == beforeReopen && afterRepair.logo.image && !afterRepair.activityIndicator.isAnimating, @"repaired blob survives new store and cold hit without another request");
    // Force only this fixture's new base journal path to fail by occupying it with a directory.
    NSString *journalPath = [cacheDirectory stringByAppendingPathComponent:[repairedMetadata[@"baseKey"] stringByAppendingPathExtension:@"epoch"]];
    FDMIconAssert(![NSFileManager.defaultManager fileExistsAtPath:journalPath], @"fresh fixture has no base invalidation journal yet");
    FDMIconAssert([NSFileManager.defaultManager createDirectoryAtPath:journalPath withIntermediateDirectories:NO attributes:nil error:&fixtureError], @"fixture journal blocker created");
    NSInteger beforeFailedRefresh = FakeLoadCount;
    FDMRefreshIcon(key); FDMFlushIconWrites();
    NSDictionary *failedRefresh = nil;
    for (NSDictionary *entry in FDMIconDiagnosticEntries()) if ([entry[@"key"] isEqual:key]) failedRefresh = entry;
    FDMIconAssert(FakeLoadCount == beforeFailedRefresh && [failedRefresh[@"source"] isEqual:@"refresh-failed"] && [failedRefresh[@"error"] length] > 0, @"failed journal commit preserves old record and reports failure instead of re-preparing");
    FDMReloadIconStoreForTesting();
    CustomTagCell *afterFailedRefresh = [CustomTagCell new];
    [afterFailedRefresh updateWithModel:FakeModel(page, resource, NO)];
    FDMIconAssert(FakeLoadCount == beforeFailedRefresh && afterFailedRefresh.logo.image, @"failed refresh never claimed invalidation; prior committed record remains valid after reopen");
    // Only the freshly created fixture blocker is removed, never cache/user data.
    FDMIconAssert([NSFileManager.defaultManager removeItemAtPath:journalPath error:&fixtureError], @"fixture journal blocker cleanup succeeds");

    NSString *failedPage = [page stringByAppendingString:@"/failed"];
    [cell updateWithModel:FakeModel(failedPage, resource, NO)];
    FakeFinish(FakeRequests.lastObject, nil, [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotFindHost userInfo:nil]); FDMFlushIconWrites();
    NSInteger failedLoads = FakeLoadCount;
    [cell updateWithModel:FakeModel(failedPage, resource, NO)];
    FDMIconAssert(FakeLoadCount == failedLoads && cell.logo.hidden && !cell.logoLabel.hidden && !cell.activityIndicator.isAnimating, @"typed negative uses native text, never fake PNG success");

    NSString *oldPage = [page stringByAppendingString:@"/old"];
    [cell updateWithModel:FakeModel(oldPage, resource, NO)]; NSDictionary *old = FakeRequests.lastObject;
    [cell updateWithModel:FakeModel([page stringByAppendingString:@"/new"], resource, NO)]; NSDictionary *new = FakeRequests.lastObject;
    FakeFinish(new, blue, nil); FakeFinish(old, red, nil); FDMFlushIconWrites();
    FDMIconAssert(cell.logo.image == blue, @"old internal setter cannot paint reused cell before external completion guard");
    [cell updateWithModel:FakeModel([page stringByAppendingString:@"/pending"], resource, NO)]; old = FakeRequests.lastObject;
    NSMutableDictionary *builtIn = FakeModel([page stringByAppendingString:@"/built-in"], @"", NO); builtIn[@"type"] = @99;
    [cell updateWithModel:builtIn]; FakeFinish(old, red, nil);
    FDMIconAssert(cell.logo.image == nil, @"built-in type skipping setup still invalidates pending network binding");

    [reopened updateWithModel:FakeModel(page, resource, NO)];
    FDMReplayStaleIconWriteForTesting(reopened);
    BOOL revived = NO;
    for (NSDictionary *entry in FDMIconDiagnosticEntries()) if ([entry[@"key"] isEqual:key]) revived = YES;
    FDMIconAssert(!revived, @"stale producer submitted after manual invalidation cannot revive entry");
    FDMReloadIconStoreForTesting();
    revived = NO;
    for (NSDictionary *entry in FDMIconDiagnosticEntries()) if ([entry[@"key"] isEqual:key]) revived = YES;
    FDMIconAssert(!revived, @"committed base epoch prevents old variant metadata from reviving after store reopen");
    NSData *oldMetadataBytes = [NSData dataWithContentsOfFile:metadataPath];
    NSDictionary *validJournal = FDMReadJSON(journalPath, nil);
    FDMIconAssert([validJournal[@"epoch"] unsignedIntegerValue] > 0, @"fixture first commits a genuine nonzero base epoch");
    NSData *corruptJournal = [@"corrupt-committed-epoch-fixture" dataUsingEncoding:NSUTF8StringEncoding];
    FDMIconAssert([corruptJournal writeToFile:journalPath options:NSDataWritingAtomic error:&fixtureError], @"fixture corrupts only this run's committed regular journal");
    FDMReloadIconStoreForTesting();
    NSDictionary *epochDiagnostic = nil;
    for (NSDictionary *entry in FDMIconDiagnosticEntries()) if ([entry[@"key"] isEqual:key]) epochDiagnostic = entry;
    FDMIconAssert([epochDiagnostic[@"source"] isEqual:@"epoch-corrupt"] && ![epochDiagnostic[@"diskCommitted"] boolValue] && ![epochDiagnostic[@"applied"] boolValue], @"malformed existing epoch blocks old epoch0 cache with explicit diagnostic");
    NSInteger beforeBlockedPrepare = FakeLoadCount;
    CustomTagCell *blocked = [CustomTagCell new];
    [blocked updateWithModel:FakeModel(page, resource, NO)];
    FDMIconAssert(FakeLoadCount == beforeBlockedPrepare + 1, @"corrupt journal never restores old metadata as a cold cache hit");
    FakeFinish(FakeRequests.lastObject, red, nil); FDMFlushIconWrites();
    FDMIconAssert(blocked.logo.image == red && !blocked.activityIndicator.isAnimating, @"native request may still display while persistence base is blocked");
    FDMIconAssert([[NSData dataWithContentsOfFile:metadataPath] isEqual:oldMetadataBytes] && [[NSData dataWithContentsOfFile:journalPath] isEqual:corruptJournal], @"blocked producer leaves old metadata and damaged journal untouched");
    NSInteger beforeBlockedRefresh = FakeLoadCount;
    FDMRefreshIcon(key); FDMFlushIconWrites();
    FDMIconAssert(FakeLoadCount == beforeBlockedRefresh, @"explicit refresh refuses unknown epoch rather than silently overwriting it");
    for (NSDictionary *entry in FDMIconDiagnosticEntries()) if ([entry[@"key"] isEqual:key]) epochDiagnostic = entry;
    FDMIconAssert([epochDiagnostic[@"source"] isEqual:@"epoch-corrupt"] && ![epochDiagnostic[@"diskCommitted"] boolValue], @"new request cannot report false disk commit for blocked base");
    [reopened updateWithModel:FakeModel(page, resource, NO)];
    FDMIconAssert(FakeLoadCount > failedLoads, @"manual invalidation prepares a new request");

    BookMarkCell *bookmark = [BookMarkCell new];
    [bookmark updateWithModel:FakeModel([page stringByAppendingString:@"/bookmark"], resource, YES) batchOperation:0];
    FakeFinish(FakeRequests.lastObject, red, nil); FDMFlushIconWrites();
    FDMIconAssert(bookmark.logoImage.image == red && bookmark.logoText.hidden, @"BookMark url/logoImage/logoText mapping applies bitmap");
    UIImageView *unmarked = [UIImageView new];
    NSInteger beforeUnmarked = FakeLoadCount;
    __block BOOL unmarkedCompleted = NO;
    [unmarked sd_setImageWithURL:[NSURL URLWithString:resource] placeholderImage:nil options:0 context:nil progress:nil completed:^(UIImage *image, NSError *error, NSInteger type, NSURL *url) { unmarkedCompleted = image == red; }];
    FakeFinish(FakeRequests.lastObject, red, nil);
    FDMIconAssert(FakeLoadCount == beforeUnmarked + 1 && unmarkedCompleted && unmarked.image == red, @"unmarked UIImageView preserves original request/setter/UI completion");
    NSString *cancelPage = [page stringByAppendingString:@"/cancelled"];
    [cell updateWithModel:FakeModel(cancelPage, resource, NO)];
    FakeFinish(FakeRequests.lastObject, nil, [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]); FDMFlushIconWrites();
    NSInteger cancelledLoads = FakeLoadCount;
    [cell updateWithModel:FakeModel(cancelPage, resource, NO)];
    FDMIconAssert(FakeLoadCount == cancelledLoads + 1, @"cancelled load is not persisted as permanent negative");
    NSError *sdkCancel = [NSError errorWithDomain:@"SDWebImageErrorDomain" code:2002 userInfo:nil];
    NSError *wrappedCancel = [NSError errorWithDomain:@"FixtureWrapper" code:1 userInfo:@{NSUnderlyingErrorKey: sdkCancel}];
    FDMFakeCyclicError *cycleA = [[FDMFakeCyclicError alloc] initWithDomain:@"FixtureCycle" code:1 userInfo:nil];
    FDMFakeCyclicError *cycleB = [[FDMFakeCyclicError alloc] initWithDomain:@"FixtureCycle" code:2 userInfo:nil];
    cycleA.fixtureUnderlying = cycleB; cycleB.fixtureUnderlying = cycleA;
    for (NSError *cancellation in @[sdkCancel, wrappedCancel, cycleA]) {
        NSString *cancellationPage = [page stringByAppendingFormat:@"/cancel-%@", NSUUID.UUID.UUIDString];
        [cell updateWithModel:FakeModel(cancellationPage, resource, NO)];
        FakeFinish(FakeRequests.lastObject, nil, cancellation); FDMFlushIconWrites();
        NSInteger beforeRepeat = FakeLoadCount;
        [cell updateWithModel:FakeModel(cancellationPage, resource, NO)];
        FDMIconAssert(FakeLoadCount == beforeRepeat + 1, @"SDK2002, underlying cancellation and cyclic attribution do not create permanent negative cache");
    }
    NSString *themePage = [page stringByAppendingString:@"/theme-pending"];
    [cell updateWithModel:FakeModel(themePage, resource, NO)];
    NSDictionary *oldThemeRequest = FakeRequests.lastObject;
    NSInteger beforeThemeChange = FakeLoadCount;
    cell.dark = YES; [cell applyTheme];
    FDMIconAssert(FakeLoadCount == beforeThemeChange + 1 && !cell.activityIndicator.isAnimating && !cell.logoLabel.hidden, @"theme transition re-prepares current model and shows stable temporary native text without spinner");
    NSDictionary *currentThemeRequest = FakeRequests.lastObject;
    FakeFinish(oldThemeRequest, red, nil);
    FDMIconAssert(cell.logo.hidden && !cell.logoLabel.hidden, @"old-theme setter/completion cannot replace current-theme placeholder");
    FakeFinish(currentThemeRequest, blue, nil); FDMFlushIconWrites();
    FDMIconAssert(cell.logo.image == blue && !cell.logo.hidden && cell.logoLabel.hidden && !cell.activityIndicator.isAnimating, @"current-theme completion applies image and terminates loading");
    NSInteger beforeThemeHit = FakeLoadCount;
    [cell updateWithModel:FakeModel(themePage, resource, NO)];
    FDMIconAssert(FakeLoadCount == beforeThemeHit && cell.logo.image && !cell.activityIndicator.isAnimating, @"temporary theme text was not persisted as a permanent negative");
    CustomTagCell *special = [CustomTagCell new];
    special.fixtureNativeImage = red;
    NSMutableDictionary *specialModel = FakeModel([page stringByAppendingString:@"/native-special"], @"", NO);
    specialModel[@"type"] = @98;
    NSInteger beforeNativeSpecial = FakeLoadCount;
    [special updateWithModel:specialModel]; FDMFlushIconWrites();
    FDMIconAssert(special.logo.image == red && !special.logo.hidden && special.logoLabel.hidden, @"synchronous native special-logo setup shows its bitmap");
    special.dark = YES; [special applyTheme]; FDMFlushIconWrites();
    FDMIconAssert(FakeLoadCount == beforeNativeSpecial && special.logo.image == red && !special.logo.hidden && special.logoLabel.hidden && !special.activityIndicator.isAnimating, @"theme transition preserves native special bitmap instead of covering it with network placeholder");
    NSLog(@"FDMRunIconRegressionTests: PASS (fixture SDK; not real Focus runtime)");
}
