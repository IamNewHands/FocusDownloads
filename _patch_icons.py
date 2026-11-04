import io

p = 'src/FocusDM.m'
s = io.open(p, encoding='utf-8').read()

block = r'''#pragma mark - 主页书签图标磁盘缓存

// 目的：主页书签/收藏的图标原本每次进页面都从空白开始重新拉取，
// 这里做一层自己的磁盘缓存：命中就直接同步填图，未命中后台下载并落盘。

static NSString *FDMIconKey(NSString *url) {
    if (!url.length) return nil;
    const char *p = url.UTF8String;
    if (!p) return nil;
    uint64_t h = 1469598103934665603ULL;
    while (*p) { h ^= (unsigned char)(*p++); h *= 1099511628211ULL; }
    return [NSString stringWithFormat:@"%016llx", h];
}

@interface FDMImageCache : NSObject
+ (instancetype)shared;
- (UIImage *)cachedImageForURL:(NSString *)url;
- (void)storeImage:(UIImage *)image forURL:(NSString *)url;
- (void)prefetchURL:(NSString *)url;
- (BOOL)isPending:(NSString *)url;
@end

@implementation FDMImageCache {
    NSCache *_memory;
    NSMutableSet *_pending;
    NSString *_dir;
    dispatch_queue_t _ioQueue;
}

+ (instancetype)shared {
    static FDMImageCache *one = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ one = [[FDMImageCache alloc] init]; });
    return one;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _memory = [[NSCache alloc] init];
        _memory.countLimit = 512;
        _pending = [NSMutableSet set];
        _ioQueue = dispatch_queue_create("com.focusdm.icons", DISPATCH_QUEUE_SERIAL);
        _dir = [FDMDocumentsPath() stringByAppendingPathComponent:@"FocusDM/icons"];
        [[NSFileManager defaultManager] createDirectoryAtPath:_dir
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:NULL];
        FDMLog(@"icon cache dir ready");
    }
    return self;
}

- (NSString *)pathForURL:(NSString *)url {
    NSString *key = FDMIconKey(url);
    return key ? [_dir stringByAppendingPathComponent:key] : nil;
}

- (UIImage *)cachedImageForURL:(NSString *)url {
    if (!url.length) return nil;
    UIImage *hit = [_memory objectForKey:url];
    if (hit) return hit;
    NSString *path = [self pathForURL:url];
    if (!path) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) return nil;
    UIImage *img = [UIImage imageWithData:data];
    if (!img) return nil;
    [_memory setObject:img forKey:url];
    return img;
}

- (void)storeImage:(UIImage *)image forURL:(NSString *)url {
    if (!image || !url.length) return;
    [_memory setObject:image forKey:url];
    NSString *path = [self pathForURL:url];
    if (!path) return;
    NSData *data = UIImagePNGRepresentation(image);
    if (!data.length) return;
    dispatch_async(_ioQueue, ^{
        [data writeToFile:path atomically:YES];
    });
}

- (BOOL)isPending:(NSString *)url {
    if (!url.length) return NO;
    @synchronized (self) { return [_pending containsObject:url]; }
}

- (void)prefetchURL:(NSString *)url {
    if (!url.length) return;
    if ([self cachedImageForURL:url]) return;
    @synchronized (self) {
        if ([_pending containsObject:url]) return;
        [_pending addObject:url];
    }

    NSURL *u = [NSURL URLWithString:url];
    if (!u) { @synchronized (self) { [_pending removeObject:url]; } return; }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
    req.timeoutInterval = 12.0;

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
                                                                completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2) return;
        UIImage *img = nil;
        if (data.length && !err) img = [UIImage imageWithData:data];
        if (img) {
            [self2 storeImage:img forURL:url];
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:@"FDMIconCached"
                                                                    object:nil
                                                                  userInfo:@{ @"url": url }];
            });
        }
        @synchronized (self2) { [_pending removeObject:url]; }
    }];
    [task resume];
}

@end

static NSString *FDMIconURLForModel(id model) {
    if (!model) return nil;
    NSString *icon = nil;
    @try {
        id v = [model valueForKey:@"iconUrl"];
        if ([v isKindOfClass:[NSString class]]) icon = v;
    } @catch (NSException *e) { (void)e; }
    if (icon.length) return icon;

    NSString *page = nil;
    @try {
        id v = [model valueForKey:@"url"];
        if ([v isKindOfClass:[NSString class]]) page = v;
    } @catch (NSException *e) { (void)e; }
    if (!page.length) return nil;

    NSString *host = [NSURL URLWithString:page].host;
    if (!host.length) return nil;
    return [NSString stringWithFormat:@"https://%@/favicon.ico", host];
}

static IMP g_origSetupLogo = NULL;

static void FDMSetupLogoForModel(id self, SEL _cmd, id model) {
    NSString *iconURL = FDMIconURLForModel(model);
    if (iconURL.length) {
        UIImage *cached = [[FDMImageCache shared] cachedImageForURL:iconURL];
        if (cached) {
            @try {
                UIImageView *iv = [self valueForKey:@"logoImage"];
                if ([iv isKindOfClass:[UIImageView class]]) {
                    iv.image = cached;
                    iv.hidden = NO;
                    UIView *text = [self valueForKey:@"logoText"];
                    if ([text isKindOfClass:[UIView class]]) text.hidden = YES;
                }
            } @catch (NSException *e) { (void)e; }
        }
    }

    if (g_origSetupLogo) ((void (*)(id, SEL, id))g_origSetupLogo)(self, _cmd, model);

    // 原始实现没拿到图时，自己下载一次并落盘，供下次进页面秒开
    if (iconURL.length) {
        UIImage *now = nil;
        @try {
            UIImageView *iv = [self valueForKey:@"logoImage"];
            if ([iv isKindOfClass:[UIImageView class]]) now = iv.image;
        } @catch (NSException *e) { (void)e; }
        if (!now && ![[FDMImageCache shared] isPending:iconURL]) {
            [[FDMImageCache shared] prefetchURL:iconURL];
        } else if (now && ![[FDMImageCache shared] cachedImageForURL:iconURL]) {
            [[FDMImageCache shared] storeImage:now forURL:iconURL];
        }
    }
}

'''

marker = '#pragma mark - 设置页插入「下载管理」行（直接改数据源，复用原生 cell）'
assert s.count(marker) == 1
s = s.replace(marker, block + marker)

# 构造函数里注册图标钩子
old = '''        FDMInstallHook(cls, @selector(tableView:didSelectRowAtIndexPath:), (IMP)FDMSettingsDidSelect, &g_origSelect);'''
new = old + '''
        Class cell = NSClassFromString(@"BookMarkCell");
        if (cell) FDMInstallHook(cell, @selector(setupLogoForModel:), (IMP)FDMSetupLogoForModel, &g_origSetupLogo);'''
assert s.count(old) == 1
s = s.replace(old, new)

io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('ok', len(s))
