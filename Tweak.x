#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ============================================================
//  SafariTool - Step 7: Class Hunter (Fixed v2)
//  الهدف: تحديد الكلاس المسؤول عن واجهة المستخدم في Safari
//  عبر تسجيل كل كلاس يتم الاعتراض عليه في سجل النظام.
// ============================================================

#pragma mark - قراءة الإعدادات

static NSString *const kSafariToolDomain = @"com.mody.safarittool";

__attribute__((unused))
static BOOL SafariTool_BoolPref(NSString *key, BOOL defaultValue) {
    CFStringRef appID = (__bridge CFStringRef)kSafariToolDomain;
    CFStringRef cfKey = (__bridge CFStringRef)key;
    Boolean exists = false;
    Boolean value = CFPreferencesGetAppBooleanValue(cfKey, appID, &exists);
    return exists ? (BOOL)value : defaultValue;
}

__attribute__((unused))
static BOOL SafariTool_IsEnabled(void) {
    return SafariTool_BoolPref(@"Enabled", YES);
}

__attribute__((unused))
static BOOL SafariTool_IsDownloadButtonEnabled(void) {
    return SafariTool_BoolPref(@"DownloadButtonEnabled", YES);
}

#pragma mark - الهوك (مجموعات متعددة)

// المجموعة 1: الكلاس التقليدي (iOS 14 وما قبل)
%group iOS14Group
%hook BrowserController
- (void)viewDidLoad {
    %orig;
    NSLog(@"[SafariTool][iOS14] Class: %s - viewDidLoad called.", object_getClassName(self));
}
%end
%end

// المجموعة 2: الكلاس المحتمل في iOS 15-17
%group iOS15Group
%hook TabDocument
- (void)viewDidLoad {
    %orig;
    NSLog(@"[SafariTool][iOS15] Class: %s - viewDidLoad called.", object_getClassName(self));
}
%end
%end

// المجموعة 3: الكلاس المحتمل في iOS 18+
%group iOS18Group
%hook SFBrowserController
- (void)viewDidLoad {
    %orig;
    NSLog(@"[SafariTool][iOS18] Class: %s - viewDidLoad called.", object_getClassName(self));
}
%end
%end

// المجموعة 4: كلاس بديل
%group AltGroup
%hook SafariViewController
- (void)viewDidLoad {
    %orig;
    NSLog(@"[SafariTool][Alt] Class: %s - viewDidLoad called.", object_getClassName(self));
}
%end
%end

#pragma mark - نقطة الدخول

%ctor {
    NSLog(@"[SafariTool] Tweak loaded. Starting class hunter...");

    if (objc_getClass("BrowserController")) {
        NSLog(@"[SafariTool] Found class: BrowserController");
        %init(iOS14Group);
    }

    if (objc_getClass("TabDocument")) {
        NSLog(@"[SafariTool] Found class: TabDocument");
        %init(iOS15Group);
    }

    if (objc_getClass("SFBrowserController")) {
        NSLog(@"[SafariTool] Found class: SFBrowserController");
        %init(iOS18Group);
    }

    if (objc_getClass("SafariViewController")) {
        NSLog(@"[SafariTool] Found class: SafariViewController");
        %init(AltGroup);
    }

    NSLog(@"[SafariTool] Class hunter initialized.");
}
