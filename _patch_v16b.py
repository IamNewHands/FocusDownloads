# -*- coding: utf-8 -*-
"""v16b: 图标统一走 SDWebImage 钩子 + 命中即跳过下载 + 入口日志"""
import io, sys

P = 'src/FocusDM.m'
s = io.open(P, encoding='utf-8').read()
n0 = len(s)

def rep(old, new, label):
    global s
    if old not in s:
        print('MISS:', label); sys.exit(1)
    if s.count(old) != 1:
        print('DUP(%d):' % s.count(old), label); sys.exit(1)
    s = s.replace(old, new)
    print('ok:', label)

# 1) 入口无条件日志（只打前 6 条），并把 key 兜底到 url
rep("""static void FDMSetupLogoForModel(id self, SEL _cmd, id model) {
    NSString *iconURL = FDMIconURLForModel(model);""",
"""static void FDMSetupLogoForModel(id self, SEL _cmd, id model) {
    static NSInteger entry = 0;
    if (entry < 6) {
        entry++;
        NSString *iu = nil, *pu = nil;
        @try { iu = FDMString([model valueForKey:@"iconUrl"]); } @catch (NSException *e) { (void)e; }
        @try { pu = FDMString([model valueForKey:@"url"]); } @catch (NSException *e) { (void)e; }
        FDMLog(@"icon: setupLogoForModel #%ld cls=%@ iconUrl=%@ url=%@",
               (long)entry, NSStringFromClass([self class]), iu, pu);
    }
    NSString *iconURL = FDMIconURLForModel(model);""", 'hook entry log')

# 2) SDWebImage 统一钩子：图标一律先查磁盘缓存，命中就不再发请求
rep("""#pragma mark - 设置页插入「下载管理」行（直接改数据源，复用原生 cell）""",
"""#pragma mark - 统一图标缓存钩子（SDWebImage）

typedef void (*FDMSDSetImageIMP)(id, SEL, NSURL *, UIImage *, NSUInteger, id);
static FDMSDSetImageIMP g_origSDSetImage = NULL;

static void FDMSDSetImageCompleted(id self, SEL _cmd, NSURL *url, UIImage *placeholder,
                                   NSUInteger options, id completedBlock) {
    NSString *key = url.absoluteString;
    if (key.length) {
        UIImage *cached = [[FDMImageCache shared] cachedImageForURL:key];
        if (cached) {
            // 命中磁盘缓存：直接给图、完全不发请求，这正是「进主页图标不再重载」的关键
            ((void (*)(id, SEL, UIImage *))objc_msgSend)(self, @selector(setImage:), cached);
            if (completedBlock) {
                void (^done)(UIImage *, NSData *, NSError *, NSInteger, BOOL, NSURL *) = completedBlock;
                done(cached, nil, nil, 3, YES, url);
            }
            static NSInteger hits = 0;
            if (hits < 5) { hits++; FDMLog(@"icon: sdhit %@", key); }
            return;
        }
        static NSInteger miss = 0;
        if (miss < 8) { miss++; FDMLog(@"icon: sdmiss %@", key); }
    }

    if (!g_origSDSetImage) return;
    if (!key.length || !completedBlock) {
        g_origSDSetImage(self, _cmd, url, placeholder, options, completedBlock);
        return;
    }

    // 没命中：转发给原生，完成后把图落盘，下次启动就能直接命中
    void (^done)(UIImage *, NSData *, NSError *, NSInteger, BOOL, NSURL *) = completedBlock;
    void (^wrap)(UIImage *, NSData *, NSError *, NSInteger, BOOL, NSURL *) =
    ^(UIImage *image, NSData *data, NSError *error, NSInteger cacheType, BOOL finished, NSURL *imageURL) {
        if (image && finished) {
            [[FDMImageCache shared] storeImage:image forURL:key];
            FDMLog(@"icon: sdstored %@", key);
        }
        done(image, data, error, cacheType, finished, imageURL);
    };
    g_origSDSetImage(self, _cmd, url, placeholder, options, (id)wrap);
}

static void FDMInstallImageHook(void) {
    Class cls = NSClassFromString(@"UIImageView");
    SEL sel = NSSelectorFromString(@"sd_setImageWithURL:placeholderImage:options:completed:");
    if (!cls || !sel) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { FDMLog(@"hook: sd_setImage not found"); return; }
    g_origSDSetImage = (FDMSDSetImageIMP)method_getImplementation(m);
    method_setImplementation(m, (IMP)FDMSDSetImageCompleted);
    FDMLog(@"hook: sd_setImageWithURL installed");
}

#pragma mark - 设置页插入「下载管理」行（直接改数据源，复用原生 cell）""", 'sd_setImage hook')

# 3) 构造函数里装上
rep("""        FDMInstallHook(cls, @selector(viewWillAppear:), (IMP)FDMSettingsWillAppear, &g_origWillAppear);""",
"""        FDMInstallImageHook();
        FDMInstallHook(cls, @selector(viewWillAppear:), (IMP)FDMSettingsWillAppear, &g_origWillAppear);""",
    'install image hook')

io.open(P, 'w', encoding='utf-8', newline='\n').write(s)
print('bytes %d -> %d' % (n0, len(s)))
