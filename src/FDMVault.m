#import "FDMVault.h"
#import "FDMCommon.h"
#import <Security/Security.h>
#import <math.h>

static NSString *const FDMVaultService = @"com.focusdm.device-local.downloads.v1";
static NSError *FDMVaultError(NSInteger code) {
    return [NSError errorWithDomain:@"FocusDM.Vault" code:code userInfo:@{NSLocalizedDescriptionKey:
        code == errSecInteractionNotAllowed ? @"设备受保护数据不可读；解锁后重试" : @"设备本地请求数据不可用；请重新发起下载"}];
}
#ifdef FDM_TESTING
static NSMutableDictionary *FDMFixtureVault(void) {
    static NSMutableDictionary *values;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ values = [NSMutableDictionary dictionary]; });
    return values;
}
#endif
// Bounded in-process copy of envelopes already read or written here. It only avoids a
// repeated Security round trip; expiry and schema checks still run on every read, and every
// write replaces the entry, so a cached envelope is never newer than the Keychain item.
static const NSUInteger FDMVaultCacheLimit = 64;
static NSMutableDictionary<NSString *, NSDictionary *> *FDMVaultCache(void) {
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}
// Recency order, least recently used first. NSMutableDictionary has no stable enumeration
// order, so evicting allKeys.firstObject dropped an arbitrary entry: the one about to be
// read again could go before one untouched for the whole session.
static NSMutableArray<NSString *> *FDMVaultCacheOrder(void) {
    static NSMutableArray *order;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ order = [NSMutableArray array]; });
    return order;
}
// Every touch moves the object to the back, so the front of the order is the next victim.
static void FDMVaultCacheTouch(NSString *objectID) {
    NSMutableArray *order = FDMVaultCacheOrder();
    [order removeObject:objectID];
    [order addObject:objectID];
}
static NSDictionary *FDMVaultCached(NSString *objectID) {
    @synchronized (FDMVaultCache()) {
        NSDictionary *envelope = FDMVaultCache()[objectID];
        if (envelope) FDMVaultCacheTouch(objectID);
        return envelope;
    }
}
static void FDMVaultCacheStore(NSString *objectID, NSDictionary *envelope) {
    if (!objectID.length || ![envelope isKindOfClass:NSDictionary.class]) return;
    @synchronized (FDMVaultCache()) {
        NSMutableDictionary *cache = FDMVaultCache();
        NSMutableArray *order = FDMVaultCacheOrder();
        FDMVaultCacheTouch(objectID);
        cache[objectID] = envelope;
        while (cache.count > FDMVaultCacheLimit && order.count) {
            NSString *victim = order.firstObject;
            [order removeObjectAtIndex:0];
            [cache removeObjectForKey:victim];
        }
    }
}
static void FDMVaultCacheDrop(NSString *objectID) {
    @synchronized (FDMVaultCache()) {
        [FDMVaultCache() removeObjectForKey:objectID];
        [FDMVaultCacheOrder() removeObject:objectID];
    }
}
static BOOL FDMVaultValidID(NSString *objectID) {
    return [objectID isKindOfClass:NSString.class] && objectID.length > 0 && objectID.length <= 180 &&
        [objectID rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}
BOOL FDMVaultPut(NSString *objectID, NSData *data, NSTimeInterval expiresAt, NSError **error) {
    if (!FDMVaultValidID(objectID) || ![data isKindOfClass:NSData.class] || data.length > 16 * 1024 * 1024 ||
        !isfinite(expiresAt) || expiresAt < 0) { if (error) *error = FDMVaultError(errSecParam); return NO; }
    NSDictionary *envelope = @{@"schema": @1, @"data": data, @"expiresAt": @(expiresAt)};
    // Rewriting the same envelope would cost two Security calls and change nothing.
    if ([FDMVaultCached(objectID) isEqual:envelope]) return YES;
#ifdef FDM_TESTING
    @synchronized (FDMFixtureVault()) { FDMFixtureVault()[objectID] = envelope; }
    FDMVaultCacheStore(objectID, envelope);
    return YES;
#else
    NSData *bytes = [NSPropertyListSerialization dataWithPropertyList:envelope format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!bytes) return NO;
    NSDictionary *query = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: FDMVaultService, (__bridge id)kSecAttrAccount: objectID,
        (__bridge id)kSecAttrSynchronizable: @NO};
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query,
        (__bridge CFDictionaryRef)@{(__bridge id)kSecValueData: bytes});
    if (status == errSecItemNotFound) {
        NSMutableDictionary *insert = [query mutableCopy];
        insert[(__bridge id)kSecValueData] = bytes;
        // Background anonymous requests need availability after first unlock. Never migrates devices.
        insert[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        status = SecItemAdd((__bridge CFDictionaryRef)insert, NULL);
    }
    if (status != errSecSuccess && error) *error = FDMVaultError(status);
    if (status == errSecSuccess) FDMVaultCacheStore(objectID, envelope);
    return status == errSecSuccess;
#endif
}
NSData *FDMVaultGet(NSString *objectID, NSError **error) {
    if (!FDMVaultValidID(objectID)) { if (error) *error = FDMVaultError(errSecParam); return nil; }
    NSDictionary *envelope = FDMVaultCached(objectID);
#ifdef FDM_TESTING
    if (!envelope) @synchronized (FDMFixtureVault()) { envelope = FDMFixtureVault()[objectID]; }
#else
    if (!envelope) {
        NSDictionary *query = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService: FDMVaultService, (__bridge id)kSecAttrAccount: objectID,
            (__bridge id)kSecAttrSynchronizable: @NO, (__bridge id)kSecReturnData: @YES,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne};
        CFTypeRef result = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
        if (status != errSecSuccess) { if (error) *error = FDMVaultError(status); return nil; }
        NSData *bytes = CFBridgingRelease(result);
        envelope = [NSPropertyListSerialization propertyListWithData:bytes options:NSPropertyListImmutable format:NULL error:error];
    }
#endif
    if (![envelope isKindOfClass:NSDictionary.class] || ![envelope[@"schema"] isEqual:@1] ||
        ![envelope[@"data"] isKindOfClass:NSData.class]) { if (error) *error = FDMVaultError(errSecDecode); return nil; }
    NSTimeInterval expiration = [envelope[@"expiresAt"] doubleValue];
    if (!isfinite(expiration) || (expiration > 0 && expiration < NSDate.date.timeIntervalSince1970)) {
        if (error) *error = FDMVaultError(errSecItemNotFound); return nil;
    }
    FDMVaultCacheStore(objectID, envelope);
    return envelope[@"data"];
}
#ifdef FDM_TESTING
NSArray<NSString *> *FDMVaultCacheIDsForTesting(void) {
    @synchronized (FDMVaultCache()) { return FDMVaultCacheOrder().copy; }
}
#endif
void FDMVaultRemove(NSString *objectID) {
    if (!FDMVaultValidID(objectID)) return;
    FDMVaultCacheDrop(objectID);
#ifdef FDM_TESTING
    @synchronized (FDMFixtureVault()) { [FDMFixtureVault() removeObjectForKey:objectID]; }
#else
    NSDictionary *query = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: FDMVaultService, (__bridge id)kSecAttrAccount: objectID,
        (__bridge id)kSecAttrSynchronizable: @NO};
    SecItemDelete((__bridge CFDictionaryRef)query);
#endif
}
