#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ============================================================
//  SafariTool - Step 10: Multi-path Diagnostic
//  نسجّل في عدة مسارات لضمان إيجاد الملف.
// ============================================================

__attribute__((unused))
static NSArray<NSString *> *SafariTool_LogPaths(void) {
    NSMutableArray *paths = [NSMutableArray array];
    [paths addObject:@"/tmp/SafariTool.log"];
    [paths addObject:[NSTemporaryDirectory() stringByAppendingPathComponent:@"SafariTool.log"]];
    NSString *home = NSHomeDirectory();
    if (home) {
        [paths addObject:[home stringByAppendingPathComponent:@"Documents/SafariTool.log"]];
    }
    [paths addObject:@"/var/mobile/Library/Logs/SafariTool.log"];
    return paths;
}

__attribute__((unused))
static void SafariTool_Log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"%@\n", message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];

    for (NSString *path in SafariTool_LogPaths()) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = [path stringByDeletingLastPathComponent];
        if (![fm fileExistsAtPath:dir]) {
            [fm createDirectoryAtPath:dir
          withIntermediateDirectories:YES
                           attributes:nil
                                error:nil];
        }

        if (![fm fileExistsAtPath:path]) {
            [fm createFileAtPath:path contents:nil attributes:nil];
        }

        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:data];
            [fh closeFile];
        }
    }

    NSLog(@"[SafariTool] %@", message);
}

__attribute__((unused))
static void SafariTool_ListRelevantClasses(void) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return;

    NSArray *keywords = @[@"Browser", @"TabDocument", @"Safari", @"WebViewController", @"PageViewController"];
    NSMutableArray *found = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];

    for (unsigned int i = 0; i < count; i++) {
        const char *name = class_getName(classes[i]);
        if (!name) continue;
        NSString *className = [NSString stringWithUTF8String:name];

        if ([seen containsObject:className]) continue;

        for (NSString *keyword in keywords) {
            if ([className containsString:keyword]) {
                [found addObject:className];
                [seen addObject:className];
                break;
            }
        }
    }
    free(classes);

    NSArray *sortedNames = [found sortedArrayUsingSelector:@selector(compare:)];

    SafariTool_Log(@"----- Relevant Classes Found (%lu) -----", (unsigned long)sortedNames.count);
    for (NSString *name in sortedNames) {
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
    SafariTool_Log(@"Home directory: %@", NSHomeDirectory());
    SafariTool_Log(@"Temp directory: %@", NSTemporaryDirectory());
    SafariTool_Log(@"-------------------------------------------------");

    SafariTool_Log(@"BrowserController exists: %d", objc_getClass("BrowserController") != NULL);
    SafariTool_Log(@"TabDocument exists: %d", objc_getClass("TabDocument") != NULL);
    SafariTool_Log(@"SFBrowserController exists: %d", objc_getClass("SFBrowserController") != NULL);
    SafariTool_Log(@"SafariViewController exists: %d", objc_getClass("SafariViewController") != NULL);
    SafariTool_Log(@"BrowserViewController exists: %d", objc_getClass("BrowserViewController") != NULL);

    SafariTool_ListRelevantClasses();

    SafariTool_Log(@"=================================================");
}
