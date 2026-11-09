#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "FDMCommon.h"

void FDMRunFormRegressionTests(void) {
    Class cls = NSClassFromString(@"FDMURLInputController");
    NSCAssert(cls, @"form controller is compiled into simulator fixture");
    UIViewController *form = [[cls alloc] init];
    [form loadViewIfNeeded];
    UITextView *address = [form valueForKey:@"address"];
    address.text = @"https://fixture.invalid/single";
    __block NSUInteger calls = 0;
    BOOL (^success)(NSString *, NSError **) = ^BOOL(NSString *url, NSError **error) { calls++; return YES; };
    [form setValue:success forKey:@"submitURL"];
    SEL submit = NSSelectorFromString(@"submit");
    ((void (*)(id, SEL))objc_msgSend)(form, submit);
    ((void (*)(id, SEL))objc_msgSend)(form, submit);
    NSCAssert(calls == 1 && !form.navigationItem.rightBarButtonItem.enabled, @"successful submit is consumed exactly once");
    UIViewController *retry = [[cls alloc] init];
    [retry loadViewIfNeeded];
    __block BOOL allowed = NO;
    __block NSUInteger tries = 0;
    BOOL (^attempt)(NSString *, NSError **) = ^BOOL(NSString *url, NSError **error) {
        tries++;
        if (!allowed && error) *error = FDMError(@"fixture rejected address");
        return allowed;
    };
    [retry setValue:attempt forKey:@"submitURL"];
    UITextView *input = [retry valueForKey:@"address"];
    input.text = @"https://fixture.invalid/user-input";
    ((void (*)(id, SEL))objc_msgSend)(retry, submit);
    NSCAssert(tries == 1 && retry.navigationItem.rightBarButtonItem.enabled && [input.text isEqual:@"https://fixture.invalid/user-input"], @"failed submit preserves input and permits retry");
    allowed = YES;
    ((void (*)(id, SEL))objc_msgSend)(retry, submit);
    ((void (*)(id, SEL))objc_msgSend)(retry, submit);
    NSCAssert(tries == 2 && !retry.navigationItem.rightBarButtonItem.enabled, @"retry succeeds once without duplicate download action");
    NSLog(@"form regression PASS");
}
