# -*- coding: utf-8 -*-
"""v15: 图标缓存命中即跳过原生 / 完成判定看文件 / 失败进已结束+重试 / 暂停不失败 / 显示大小"""
import io, sys

P = 'src/FocusDM.m'
s = io.open(P, encoding='utf-8').read()
orig_len = len(s)

def rep(old, new, label):
    global s
    if old not in s:
        print('MISS:', label); sys.exit(1)
    if s.count(old) != 1:
        print('DUP(%d):' % s.count(old), label); sys.exit(1)
    s = s.replace(old, new)
    print('ok:', label)

# ---------- 1) 宿主任务显示总大小 / 已下载 ----------
rep("""        if (row.size) [bits addObject:[NSString stringWithFormat:@"已下 %@", FDMHumanSize((double)row.size)]];
    } else if (row.state == FDMStateCompleted) {""",
"""        double total = 0;
        id resp = FDMValue(task, @"response");
        if ([resp respondsToSelector:@selector(expectedContentLength)]) {
            long long exp = [resp expectedContentLength];
            if (exp > 0) total = (double)exp;
        }
        if (total > 0) {
            [bits addObject:[NSString stringWithFormat:@"已下 %@ / %@",
                             FDMHumanSize(total * row.progress), FDMHumanSize(total)]];
        } else if (row.size) {
            [bits addObject:[NSString stringWithFormat:@"已下 %@", FDMHumanSize((double)row.size)]];
        }
    } else if (row.state == FDMStateCompleted) {""", 'host task size meta')

# ---------- 2) 宿主任务：失败进已结束；快照带 path/size ----------
rep("""    // 2) 宿主引擎的任务：只活在内存里，重启后消失，只能重下
    for (id task in tasks) {""",
"""    NSMutableArray *finishedLive = [NSMutableArray array];

    // 2) 宿主引擎的任务：只活在内存里，重启后消失，只能重下
    for (id task in tasks) {""", 'declare finishedLive')

rep("""        NSMutableDictionary *old = [[FDMStore shared] recordForKey:row.key];
        if (row.state == FDMStateCompleted) {
            // 关键：之前可能写过一条「已中断」快照，这里必须把它改写成已完成，
            // 否则历史里会留着「已中断」而真正的完成记录被跳过
            if (!old || [old[@"state"] integerValue] != FDMStateCompleted) {
                [self recordForRow:row state:FDMStateCompleted];
            }
        } else {
            [active addObject:row];
            if (row.state == FDMStateDownloading || row.state == FDMStatePaused) {
                if (!old || [old[@"state"] integerValue] != FDMStateCompleted) {
                    // 顺手把进度写进历史，App 被杀后至少能看到「已中断」
                    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
                    snapshot[@"key"] = row.key;
                    snapshot[@"url"] = row.url ?: row.key;
                    snapshot[@"name"] = row.name ?: row.key;
                    snapshot[@"state"] = @(FDMStateInterrupted);
                    snapshot[@"progress"] = @(row.progress);
                    snapshot[@"time"] = @([[NSDate date] timeIntervalSince1970]);
                    [[FDMStore shared] upsertRecord:snapshot];
                }
            }
        }
    }""",
"""        NSMutableDictionary *old = [[FDMStore shared] recordForKey:row.key];
        if (row.state == FDMStateCompleted) {
            // 之前可能写过一条「已中断」快照，这里必须改写成已完成
            if (!old || [old[@"state"] integerValue] != FDMStateCompleted) {
                [self recordForRow:row state:FDMStateCompleted];
            }
        } else if (row.state == FDMStateFailed) {
            // 失败不再留在「进行中」：落到「已结束」，行内提供「重试」
            [self recordForRow:row state:FDMStateFailed];
            [finishedLive addObject:row];
        } else {
            [active addObject:row];
            if (row.state == FDMStateDownloading || row.state == FDMStatePaused) {
                if (!old || [old[@"state"] integerValue] != FDMStateCompleted) {
                    // 进度快照：App 被杀后至少能看到进度；path 用来判断文件是否其实已下完
                    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
                    snapshot[@"key"] = row.key;
                    snapshot[@"url"] = row.url ?: row.key;
                    snapshot[@"name"] = row.name ?: row.key;
                    snapshot[@"path"] = row.path ?: @"";
                    snapshot[@"size"] = @(row.size);
                    snapshot[@"state"] = @(FDMStateInterrupted);
                    snapshot[@"progress"] = @(row.progress);
                    snapshot[@"time"] = @([[NSDate date] timeIntervalSince1970]);
                    [[FDMStore shared] upsertRecord:snapshot];
                }
            }
        }
    }""", 'host task classification')

# ---------- 3) 记录段：文件在盘就算完成；暂停的记录回到进行中 ----------
rep("""    NSMutableArray *finished = [NSMutableArray array];
    for (NSDictionary *record in [[FDMStore shared] records]) {
        NSString *recordKey = record[@"key"];
        // 同一任务还在下载时，历史里的「已中断」快照不能再单列一条，否则两段里各出现一次
        if (recordKey.length && [nowKeys containsObject:recordKey]) continue;
        [finished addObject:[self rowFromRecord:record]];
    }""",
"""    NSMutableArray *finished = [NSMutableArray arrayWithArray:finishedLive];
    NSMutableArray *pausedFromStore = [NSMutableArray array];
    for (NSDictionary *record in [[FDMStore shared] records]) {
        NSString *recordKey = record[@"key"];
        // 同一任务还在下载时，历史里的快照不能再单列一条，否则两段里各出现一次
        if (recordKey.length && [nowKeys containsObject:recordKey]) continue;

        NSInteger st = [record[@"state"] integerValue];
        NSString *storedPath = record[@"path"];

        // 文件已经落盘：不管记录写的是「已中断」还是「已暂停」，实际就是下完了
        if (st != FDMStateCompleted && storedPath.length) {
            unsigned long long sz = FDMFileSizeAtPath(storedPath);
            if (sz > 0) {
                st = FDMStateCompleted;
                NSMutableDictionary *fixed = [record mutableCopy];
                fixed[@"state"] = @(FDMStateCompleted);
                fixed[@"size"] = @(sz);
                fixed[@"progress"] = @1.0;
                [[FDMStore shared] upsertRecord:fixed];
            }
        }

        FDMRow *row = [self rowFromRecord:record];
        if (st == FDMStateCompleted) {
            row.state = FDMStateCompleted;
            row.progress = 1.0;
            [finished addObject:row];
        } else if (st == FDMStatePaused) {
            // 自己暂停的任务留在「进行中」，点「继续」用可恢复引擎接着下
            row.state = FDMStatePaused;
            row.source = 2;
            row.url = record[@"url"] ?: recordKey;
            [pausedFromStore addObject:row];
            [nowKeys addObject:recordKey ?: @""];
        } else {
            [finished addObject:row];
        }
    }
    [active addObjectsFromArray:pausedFromStore];""", 'store record reclassify')

# ---------- 4) 暂停/继续/重试 ----------
rep("""- (void)toggleRow:(FDMRow *)row {
    if (row.source == 0) {
        if (row.state == FDMStateDownloading) [[FDMEngine shared] pauseKey:row.key];
        else [[FDMEngine shared] resumeKey:row.key];
    } else if (row.source == 1) {
        id fm = FDMSharedFileManager();
        if (row.state == FDMStateDownloading) {
            if ([fm respondsToSelector:@selector(suspendTask:)]) [fm suspendTask:row.task];
        } else {
            if ([fm respondsToSelector:@selector(startTask:)]) [fm startTask:row.task];
        }
    } else {
        [self restartRow:row];
    }""",
"""- (void)toggleRow:(FDMRow *)row {
    id fm = FDMSharedFileManager();
    NSString *url = row.url.length ? row.url : row.key;

    if (row.state == FDMStateDownloading) {
        if (row.source == 0) {
            [[FDMEngine shared] pauseKey:row.key];
        } else {
            // 宿主引擎的 suspend 会把任务直接打成失败，所以这里「取消 + 记成已暂停」，
            // 等用户点继续时交给可恢复引擎重下，任务留在「进行中」
            if (row.task && [fm respondsToSelector:@selector(cancelTask:)]) [fm cancelTask:row.task];
            NSMutableDictionary *rec = [NSMutableDictionary dictionary];
            rec[@"key"] = row.key ?: @"";
            rec[@"url"] = url ?: @"";
            rec[@"name"] = row.name ?: (row.key ?: @"");
            rec[@"path"] = row.path ?: @"";
            rec[@"size"] = @(row.size);
            rec[@"progress"] = @(row.progress);
            rec[@"state"] = @(FDMStatePaused);
            rec[@"time"] = @([[NSDate date] timeIntervalSince1970]);
            [[FDMStore shared] upsertRecord:rec];
        }
    } else if (row.source == 0 && [row.key length]) {
        [[FDMEngine shared] resumeKey:row.key];
    } else if (url.length) {
        // 继续（自己的记录）/ 重试（失败或已中断）→ 可恢复引擎接管，任务回到「进行中」
        [[FDMEngine shared] startURL:url name:row.name];
        [[FDMStore shared] dropKey:row.key];
    }""", 'toggleRow pause/resume/retry')

rep("""- (void)restartRow:(FDMRow *)row {
    NSString *url = row.url.length ? row.url : row.key;
    if (url.length) [[FDMEngine shared] startURL:url name:row.name];
}""",
"""- (void)restartRow:(FDMRow *)row {
    NSString *url = row.url.length ? row.url : row.key;
    if (!url.length) return;
    [[FDMEngine shared] startURL:url name:row.name];
    [[FDMStore shared] dropKey:row.key];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refresh];
    });
}""", 'restartRow drops record')

# ---------- 5) 失败行也给按钮 ----------
rep("""    BOOL canToggle = (row.state == FDMStateDownloading || row.state == FDMStatePaused || row.state == FDMStateInterrupted);""",
"""    BOOL canToggle = (row.state == FDMStateDownloading || row.state == FDMStatePaused
                      || row.state == FDMStateInterrupted || row.state == FDMStateFailed);""", 'canToggle includes failed')

rep("""        NSString *title = @"继续";
        if (row.state == FDMStateDownloading) title = @"暂停";
        else if (row.source == 2) title = @"重试";""",
"""        NSString *title = @"继续";
        if (row.state == FDMStateDownloading) title = @"暂停";
        else if (row.state == FDMStateFailed || row.state == FDMStateInterrupted) title = @"重试";""", 'retry title')

# ---------- 6) 图标：命中即跳过原生；多拍抓图落盘 ----------
rep("""    // 先跑原生实现：它会清空/起一个异步请求，之后我们再把自己的磁盘缓存图盖上去，
    // 这样每次进主页都是立刻有图，而不是「先空白 → 再闪一下」
    if (g_origSetupLogo) ((void (*)(id, SEL, id))g_origSetupLogo)(self, _cmd, model);
    if (!iconURL.length) return;

    UIImage *cached = [[FDMImageCache shared] cachedImageForURL:iconURL];
    if (cached) {
        FDMApplyCachedIcon(self, cached);
        return;
    }

    if (![[FDMImageCache shared] isPending:iconURL]) [[FDMImageCache shared] prefetchURL:iconURL];

    // 原生异步加载完成后把图抓下来存盘（只抓一次，避免重复写）
    __weak id weakCell = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id cell = weakCell;
        if (!cell) return;
        UIImage *now = FDMCurrentLogoImage(cell);
        if (!now || [[FDMImageCache shared] cachedImageForURL:iconURL]) return;
        [[FDMImageCache shared] storeImage:now forURL:iconURL];
        static NSInteger stored = 0;
        stored++;
        FDMLog(@"icon: stored %@ (total %ld)", [iconURL lastPathComponent], (long)stored);
    });""",
"""    // 命中磁盘缓存就直接铺图，并且**完全不跑原生实现**：
    // 原生一定会先清空再起一次请求，那正是「每次进主页图标都闪一下重载」的来源
    if (iconURL.length) {
        UIImage *cached = [[FDMImageCache shared] cachedImageForURL:iconURL];
        if (cached) {
            FDMApplyCachedIcon(self, cached);
            static NSInteger hits = 0;
            if (hits < 5) { hits++; FDMLog(@"icon: hit %@", iconURL); }
            return;
        }
        static NSInteger misses = 0;
        if (misses < 5) { misses++; FDMLog(@"icon: miss %@ model=%@", iconURL, model); }
    }

    if (g_origSetupLogo) ((void (*)(id, SEL, id))g_origSetupLogo)(self, _cmd, model);
    if (!iconURL.length) return;

    if (![[FDMImageCache shared] isPending:iconURL]) [[FDMImageCache shared] prefetchURL:iconURL];

    // 原生是异步加载：分几拍去抓，抓住一次就落盘（旧版只等 0.9s，网络慢就永远存不上）
    __weak id weakCell = self;
    static const double kDelays[] = {0.25, 0.7, 1.6, 3.2};
    for (int i = 0; i < 4; i++) {
        double d = kDelays[i];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            id cell = weakCell;
            if (!cell) return;
            if ([[FDMImageCache shared] cachedImageForURL:iconURL]) return;
            UIImage *now = FDMCurrentLogoImage(cell);
            if (!now || now.size.width < 2.0) return;
            [[FDMImageCache shared] storeImage:now forURL:iconURL];
            FDMLog(@"icon: stored %@", iconURL);
        });
    }""", 'icon skip-original-on-hit')

io.open(P, 'w', encoding='utf-8', newline='\n').write(s)
print('bytes %d -> %d' % (orig_len, len(s)))
