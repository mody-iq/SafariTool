#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// ============================================================
//  SafariTool - Step 7: Class Hunter
//  الهدف: تحديد الكلاس المسؤول عن واجهة المستخدم في Safari
//  عبر تسجيل كل كلاس يتم الاعتراض عليه في سجل النظام.
// ============================================================

#pragma mark - قراءة الإعدادات

static NSString *const kSafariToolDomain = @"com.mody.safarittool";

static BOOL SafariTool_BoolPref(NSString *key, BOOL defaultValue) {
    CFStringRef appID = (__bridge CFStringRef)kSafariToolDomain;
    CFStringRef cfKey = (__bridge CFStringRef)key;
    Boolean exists = false;
    Boolean value = CFPreferencesGetAppBooleanValue(cfKey, appID, &exists);
    return exists ? (BOOL)value : defaultValue;
}

static inline BOOL SafariTool_IsEnabled(void) {
    return SafariTool_BoolPref(@"Enabled", YES);
}

static inline BOOL SafariTool_IsDownloadButtonEnabled(void) {
    return SafariTool_BoolPref(@"DownloadButtonEnabled", YES);
}

#pragma mark - الهوك (مجموعات متعددة)

// %group يستخدم لتجميع الهوكات المتعلقة بكلاس معين.
// سيتم تفعيل كل مجموعة داخل %ctor بناءً على ما هو موجود في النظام.

// المجموعة 1: الكلاس التقليدي (iOS 14 وما قبل)
%group iOS14Group
%hook BrowserController
- (void)viewDidLoad {
    %orig;
    NSLog(@"[SafariTool][iOS14] Class: %@ - viewDidLoad called.", NSStringFromClass([self class]));
}
%end
%end

// المجموعة 2: الكلاس المحتمل في iOS 15-17
%group iOS15Group
%hook TabDocument
- (void)viewDidLoad {
    %orig;
    NSLog(@"[SafariTool][iOS15] Class: %@ - viewDidLoad called.", NSStringFromClass([self class]));
}
%end
%end

// المجموعة 3: الكلاس المحتمل في iOS 18+
%group iOS18Group
%hook SFBrowserController
- (void)viewDidLoad {
    %orig;
    NSLog(@"[SafariTool][iOS18] Class: %@ - viewDidLoad called.", NSStringFromClass([self class]));
}
%end
%end

// المجموعة 4: كلاس بديل
%group AltGroup
%hook SafariViewController
- (void)viewDidLoad {
    %orig;
    NSLog(@"[SafariTool][Alt] Class: %@ - viewDidLoad called.", NSStringFromClass([self class]));
}
%end
%end

#pragma mark - نقطة الدخول

%ctor {
    NSLog(@"[SafariTool] Tweak loaded. Starting class hunter...");

    // تفعيل كل مجموعة فقط إذا كان الكلاس موجوداً في النظام.
    // هذا يتفادى أخطاء "class not found" ويمنع تعليق العملية.

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
