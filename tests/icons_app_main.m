#import <UIKit/UIKit.h>
#import <stdlib.h>

void FDMRunIconRegressionTests(void);
void FDMRunFormRegressionTests(void);
void FDMRunSettingsRegressionTests(void);
void FDMRunDownloadUIRegressionTests(void);
void FDMRunPageNavigationRegressionTests(void (^completion)(NSException *));

static void FDMFinishSimulatorRegression(NSException *exception) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *result = exception ? [NSString stringWithFormat:@"FAIL %@: %@", exception.name, exception.reason] : @"PASS";
    [result writeToFile:[documents stringByAppendingPathComponent:@"regression-result.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"FocusDM simulator icon regression %@", result);
}

@interface FDMRegressionAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation FDMRegressionAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [UIViewController new];
    [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"focusdm-icons-regression-" stringByAppendingString:NSUUID.UUID.UUIDString]];
            NSError *error = nil;
            if (![[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:&error]) [NSException raise:@"FixtureCreation" format:@"%@", error];
            setenv("FDM_TEST_DOCUMENTS", root.fileSystemRepresentation, 1);
            FDMRunIconRegressionTests();
            FDMRunFormRegressionTests();
            FDMRunSettingsRegressionTests();
            FDMRunDownloadUIRegressionTests();
            FDMRunPageNavigationRegressionTests(^(NSException *exception) {
                FDMFinishSimulatorRegression(exception);
            });
        } @catch (NSException *exception) {
            FDMFinishSimulatorRegression(exception);
        }
    });
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(FDMRegressionAppDelegate.class));
    }
}
