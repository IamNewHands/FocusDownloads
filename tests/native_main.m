#import <Foundation/Foundation.h>
#import "FDMCommon.h"
#import "FDMStore.h"
#import <stdlib.h>

void FDMRunEngineRegression(void);
void FDMRunHostRegressionTests(void);
void FDMRunOwnerEdgeRegression(void);
void FDMRunMalformedTaskRegression(void);

static void FDMRunCommonRegression(void) {
    NSError *error = nil;
    NSCAssert(FDMValidatedURL(@" https://example.com/file?a=1 ", &error), @"valid URL");
    NSCAssert(!FDMValidatedURL(@"file:///private/file", &error), @"file URL rejected");
    NSCAssert(!FDMValidatedURL(@"https://user:password@example.com/file", &error), @"inline credential rejected");
    NSCAssert(!FDMValidatedURL(@"https:///bad", &error), @"missing host rejected");
    NSString *redacted = FDMRedactedURL(@"https://user:password@example.com/private?token=secret#fragment");
    NSCAssert(![redacted containsString:@"password"] && ![redacted containsString:@"secret"] && ![redacted containsString:@"private"], @"URL logs redacted");
    NSCAssert([FDMSafeFilename(@"../../other.txt") isEqual:@"other.txt"], @"filename basename");
    NSCAssert([FDMSafeFilename(@"..\\..\\other.txt") isEqual:@"other.txt"], @"backslash traversal");
    NSCAssert([FDMHumanSize(0) isEqual:@"0 B"], @"zero size is known");
    NSString *root = FDMDocumentsPath();
    NSCAssert([root.lastPathComponent hasPrefix:@"focusdm-engine-regression-"] && [[NSProcessInfo processInfo].environment[@"FDM_TEST_DOCUMENTS"] isEqual:root], @"test sandbox only");
    NSString *outside = [root stringByAppendingPathComponent:@"../outside.txt"];
    NSCAssert(!FDMRelativeDocumentPath(outside), @"out of root rejected");
    NSCAssert(!FDMRelativeDocumentPath([root stringByAppendingString:@"-sibling/file"]), @"sibling prefix rejected");
    NSString *dir = FDMDirectory(@"regression-files");
    NSString *owned = [dir stringByAppendingPathComponent:@"owned.txt"];
    NSString *other = [FDMDirectory(@"other-directory") stringByAppendingPathComponent:@"owned.txt"];
    NSData *content = [@"preserve unrelated" dataUsingEncoding:NSUTF8StringEncoding];
    NSCAssert([content writeToFile:owned atomically:YES] && [content writeToFile:other atomically:YES], @"fixtures written");
    NSDictionary *identity = FDMFileIdentity(owned);
    NSCAssert(identity, @"regular file identity");
    NSCAssert(!FDMRemoveOwnedFile(@{@"path": owned}, &error), @"unknown identity preserved");
    NSCAssert([[NSFileManager defaultManager] fileExistsAtPath:owned], @"unknown file remains");
    NSCAssert(FDMRemoveOwnedFile(@{@"relativePath": FDMRelativeDocumentPath(owned), @"fileIdentity": identity}, &error), @"confirmed exact file removed");
    NSCAssert([[NSFileManager defaultManager] fileExistsAtPath:other], @"same name in another directory preserved");
    NSString *directory = FDMDirectory(@"must-not-delete");
    NSCAssert(!FDMFileIdentity(directory), @"directories never treated as files");
    NSCAssert(!FDMRemoveOwnedFile(@{@"path": directory, @"fileIdentity": @{}}, &error), @"directory preserved");
    NSDictionary *canonical = @{@"key": @"legacy-id", @"legacyKey": @"https://example.com/old", @"url": @"https://example.com/old"};
    NSCAssert(FDMLegacyAliasMatches(canonical, @{@"key": @"https://example.com/old", @"state": @(FDMStatePaused)}), @"unfinished legacy snapshot may merge");
    NSCAssert(!FDMLegacyAliasMatches(canonical, @{@"key": @"https://example.com/old", @"state": @(FDMStateCompleted)}), @"completed legacy history must remain independent");
    NSCAssert(!FDMLegacyAliasMatches(canonical, @{@"key": @"https://example.com/other", @"state": @(FDMStatePaused)}), @"different legacy records never merge");
    NSCAssert(FDMValidStoredRecord(@{@"key": @"valid", @"state": @1}), @"valid legacy record accepted");
    NSCAssert(!FDMValidStoredRecord(@{@"key": @"invalid", @"state": NSNull.null}), @"null state rejected");
    NSCAssert(!FDMValidStoredRecord(@{@"key": @"invalid", @"state": @1, @"generation": NSNull.null}), @"null generation rejected");
    NSCAssert(!FDMValidStoredRecord(@{@"key": @"invalid", @"state": @1, @"url": @42}), @"non-string URL rejected");
    NSDictionary *row = @{@"key": @"common-record", @"state": @(FDMStateFailed), @"url": @"https://example.com/a"};
    NSCAssert([FDMStore.shared upsertRecord:row error:&error], @"history write");
    NSArray *before = [FDMStore.shared records];
    NSCAssert([FDMStore.shared upsertRecord:@{@"key": @"common-record", @"state": @(FDMStateCompleted)} error:&error], @"replace record");
    NSDictionary *old = [before filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"key == %@", @"common-record"]].firstObject;
    NSCAssert([old[@"state"] integerValue] == FDMStateFailed, @"history immutable snapshot survives update");
    NSCAssert([FDMStore.shared dropKey:@"common-record" error:&error], @"history drop");
    printf("common regression passed\n");
}

int main(void) {
    @autoreleasepool {
        @try {
            // The engine suite creates the one test-only Documents root before any singleton store is accessed.
            FDMRunEngineRegression();
            FDMRunCommonRegression();
            FDMRunHostRegressionTests();
            FDMRunOwnerEdgeRegression();
            FDMRunMalformedTaskRegression();
            printf("all Foundation native regression suites passed\n");
            return 0;
        } @catch (NSException *exception) {
            fprintf(stderr, "native regression failed: %s: %s\n", exception.name.UTF8String, exception.reason.UTF8String);
            return 1;
        }
    }
}
