#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
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
    @autoreleasepool {
        NSString *process = [[NSProcessInfo processInfo] processName] ?: @"unknown";
        NSString *keyPrefix = [NSString stringWithFormat:@"proc_%@", process];

        SafariTool_Diag([NSString stringWithFormat:@"%@_loaded", keyPrefix], @"YES");
        SafariTool_Diag([NSString stringWithFormat:@"%@_bundleID", keyPrefix],
                        [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown");
        SafariTool_Diag([NSString stringWithFormat:@"%@_timestamp", keyPrefix],
                        [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]]);

        SafariTool_Diag(@"lastProcessName", process);
        SafariTool_Diag(@"lastBundleID", [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown");

        NSMutableString *classes = [NSMutableString string];
        NSArray *names = @[@"WKWebView", @"BrowserController", @"TabDocument",
                           @"SFBrowserController", @"SafariViewController", @"BrowserViewController"];
        for (NSString *name in names) {
            if (objc_getClass([name UTF8String])) {
                [classes appendFormat:@"%@,", name];
            }
        }
        SafariTool_Diag(@"foundClasses", classes.length > 0 ? classes : @"none");

        NSLog(@"[SafariTool][DIAG] Done. Process: %@", process);
    }
}
