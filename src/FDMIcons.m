#import "FDMIcons.h"
#import "FDMCommon.h"
#import <CommonCrypto/CommonDigest.h>
#import <ImageIO/ImageIO.h>
#import <math.h>
#import <string.h>

NSNotificationName const FDMIconCacheDidChangeNotification = @"FDMIconCacheDidChange";
static const NSUInteger FDMIconSchema = 1;
static const NSUInteger FDMIconMaxMemoryCost = 24 * 1024 * 1024;
static const unsigned long long FDMIconMaxDiskBytes = 32 * 1024 * 1024;
static const NSUInteger FDMIconMaxEncodedBytes = 2 * 1024 * 1024;
static char FDMOwnerBindingKey, FDMViewBindingKey, FDMOwnerGenerationKey, FDMThemeTransitionKey;

// These are the distinct ABI contracts established from Focus 2.9.7.
typedef void (^FDMUICompletion)(UIImage *, NSError *, NSInteger, NSURL *);
typedef void (^FDMInternalCompletion)(UIImage *, NSData *, NSError *, NSInteger, BOOL, NSURL *);
typedef void (^FDMImageSetter)(UIImage *, NSData *, NSInteger, NSURL *);
typedef void (*FDMLongImageIMP)(id, SEL, NSURL *, UIImage *, NSUInteger, NSDictionary *, id, id);
typedef id (*FDMInternalImageIMP)(id, SEL, NSURL *, UIImage *, NSUInteger, NSDictionary *, id, id, id);
static FDMLongImageIMP FDMOriginalLongImage;
static FDMInternalImageIMP FDMOriginalInternalImage;
static IMP FDMOriginalProtection;

static NSString *FDMIconDataDigest(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *result = [NSMutableString stringWithCapacity:64];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [result appendFormat:@"%02x", digest[i]];
    return result;
}

static NSString *FDMIconDigest(NSString *text) {
    return FDMIconDataDigest([text dataUsingEncoding:NSUTF8StringEncoding]);
}

static BOOL FDMIconValidKey(id key) {
    if (![key isKindOfClass:NSString.class] || [(NSString *)key length] != 64) return NO;
    return [(NSString *)key rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet].location == NSNotFound;
}

static NSString *FDMIconPage(id model, NSString *key) {
    if (!key.length) return nil;
    NSString *page = FDMString(FDMValue(model, key));
    return [page stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *FDMIconContentSignature(id model, NSString *page) {
    NSArray *parts = @[page ?: @"", FDMString(FDMValue(model, @"iconUrl")) ?: @"",
                       FDMString(FDMValue(model, @"title")) ?: @"", FDMValue(model, @"type") ?: @"",
                       FDMValue(model, @"fileType") ?: @""];
    NSData *data = [NSJSONSerialization dataWithJSONObject:parts options:0 error:nil];
    return FDMIconDigest([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: page);
}

static BOOL FDMIconDark(id owner) {
    SEL selector = NSSelectorFromString(@"isDarkTheme");
    if ([owner respondsToSelector:selector]) return ((BOOL (*)(id, SEL))objc_msgSend)(owner, selector);
    return [owner isKindOfClass:UIView.class] ? [(UIView *)owner traitCollection].userInterfaceStyle == UIUserInterfaceStyleDark :
           [owner isKindOfClass:UIViewController.class] && [(UIViewController *)owner traitCollection].userInterfaceStyle == UIUserInterfaceStyleDark;
}

static void FDMIconChanged(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:FDMIconCacheDidChangeNotification object:nil];
    });
}

@interface FDMIconBinding : NSObject
@property (nonatomic, weak) id owner;
@property (nonatomic, weak) UIImageView *view;
@property (nonatomic, weak) UIView *textView;
@property (nonatomic, copy) NSString *pageKey;
@property (nonatomic, copy) NSString *page;
@property (nonatomic, copy) NSString *signature;
@property (nonatomic, copy) NSString *baseKey;
@property (nonatomic, copy) NSString *entryKey;
@property (nonatomic, copy) NSString *displayKey;
@property (nonatomic, copy) NSString *resource;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) NSUInteger requestSerial;
@property (nonatomic) NSUInteger cacheEpoch;
@property (nonatomic) BOOL valid;
@property (nonatomic) BOOL requested;
@property (nonatomic) BOOL dark;
@property (nonatomic) CGSize targetSize;
@property (nonatomic) CGFloat displayScale;
@property (nonatomic) BOOL acceptedBitmap;
@property (nonatomic, copy) NSString *lastSource;
@end
@implementation FDMIconBinding
@end

static NSDictionary *FDMIconBlockedDiagnostic(NSDictionary *record) {
    return @{ @"key": record[@"key"], @"url": FDMRedactedURL(record[@"page"]), @"kind": record[@"kind"],
              @"source": @"epoch-corrupt", @"applied": @NO, @"diskCommitted": @NO,
              @"version": record[@"version"] ?: @"unknown", @"updated": @(NSDate.date.timeIntervalSince1970),
              @"error": @"epoch 元数据已损坏；未读取或覆盖旧缓存，刷新未提交" };
}

@interface FDMIconStore : NSObject
+ (instancetype)shared;
- (NSDictionary *)recordForKey:(NSString *)key source:(NSString **)source;
- (UIImage *)imageForRecord:(NSDictionary *)record;
- (void)storeKind:(NSString *)kind binding:(FDMIconBinding *)binding image:(UIImage *)image;
- (void)markApplied:(NSString *)key source:(NSString *)source success:(BOOL)success;
- (NSUInteger)epochForBase:(NSString *)base;
- (NSArray<NSDictionary *> *)diagnostics;
- (NSDictionary *)invalidateEntry:(NSString *)key;
- (void)flush;
@end

static FDMIconStore *FDMSharedIconStore;
@implementation FDMIconStore {
    NSCache *_images;
    NSMutableDictionary *_records;
    NSMutableDictionary *_diagnostics;
    NSMutableDictionary *_epochs;
    NSMutableSet *_committed;
    NSMutableSet *_invalidated;
    NSMutableSet *_blockedBases;
    NSString *_directory;
    dispatch_queue_t _io;
    unsigned long long _diskBytes;
    void *_queueIdentity;
}

+ (instancetype)shared {
    @synchronized (self) {
        if (!FDMSharedIconStore) FDMSharedIconStore = [FDMIconStore new];
        return FDMSharedIconStore;
    }
}

- (instancetype)init {
    if ((self = [super init])) {
        _images = [NSCache new]; _images.totalCostLimit = FDMIconMaxMemoryCost;
        _records = [NSMutableDictionary new]; _diagnostics = [NSMutableDictionary new];
        _epochs = [NSMutableDictionary new]; _committed = [NSMutableSet new]; _invalidated = [NSMutableSet new]; _blockedBases = [NSMutableSet new];
        _directory = FDMDirectory(@"FocusDM/icons-v19");
        _io = dispatch_queue_create("FocusDM.icons.storage", DISPATCH_QUEUE_SERIAL);
        _queueIdentity = &_queueIdentity;
        dispatch_queue_set_specific(_io, _queueIdentity, _queueIdentity, NULL);
        dispatch_sync(_io, ^{
            // One directory pass. Epoch journals are read before the image records that
            // reference them, so a second full listing and its extra stat/read round is
            // not needed.
            NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:self->_directory error:nil];
            NSMutableArray *recordNames = [NSMutableArray array];
            for (NSString *name in names) {
                NSString *extension = name.pathExtension;
                NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:[self->_directory stringByAppendingPathComponent:name] error:nil];
                if (![attributes[NSFileType] isEqual:NSFileTypeRegular]) continue;
                // Every regular file counts toward the cache size budget, including images.
                self->_diskBytes += [attributes[NSFileSize] unsignedLongLongValue];
                if ([extension isEqual:@"epoch"]) {
                    NSString *base = name.stringByDeletingPathExtension;
                    if (!FDMIconValidKey(base)) continue;
                    NSDictionary *journal = FDMReadJSON([self pathForKey:base extension:@"epoch"], nil);
                    if ([journal isKindOfClass:NSDictionary.class] && [journal[@"schema"] isEqual:@(FDMIconSchema)] && [journal[@"baseKey"] isEqual:base] && [journal[@"epoch"] isKindOfClass:NSNumber.class] && [journal[@"epoch"] unsignedIntegerValue] > 0 && [journal[@"epoch"] unsignedIntegerValue] < NSUIntegerMax) self->_epochs[base] = journal[@"epoch"];
                    else { [self->_blockedBases addObject:base]; FDMLog(@"icon: epoch metadata corrupt; old cache blocked base=%@", base); }
                } else if ([extension isEqual:@"json"]) {
                    [recordNames addObject:name];
                }
            }
            for (NSString *name in recordNames) {
                NSString *key = name.stringByDeletingPathExtension;
                if (!FDMIconValidKey(key)) continue;
                NSDictionary *record = FDMReadJSON([self pathForKey:key extension:@"json"], nil);
                if (![self validRecord:record key:key]) continue;
                if ([self->_blockedBases containsObject:record[@"baseKey"]]) { self->_diagnostics[key] = FDMIconBlockedDiagnostic(record); continue; }
                if ([record[@"epoch"] unsignedIntegerValue] == [self->_epochs[record[@"baseKey"]] unsignedIntegerValue]) {
                    self->_records[key] = record; [self->_committed addObject:key];
                }
            }
        });
    }
    return self;
}

- (NSString *)pathForKey:(NSString *)key extension:(NSString *)extension {
    return FDMIconValidKey(key) ? [_directory stringByAppendingPathComponent:[key stringByAppendingPathExtension:extension]] : nil;
}

- (BOOL)validRecord:(id)value key:(NSString *)key {
    if (![value isKindOfClass:NSDictionary.class] || !FDMIconValidKey(key)) return NO;
    NSDictionary *record = value;
    NSString *kind = FDMString(record[@"kind"]);
    if (![record[@"schema"] isKindOfClass:NSNumber.class] || [record[@"schema"] unsignedIntegerValue] != FDMIconSchema ||
        ![record[@"key"] isEqual:key] || !FDMIconValidKey(record[@"baseKey"]) || !FDMIconValidKey(record[@"signature"]) ||
        ![record[@"page"] isKindOfClass:NSString.class] || ![record[@"display"] isKindOfClass:NSString.class] ||
        ![record[@"scale"] isKindOfClass:NSNumber.class] || !isfinite([record[@"scale"] doubleValue]) || [record[@"scale"] doubleValue] <= 0 ||
        ![record[@"updated"] isKindOfClass:NSNumber.class] || ![record[@"epoch"] isKindOfClass:NSNumber.class] || ![record[@"orientation"] isKindOfClass:NSNumber.class] ||
        [record[@"orientation"] integerValue] < UIImageOrientationUp || [record[@"orientation"] integerValue] > UIImageOrientationRightMirrored) return NO;
    if ([kind isEqual:@"textFallback"]) return YES;
    return [kind isEqual:@"bitmap"] && FDMIconValidKey(record[@"imageDigest"]);
}

- (NSUInteger)epochForBase:(NSString *)base {
    __block NSUInteger epoch;
    dispatch_sync(_io, ^{ epoch = [self->_blockedBases containsObject:base] ? NSUIntegerMax : [self->_epochs[base] unsignedIntegerValue]; });
    return epoch;
}

- (NSDictionary *)recordForKey:(NSString *)key source:(NSString **)source {
    if (!FDMIconValidKey(key)) return nil;
    __block NSDictionary *record;
    __block BOOL committed;
    dispatch_sync(_io, ^{
        if ([self->_invalidated containsObject:key]) return;
        record = self->_records[key];
        if (record && [self->_blockedBases containsObject:record[@"baseKey"]]) { record = nil; return; }
        committed = [self->_committed containsObject:key];
    });
    if (source) *source = !record ? @"miss" : ([_images objectForKey:key] || !committed ? @"memory" : @"disk");
    return record;
}

- (UIImage *)imageForRecord:(NSDictionary *)record {
    NSString *key = record[@"key"];
    UIImage *image = [_images objectForKey:key];
    if (image) return image;
    NSString *digest = record[@"imageDigest"];
    if (!FDMIconValidKey(digest)) return nil;
    NSData *data = [NSData dataWithContentsOfFile:[self pathForKey:digest extension:@"image"] options:0 error:nil];
    if (!data.length || data.length > FDMIconMaxEncodedBytes || ![FDMIconDataDigest(data) isEqual:digest]) return nil;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return nil;
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    double width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] doubleValue];
    double height = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] doubleValue];
    if (width < 1 || height < 1 || width > 2048 || height > 2048) { CFRelease(source); return nil; }
    CGImageRef decoded = CGImageSourceCreateImageAtIndex(source, 0, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES});
    CFRelease(source);
    if (!decoded) return nil;
    image = [UIImage imageWithCGImage:decoded scale:[record[@"scale"] doubleValue] orientation:[record[@"orientation"] integerValue]];
    CGImageRelease(decoded);
    if (image) [_images setObject:image forKey:key cost:(NSUInteger)(width * height * 4)];
    return image;
}

- (void)markApplied:(NSString *)key source:(NSString *)source success:(BOOL)success {
    if (!FDMIconValidKey(key)) return;
    dispatch_async(_io, ^{
        NSDictionary *record = self->_records[key];
        if (!record) return;
        NSMutableDictionary *entry = [self->_diagnostics[key] mutableCopy] ?: [NSMutableDictionary new];
        [entry addEntriesFromDictionary:@{ @"key": key, @"url": FDMRedactedURL(record[@"page"]), @"kind": record[@"kind"],
                                           @"source": source ?: @"unknown", @"applied": @(success),
                                           @"diskCommitted": @([self->_committed containsObject:key]),
                                           @"version": record[@"version"] ?: @"unknown", @"updated": @(NSDate.date.timeIntervalSince1970) }];
        if (!entry[@"error"]) entry[@"error"] = @"";
        self->_diagnostics[key] = entry;
        FDMIconChanged();
    });
}

- (void)storeKind:(NSString *)kind binding:(FDMIconBinding *)binding image:(UIImage *)image {
    BOOL bitmap = [kind isEqual:@"bitmap"];
    NSString *key = bitmap ? binding.entryKey : FDMIconDigest([binding.baseKey stringByAppendingString:@"|text"]);
    if (!FDMIconValidKey(key) || (bitmap && (!image.CGImage || CGImageGetWidth(image.CGImage) > 2048 || CGImageGetHeight(image.CGImage) > 2048))) return;
    // Snapshot all producer fields now. The I/O block never reads a mutable/reused UI binding.
    NSString *base = [binding.baseKey copy];
    NSUInteger epoch = binding.cacheEpoch;
    NSMutableDictionary *record = [@{ @"schema": @(FDMIconSchema), @"key": key, @"baseKey": base,
                                      @"signature": binding.signature, @"page": binding.page, @"kind": kind,
                                      @"display": bitmap ? binding.displayKey ?: @"" : @"theme-neutral-text",
                                      @"resource": FDMIconDigest(binding.resource ?: @"native"),
                                      @"source": binding.requested ? @"sd-raw-completion" : @"native-explicit-state",
                                      @"version": FDMPatchVersion(), @"revision": FDMBuildRevision(), @"epoch": @(epoch),
                                      @"scale": @(image ? image.scale : 1), @"orientation": @(image ? image.imageOrientation : 0),
                                      @"updated": @(NSDate.date.timeIntervalSince1970) } mutableCopy];
    CGImageRef pixels = bitmap ? CGImageRetain(image.CGImage) : NULL;
    dispatch_async(_io, ^{
        if ([self->_blockedBases containsObject:base]) { if (pixels) CGImageRelease(pixels); self->_diagnostics[key] = FDMIconBlockedDiagnostic(record); FDMIconChanged(); return; }
        if ([self->_epochs[base] unsignedIntegerValue] != epoch) { if (pixels) CGImageRelease(pixels); return; }
        if (image) [self->_images setObject:image forKey:key cost:CGImageGetWidth(pixels) * CGImageGetHeight(pixels) * 4];
        NSError *error = nil;
        NSData *encoded = nil;
        if (pixels) {
            NSMutableData *output = [NSMutableData new];
            CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)output, CFSTR("public.png"), 1, NULL);
            if (destination) {
                CGImageDestinationAddImage(destination, pixels, NULL);
                if (CGImageDestinationFinalize(destination)) encoded = [output copy];
                CFRelease(destination);
            }
            CGImageRelease(pixels);
        }
        BOOL encodedOK = !bitmap || (encoded.length && encoded.length <= FDMIconMaxEncodedBytes);
        if (encodedOK && bitmap) record[@"imageDigest"] = FDMIconDataDigest(encoded);
        NSData *json = encodedOK ? [NSJSONSerialization dataWithJSONObject:record options:0 error:&error] : nil;
        NSString *jsonPath = [self pathForKey:key extension:@"json"];
        NSString *imagePath = bitmap && encodedOK ? [self pathForKey:record[@"imageDigest"] extension:@"image"] : nil;
        unsigned long long oldJSON = [[[NSFileManager defaultManager] attributesOfItemAtPath:jsonPath error:nil][NSFileSize] unsignedLongLongValue];
        NSDictionary *imageAttributes = imagePath ? [NSFileManager.defaultManager attributesOfItemAtPath:imagePath error:nil] : nil;
        unsigned long long oldImageBytes = [imageAttributes[NSFileType] isEqual:NSFileTypeRegular] ? [imageAttributes[NSFileSize] unsignedLongLongValue] : 0;
        NSData *existingImage = oldImageBytes > 0 && oldImageBytes <= FDMIconMaxEncodedBytes ? [NSData dataWithContentsOfFile:imagePath options:0 error:nil] : nil;
        BOOL imageValid = bitmap && encodedOK && existingImage.length == encoded.length && existingImage.length > 0 &&
                          [FDMIconDataDigest(existingImage) isEqual:record[@"imageDigest"]];
        unsigned long long replacedBytes = imageValid ? 0 : oldImageBytes;
        unsigned long long addition = (imageValid ? 0 : encoded.length) + json.length;
        BOOL room = self->_diskBytes - MIN(self->_diskBytes, oldJSON + replacedBytes) + addition <= FDMIconMaxDiskBytes;
        BOOL wroteImage = room && encodedOK && (!bitmap || imageValid || [encoded writeToFile:imagePath options:NSDataWritingAtomic error:&error]);
        BOOL saved = wroteImage && json.length && [json writeToFile:jsonPath options:NSDataWritingAtomic error:&error];
        // Only verified blobs are reused. Repair this v19-derived blob atomically; JSON remains the commit point.
        if (wroteImage && bitmap && !imageValid) self->_diskBytes = self->_diskBytes - MIN(self->_diskBytes, oldImageBytes) + encoded.length;
        if (saved) { self->_diskBytes = self->_diskBytes - MIN(self->_diskBytes, oldJSON) + json.length; [self->_committed addObject:key]; }
        else [self->_committed removeObject:key];
        self->_records[key] = [record copy];
        [self->_invalidated removeObject:key];
        self->_diagnostics[key] = @{ @"key": key, @"url": FDMRedactedURL(record[@"page"]), @"kind": kind,
                                    @"source": @"producer", @"applied": @NO, @"diskCommitted": @(saved),
                                    @"error": saved ? @"" : (!encodedOK ? @"图片编码不可持久化" : room ? error.localizedDescription ?: @"写入失败" : @"新增缓存达到上限；已有文件未删除"),
                                    @"version": record[@"version"], @"updated": record[@"updated"] };
        FDMLog(@"icon: write key=%@ kind=%@ disk=%d error=%@", key, kind, saved, error.localizedDescription ?: @"");
        FDMIconChanged();
    });
}

- (NSArray<NSDictionary *> *)diagnostics {
    __block NSMutableArray *entries;
    dispatch_sync(_io, ^{
        entries = [NSMutableArray new];
        for (NSDictionary *record in self->_records.allValues) {
            [entries addObject:self->_diagnostics[record[@"key"]] ?: @{ @"key": record[@"key"], @"url": FDMRedactedURL(record[@"page"]),
                           @"kind": record[@"kind"], @"source": @"disk", @"applied": @NO, @"diskCommitted": @([self->_committed containsObject:record[@"key"]]),
                           @"error": @"", @"version": record[@"version"] ?: @"unknown", @"updated": record[@"updated"] ?: @0 }];
        }
        for (NSString *key in self->_diagnostics) if (!self->_records[key]) [entries addObject:self->_diagnostics[key]];
    });
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"updated"] compare:a[@"updated"]]; }];
    return entries;
}

- (NSDictionary *)invalidateEntry:(NSString *)key {
    __block NSDictionary *record;
    dispatch_sync(_io, ^{
        NSDictionary *candidate = self->_records[key];
        if (!candidate || [self->_blockedBases containsObject:candidate[@"baseKey"]]) return;
        NSString *base = candidate[@"baseKey"];
        NSUInteger next = [self->_epochs[base] unsignedIntegerValue] + 1;
        NSDictionary *journal = @{ @"schema": @(FDMIconSchema), @"baseKey": base, @"epoch": @(next), @"updated": @(NSDate.date.timeIntervalSince1970) };
        NSString *journalPath = [self pathForKey:base extension:@"epoch"];
        unsigned long long oldSize = [[NSFileManager.defaultManager attributesOfItemAtPath:journalPath error:nil][NSFileSize] unsignedLongLongValue];
        NSError *error = nil;
        if (!FDMWriteJSON(journal, journalPath, &error)) {
            NSMutableDictionary *diagnostic = [self->_diagnostics[key] mutableCopy] ?: [NSMutableDictionary new];
            [diagnostic addEntriesFromDictionary:@{ @"key": key, @"url": FDMRedactedURL(candidate[@"page"]), @"kind": candidate[@"kind"],
                @"source": @"refresh-failed", @"applied": diagnostic[@"applied"] ?: @NO,
                @"diskCommitted": @([self->_committed containsObject:key]), @"version": candidate[@"version"] ?: @"unknown",
                @"error": [@"刷新未提交；原缓存保留：" stringByAppendingString:error.localizedDescription ?: @"写入失败"], @"updated": @(NSDate.date.timeIntervalSince1970) }];
            self->_diagnostics[key] = diagnostic;
            FDMLog(@"icon refresh not committed: %@", error.localizedDescription);
            return;
        }
        unsigned long long newSize = [[NSFileManager.defaultManager attributesOfItemAtPath:journalPath error:nil][NSFileSize] unsignedLongLongValue];
        self->_diskBytes = self->_diskBytes - MIN(self->_diskBytes, oldSize) + newSize;
        self->_epochs[base] = @(next);
        record = candidate;
        // A single committed base epoch invalidates every display variant; no multi-file partial invalidation.
        for (NSString *related in [self->_records.allKeys copy]) {
            if (![self->_records[related][@"baseKey"] isEqual:base]) continue;
            [self->_records removeObjectForKey:related]; [self->_committed removeObject:related];
            [self->_invalidated addObject:related]; [self->_images removeObjectForKey:related]; [self->_diagnostics removeObjectForKey:related];
        }
    });
    FDMIconChanged();
    return record;
}
- (void)flush { if (!dispatch_get_specific(_queueIdentity)) dispatch_sync(_io, ^{}); }
@end

static NSHashTable<FDMIconBinding *> *FDMIconBindings;
static NSMutableDictionary<NSString *, NSValue *> *FDMIconOriginals;
static __weak FDMIconBinding *FDMActiveIconBinding;

static NSDictionary *FDMIconAdapter(id owner) {
    NSArray *specs = @[@[@"BookMarkCell", @"url", @"logoImage", @"logoText"],
                       @[@"HistoryCell", @"url", @"logoImage", @"logoText"],
                       @[@"CustomTagCell", @"targetUrl", @"logo", @"logoLabel"],
                       @[@"ContextMenuController", @"targetUrl", @"logo", @"logoLabel"]];
    for (NSArray *spec in specs) {
        Class cls = NSClassFromString(spec[0]);
        if (cls && [owner isKindOfClass:cls]) return @{ @"page": spec[1], @"image": spec[2], @"text": spec[3] };
    }
    return nil;
}

static IMP FDMIconOriginal(id owner, SEL selector) {
    for (Class cls = [owner class]; cls; cls = class_getSuperclass(cls)) {
        NSValue *value = FDMIconOriginals[[NSString stringWithFormat:@"%@|%@", NSStringFromClass(cls), NSStringFromSelector(selector)]];
        if (value) return [value pointerValue];
    }
    return NULL;
}

static void FDMIconCancel(UIImageView *view) {
    if (!view) return;
    SEL selector = NSSelectorFromString(@"sd_cancelCurrentImageLoad");
    if ([view respondsToSelector:selector]) ((void (*)(id, SEL))objc_msgSend)(view, selector);
}

static void FDMInvalidateOwner(id owner) {
    FDMIconBinding *old = objc_getAssociatedObject(owner, &FDMOwnerBindingKey);
    old.valid = NO;
    if (old.view && objc_getAssociatedObject(old.view, &FDMViewBindingKey) == old) objc_setAssociatedObject(old.view, &FDMViewBindingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    FDMIconCancel(old.view);
    objc_setAssociatedObject(owner, &FDMOwnerBindingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSUInteger generation = [objc_getAssociatedObject(owner, &FDMOwnerGenerationKey) unsignedIntegerValue] + 1;
    objc_setAssociatedObject(owner, &FDMOwnerGenerationKey, @(generation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL FDMIconBindingCurrent(FDMIconBinding *binding, NSUInteger serial) {
    id owner = binding.owner;
    if (!binding.valid || !owner || !binding.view || (serial && binding.requestSerial != serial) || FDMIconDark(owner) != binding.dark) return NO;
    if ([objc_getAssociatedObject(owner, &FDMOwnerGenerationKey) unsignedIntegerValue] != binding.generation) return NO;
    if (objc_getAssociatedObject(owner, &FDMOwnerBindingKey) != binding || objc_getAssociatedObject(binding.view, &FDMViewBindingKey) != binding) return NO;
    id model = FDMValue(owner, @"model");
    return [FDMIconPage(model, binding.pageKey) isEqual:binding.page] && [FDMIconContentSignature(model, binding.page) isEqual:binding.signature];
}

static void FDMStopIconSpinner(FDMIconBinding *binding) {
    id indicator = FDMValue(binding.owner, @"activityIndicator");
    if ([indicator isKindOfClass:UIActivityIndicatorView.class]) { [indicator stopAnimating]; [indicator setHidden:YES]; }
}

static BOOL FDMApplyTextIcon(FDMIconBinding *binding) {
    if (!FDMIconBindingCurrent(binding, 0) || ![binding.textView isKindOfClass:UILabel.class]) return NO;
    id owner = binding.owner;
    SEL own = NSSelectorFromString(@"setupTextLogo");
    if ([owner respondsToSelector:own]) ((void (*)(id, SEL))objc_msgSend)(owner, own);
    else {
        Class cls = NSClassFromString(@"IconCacheManager");
        SEL shared = NSSelectorFromString(@"sharedInstance");
        SEL setup = NSSelectorFromString(@"setupTextLogoWithTitle:logoLabel:url:");
        id manager = cls && [cls respondsToSelector:shared] ? ((id (*)(id, SEL))objc_msgSend)(cls, shared) : nil;
        if (![manager respondsToSelector:setup]) return NO;
        NSString *title = FDMString(FDMValue(FDMValue(owner, @"model"), @"title")) ?: @"";
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(manager, setup, title, binding.textView, binding.page);
    }
    binding.view.hidden = YES;
    binding.textView.hidden = NO;
    SEL theme = NSSelectorFromString(@"applyTheme");
    if ([owner respondsToSelector:theme]) ((void (*)(id, SEL))objc_msgSend)(owner, theme);
    FDMStopIconSpinner(binding);
    return YES;
}

static NSString *FDMIconContextSignature(NSDictionary *context) {
    NSMutableArray *parts = [NSMutableArray new];
    for (id key in [[context allKeys] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) { return [[a description] compare:[b description]]; }]) {
        id value = context[key];
        if (![key isKindOfClass:NSString.class]) return nil;
        if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSValue.class])
            [parts addObject:[NSString stringWithFormat:@"%@=%@", key, value]];
        else return nil; // An unknown transformer/loader object cannot be identified only by its class.
    }
    return FDMIconDigest([parts componentsJoinedByString:@"|"]);
}

static void FDMIconConfigureDisplay(FDMIconBinding *binding, NSURL *resource, NSDictionary *context) {
    binding.resource = resource.absoluteString ?: FDMString(FDMValue(FDMValue(binding.owner, @"model"), @"iconUrl")) ?: @"native";
    binding.displayScale = binding.view.traitCollection.displayScale ?: UIScreen.mainScreen.scale;
    CGSize size = CGSizeZero;
    id thumbnail = context[@"imageThumbnailPixelSize"];
    if ([thumbnail isKindOfClass:NSValue.class] && strcmp([(NSValue *)thumbnail objCType], @encode(CGSize)) == 0) {
        CGSize pixels = [thumbnail CGSizeValue];
        if (pixels.width > 0 && pixels.height > 0) size = CGSizeMake(pixels.width / binding.displayScale, pixels.height / binding.displayScale);
    }
    BOOL knownSize = size.width > 0 && size.height > 0;
    binding.targetSize = size;
    binding.dark = FDMIconDark(binding.owner);
    // Layout-free raster requests share an explicit natural-size condition; they never store a transient 0x0 key.
    NSString *sizeKey = knownSize ? [NSString stringWithFormat:@"%.2fx%.2f", size.width, size.height] : @"natural-raster";
    NSString *contextKey = FDMIconContextSignature(context ?: @{});
    binding.displayKey = [NSString stringWithFormat:@"resource:%@|theme:%d|target:%@|scale:%.2f|context:%@",
                          FDMIconDigest(binding.resource), binding.dark, sizeKey, binding.displayScale, contextKey ?: @"unsupported"];
    binding.entryKey = contextKey ? FDMIconDigest([binding.baseKey stringByAppendingFormat:@"|%@", binding.displayKey]) : nil;
}

static BOOL FDMApplyBitmapIcon(FDMIconBinding *binding, UIImage *image, FDMUICompletion completion, NSURL *url) {
    if (!image || !FDMIconBindingCurrent(binding, 0)) return NO;
    FDMIconCancel(binding.view);
    binding.acceptedBitmap = YES;
    binding.view.image = image;
    binding.view.hidden = NO;
    binding.textView.hidden = YES;
    if (completion) {
        FDMIconBinding *previous = FDMActiveIconBinding; FDMActiveIconBinding = binding;
        completion(image, nil, 1, url); // SDImageCacheTypeDisk = 1.
        FDMActiveIconBinding = previous;
    }
    else {
        SEL selector = NSSelectorFromString(@"applyTheme");
        if ([binding.owner respondsToSelector:selector]) ((void (*)(id, SEL))objc_msgSend)(binding.owner, selector);
    }
    FDMStopIconSpinner(binding);
    return binding.view.image != nil;
}

static BOOL FDMIconCanPersistFailure(NSError *error) {
    if (![error isKindOfClass:NSError.class]) return NO;
    NSHashTable *seen = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality | NSPointerFunctionsStrongMemory];
    NSError *current = error;
    for (NSUInteger depth = 0; depth < 8; depth++) {
        if ([seen containsObject:current]) return NO;
        [seen addObject:current];
        if (([current.domain isEqual:NSURLErrorDomain] && current.code == NSURLErrorCancelled) ||
            ([current.domain isEqual:@"SDWebImageErrorDomain"] && current.code == 2002)) return NO;
        id underlying = current.userInfo[NSUnderlyingErrorKey];
        if (!underlying) return YES;
        if (![underlying isKindOfClass:NSError.class]) return NO;
        current = underlying;
    }
    return NO; // Truncated/cyclic attribution is not proof of a permanent site failure.
}

static void FDMIconLongImage(id view, SEL selector, NSURL *url, UIImage *placeholder, NSUInteger options,
                             NSDictionary *context, id progress, id completed) {
    FDMIconBinding *binding = objc_getAssociatedObject(view, &FDMViewBindingKey);
    if (!binding || !FDMIconBindingCurrent(binding, 0)) {
        FDMOriginalLongImage(view, selector, url, placeholder, options, context, progress, completed);
        return;
    }
    FDMIconConfigureDisplay(binding, url, context);
    binding.requested = YES;
    NSUInteger serial = ++binding.requestSerial;
    FDMIconCancel(binding.view);
    NSString *source = nil;
    NSDictionary *fallback = [[FDMIconStore shared] recordForKey:FDMIconDigest([binding.baseKey stringByAppendingString:@"|text"]) source:&source];
    if (fallback && FDMApplyTextIcon(binding)) {
        binding.lastSource = source;
        [[FDMIconStore shared] markApplied:fallback[@"key"] source:source success:YES];
        FDMLog(@"icon: hit=%@ applied=text %@", source, FDMRedactedURL(binding.page));
        return;
    }
    NSDictionary *record = [[FDMIconStore shared] recordForKey:binding.entryKey source:&source];
    UIImage *cached = [record[@"kind"] isEqual:@"bitmap"] ? [[FDMIconStore shared] imageForRecord:record] : nil;
    if (cached && FDMApplyBitmapIcon(binding, cached, completed, url)) {
        binding.lastSource = source;
        [[FDMIconStore shared] markApplied:record[@"key"] source:source success:YES];
        FDMLog(@"icon: hit=%@ applied=bitmap %@", source, FDMRedactedURL(binding.page));
        return;
    }
    FDMUICompletion original = completed;
    __weak FDMIconBinding *weakBinding = binding;
    FDMUICompletion wrap = ^(UIImage *image, NSError *error, NSInteger cacheType, NSURL *imageURL) {
        FDMIconBinding *current = weakBinding;
        if (!FDMIconBindingCurrent(current, serial)) return;
        if (original) {
            FDMIconBinding *previous = FDMActiveIconBinding; FDMActiveIconBinding = current;
            original(image, error, cacheType, imageURL);
            FDMActiveIconBinding = previous;
        }
        if (!FDMIconBindingCurrent(current, serial)) return;
        if (image && !error) {
            if (!original) { current.view.hidden = NO; current.textView.hidden = YES; }
            current.acceptedBitmap = YES;
            current.lastSource = @"network-or-sdk-cache";
            // Preserve the loader result, not the native appearance-transformed UIImageView pixels.
            [[FDMIconStore shared] storeKind:@"bitmap" binding:current image:image];
            [[FDMIconStore shared] markApplied:current.entryKey source:@"producer" success:current.view.image != nil && !current.view.hidden];
            FDMStopIconSpinner(current);
        } else if (FDMIconCanPersistFailure(error) && !current.acceptedBitmap && current.entryKey.length && FDMApplyTextIcon(current)) {
            [[FDMIconStore shared] storeKind:@"textFallback" binding:current image:nil];
            [[FDMIconStore shared] markApplied:FDMIconDigest([current.baseKey stringByAppendingString:@"|text"]) source:@"producer" success:YES];
        }
    };
    FDMLog(@"icon: hit=miss request=%lu %@", (unsigned long)serial, FDMRedactedURL(binding.page));
    FDMOriginalLongImage(view, selector, url, placeholder, options, context, progress, wrap);
}

static id FDMIconInternalImage(id view, SEL selector, NSURL *url, UIImage *placeholder, NSUInteger options,
                              NSDictionary *context, id setter, id progress, id completed) {
    FDMIconBinding *binding = objc_getAssociatedObject(view, &FDMViewBindingKey);
    if (!binding || !binding.requested || !binding.requestSerial || !FDMIconBindingCurrent(binding, 0)) return FDMOriginalInternalImage(view, selector, url, placeholder, options, context, setter, progress, completed);
    NSUInteger serial = binding.requestSerial;
    FDMImageSetter originalSetter = setter;
    FDMInternalCompletion originalCompleted = completed;
    __weak FDMIconBinding *weakBinding = binding;
    FDMImageSetter guardedSetter = ^(UIImage *image, NSData *data, NSInteger cacheType, NSURL *imageURL) {
        FDMIconBinding *current = weakBinding;
        if (!FDMIconBindingCurrent(current, serial)) return;
        if (originalSetter) originalSetter(image, data, cacheType, imageURL);
        else current.view.image = image; // Native internal default setter is plain UIImageView assignment at this boundary.
    };
    FDMInternalCompletion guardedCompletion = ^(UIImage *image, NSData *data, NSError *error, NSInteger cacheType, BOOL finished, NSURL *imageURL) {
        FDMIconBinding *current = weakBinding;
        if (!FDMIconBindingCurrent(current, serial)) return;
        if (originalCompleted) originalCompleted(image, data, error, cacheType, finished, imageURL);
    };
    return FDMOriginalInternalImage(view, selector, url, placeholder, options, context, guardedSetter, progress, guardedCompletion);
}

static void FDMIconSetup(id owner, SEL selector, id model) {
    IMP original = FDMIconOriginal(owner, selector);
    NSDictionary *adapter = FDMIconAdapter(owner);
    NSString *page = FDMIconPage(model, adapter[@"page"]);
    UIImageView *view = FDMValue(owner, adapter[@"image"]);
    UIView *text = FDMValue(owner, adapter[@"text"]);
    FDMInvalidateOwner(owner);
    if (!adapter || !page.length || ![view isKindOfClass:UIImageView.class] || ![text isKindOfClass:UIView.class]) {
        if (original) ((void (*)(id, SEL, id))original)(owner, selector, model);
        return;
    }
    FDMIconBinding *binding = [FDMIconBinding new];
    binding.owner = owner; binding.view = view; binding.textView = text;
    binding.pageKey = adapter[@"page"]; binding.page = page;
    binding.signature = FDMIconContentSignature(model, page);
    binding.baseKey = FDMIconDigest([page stringByAppendingFormat:@"|%@", binding.signature]);
    binding.cacheEpoch = [[FDMIconStore shared] epochForBase:binding.baseKey];
    binding.generation = [objc_getAssociatedObject(owner, &FDMOwnerGenerationKey) unsignedIntegerValue];
    binding.valid = YES; binding.dark = FDMIconDark(owner);
    objc_setAssociatedObject(owner, &FDMOwnerBindingKey, binding, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &FDMViewBindingKey, binding, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!FDMIconBindings) FDMIconBindings = [NSHashTable weakObjectsHashTable];
    [FDMIconBindings addObject:binding];
    // Always retain native initialization/layout/theme. The actual SD boundary handles typed hits.
    FDMIconBinding *previous = FDMActiveIconBinding; FDMActiveIconBinding = binding;
    if (original) ((void (*)(id, SEL, id))original)(owner, selector, model);
    FDMActiveIconBinding = previous;
    if (!FDMIconBindingCurrent(binding, 0)) return;
    if (binding.requested) { if (binding.lastSource) FDMStopIconSpinner(binding); return; }
    FDMIconConfigureDisplay(binding, nil, nil);
    if (!text.hidden && view.hidden) {
        binding.lastSource = @"native-text";
        [[FDMIconStore shared] storeKind:@"textFallback" binding:binding image:nil];
        [[FDMIconStore shared] markApplied:FDMIconDigest([binding.baseKey stringByAppendingString:@"|text"]) source:@"native" success:YES];
    } else if (view.image && !view.hidden) {
        binding.acceptedBitmap = YES;
        binding.lastSource = @"native";
        [[FDMIconStore shared] storeKind:@"bitmap" binding:binding image:view.image];
        [[FDMIconStore shared] markApplied:binding.entryKey source:@"native" success:YES];
    }
    FDMStopIconSpinner(binding);
}

static void FDMIconUpdate(id owner, SEL selector, id model) {
    IMP original = FDMIconOriginal(owner, selector);
    FDMInvalidateOwner(owner);
    if (original) ((void (*)(id, SEL, id))original)(owner, selector, model);
}
static void FDMIconBookmarkUpdate(id owner, SEL selector, id model, NSInteger operation) {
    IMP original = FDMIconOriginal(owner, selector);
    FDMInvalidateOwner(owner);
    if (original) ((void (*)(id, SEL, id, NSInteger))original)(owner, selector, model, operation);
}
static void FDMIconPrepareReuse(id owner, SEL selector) {
    IMP original = FDMIconOriginal(owner, selector);
    FDMInvalidateOwner(owner);
    if (original) ((void (*)(id, SEL))original)(owner, selector);
}

static void FDMIconApplyTheme(id owner, SEL selector) {
    IMP original = FDMIconOriginal(owner, selector);
    FDMIconBinding *binding = objc_getAssociatedObject(owner, &FDMOwnerBindingKey);
    BOOL transitioning = [objc_getAssociatedObject(owner, &FDMThemeTransitionKey) boolValue];
    if (!binding || binding.dark == FDMIconDark(owner) || transitioning) {
        if (original) ((void (*)(id, SEL))original)(owner, selector);
        return;
    }
    objc_setAssociatedObject(owner, &FDMThemeTransitionKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try {
        FDMStopIconSpinner(binding);
        FDMInvalidateOwner(owner);
        SEL setProtection = NSSelectorFromString(@"setShouldProtectDarkLogo:");
        SEL setKey = NSSelectorFromString(@"setProtectionCacheKey:");
        if ([owner respondsToSelector:setProtection]) ((void (*)(id, SEL, BOOL))objc_msgSend)(owner, setProtection, NO);
        if ([owner respondsToSelector:setKey]) ((void (*)(id, SEL, id))objc_msgSend)(owner, setKey, nil);
        if (original) ((void (*)(id, SEL))original)(owner, selector);
        SEL setup = NSSelectorFromString(@"setupLogoForModel:");
        if ([owner respondsToSelector:setup]) ((void (*)(id, SEL, id))objc_msgSend)(owner, setup, FDMValue(owner, @"model"));
        FDMIconBinding *current = objc_getAssociatedObject(owner, &FDMOwnerBindingKey);
        // New theme may still be preparing; show native text without recording a permanent failure.
        if (current.requested && !current.lastSource && !current.acceptedBitmap) FDMApplyTextIcon(current);
        if (current) FDMStopIconSpinner(current);
    } @finally {
        objc_setAssociatedObject(owner, &FDMThemeTransitionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void FDMIconProtection(id manager, SEL selector, UIImage *image, NSString *cacheKey, id completion) {
    // Native icon owner callbacks only update a BOOL and then current appearance, but must not apply old-theme decisions.
    FDMIconBinding *binding = FDMActiveIconBinding;
    if (!FDMIconBindingCurrent(binding, 0) || ![FDMValue(binding.owner, @"protectionCacheKey") isEqual:cacheKey] || !completion) {
        ((void (*)(id, SEL, id, id, id))FDMOriginalProtection)(manager, selector, image, cacheKey, completion);
        return;
    }
    void (^original)(BOOL) = completion;
    NSUInteger serial = binding.requestSerial;
    __weak FDMIconBinding *weak = binding;
    ((void (*)(id, SEL, id, id, id))FDMOriginalProtection)(manager, selector, image, cacheKey, ^(BOOL protect) {
        if (FDMIconBindingCurrent(weak, serial)) original(protect);
    });
}

static void FDMIconInstall(Class cls, SEL selector, IMP replacement) {
    if (!cls) return;
    Method method = class_getInstanceMethod(cls, selector);
    NSString *key = [NSString stringWithFormat:@"%@|%@", NSStringFromClass(cls), NSStringFromSelector(selector)];
    if (!method || FDMIconOriginals[key]) return;
    IMP original = method_getImplementation(method);
    FDMIconOriginals[key] = [NSValue valueWithPointer:original];
    if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) method_setImplementation(method, replacement);
}

static BOOL FDMIconMethodABI(Method method, const char *returnType, NSUInteger arguments) {
    if (!method || method_getNumberOfArguments(method) != arguments) return NO;
    char result[8] = {0}; method_getReturnType(method, result, sizeof(result));
    if (result[0] != returnType[0]) return NO;
    for (NSUInteger i = 2; i < arguments; i++) {
        char type[16] = {0}; method_getArgumentType(method, (unsigned int)i, type, sizeof(type));
        if (arguments >= 8 && i == 4) { if (type[0] != 'Q') return NO; }
        else if (type[0] != '@') return NO;
    }
    return YES;
}

void FDMInstallIconHooks(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ FDMInstallIconHooks(); }); return; }
    if (!FDMIconOriginals) FDMIconOriginals = [NSMutableDictionary new];
    SEL longSelector = NSSelectorFromString(@"sd_setImageWithURL:placeholderImage:options:context:progress:completed:");
    SEL internal = NSSelectorFromString(@"sd_internalSetImageWithURL:placeholderImage:options:context:setImageBlock:progress:completed:");
    Class imageClass = UIImageView.class;
    Method longMethod = class_getInstanceMethod(imageClass, longSelector);
    Method internalMethod = class_getInstanceMethod(imageClass, internal);
    // Install the pair only after both live ABIs have been checked; otherwise leave every owner untouched.
    if (!FDMIconMethodABI(longMethod, "v", 8) || !FDMIconMethodABI(internalMethod, "@", 9)) {
        FDMLog(@"icon: verified SD ABI unavailable; all owner hooks deferred");
        return;
    }
    if (!FDMOriginalLongImage && !FDMOriginalInternalImage) {
        FDMOriginalLongImage = (FDMLongImageIMP)method_getImplementation(longMethod);
        FDMOriginalInternalImage = (FDMInternalImageIMP)method_getImplementation(internalMethod);
        FDMIconInstall(imageClass, longSelector, (IMP)FDMIconLongImage);
        FDMIconInstall(imageClass, internal, (IMP)FDMIconInternalImage);
    }
    for (NSString *name in @[@"BookMarkCell", @"HistoryCell", @"CustomTagCell", @"ContextMenuController"]) {
        Class cls = NSClassFromString(name);
        FDMIconInstall(cls, NSSelectorFromString(@"setupLogoForModel:"), (IMP)FDMIconSetup);
        FDMIconInstall(cls, NSSelectorFromString(@"updateWithModel:"), (IMP)FDMIconUpdate);
        FDMIconInstall(cls, NSSelectorFromString(@"updateWithModel:batchOperation:"), (IMP)FDMIconBookmarkUpdate);
        SEL theme = NSSelectorFromString(@"applyTheme");
        if (FDMIconMethodABI(class_getInstanceMethod(cls, theme), "v", 2)) FDMIconInstall(cls, theme, (IMP)FDMIconApplyTheme);
        if ([name hasSuffix:@"Cell"]) FDMIconInstall(cls, @selector(prepareForReuse), (IMP)FDMIconPrepareReuse);
    }
    if (!FDMOriginalProtection) {
        Class cls = NSClassFromString(@"IconCacheManager");
        SEL selector = NSSelectorFromString(@"resolveDarkModeProtectionForImage:cacheKey:completion:");
        Method method = class_getInstanceMethod(cls, selector);
        if (FDMIconMethodABI(method, "v", 5)) { FDMOriginalProtection = method_getImplementation(method); FDMIconInstall(cls, selector, (IMP)FDMIconProtection); }
    }
    FDMLog(@"icon: boundaries installed %@ revision=%@", FDMPatchVersion(), FDMBuildRevision());
}

void FDMFlushIconWrites(void) { [[FDMIconStore shared] flush]; }
NSArray<NSDictionary *> *FDMIconDiagnosticEntries(void) { return [[FDMIconStore shared] diagnostics]; }
void FDMRefreshIcon(NSString *entryKey) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ FDMRefreshIcon(entryKey); }); return; }
    NSDictionary *record = [[FDMIconStore shared] invalidateEntry:entryKey];
    if (!record) return;
    NSMutableArray *owners = [NSMutableArray new];
    for (FDMIconBinding *binding in FDMIconBindings.allObjects) {
        if ([binding.baseKey isEqual:record[@"baseKey"]] && binding.owner) { [owners addObject:binding.owner]; FDMInvalidateOwner(binding.owner); }
    }
    for (id owner in owners) {
        SEL setup = NSSelectorFromString(@"setupLogoForModel:");
        if ([owner respondsToSelector:setup]) ((void (*)(id, SEL, id))objc_msgSend)(owner, setup, FDMValue(owner, @"model"));
    }
    FDMLog(@"icon: explicit refresh key=%@ %@", entryKey, FDMRedactedURL(record[@"page"]));
}

#ifdef FDM_TESTING
void FDMReloadIconStoreForTesting(void) {
    NSCAssert(NSThread.isMainThread, @"Icon tests require UIKit main thread");
    [FDMSharedIconStore flush];
    FDMSharedIconStore = [FDMIconStore new];
}
NSString *FDMIconEntryKeyForTesting(id owner) {
    FDMIconBinding *binding = objc_getAssociatedObject(owner, &FDMOwnerBindingKey);
    return binding.entryKey ?: @"";
}
void FDMReplayStaleIconWriteForTesting(id owner) {
    FDMIconBinding *binding = objc_getAssociatedObject(owner, &FDMOwnerBindingKey);
    if (!binding) return;
    NSString *key = binding.entryKey;
    FDMIconBinding *stale = binding;
    [[FDMIconStore shared] invalidateEntry:key];
    // Deliberately submit an old producer after explicit invalidation; the real store's epoch gate must reject it.
    [[FDMIconStore shared] storeKind:@"bitmap" binding:stale image:stale.view.image];
    FDMFlushIconWrites();
}
#endif
