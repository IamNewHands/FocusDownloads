// Test-app entry point for the navigation regression.
//
// Reads TEST_ORIGIN from the bundle (written by run_navigation_simulator.py), isolates every
// FDM_TEST_DOCUMENTS path into a fresh temporary directory, runs the real module suite and
// writes PASS/FAIL to Documents/regression-result.txt for the runner to read.
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

void FDMRunNavigationRegression(NSString *origin);

@interface FDMNavigationAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation FDMNavigationAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [UIViewController new];
    [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *resultPath = [documents stringByAppendingPathComponent:@"regression-result.txt"];
        @try {
            NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [@"focusdm-navigation-regression-" stringByAppendingString:NSUUID.UUID.UUIDString]];
            NSError *error = nil;
            if (![[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES
                                           attributes:nil error:&error]) {
                [NSException raise:@"FixtureCreation" format:@"%@", error.localizedDescription];
            }
            // Every store the module touches must be isolated from the host container.
            setenv("FDM_TEST_DOCUMENTS", root.fileSystemRepresentation, 1);

            NSString *origin = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"TEST_ORIGIN"];
            if (![origin isKindOfClass:NSString.class] || !origin.length) {
                [NSException raise:@"FixtureOrigin" format:@"TEST_ORIGIN is missing from Info.plist"];
            }
            FDMRunNavigationRegression(origin);
            [@"PASS" writeToFile:resultPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSLog(@"FocusDM simulator navigation regression PASS");
        } @catch (NSException *exception) {
            NSString *result = [NSString stringWithFormat:@"FAIL %@: %@", exception.name, exception.reason];
            [result writeToFile:resultPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSLog(@"%@", result);
        }
    });
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(FDMNavigationAppDelegate.class));
    }
}
