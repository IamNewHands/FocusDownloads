#import "FDMBackupReadBarrier.h"

// All snapshots live only for one restore. No file, defaults suite or persistent mirror is added.
static NSRecursiveLock *FDMBReadLock;
static NSMutableArray<NSDictionary *> *FDMBDefaults;
static NSMutableArray<NSDictionary *> *FDMBDeferred;
static NSDictionary<NSString *, NSData *> *FDMBFiles;
static NSString *FDMBScriptDirectory;
static BOOL FDMBActive, FDMBConflict;
static char FDMBDefaultsScopeKey;
static NSString *const FDMBInternalKey = @"FocusDM.backup.internal-access";
static IMP FDMBOriginalDefaultsInit, FDMBOriginalObject, FDMBOriginalArray, FDMBOriginalData;
static IMP FDMBOriginalSet, FDMBOriginalRemove, FDMBOriginalContents, FDMBOriginalExists;
static IMP FDMBOriginalDataFile, FDMBOriginalDataFileOptions, FDMBOriginalDataWrite, FDMBOriginalRemoveFile;

static BOOL FDMBIsInternal(void) { return [NSThread.currentThread.threadDictionary[FDMBInternalKey] unsignedIntegerValue] != 0; }
BOOL FDMBackupInternalAccess(BOOL (^block)(void)) {
    NSMutableDictionary *thread = NSThread.currentThread.threadDictionary;
    NSUInteger prior = [thread[FDMBInternalKey] unsignedIntegerValue]; thread[FDMBInternalKey] = @(prior + 1);
    @try { return block(); }
    @finally { if (prior) thread[FDMBInternalKey] = @(prior); else [thread removeObjectForKey:FDMBInternalKey]; }
}
static NSDictionary *FDMBDefaultRule(id store, NSString *key) {
    NSString *scope = objc_getAssociatedObject(store, &FDMBDefaultsScopeKey);
    for (NSDictionary *rule in FDMBDefaults) {
        if (![rule[@"key"] isEqual:key]) continue;
        if (rule[@"store"] == store || (scope.length && [scope isEqual:rule[@"scope"]]) ||
            ([rule[@"scope"] isEqual:@"standard"] && store == NSUserDefaults.standardUserDefaults)) return rule;
    }
    return nil;
}
static id FDMBDefaultsInit(id self, SEL selector, NSString *suite) {
    id value = ((id (*)(id, SEL, id))FDMBOriginalDefaultsInit)(self, selector, suite);
    if (value && suite.length) objc_setAssociatedObject(value, &FDMBDefaultsScopeKey, suite, OBJC_ASSOCIATION_COPY_NONATOMIC);
    return value;
}
static id FDMBDefaultsRead(id self, SEL selector, NSString *key) {
    IMP original = selector == @selector(arrayForKey:) ? FDMBOriginalArray : (selector == @selector(dataForKey:) ? FDMBOriginalData : FDMBOriginalObject);
    if (FDMBIsInternal()) return ((id (*)(id, SEL, id))original)(self, selector, key);
    [FDMBReadLock lock]; NSDictionary *rule = FDMBActive ? FDMBDefaultRule(self, key) : nil;
    id value = rule[@"before"]; [FDMBReadLock unlock];
    if (rule) return value == NSNull.null ? nil : value;
    return ((id (*)(id, SEL, id))original)(self, selector, key);
}
static void FDMBDefaultsSet(id self, SEL selector, id value, NSString *key) {
    if (FDMBIsInternal()) { ((void (*)(id, SEL, id, id))FDMBOriginalSet)(self, selector, value, key); return; }
    [FDMBReadLock lock]; BOOL protect = FDMBActive && FDMBDefaultRule(self, key) != nil;
    if (protect) {
        id copied = value;
        if (value) { NSData *bytes = [NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
            if (bytes) copied = [NSPropertyListSerialization propertyListWithData:bytes options:NSPropertyListImmutable format:NULL error:NULL]; }
        [FDMBDeferred addObject:@{@"store": self, @"key": key, @"value": copied ?: NSNull.null}]; FDMBConflict = YES;
    }
    [FDMBReadLock unlock];
    if (!protect) ((void (*)(id, SEL, id, id))FDMBOriginalSet)(self, selector, value, key);
}
static void FDMBDefaultsRemove(id self, SEL selector, NSString *key) {
    if (FDMBIsInternal()) { ((void (*)(id, SEL, id))FDMBOriginalRemove)(self, selector, key); return; }
    [FDMBReadLock lock]; BOOL protect = FDMBActive && FDMBDefaultRule(self, key) != nil;
    if (protect) { [FDMBDeferred addObject:@{@"store": self, @"key": key, @"value": NSNull.null}]; FDMBConflict = YES; }
    [FDMBReadLock unlock];
    if (!protect) ((void (*)(id, SEL, id))FDMBOriginalRemove)(self, selector, key);
}
static BOOL FDMBProtectedFile(NSString *path) {
    if (!FDMBActive || !FDMBScriptDirectory || ![path isKindOfClass:NSString.class]) return NO;
    NSString *standard = path.stringByStandardizingPath;
    return [standard.stringByDeletingLastPathComponent isEqual:FDMBScriptDirectory] && [standard.pathExtension isEqual:@"js"];
}
static NSData *FDMBReadFile(NSString *path, BOOL *protected) {
    [FDMBReadLock lock]; *protected = FDMBProtectedFile(path); NSData *bytes = *protected ? FDMBFiles[path.lastPathComponent] : nil;
    [FDMBReadLock unlock]; return bytes;
}
static id FDMBContents(id self, SEL selector, NSString *path) {
    BOOL protect = NO; NSData *bytes = FDMBIsInternal() ? nil : FDMBReadFile(path, &protect);
    return protect ? bytes : ((id (*)(id, SEL, id))FDMBOriginalContents)(self, selector, path);
}
static BOOL FDMBExists(id self, SEL selector, NSString *path) {
    BOOL protect = NO; NSData *bytes = FDMBIsInternal() ? nil : FDMBReadFile(path, &protect);
    return protect ? bytes != nil : ((BOOL (*)(id, SEL, id))FDMBOriginalExists)(self, selector, path);
}
static id FDMBDataFile(id self, SEL selector, NSString *path) {
    BOOL protect = NO; NSData *bytes = FDMBIsInternal() ? nil : FDMBReadFile(path, &protect);
    return protect ? bytes : ((id (*)(id, SEL, id))FDMBOriginalDataFile)(self, selector, path);
}
static id FDMBDataFileOptions(id self, SEL selector, NSString *path, NSUInteger options, NSError **error) {
    BOOL protect = NO; NSData *bytes = FDMBIsInternal() ? nil : FDMBReadFile(path, &protect);
    if (protect) { if (!bytes && error) *error = FDMError(@"该脚本尚未在已发布配置中存在"); return bytes; }
    return ((id (*)(id, SEL, id, NSUInteger, NSError **))FDMBOriginalDataFileOptions)(self, selector, path, options, error);
}
static BOOL FDMBRefuseFileWrite(NSString *path, NSError **error) {
    if (FDMBIsInternal()) return NO;
    [FDMBReadLock lock]; BOOL protect = FDMBProtectedFile(path); if (protect) FDMBConflict = YES; [FDMBReadLock unlock];
    if (protect && error) *error = FDMError(@"脚本配置正在恢复，当前修改未写入；请待恢复结束后重试"); return protect;
}
static BOOL FDMBDataWrite(id self, SEL selector, NSString *path, NSUInteger options, NSError **error) {
    if (FDMBRefuseFileWrite(path, error)) return NO;
    return ((BOOL (*)(id, SEL, id, NSUInteger, NSError **))FDMBOriginalDataWrite)(self, selector, path, options, error);
}
static BOOL FDMBRemoveFile(id self, SEL selector, NSString *path, NSError **error) {
    if (FDMBRefuseFileWrite(path, error)) return NO;
    return ((BOOL (*)(id, SEL, id, NSError **))FDMBOriginalRemoveFile)(self, selector, path, error);
}
static void FDMBHook(Class cls, SEL selector, IMP hook, IMP *original) {
    Method method = class_getInstanceMethod(cls, selector); if (!method) return;
    *original = method_getImplementation(method);
    if (!class_addMethod(cls, selector, hook, method_getTypeEncoding(method))) method_setImplementation(method, hook);
}
static void FDMBInstall(void) {
    static dispatch_once_t once; dispatch_once(&once, ^{
        FDMBReadLock = [NSRecursiveLock new]; FDMBDefaults = [NSMutableArray array]; FDMBDeferred = [NSMutableArray array];
        FDMBHook(NSUserDefaults.class, @selector(initWithSuiteName:), (IMP)FDMBDefaultsInit, &FDMBOriginalDefaultsInit);
        FDMBHook(NSUserDefaults.class, @selector(objectForKey:), (IMP)FDMBDefaultsRead, &FDMBOriginalObject);
        FDMBHook(NSUserDefaults.class, @selector(arrayForKey:), (IMP)FDMBDefaultsRead, &FDMBOriginalArray);
        FDMBHook(NSUserDefaults.class, @selector(dataForKey:), (IMP)FDMBDefaultsRead, &FDMBOriginalData);
        FDMBHook(NSUserDefaults.class, @selector(setObject:forKey:), (IMP)FDMBDefaultsSet, &FDMBOriginalSet);
        FDMBHook(NSUserDefaults.class, @selector(removeObjectForKey:), (IMP)FDMBDefaultsRemove, &FDMBOriginalRemove);
        FDMBHook(NSFileManager.class, @selector(contentsAtPath:), (IMP)FDMBContents, &FDMBOriginalContents);
        FDMBHook(NSFileManager.class, @selector(fileExistsAtPath:), (IMP)FDMBExists, &FDMBOriginalExists);
        FDMBHook(object_getClass(NSData.class), @selector(dataWithContentsOfFile:), (IMP)FDMBDataFile, &FDMBOriginalDataFile);
        FDMBHook(object_getClass(NSData.class), @selector(dataWithContentsOfFile:options:error:), (IMP)FDMBDataFileOptions, &FDMBOriginalDataFileOptions);
        FDMBHook(NSData.class, @selector(writeToFile:options:error:), (IMP)FDMBDataWrite, &FDMBOriginalDataWrite);
        FDMBHook(NSFileManager.class, @selector(removeItemAtPath:error:), (IMP)FDMBRemoveFile, &FDMBOriginalRemoveFile);
    });
}
__attribute__((constructor)) static void FDMBInit(void) { @autoreleasepool { FDMBInstall(); } }
void FDMBackupBeginReadBarrier(void) {
    FDMBInstall(); [FDMBReadLock lock];
    if (!FDMBActive) { FDMBActive = YES; FDMBConflict = NO; [FDMBDefaults removeAllObjects]; [FDMBDeferred removeAllObjects]; FDMBFiles = nil; FDMBScriptDirectory = nil; }
    [FDMBReadLock unlock];
}
void FDMBackupProtectDefaults(NSUserDefaults *store, NSString *scope, NSString *key) {
    [FDMBReadLock lock];
    if (FDMBActive && !FDMBDefaultRule(store, key)) {
        __block id before = nil; FDMBackupInternalAccess(^BOOL { before = [store objectForKey:key]; return YES; });
        objc_setAssociatedObject(store, &FDMBDefaultsScopeKey, scope, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [FDMBDefaults addObject:@{@"store": store, @"scope": scope, @"key": key, @"before": before ?: NSNull.null}];
    }
    [FDMBReadLock unlock];
}
void FDMBackupProtectScriptFiles(NSString *directory, NSDictionary<NSString *, NSData *> *files) {
    [FDMBReadLock lock]; if (FDMBActive && !FDMBScriptDirectory) { FDMBScriptDirectory = directory.stringByStandardizingPath; FDMBFiles = [files copy]; } [FDMBReadLock unlock];
}
BOOL FDMBackupReadBarrierCommit(BOOL (^writeMarker)(void)) {
    [FDMBReadLock lock]; BOOL ok = NO;
    @try {
        if (!FDMBConflict) ok = FDMBackupInternalAccess(writeMarker);
        // A writer arriving after this point is a new edit on the committed configuration,
        // not a late concurrent edit of the configuration whose marker was just written.
        if (ok) { FDMBActive = NO; [FDMBDefaults removeAllObjects]; FDMBFiles = nil; FDMBScriptDirectory = nil; }
    } @finally { [FDMBReadLock unlock]; }
    return ok;
}
void FDMBackupFinishReadBarrier(BOOL publish) {
    if (!publish) return;
    [FDMBReadLock lock]; NSArray *deferred = [FDMBDeferred copy];
    @try {
        // Replay accepted concurrent edits before releasing the lock; a newer writer must not
        // be overwritten by an older deferred edit after publication.
        FDMBackupInternalAccess(^BOOL {
            for (NSDictionary *edit in deferred) {
                NSUserDefaults *store = edit[@"store"];
                if (edit[@"value"] == NSNull.null) [store removeObjectForKey:edit[@"key"]]; else [store setObject:edit[@"value"] forKey:edit[@"key"]];
                [store synchronize];
            }
            return YES;
        });
        FDMBActive = NO; [FDMBDefaults removeAllObjects]; [FDMBDeferred removeAllObjects]; FDMBFiles = nil; FDMBScriptDirectory = nil;
    } @finally { [FDMBReadLock unlock]; }
}
