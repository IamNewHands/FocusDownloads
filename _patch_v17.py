# -*- coding: utf-8 -*-
"""v17: 主页/书签图标改为「按页面 URL 的整块 logo 快照」缓存；工具栏意见反馈改成下载管理入口。"""
import io, sys

P = 'src/FocusDM.m'
s = io.open(P, encoding='utf-8').read()
orig_len = len(s)

# ---------- E1: 快照缓存 + 渲染/采集 helper ----------
anchor1 = 'static IMP g_origSetupLogo = NULL;'
assert s.count(anchor1) == 1
e1 = anchor1 + r'''

// ---- 按页面 URL 的 logo 快照缓存（整块渲染，与网络无关） ----
@interface FDMSnapCache : NSObject
+ (instancetype)shared;
- (UIImage *)imageForKey:(NSString *)key;
- (void)storeImage:(UIImage *)image forKey:(NSString *)key;
@end

@implementation FDMSnapCache {
    NSCache *_memory;
    NSString *_dir;
    dispatch_queue_t _io;
}

+ (instancetype)shared {
    static FDMSnapCache *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[FDMSnapCache alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _memory = [[NSCache alloc] init];
        _memory.countLimit = 300;
        _io = dispatch_queue_create("focusdm.snap", DISPATCH_QUEUE_SERIAL);
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        _dir = [[docs stringByAppendingPathComponent:@"FocusDM"] stringByAppendingPathComponent:@"snaps"];
        [[NSFileManager defaultManager] createDirectoryAtPath:_dir withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    return self;
}

- (NSString *)pathForKey:(NSString *)key {
    if (!key.length) return nil;
    return [_dir stringByAppendingPathComponent:key];
}

- (UIImage *)imageForKey:(NSString *)key {
    if (!key.length) return nil;
    UIImage *hit = [_memory objectForKey:key];
    if (hit) return hit;
    NSData *data = [NSData dataWithContentsOfFile:[self pathForKey:key]];
    if (!data.length) return nil;
    UIImage *img = [UIImage imageWithData:data];
    if (img) [_memory setObject:img forKey:key];
    return img;
}

- (void)storeImage:(UIImage *)image forKey:(NSString *)key {
    if (!image || !key.length) return;
    [_memory setObject:image forKey:key];
    NSData *data = UIImagePNGRepresentation(image);
    if (!data.length) return;
    NSString *path = [self pathForKey:key];
    dispatch_async(_io, ^{ [data writeToFile:path atomically:YES]; });
}
@end

static NSString *FDMSnapKey(NSString *page, BOOL dark) {
    if (!page.length) return nil;
    unsigned long long h = 1469598103934665603ULL;
    NSString *src = [NSString stringWithFormat:@"%@|%d", page, dark ? 1 : 0];
    const char *p = src.UTF8String;
    for (size_t i = 0; p && p[i]; i++) { h ^= (unsigned char)p[i]; h *= 1099511628211ULL; }
    return [NSString stringWithFormat:@"%016llx", h];
}

static BOOL FDMIsDarkCell(id cell) {
    BOOL dark = NO;
    @try {
        id tc = [cell valueForKey:@"traitCollection"];
        if (tc && [tc respondsToSelector:@selector(userInterfaceStyle)]) {
            dark = (((NSInteger (*)(id, SEL))objc_msgSend)(tc, @selector(userInterfaceStyle)) == 2);
        }
    } @catch (NSException *e) { (void)e; }
    return dark;
}

static UIImage *FDMRenderView(UIView *v) {
    if (!v) return nil;
    CGSize sz = v.bounds.size;
    if (sz.width < 4 || sz.height < 4 || sz.width > 200 || sz.height > 200) return nil;
    UIGraphicsBeginImageContextWithOptions(sz, NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) { UIGraphicsEndImageContext(); return nil; }
    @try { [v.layer renderInContext:ctx]; } @catch (NSException *e) { (void)e; }
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

// 采集「这块 logo 现在到底长什么样」：优先位图，否则把容器（含文字 logo 与底色）整块渲染
static UIImage *FDMCaptureLogo(id cell) {
    UIImage *bitmap = nil;
    UIView *container = nil;
    @try {
        UIImageView *iv = [cell valueForKey:@"logoImage"];
        if ([iv isKindOfClass:[UIImageView class]]) {
            bitmap = iv.image;
            container = iv.superview;
        }
    } @catch (NSException *e) { (void)e; }
    if (bitmap && bitmap.size.width >= 4.0) return bitmap;
    if (container && container.bounds.size.width >= 8 && container.bounds.size.width <= 96) {
        UIImage *shot = FDMRenderView(container);
        if (shot) return shot;
    }
    return nil;
}

static void FDMApplySnapshot(id cell, UIImage *image) {
    @try {
        UIImageView *iv = [cell valueForKey:@"logoImage"];
        UIView *container = [iv isKindOfClass:[UIImageView class]] ? iv.superview : nil;
        if ([iv isKindOfClass:[UIImageView class]]) {
            iv.image = image;
            iv.hidden = NO;
            iv.contentMode = UIViewContentModeScaleToFill;
            if (container && container.bounds.size.width >= 8 && container.bounds.size.width <= 96) {
                iv.frame = container.bounds;
            }
        }
        UIView *text = [cell valueForKey:@"logoText"];
        if ([text isKindOfClass:[UIView class]]) text.hidden = YES;
    } @catch (NSException *e) { (void)e; }
}

static NSMapTable *g_logoOrig = nil;

static IMP FDMOriginalLogoIMP(Class c) {
    if (!g_logoOrig) return NULL;
    for (Class k = c; k; k = class_getSuperclass(k)) {
        id v = [g_logoOrig objectForKey:k];
        if (v) return (IMP)[v pointerValue];
    }
    return NULL;
}
'''
s = s.replace(anchor1, e1, 1)

# ---------- E2: 重写 setupLogoForModel 的判定与采集 ----------
start = s.index('    NSString *iconURL = FDMIconURLForModel(model);')
end = s.index('\n}\n\n#pragma mark - 统一图标缓存钩子', start)
e2 = r'''    NSString *page = nil;
    @try { page = FDMString([model valueForKey:@"url"]); } @catch (NSException *e) { (void)e; }
    if (!page.length) page = FDMIconURLForModel(model);
    NSString *snapKey = FDMSnapKey(page, FDMIsDarkCell(self));

    // 命中快照就直接铺图、完全不跑原生实现（原生会先清空再起请求，那就是"每次重载"的来源）
    if (snapKey.length) {
        UIImage *snap = [[FDMSnapCache shared] imageForKey:snapKey];
        if (snap) {
            FDMApplySnapshot(self, snap);
            static NSInteger hits = 0;
            if (hits < 8) { hits++; FDMLog(@"icon: snap-hit %@", page); }
            return;
        }
        static NSInteger misses = 0;
        if (misses < 8) { misses++; FDMLog(@"icon: snap-miss %@", page); }
    }

    IMP origLogo = FDMOriginalLogoIMP([self class]);
    if (origLogo) ((void (*)(id, SEL, id))origLogo)(self, _cmd, model);
    if (!snapKey.length) return;

    __weak id weakCell = self;
    static const double kDelays[] = {0.30, 0.90, 2.20};
    for (int i = 0; i < 3; i++) {
        double d = kDelays[i];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            id cell = weakCell;
            if (!cell) return;
            if ([[FDMSnapCache shared] imageForKey:snapKey]) return;
            UIImage *shot = FDMCaptureLogo(cell);
            if (!shot) return;
            [[FDMSnapCache shared] storeImage:shot forKey:snapKey];
            FDMLog(@"icon: snap-stored %@ (%.0fx%.0f)", page, shot.size.width, shot.size.height);
        });
    }'''
s = s[:start] + e2 + s[end:]

# ---------- E3: 工具栏「意见反馈」→ 下载管理 ----------
anchor3 = '__attribute__((constructor))\nstatic void FDMInitialize(void) {'
assert s.count(anchor3) == 1
e3 = r'''static IMP g_origPrefSelect = NULL;
static IMP g_origPrefCellUpdate = NULL;

static NSInteger FDMItemTypeOf(id item) {
    NSInteger t = -1;
    @try {
        if ([item respondsToSelector:NSSelectorFromString(@"itemType")]) {
            t = ((NSInteger (*)(id, SEL))objc_msgSend)(item, NSSelectorFromString(@"itemType"));
        }
    } @catch (NSException *e) { (void)e; }
    return t;
}

static void FDMPrefSelect(id self, SEL _cmd, id item) {
    if (FDMItemTypeOf(item) == 17) {
        FDMLog(@"pref: feedback item -> downloads");
        FDMOpenDownloads((UIViewController *)self);
        return;
    }
    if (g_origPrefSelect) ((void (*)(id, SEL, id))g_origPrefSelect)(self, _cmd, item);
}

static void FDMPrefCellUpdate(id self, SEL _cmd, id model) {
    if (FDMItemTypeOf(model) == 17) {
        @try {
            [model setValue:@"下载管理" forKey:@"title"];
            [model setValue:@"tool_down_icon" forKey:@"imageName"];
        } @catch (NSException *e) { (void)e; }
    }
    if (g_origPrefCellUpdate) ((void (*)(id, SEL, id))g_origPrefCellUpdate)(self, _cmd, model);
}

static void FDMInstallPreferenceHook(void) {
    Class bvc = NSClassFromString(@"BrowserViewController");
    if (bvc) {
        FDMInstallHook(bvc, NSSelectorFromString(@"preferenceViewDidSelectItem:"),
                       (IMP)FDMPrefSelect, &g_origPrefSelect);
    }
    Class cell = NSClassFromString(@"PreferenceItemCell");
    if (cell) {
        SEL sel = NSSelectorFromString(@"updateWithModel:");
        Method m = class_getInstanceMethod(cell, sel);
        if (m) {
            g_origPrefCellUpdate = method_getImplementation(m);
            method_setImplementation(m, (IMP)FDMPrefCellUpdate);
            FDMLog(@"hook: PreferenceItemCell updateWithModel: installed");
        } else {
            FDMLog(@"hook: PreferenceItemCell updateWithModel: missing");
        }
    }
}

''' + anchor3
s = s.replace(anchor3, e3, 1)

# ---------- E4: 构造里装四个类的 setupLogo 钩子 + 工具栏钩子 ----------
old4 = '''        Class cell = NSClassFromString(@"BookMarkCell");
        if (cell) FDMInstallHook(cell, @selector(setupLogoForModel:), (IMP)FDMSetupLogoForModel, &g_origSetupLogo);'''
assert s.count(old4) == 1
new4 = '''        g_logoOrig = [NSMapTable strongToStrongObjectsMapTable];
        NSArray *logoOwners = @[@"BookMarkCell", @"HistoryCell", @"CustomTagCell", @"ContextMenuController"];
        for (NSString *name in logoOwners) {
            Class owner = NSClassFromString(name);
            if (!owner) continue;
            SEL sel = @selector(setupLogoForModel:);
            Method m = class_getInstanceMethod(owner, sel);
            if (!m) { FDMLog(@"hook: %@ setupLogoForModel: missing", name); continue; }
            IMP old = method_getImplementation(m);
            [g_logoOrig setObject:[NSValue valueWithPointer:old] forKey:owner];
            if (!class_addMethod(owner, sel, (IMP)FDMSetupLogoForModel, method_getTypeEncoding(m))) {
                method_setImplementation(m, (IMP)FDMSetupLogoForModel);
            }
            FDMLog(@"hook: %@ setupLogoForModel: installed", name);
        }
        FDMInstallPreferenceHook();'''
s = s.replace(old4, new4, 1)

io.open(P, 'w', encoding='utf-8', newline='\n').write(s)
print('patched', orig_len, '->', len(s))

# 校验引号奇偶
bad = 0
for i, line in enumerate(s.splitlines(), 1):
    if line.count('"') % 2 == 1:
        if 'NSStringFromSelector' in line or 'FDMLog(' in line:
            pass
        bad += 1
        print('odd-quote line', i, line.strip()[:80])
print('odd-quote lines:', bad)
