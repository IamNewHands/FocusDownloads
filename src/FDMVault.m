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
static BOOL FDMVaultValidID(NSString *objectID) {
    return [objectID isKindOfClass:NSString.class] && objectID.length > 0 && objectID.length <= 180 &&
        [objectID rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}
BOOL FDMVaultPut(NSString *objectID, NSData *data, NSTimeInterval expiresAt, NSError **error) {
    if (!FDMVaultValidID(objectID) || ![data isKindOfClass:NSData.class] || data.length > 16 * 1024 * 1024 ||
        !isfinite(expiresAt) || expiresAt < 0) { if (error) *error = FDMVaultError(errSecParam); return NO; }
    NSDictionary *envelope = @{@"schema": @1, @"data": data, @"expiresAt": @(expiresAt)};
#ifdef FDM_TESTING
    @synchronized (FDMFixtureVault()) { FDMFixtureVault()[objectID] = envelope; }
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
    return status == errSecSuccess;
#endif
}
NSData *FDMVaultGet(NSString *objectID, NSError **error) {
    if (!FDMVaultValidID(objectID)) { if (error) *error = FDMVaultError(errSecParam); return nil; }
    NSDictionary *envelope = nil;
#ifdef FDM_TESTING
    @synchronized (FDMFixtureVault()) { envelope = FDMFixtureVault()[objectID]; }
#else
    NSDictionary *query = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: FDMVaultService, (__bridge id)kSecAttrAccount: objectID,
        (__bridge id)kSecAttrSynchronizable: @NO, (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne};
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess) { if (error) *error = FDMVaultError(status); return nil; }
    NSData *bytes = CFBridgingRelease(result);
    envelope = [NSPropertyListSerialization propertyListWithData:bytes options:NSPropertyListImmutable format:NULL error:error];
#endif
    if (![envelope isKindOfClass:NSDictionary.class] || ![envelope[@"schema"] isEqual:@1] ||
        ![envelope[@"data"] isKindOfClass:NSData.class]) { if (error) *error = FDMVaultError(errSecDecode); return nil; }
    NSTimeInterval expiration = [envelope[@"expiresAt"] doubleValue];
    if (!isfinite(expiration) || (expiration > 0 && expiration < NSDate.date.timeIntervalSince1970)) {
        if (error) *error = FDMVaultError(errSecItemNotFound); return nil;
    }
    return envelope[@"data"];
}
