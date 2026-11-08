// Edge cases use the same fake transport types as the main engine suite.
#import <Foundation/Foundation.h>
#import "FDMEngine.h"
#import "FDMStore.h"

@interface FDMEFakeTask : NSObject
@property (nonatomic, copy) NSString *taskDescription;
@property (nonatomic) NSUInteger taskIdentifier;
@property (nonatomic) NSURLSessionTaskState state;
@end
@interface FDMEFakeSession : NSObject
@property (nonatomic, weak) id<NSURLSessionDownloadDelegate> delegate;
@property (nonatomic, strong) NSOperationQueue *delegateQueue;
@property (nonatomic, copy) NSArray<FDMEFakeTask *> *enumerationSnapshot;
@property (nonatomic, strong) NSMutableArray<FDMEFakeTask *> *created;
- (void)replyEnumeration;
- (void)finishTask:(FDMEFakeTask *)task status:(NSInteger)status temporaryURL:(NSURL *)url;
- (void)abandonForSimulatedExit;
@end

static FDMEngine *EdgeEngine(FDMEFakeSession *session) {
    FDMEngine *engine = [[FDMEngine alloc] initForTestingWithSessionFactory:^NSURLSession *(id<NSURLSessionDelegate> delegate, NSOperationQueue *queue) {
        session.delegate = (id<NSURLSessionDownloadDelegate>)delegate;
        session.delegateQueue = queue;
        return (NSURLSession *)(id)session;
    }];
    [session replyEnumeration];
    [engine drainForTesting];
    return engine;
}

static void EdgeFlushMain(void) {
    __block BOOL complete = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ complete = YES; });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
    while (!complete && deadline.timeIntervalSinceNow > 0) [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    NSCAssert(complete, @"main queue handoff timed out");
}

void FDMRunOwnerEdgeRegression(void) {
    NSString *root = FDMDocumentsPath();
    NSCAssert([root.lastPathComponent hasPrefix:@"focusdm-engine-regression-"], @"fixture root supplied by main engine suite");
    NSString *tasksPath = [FDMDirectory(@"FocusDM") stringByAppendingPathComponent:@"tasks.json"];
    NSString *deletedPath = [FDMDirectory(@"FocusDM") stringByAppendingPathComponent:@"deleted-task-ids.json"];
    NSError *error = nil;
    NSCAssert(FDMWriteJSON(@[], tasksPath, &error) && FDMWriteJSON(@[], deletedPath, &error), @"new owner fixtures reset");
    FDMEFakeSession *session = [FDMEFakeSession new];
    FDMEngine *engine = EdgeEngine(session);
    NSString *key = [engine startURL:@"https://fixture.invalid/finish-only" name:@"finish-only.bin" error:&error];
    NSCAssert(key, @"edge task created");
    NSString *savedTasks = [tasksPath stringByAppendingString:@".retained-finish-only"];
    NSCAssert([[NSFileManager defaultManager] moveItemAtPath:tasksPath toPath:savedTasks error:&error], @"retain fixture tasks");
    NSCAssert([[NSFileManager defaultManager] createDirectoryAtPath:tasksPath withIntermediateDirectories:NO attributes:nil error:&error], @"block only this new fixture tasks write");
    NSData *body = [@"finish durable before didComplete" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *temporary = [FDMDirectory(@"owner-edge-files") stringByAppendingPathComponent:@"temp-download.bin"];
    NSCAssert([body writeToFile:temporary atomically:YES], @"temporary payload fixture");
    [session finishTask:session.created.lastObject status:200 temporaryURL:[NSURL fileURLWithPath:temporary]];
    NSDictionary *durable = [FDMStore.shared recordForKey:key];
    NSCAssert([durable[@"state"] integerValue] == FDMStateCompleted && durable[@"fileIdentity"], @"success evidence committed during finish callback");
    [session abandonForSimulatedExit];
    engine = nil;
    NSString *retainedBlocker = [tasksPath stringByAppendingString:@".retained-write-blocker"];
    NSCAssert([[NSFileManager defaultManager] moveItemAtPath:tasksPath toPath:retainedBlocker error:&error] && [[NSFileManager defaultManager] moveItemAtPath:savedTasks toPath:tasksPath error:&error], @"restore stale fixture tasks without flushing terminal state");
    session = [FDMEFakeSession new];
    engine = EdgeEngine(session);
    for (NSDictionary *row in engine.items) NSCAssert(![row[@"key"] isEqual:key], @"durable finish wins over stale downloading tasks");
    NSCAssert([[NSData dataWithContentsOfFile:FDMResolveDocumentPath([FDMStore.shared recordForKey:key])] isEqual:body], @"finished file retained across simulated exit");

    __block NSUInteger first = 0, second = 0;
    [engine setBackgroundCompletion:^{ first++; }];
    [engine drainForTesting];
    [engine URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)(id)session];
    [engine drainForTesting]; EdgeFlushMain();
    NSCAssert(first == 1, @"first handoff consumed once");
    [engine URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)(id)session];
    [engine setBackgroundCompletion:^{ second++; }];
    __block NSUInteger parallel = 0;
    [engine setBackgroundCompletion:^{ parallel++; }];
    [engine drainForTesting]; EdgeFlushMain();
    NSCAssert(second == 0, @"old duplicate finish cannot release a new batch");
    [engine URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)(id)session];
    [engine drainForTesting]; EdgeFlushMain();
    NSCAssert(second == 1 && parallel == 1, @"new batch preserves every handler and waits for its own finish signal");

    NSData *broken = [@"{malformed deletion journal" dataUsingEncoding:NSUTF8StringEncoding];
    NSCAssert([broken writeToFile:deletedPath atomically:YES], @"malformed journal fixture");
    session = [FDMEFakeSession new];
    engine = EdgeEngine(session);
    __block NSError *failure;
    [engine removeKey:@"unknown" deleteFile:NO completion:^(NSError *problem) { failure = problem; }];
    [engine drainForTesting]; EdgeFlushMain();
    NSCAssert(failure && [[NSData dataWithContentsOfFile:deletedPath] isEqual:broken], @"unreadable journal is never overwritten by record deletion");
    NSCAssert(FDMWriteJSON(@[], deletedPath, &error), @"restore only this fixture journal");

    NSData *history = [NSData dataWithContentsOfFile:[FDMDirectory(@"FocusDM") stringByAppendingPathComponent:@"history.json"]];
    NSString *historyPath = [FDMDirectory(@"FocusDM") stringByAppendingPathComponent:@"history.json"];
    NSCAssert(FDMWriteJSON(@{@"records": @42}, historyPath, &error), @"invalid container fixture");
    FDMStore *isolated = [FDMStore new];
    NSCAssert((isolated.records.count == 0 && ![isolated upsertRecord:@{@"key": @"forbidden", @"state": @1} error:&error]), @"invalid records container degrades without exception or overwrite");
    NSCAssert(history && [history writeToFile:historyPath atomically:YES], @"restore only fixture history");
    printf("owner edge regression: finish-only durability, background batch, damaged storage passed\n");
}
