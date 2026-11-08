#import <Foundation/Foundation.h>
#import "FDMHostDownloads.h"
#import "FDMStore.h"

@interface FDMFakeHostTask : NSObject
@property (nonatomic) NSInteger status;
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, copy) NSString *fileName;
@property (nonatomic, copy) NSString *filePath;
@property (nonatomic, strong) NSHTTPURLResponse *response;
@property (nonatomic, strong) NSProgress *progress;
@property (nonatomic) NSInteger speed;
@property (nonatomic, strong) NSError *error;
@end
@implementation FDMFakeHostTask
@end

static FDMFakeHostTask *FDMHostFixture(NSString *path, NSInteger code) {
    FDMFakeHostTask *task = [[FDMFakeHostTask alloc] init];
    task.status = 6;
    task.url = [NSURL URLWithString:@"https://example.com/download.dat"];
    task.fileName = @"download.dat";
    task.filePath = path;
    task.response = [[NSHTTPURLResponse alloc] initWithURL:task.url statusCode:code HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Length": @"3"}];
    task.progress = [NSProgress progressWithTotalUnitCount:3];
    task.progress.completedUnitCount = 3;
    return task;
}

void FDMRunHostRegressionTests(void) {
    NSCAssert(NSThread.isMainThread, @"host adapter belongs to main");
    NSString *root = FDMDocumentsPath();
    NSCAssert(root.length && ![root isEqual:NSHomeDirectory()], @"test-only documents root already supplied by engine suite");
    FDMState expected[] = {FDMStateDownloading, FDMStateDownloading, FDMStatePaused, FDMStateFailed, FDMStateFailed,
        FDMStateInterrupted, FDMStateCompleted, FDMStateDownloading, FDMStateInterrupted, FDMStateInterrupted};
    for (NSInteger status = 0; status < 10; status++) NSCAssert(FDMHostProjectedState(status, NO) == expected[status], @"verified native status mapping %ld", (long)status);
    NSCAssert(FDMHostProjectedState(-1, NO) == FDMStateInterrupted, @"unknown negative not complete");
    NSCAssert(FDMHostProjectedState(99, NO) == FDMStateInterrupted, @"unknown positive not complete");
    NSCAssert(FDMHostProjectedState(3, YES) == FDMStatePaused, @"user pause intent overrides cancel callback");
    NSCAssert(FDMHostProjectedState(4, YES) == FDMStatePaused, @"user pause intent overrides failure callback");
    NSCAssert(FDMHostProjectedState(6, YES) == FDMStateCompleted, @"actual success wins over pause intent");

    NSString *owned = [FDMDirectory(@"host-regression") stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *sameName = [FDMDirectory(@"host-unrelated") stringByAppendingPathComponent:owned.lastPathComponent];
    NSData *body = [@"abc" dataUsingEncoding:NSUTF8StringEncoding];
    NSCAssert([body writeToFile:owned atomically:YES] && [body writeToFile:sameName atomically:YES], @"host fixtures saved");
    FDMFakeHostTask *task = FDMHostFixture(owned, 200);
    task.status = 0;
    task.speed = 0;
    NSDictionary *waiting = FDMHostProjectTask(task, @"host-waiting", NO, nil);
    NSCAssert([waiting[@"state"] integerValue] == FDMStateDownloading, @"zero speed waiting never guessed paused");
    task.status = 1;
    NSCAssert([FDMHostProjectTask(task, @"host-running", NO, nil)[@"state"] integerValue] == FDMStateDownloading, @"100 percent running never guessed completed");
    task.status = 6;
    NSDictionary *complete = FDMHostProjectTask(task, @"host-complete", NO, nil);
    NSCAssert([complete[@"state"] integerValue] == FDMStateCompleted && complete[@"fileIdentity"], @"status6 + HTTP success + regular file verified");
    NSCAssert([complete[@"completionEvidence"] isEqual:@"host-status-http-file"], @"completion evidence recorded");
    task.response = [[NSHTTPURLResponse alloc] initWithURL:task.url statusCode:404 HTTPVersion:@"HTTP/1.1" headerFields:nil];
    NSCAssert([FDMHostProjectTask(task, @"host-http-error", NO, nil)[@"state"] integerValue] != FDMStateCompleted, @"HTTP404 body cannot complete even status6");
    task.response = nil;
    NSCAssert([FDMHostProjectTask(task, @"host-no-response", NO, nil)[@"state"] integerValue] != FDMStateCompleted, @"missing HTTP response not completed");
    task.response = [[NSHTTPURLResponse alloc] initWithURL:task.url statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:nil];
    task.filePath = FDMDirectory(@"host-directory-not-file");
    NSCAssert([FDMHostProjectTask(task, @"host-directory", NO, nil)[@"state"] integerValue] != FDMStateCompleted, @"directory not claimed as downloaded file");
    task.filePath = [root stringByAppendingPathComponent:@"no-such-host-file"];
    NSCAssert([FDMHostProjectTask(task, @"host-missing", NO, nil)[@"state"] integerValue] != FDMStateCompleted, @"missing file not completed");
    task.filePath = owned;
    NSMutableDictionary *wrong = [complete mutableCopy];
    NSMutableDictionary *identity = [complete[@"fileIdentity"] mutableCopy];
    identity[@"inode"] = @([identity[@"inode"] unsignedLongLongValue] + 1);
    wrong[@"fileIdentity"] = identity;
    NSCAssert([FDMHostProjectTask(task, @"host-complete", NO, wrong)[@"state"] integerValue] != FDMStateCompleted, @"changed inode not silently re-owned");
    task.filePath = sameName;
    NSCAssert([FDMHostProjectTask(task, @"host-complete", NO, complete)[@"state"] integerValue] != FDMStateCompleted, @"changed path not silently re-owned");
    task.filePath = owned;
    task.status = 4;
    task.error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
    NSDictionary *paused = FDMHostProjectTask(task, @"host-paused", YES, nil);
    NSCAssert([paused[@"state"] integerValue] == FDMStatePaused && ![paused[@"canResume"] boolValue] && !paused[@"error"], @"pause callback does not overwrite user intent or claim resume");

    FDMHostDownloads *adapter = FDMHostDownloads.shared;
    FDMFakeHostTask *first = FDMHostFixture(owned, 200);
    FDMFakeHostTask *second = FDMHostFixture(sameName, 200);
    [NSNotificationCenter.defaultCenter postNotificationName:@"kTaskSuccessNotification" object:first];
    [NSNotificationCenter.defaultCenter postNotificationName:@"kTaskSuccessNotification" object:second];
    NSArray *rows = [adapter rows];
    NSMutableArray *matches = [NSMutableArray array];
    for (NSDictionary *row in rows) if ([row[@"url"] isEqual:first.url.absoluteString]) [matches addObject:row];
    NSCAssert(matches.count == 2, @"same URL task instances preserve distinct attempts");
    NSCAssert(![matches[0][@"key"] isEqual:matches[1][@"key"]], @"same URL gets distinct hostUUID keys");
    [NSNotificationCenter.defaultCenter postNotificationName:@"kTaskSuccessNotification" object:first];
    NSCAssert([adapter rows].count == rows.count, @"repeat event for same wrapper idempotent");
    NSDictionary *firstRecord = nil;
    for (NSDictionary *row in matches) if ([row[@"path"] isEqual:owned]) firstRecord = row;
    __block NSError *failure = nil;
    __block BOOL called = NO;
    [adapter removeKey:firstRecord[@"key"] deleteFile:NO completion:^(NSError *error) { called = YES; failure = error; }];
    NSCAssert(called && !failure, @"record-only deletion reports completion");
    NSCAssert([[NSFileManager defaultManager] fileExistsAtPath:owned], @"record-only deletion preserves saved file");
    NSCAssert([[NSFileManager defaultManager] fileExistsAtPath:sameName], @"unrelated same-name file preserved");
    NSCAssert([adapter isSuppressedKey:firstRecord[@"key"]], @"deleted host attempt tombstoned");
    [NSNotificationCenter.defaultCenter postNotificationName:@"kTaskSuccessNotification" object:first];
    for (NSDictionary *row in [adapter rows]) NSCAssert(![row[@"key"] isEqual:firstRecord[@"key"]], @"deleted task does not reappear after late callback");

    // Only these newly created test fixtures are deleted by the owned-file API.
    NSDictionary *secondRecord = nil;
    for (NSDictionary *row in [adapter rows]) if ([row[@"path"] isEqual:sameName]) secondRecord = row;
    [adapter removeKey:secondRecord[@"key"] deleteFile:YES completion:^(NSError *error) { failure = error; }];
    NSCAssert(!failure && ![[NSFileManager defaultManager] fileExistsAtPath:sameName], @"verified host file deletion affects one exact path");
    NSCAssert([[NSFileManager defaultManager] fileExistsAtPath:owned], @"other same-name file is not deleted");
    printf("host regression passed\n");
}
