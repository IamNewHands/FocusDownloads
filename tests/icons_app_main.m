#import <UIKit/UIKit.h>
#import <stdlib.h>

void FDMRunIconRegressionTests(void);
void FDMRunFormRegressionTests(void);

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
            NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            [@"PASS" writeToFile:[documents stringByAppendingPathComponent:@"regression-result.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSLog(@"FocusDM simulator icon regression PASS");
        } @catch (NSException *exception) {
            NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            NSString *result = [NSString stringWithFormat:@"FAIL %@: %@", exception.name, exception.reason];
            [result writeToFile:[documents stringByAppendingPathComponent:@"regression-result.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSLog(@"%@", result);
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
