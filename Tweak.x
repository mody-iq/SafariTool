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
    SafariTool_Diag(@"loaded", @"YES");
    SafariTool_Diag(@"processName", [[NSProcessInfo processInfo] processName]);
    SafariTool_Diag(@"bundleID", [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown");
    SafariTool_Diag(@"iosVersion", [[UIDevice currentDevice] systemVersion]);
    SafariTool_Diag(@"timestamp", [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]]);

    NSLog(@"[SafariTool][DIAG] Done. Process: %@", [[NSProcessInfo processInfo] processName]);
}
