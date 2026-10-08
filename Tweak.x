#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ============================================================
//  SafariTool - Step 9: File-based Diagnostic
//  نسجّل كل شيء في ملف نصي قابل للقراءة مباشرةً.
//  المسار: /var/mobile/Documents/SafariTool.log
// ============================================================

static NSString *const kSafariToolLogPath = @"/var/mobile/Documents/SafariTool.log";

__attribute__((unused))
static void SafariTool_Log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"%@\n", message];

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kSafariToolLogPath];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [line writeToFile:kSafariToolLogPath
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:nil];
    }

    NSLog(@"[SafariTool] %@", message);
}

// سرد كل الكلاسات التي تحتوي على كلمات مفتاحية مفيدة
__attribute__((unused))
static void SafariTool_ListRelevantClasses(void) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return;

    NSArray *keywords = @[@"Browser", @"TabDocument", @"Safari", @"WebViewController", @"PageViewController"];
    NSMutableSet *found = [NSMutableSet set];

    for (unsigned int i = 0; i < count; i++) {
        const char *name = class_getName(classes[i]);
        if (!name) continue;
        NSString *className = [NSString stringWithUTF8String:name];

        for (NSString *keyword in keywords) {
            if ([className containsString:keyword]) {
                [found addObject:className];
                break;
            }
        }
    }
    free(classes);

    SafariTool_Log(@"----- Relevant Classes Found (%lu) -----", (unsigned long)found.count);
    for (NSString *name in [found sortedArrayUsingSelector:@selector(compare:)]) {
        SafariTool_Log(@"CLASS: %@", name);
    }
    SafariTool_Log(@"----- End of class list -----");
}

%ctor {
    SafariTool_Log(@"=================================================");
    SafariTool_Log(@"SafariTool LOADED.");
    SafariTool_Log(@"Process name: %@", [[NSProcessInfo processInfo] processName]);
    SafariTool_Log(@"Bundle ID: %@", [[NSBundle mainBundle] bundleIdentifier]);
    SafariTool_Log(@"PID: %d", [[NSProcessInfo processInfo] processIdentifier]);
    SafariTool_Log(@"iOS version: %@", [[UIDevice currentDevice] systemVersion]);
    SafariTool_Log(@"-------------------------------------------------");

    SafariTool_Log(@"BrowserController exists: %d", objc_getClass("BrowserController") != NULL);
    SafariTool_Log(@"TabDocument exists: %d", objc_getClass("TabDocument") != NULL);
    SafariTool_Log(@"SFBrowserController exists: %d", objc_getClass("SFBrowserController") != NULL);
    SafariTool_Log(@"SafariViewController exists: %d", objc_getClass("SafariViewController") != NULL);
    SafariTool_Log(@"BrowserViewController exists: %d", objc_getClass("BrowserViewController") != NULL);

    SafariTool_ListRelevantClasses();

    SafariTool_Log(@"=================================================");
}
