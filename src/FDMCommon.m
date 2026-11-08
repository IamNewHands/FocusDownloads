#import "FDMCommon.h"
#import <sys/stat.h>
#import <sys/time.h>
#import <fcntl.h>
#import <unistd.h>
#import <signal.h>
#import <math.h>
#import <stdio.h>
#import <stdarg.h>

#ifndef FDM_PATCH_VERSION
#define FDM_PATCH_VERSION "v19"
#endif
#ifndef FDM_BUILD_REVISION
#define FDM_BUILD_REVISION "local-uncompiled"
#endif

__attribute__((used)) const char FDMBuildMetadata[] =
    "FOCUSDM_BUILD_METADATA:{\"schema_version\":1,\"patch_version\":\"" FDM_PATCH_VERSION
    "\",\"source_sha\":\"" FDM_BUILD_REVISION "\"}";

NSString *const FDMRecordsDidChangeNotification = @"FDMRecordsDidChange";
NSString *const FDMBackgroundSessionIdentifier = @"FocusDM.resumable";
static char FDMLogPath[1024];
static NSUncaughtExceptionHandler *FDMPreviousExceptionHandler;

NSString *FDMPatchVersion(void) { return @FDM_PATCH_VERSION; }
NSString *FDMBuildRevision(void) { return @FDM_BUILD_REVISION; }
NSError *FDMError(NSString *message) {
    return [NSError errorWithDomain:@"FocusDM" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

NSString *FDMDocumentsPath(void) {
#ifdef FDM_TESTING
    NSString *test = [NSProcessInfo processInfo].environment[@"FDM_TEST_DOCUMENTS"];
    if (test.length) return test;
#endif
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

NSString *FDMDirectory(NSString *relative) {
    NSString *path = [FDMDocumentsPath() stringByAppendingPathComponent:relative];
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&error]) {
        NSLog(@"FocusDM directory error: %@", error.localizedDescription);
    }
    return path;
}

NSString *FDMLegacyHash(NSString *text) {
    uint64_t hash = 1469598103934665603ULL;
    const unsigned char *p = (const unsigned char *)text.UTF8String;
    while (p && *p) { hash ^= *p++; hash *= 1099511628211ULL; }
    return [NSString stringWithFormat:@"%016llx", (unsigned long long)hash];
}

NSString *FDMRedactedURL(NSString *text) {
    if (!text.length) return @"<empty>";
    NSURLComponents *parts = [NSURLComponents componentsWithString:text];
    if (!parts.host.length) return [NSString stringWithFormat:@"id:%@", FDMLegacyHash(text)];
    return [NSString stringWithFormat:@"%@://%@ [%@]", parts.scheme.lowercaseString ?: @"https", parts.host.lowercaseString, FDMLegacyHash(text)];
}

NSURL *FDMValidatedURL(NSString *text, NSError **error) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSURLComponents *parts = [NSURLComponents componentsWithString:trimmed];
    NSString *scheme = parts.scheme.lowercaseString;
    if (!parts.URL || !parts.host.length || !([scheme isEqual:@"http"] || [scheme isEqual:@"https"]) || parts.user.length || parts.password.length) {
        if (error) *error = FDMError(@"请输入有效的 http/https 文件地址（不支持地址内用户名或密码）");
        return nil;
    }
    return parts.URL;
}

NSString *FDMSafeFilename(NSString *name) {
    NSString *component = [[(name ?: @"download") stringByReplacingOccurrencesOfString:@"\\" withString:@"/"] lastPathComponent];
    component = [component stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/:\0\r\n"];
    component = [[component componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"];
    if (!component.length || [component isEqual:@"."] || [component isEqual:@".."]) component = @"download";
    if (component.length > 160) component = [component substringWithRange:[component rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 160)]];
    return component;
}

id FDMValue(id object, NSString *key) {
    if (!object) return nil;
    @try { return [object valueForKey:key]; }
    @catch (NSException *exception) { return nil; }
}

NSString *FDMString(id object) {
    if ([object isKindOfClass:NSString.class]) return object;
    if ([object isKindOfClass:NSURL.class]) return [object absoluteString];
    return nil;
}

id FDMSharedFileManager(void) {
    static id shared;
    @synchronized (NSObject.class) {
        if (shared) return shared;
        Class cls = NSClassFromString(@"FileManager");
        SEL selector = NSSelectorFromString(@"shareInstance");
        if (cls && [cls respondsToSelector:selector]) shared = ((id (*)(id, SEL))objc_msgSend)(cls, selector);
        return shared;
    }
}

double FDMDouble(id object, NSString *key) {
    id value = FDMValue(object, key);
    if ([value isKindOfClass:NSProgress.class]) return [(NSProgress *)value fractionCompleted];
    if ([value respondsToSelector:@selector(doubleValue)]) return [value doubleValue];
    return 0;
}

double FDMProgressOfTask(id task) {
    id progress = FDMValue(task, @"progress");
    if ([progress isKindOfClass:NSProgress.class]) return MIN(1, MAX(0, [progress fractionCompleted]));
    double value = FDMDouble(task, @"progress");
    return MIN(1, MAX(0, value));
}

NSString *FDMHumanSize(double bytes) {
    if (!isfinite(bytes) || bytes < 0) return @"未知";
    NSArray *units = @[@"B", @"KB", @"MB", @"GB", @"TB"];
    NSUInteger index = 0;
    while (bytes >= 1024 && index < units.count - 1) { bytes /= 1024; index++; }
    return [NSString stringWithFormat:index ? @"%.1f %@" : @"%.0f %@", bytes, units[index]];
}

NSString *FDMHumanETA(double seconds) {
    if (!(seconds > 0) || !isfinite(seconds) || seconds > 359999) return nil;
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)seconds / 60, (long)seconds % 60];
}

NSString *FDMRelativeDocumentPath(NSString *path) {
    NSString *root = FDMDocumentsPath().stringByStandardizingPath.stringByResolvingSymlinksInPath;
    NSString *resolved = path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    NSString *prefix = [root stringByAppendingString:@"/"];
    if (![resolved hasPrefix:prefix] || resolved.length <= prefix.length) return nil;
    return [resolved substringFromIndex:prefix.length];
}

NSString *FDMResolveDocumentPath(NSDictionary *record) {
    NSString *relative = FDMString(record[@"relativePath"]);
    NSString *path = relative.length ? [FDMDocumentsPath() stringByAppendingPathComponent:relative] : FDMString(record[@"path"]);
    if (!path.length || !FDMRelativeDocumentPath(path)) return nil;
    return path.stringByStandardizingPath;
}

NSDictionary *FDMFileIdentity(NSString *path) {
    if (!FDMRelativeDocumentPath(path)) return nil;
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if (![attributes[NSFileType] isEqual:NSFileTypeRegular]) return nil;
    NSNumber *device = attributes[NSFileSystemNumber];
    NSNumber *inode = attributes[NSFileSystemFileNumber];
    if (!device || !inode) return nil;
    return @{@"device": device, @"inode": inode, @"size": attributes[NSFileSize] ?: @0};
}

BOOL FDMRemoveOwnedFile(NSDictionary *record, NSError **error) {
    NSString *path = FDMResolveDocumentPath(record);
    if (!path) {
        if (error) *error = FDMError(@"没有可确认归属的文件路径；记录保留，请在“文件”中确认后处理");
        return NO;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return YES;
    NSDictionary *expected = record[@"fileIdentity"];
    NSDictionary *current = FDMFileIdentity(path);
    if (![expected isKindOfClass:NSDictionary.class] || !current || ![expected[@"device"] isEqual:current[@"device"]] || ![expected[@"inode"] isEqual:current[@"inode"]] || ![expected[@"size"] isEqual:current[@"size"]]) {
        if (error) *error = FDMError(@"文件身份无法确认或文件已被替换；未删除文件，记录保留");
        return NO;
    }
    return [[NSFileManager defaultManager] removeItemAtPath:path error:error];
}

BOOL FDMWriteJSON(id object, NSString *path, NSError **error) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:error];
    return data && [data writeToFile:path options:NSDataWritingAtomic error:error];
}

id FDMReadJSON(NSString *path, NSError **error) {
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:error] : nil;
}

NSDictionary *FDMImmutableRecord(NSDictionary *record) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:&error];
    NSDictionary *copy = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
    return [copy isKindOfClass:NSDictionary.class] ? copy : @{};
}

BOOL FDMValidStoredRecord(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *row = value;
    if (!FDMString(row[@"key"]).length) return NO;
    NSArray *strings = @[@"url", @"name", @"path", @"relativePath", @"legacyKey", @"error", @"actionError", @"completionEvidence", @"resumeRelativePath", @"legacyResumeRelativePath"];
    for (NSString *key in strings) if (row[key] && ![row[key] isKindOfClass:NSString.class]) return NO;
    NSArray *numbers = @[@"schema", @"state", @"generation", @"taskIdentifier", @"received", @"total", @"size", @"speed", @"progress", @"time", @"completedAt", @"source", @"hostStatus", @"pausing", @"pauseIntent", @"resumeRequested", @"resumeRejected", @"usedResume", @"canResume"];
    for (NSString *key in numbers) if (row[key] && ![row[key] isKindOfClass:NSNumber.class]) return NO;
    if (!row[@"state"] || [row[@"state"] integerValue] < FDMStateDownloading || [row[@"state"] integerValue] > FDMStateInterrupted) return NO;
    if (row[@"fileIdentity"] && ![row[@"fileIdentity"] isKindOfClass:NSDictionary.class]) return NO;
    return YES;
}

BOOL FDMLegacyAliasMatches(NSDictionary *canonical, NSDictionary *legacyRecord) {
    NSString *legacy = FDMString(canonical[@"legacyKey"]);
    if (!legacy.length || !legacyRecord || [legacyRecord[@"state"] integerValue] == FDMStateCompleted || ![FDMString(legacyRecord[@"key"]) isEqual:legacy]) return NO;
    if ([legacyRecord[@"schema"] isEqual:@2]) return NO;
    return [(FDMString(legacyRecord[@"url"]) ?: legacy) isEqual:FDMString(canonical[@"url"])];
}

void FDMNotifyRecordsChanged(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:FDMRecordsDidChangeNotification object:nil];
    });
}

static dispatch_queue_t FDMLogQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("FocusDM.diagnostics", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static void FDMAppendLog(NSData *data) {
    int fd = open(FDMLogPath, O_CREAT | O_WRONLY | O_APPEND, 0600);
    if (fd < 0) return;
    struct stat info;
    // v19 uses its own bounded file; never truncate or remove an older user log.
    if (fstat(fd, &info) == 0 && info.st_size < 2 * 1024 * 1024) {
        const uint8_t *bytes = data.bytes;
        size_t done = 0;
        while (done < data.length) {
            ssize_t count = write(fd, bytes + done, data.length - done);
            if (count <= 0) break;
            done += (size_t)count;
        }
    }
    close(fd);
}

void FDMLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    static NSRegularExpression *urls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ urls = [NSRegularExpression regularExpressionWithPattern:@"https?://[^\\s\\]\"<>]+" options:NSRegularExpressionCaseInsensitive error:nil]; });
    message = [urls stringByReplacingMatchesInString:message options:0 range:NSMakeRange(0, message.length) withTemplate:@"<redacted-url>"];
    struct timeval tv;
    gettimeofday(&tv, NULL);
    NSString *line = [NSString stringWithFormat:@"%lld.%03d %@\n", (long long)tv.tv_sec, (int)(tv.tv_usec / 1000), message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    dispatch_async(FDMLogQueue(), ^{ FDMAppendLog(data); });
}

static void FDMExceptionHandler(NSException *exception) {
    FDMLog(@"exception %@: %@", exception.name, exception.reason);
    dispatch_sync(FDMLogQueue(), ^{});
    if (FDMPreviousExceptionHandler) FDMPreviousExceptionHandler(exception);
}

void FDMInstallCrashHandlers(void) {
    NSString *path = [FDMDirectory(@"FocusDM") stringByAppendingPathComponent:@"diagnostics-v19.log"];
    snprintf(FDMLogPath, sizeof(FDMLogPath), "%s", path.fileSystemRepresentation);
    FDMPreviousExceptionHandler = NSGetUncaughtExceptionHandler();
    if (FDMPreviousExceptionHandler != FDMExceptionHandler) NSSetUncaughtExceptionHandler(FDMExceptionHandler);
    // Do not replace host signal handlers. Exception diagnostics are supplementary.
    FDMLog(@"FocusDM %@ revision=%@", FDMPatchVersion(), FDMBuildRevision());
}
