#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kDiagDomain = @"com.mody.safarittool.diag";

__attribute__((unused))
static void SafariTool_Diag(NSString *key, NSString *value) {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kDiagDomain];
    [defaults setObject:value forKey:key];
    [defaults synchronize];
    NSLog(@"[SafariTool][DIAG] %@ = %@", key, value);
}

%ctor {
    NSString *process = [[NSProcessInfo processInfo] processName] ?: @"unknown";

    // نسجّل بمفتاح خاص لكل عملية لتفادي الكتابة فوق بعضها
    NSString *keyPrefix = [NSString stringWithFormat:@"proc_%@", process];

    SafariTool_Diag([NSString stringWithFormat:@"%@_loaded", keyPrefix], @"YES");
    SafariTool_Diag([NSString stringWithFormat:@"%@_bundleID", keyPrefix],
                    [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown");
    SafariTool_Diag([NSString stringWithFormat:@"%@_timestamp", keyPrefix],
                    [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]]);

    // نكتب مؤشراً عاماً بأن شيئاً ما حُمّل
    SafariTool_Diag(@"lastProcessName", process);
    SafariTool_Diag(@"lastBundleID", [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown");

    // فحص الكلاسات المتعلقة بـ Safari
    NSMutableString *classes = [NSMutableString string];
    NSArray *names = @[@"BrowserController", @"TabDocument", @"SFBrowserController",
                       @"SafariViewController", @"BrowserViewController",
                       @"TabBarController", @"TabController"];
    for (NSString *name in names) {
        if (objc_getClass([name UTF8String])) {
            [classes appendFormat:@"%@,", name];
        }
    }
    SafariTool_Diag(@"foundClasses", classes.length > 0 ? classes : @"none");

    NSLog(@"[SafariTool][DIAG] Done. Process: %@", process);
}
