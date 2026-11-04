# -*- coding: utf-8 -*-
"""v18: 图标首次固定(不再重载) + 点工具栏下载管理前收起面板"""
import io, sys, re

P = "src/FocusDM.m"
src = io.open(P, encoding="utf-8").read()

# ---------- 1) 面板收起 ----------
old_pref = """static void FDMPrefSelect(id self, SEL _cmd, id item) {
    if (FDMItemTypeOf(item) == 17) {
        FDMLog(@"pref: feedback item -> downloads");
        FDMOpenDownloads((UIViewController *)self);
        return;
    }
    if (g_origPrefSelect) ((void (*)(id, SEL, id))g_origPrefSelect)(self, _cmd, item);
}"""
new_pref = """static void FDMPrefSelect(id self, SEL _cmd, id item) {
    if (FDMItemTypeOf(item) == 17) {
        FDMLog(@"pref: feedback item -> downloads");
        // 原分发器第一句会收起偏好面板，我们绕过了它，必须自己收
        SEL hideSel = NSSelectorFromString(@"hideUserPreferenceView");
        if ([self respondsToSelector:hideSel]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(self, hideSel); FDMLog(@"pref: hid preference view"); }
            @catch (NSException *e) { FDMLog(@"pref: hide failed %@", e.reason); }
        } else {
            FDMLog(@"pref: hideUserPreferenceView missing");
        }
        FDMOpenDownloads((UIViewController *)self);
        return;
    }
    if (g_origPrefSelect) ((void (*)(id, SEL, id))g_origPrefSelect)(self, _cmd, item);
}"""
assert old_pref in src, "pref select block not found"
src = src.replace(old_pref, new_pref, 1)

# ---------- 2) 图标：首次固定 + 只升不降 ----------
start = src.index("static void FDMSetupLogoForModel(id self, SEL _cmd, id model) {")
end = src.index("#pragma mark - 统一图标缓存钩子（SDWebImage）")
old_fn = src[start:end]

new_fn = """static NSMutableSet *g_snapUpgraded = nil;

static BOOL FDMUpgradeOnce(NSString *key) {
    if (!key.length) return NO;
    if (!g_snapUpgraded) g_snapUpgraded = [NSMutableSet set];
    if ([g_snapUpgraded containsObject:key]) return NO;
    [g_snapUpgraded addObject:key];
    return YES;
}

static void FDMSetupLogoForModel(id self, SEL _cmd, id model) {
    static NSInteger entry = 0;
    if (entry < 6) {
        entry++;
        NSString *iu = nil, *pu = nil;
        @try { iu = FDMString([model valueForKey:@"iconUrl"]); } @catch (NSException *e) { (void)e; }
        @try { pu = FDMString([model valueForKey:@"url"]); } @catch (NSException *e) { (void)e; }
        FDMLog(@"icon: setupLogoForModel #%ld cls=%@ iconUrl=%@ url=%@",
               (long)entry, NSStringFromClass([self class]), iu, pu);
    }
    NSString *page = nil;
    @try { page = FDMString([model valueForKey:@"url"]); } @catch (NSException *e) { (void)e; }
    if (!page.length) page = FDMIconURLForModel(model);
    // 快照与深色模式无关：同一个页面永远命中同一张图
    NSString *snapKey = FDMSnapKey(page, NO);

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

    // 第一步：尽快把「第一眼看到的样子」固定下来。连不上的站抓到的是文字占位块，
    // 之后就一直用这块图，永远不会再出现"重新加载"。
    static const double kFix[] = {0.10, 0.40};
    for (int i = 0; i < 2; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kFix[i] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            id cell = weakCell;
            if (!cell) return;
            if ([[FDMSnapCache shared] imageForKey:snapKey]) return;
            UIImage *shot = FDMCaptureLogo(cell);
            if (!shot) return;
            [[FDMSnapCache shared] storeImage:shot forKey:snapKey];
            FDMLog(@"icon: snap-fixed %@ (%.0fx%.0f)", page, shot.size.width, shot.size.height);
        });
    }

    // 第二步：若之后真的拿到图标，只升级一次（只升不降）
    static const double kUp[] = {1.00, 2.00, 3.50};
    for (int i = 0; i < 3; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kUp[i] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            id cell = weakCell;
            if (!cell) return;
            UIImage *real = FDMCurrentLogoImage(cell);
            if (!real || real.size.width < 4.0) return;
            UIImage *existing = [[FDMSnapCache shared] imageForKey:snapKey];
            if (existing && existing.size.width >= 4.0 &&
                fabs(existing.size.width - real.size.width) < 0.5 &&
                fabs(existing.size.height - real.size.height) < 0.5) return;
            if (!FDMUpgradeOnce(snapKey)) return;
            [[FDMSnapCache shared] storeImage:real forKey:snapKey];
            FDMLog(@"icon: snap-upgrade %@ (%.0fx%.0f)", page, real.size.width, real.size.height);
        });
    }
}

"""
src = src[:start] + new_fn + src[end:]

io.open(P, "w", encoding="utf-8", newline="\n").write(src)

# 引号奇偶校验
bad = 0
for i, line in enumerate(src.splitlines(), 1):
    s = line.strip()
    if s.startswith("//") or s.startswith("#"):
        continue
    if line.count('"') % 2 == 1:
        bad += 1
        print("odd-quote %d: %s" % (i, line[:100]))
print("odd-quote lines:", bad)
print("lines:", len(src.splitlines()))
