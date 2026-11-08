#import "FDMCommon.h"
#import "FDMEngine.h"

void FDMRunMalformedTaskRegression(void) {
    NSString *root = FDMDocumentsPath();
    NSCAssert([root.lastPathComponent hasPrefix:@"focusdm-engine-regression-"], @"test root only");
    NSString *tasksPath = [FDMDirectory(@"FocusDM") stringByAppendingPathComponent:@"tasks.json"];
    NSData *saved = [NSData dataWithContentsOfFile:tasksPath];
    NSError *error = nil;
    NSDictionary *invalid = @{@"key": @"invalid-type", @"state": NSNull.null, @"generation": NSNull.null};
    NSCAssert(FDMWriteJSON(@[invalid], tasksPath, &error), @"malformed task field fixture written");
    NSData *broken = [NSData dataWithContentsOfFile:tasksPath];
    // Empty transport never creates a network task; it reports an empty system snapshot.
    Class transport = NSClassFromString(@"FDMEFakeSession");
    id session = [transport new];
    FDMEngine *engine = [[FDMEngine alloc] initForTestingWithSessionFactory:^NSURLSession *(id<NSURLSessionDelegate> delegate, NSOperationQueue *queue) {
        [session setValue:delegate forKey:@"delegate"];
        [session setValue:queue forKey:@"delegateQueue"];
        return session;
    }];
    [session performSelector:NSSelectorFromString(@"replyEnumeration")];
    [engine drainForTesting];
    NSCAssert(engine.items.count == 0 && [[NSData dataWithContentsOfFile:tasksPath] isEqual:broken], @"invalid task fields degrade without crash or overwrite");
    NSCAssert(saved && [saved writeToFile:tasksPath atomically:YES], @"restore only new fixture task file");
    printf("malformed task regression passed\n");
}
