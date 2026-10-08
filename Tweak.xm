#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

// ============================================================
//  SafariTool - Foundation (Based on proven WKWebView technique)
//  Features: Force Copy + Desktop Mode
// ============================================================

static NSString *const kSTGuardVersion = @"0.2.1";
static const NSInteger kSTCrashLimit = 3;
static const double kSTSurviveSeconds = 6.0;

static char kSTInstalledKey;

typedef void (^STDecisionHandler)(WKNavigationActionPolicy, WKWebpagePreferences *);

// ---------- قراءة الإعدادات (طريقة موثوقة من sandbox) ----------

static id ST_GlobalVal(NSString *key) {
    CFPropertyListRef cf = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                    kCFPreferencesAnyApplication);
    if (!cf) {
        return nil;
    }
    return CFBridgingRelease(cf);
}

static id ST_RawPref(NSString *key) {
    id v = nil;
    @try {
        v = ST_GlobalVal(key);
        if (v) {
            return v;
        }
        v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    } @catch (NSException *e) {
    }
    return v;
}

static BOOL ST_Pref(NSString *key, BOOL def) {
    id v = ST_RawPref(key);
    if ([v respondsToSelector:@selector(boolValue)]) {
        return [v boolValue];
    }
    return def;
}

// ---------- حماية من الانهيار المتكرر ----------

static BOOL ST_GuardBegin(void) {
    @try {
        NSUserDefaults *std = [NSUserDefaults standardUserDefaults];

        NSString *savedVersion = [std stringForKey:@"STGuardVersion"];
        if (![savedVersion isEqualToString:kSTGuardVersion]) {
            [std setObject:kSTGuardVersion forKey:@"STGuardVersion"];
            [std setInteger:0 forKey:@"STCrashCount"];
            [std setBool:NO forKey:@"STTripped"];
            [std setBool:NO forKey:@"STPending"];
        }

        if ([std boolForKey:@"STTripped"]) {
            [std synchronize];
            return NO;
        }

        if ([std boolForKey:@"STPending"]) {
            NSInteger count = [std integerForKey:@"STCrashCount"] + 1;
            [std setInteger:count forKey:@"STCrashCount"];
            if (count >= kSTCrashLimit) {
                [std setBool:YES forKey:@"STTripped"];
                [std setBool:NO forKey:@"STPending"];
                [std synchronize];
                return NO;
            }
        }

        [std setBool:YES forKey:@"STPending"];
        [std synchronize];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSTSurviveSeconds * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NSUserDefaults *s = [NSUserDefaults standardUserDefaults];
            [s setBool:NO forKey:@"STPending"];
            [s setInteger:0 forKey:@"STCrashCount"];
            [s synchronize];
        });
        return YES;
    } @catch (NSException *e) {
        return NO;
    }
}

// ---------- ميزة سطح المكتب ----------

static BOOL ST_DesktopEffective(void) {
    @try {
        id ov = [[NSUserDefaults standardUserDefaults] objectForKey:@"STDesktopOverride"];
        if ([ov respondsToSelector:@selector(boolValue)]) {
            return [ov boolValue];
        }
    } @catch (NSException *e) {
    }
    return ST_Pref(@"SafariTool_Desktop", NO);
}

static void ST_PatchDelegateClass(Class cls) {
    if (!cls) {
        return;
    }
    static NSMutableSet *done = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        done = [NSMutableSet set];
    });
    NSString *name = NSStringFromClass(cls);
    @synchronized (done) {
        if ([done containsObject:name]) {
            return;
        }
        [done addObject:name];
    }

    SEL sel = @selector(webView:decidePolicyForNavigationAction:preferences:decisionHandler:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        return;
    }
    IMP orig = method_getImplementation(m);
    const char *types = method_getTypeEncoding(m);
    if (!orig || !types) {
        return;
    }

    IMP newImp = imp_implementationWithBlock(
        ^(id self_, WKWebView *wv, WKNavigationAction *action, WKWebpagePreferences *prefs,
          STDecisionHandler handler) {
            BOOL should = NO;
            @try {
                BOOL isMain = (!action.targetFrame || action.targetFrame.isMainFrame);
                NSString *scheme = [action.request.URL.scheme lowercaseString];
                BOOL web = ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]);
                should = (isMain && web && ST_DesktopEffective());
            } @catch (NSException *e) {
                should = NO;
            }

            STDecisionHandler wrapped = handler;
            if (should && handler) {
                wrapped = ^(WKNavigationActionPolicy policy, WKWebpagePreferences *pp) {
                    WKWebpagePreferences *use = pp;
                    if (!use) {
                        use = prefs;
                    }
                    if (!use) {
                        use = [[WKWebpagePreferences alloc] init];
                    }
                    use.preferredContentMode = WKContentModeDesktop;
                    handler(policy, use);
                };
            }

            ((void (*)(id, SEL, WKWebView *, WKNavigationAction *, WKWebpagePreferences *,
                       STDecisionHandler))orig)(self_, sel, wv, action, prefs, wrapped);
        });
    class_replaceMethod(cls, sel, newImp, types);
}

WK// ---------- ميزة نسخ النص بالقوة (JS) ----------

static NSString *ST_ForceCopyJS(void) {
    static NSString *js = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *lines = @[
            @"(function () {",
            @"  if (window.__stForceCopy) { return; }",
            @"  window.__stForceCopy = true;",
            @"  var css = '*,*::before,*::after{-webkit-user-select:text !important;user-select:text !important;-webkit-touch-callout:default !important;}';",
            @"  function injectStyle() {",
            @"    try {",
            @"      var s = document.createElement('style');",
            @"      s.setAttribute('data-st', 'forcecopy');",
            @"      s.textContent = css;",
            @"      (document.head || document.documentElement).appendChild(s);",
            @"    } catch (e) {}",
            @"  }",
            @"  injectStyle();",
            @"  var evts = ['copy', 'cut', 'contextmenu', 'selectstart', 'dragstart'];",
            @"  evts.forEach(function (n) {",
            @"    window.addEventListener(n, function (e) { e.stopImmediatePropagation(); }, true);",
            @"  });",
            @"  var attrs = ['oncopy', 'oncut', 'oncontextmenu', 'onselectstart', 'ondragstart'];Web",
            @"  function clean(elView) {",
            @"    try {",
            *) @"      attrs.forEach(function (a) {",
           r @"        if (el && el.hasAttribute && el.hasAttribute);
(a)) { el.removeAttribute(a); }",
            @"      });",
            @"    } catch (e) {}",
            @"  }",
            @"  function cleanAll() {",
            @"    try {",
            @"      clean(document.documentElement);",
            @"      if (document.body) { clean(document.body); }",
            @"      attrs.forEach(function (a) { document[a] = null; });",
            @"      var list = document.querySelectorAll('[oncopy],[oncut],[oncontextmenu],[onselectstart],[ondragstart]');",
            @"      for (var i = 0; i < list.length; i++) { clean(list[i]); }",
            @"    } catch (e) {}",
            @"  }",
            @"  cleanAll();",
            @"  var timer = null;",
            @"  function schedule() {",
            @"    if (timer) { return; }",
            @"    timer = setTimeout(function () { timer = null; cleanAll(); }, 300);",
            @"  }",
            @"  document.addEventListener('DOMContentLoaded', function () { injectStyle(); cleanAll(); });",
            @"  window.addEventListener('load', cleanAll);",
            @"  try {",
            @"    new MutationObserver(schedule).observe(document.documentElement, {",
            @"      childList: true,",
            @"      subtree: true,",
            @"      attributes: true,",
            @"      attributeFilter: attrs",
            @"    });",
            @"  } catch (e) {}",
            @"})();"
        ];
        js = [lines componentsJoinedByString:@"\n"];
    });
    return js;
}

static void ST_InstallScripts(WKWebView *wv) {
    @try {
        WKUserContentController *ucc = wv.configuration.userContentController;
        if (!ucc) {
            return;
        }
        if (objc_getAssociatedObject(ucc, &kSTInstalledKey)) {
            return;
        }
        objc_setAssociatedObject(ucc, &kSTInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        if (ST_Pref(@"SafariTool_ForceCopy", YES)) {
            WKUserScript *script =
                [[WKUserScript alloc] initWithSource:ST_ForceCopyJS()
                                       injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                    forMainFrameOnly:NO];
            [ucc addUserScript:script];
        }
    } @catch (NSException *e) {
    }
}

// ---------- الهوك ----------

%group STWebKit

%hook WKWebView

- (id)initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration {
    id r = %orig;
    if (r) {
        ST_InstallScripts((    }
    return r;
}

- (void)setNavigationDelegate:(id<WKNavigationDelegate>)delegate {
    %orig;
    if (delegate) {
        ST_PatchDelegateClass([(NSObject *)delegate class]);
    }
}

%end

%end

// ---------- نقطة الدخول ----------

%ctor {
    @autoreleasepool {
        if (![[[NSProcessInfo processInfo] processName] isEqualToString:@"MobileSafari"]) {
            return;
        }
        if (![[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){16, 0, 0}]) {
            return;
        }
        if (!objc_getClass("WKWebView")) {
            return;
        }
        if (!ST_GuardBegin()) {
            return;
        }
        if (!ST_Pref(@"SafariTool_Enabled", YES)) {
            return;
        }
        %init(STWebKit);
    }
}
