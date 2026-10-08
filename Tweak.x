#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// ============================================================
//  SafariTool - Step 5: Download Button (Initial Test)
//  الهدف: التحقق من عمل %hook وإضافة زر في شريط التنقل
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

#pragma mark - الواجهات الأمامية

@interface BrowserController : UIViewController
@end

#pragma mark - الهوك

%hook BrowserController

- (void)viewDidLoad {
    %orig;

    if (!SafariTool_IsEnabled() || !SafariTool_IsDownloadButtonEnabled()) {
        return;
    }

    UIBarButtonItem *existing = self.navigationItem.rightBarButtonItem;
    if (existing && [existing.accessibilityIdentifier isEqualToString:@"SafariToolDownloadBtn"]) {
        return;
    }

    UIBarButtonItem *downloadButton = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                             target:self
                             action:@selector(safaritool_downloadTapped:)];

    downloadButton.accessibilityIdentifier = @"SafariToolDownloadBtn";
    downloadButton.tintColor = [UIColor systemBlueColor];

    self.navigationItem.rightBarButtonItem = downloadButton;

    NSLog(@"[SafariTool] Download button injected into BrowserController.");
}

- (void)safaritool_downloadTapped:(UIBarButtonItem *)sender {
    NSLog(@"[SafariTool] Download button tapped.");

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"SafariTool"
                         message:@"زر التنزيل يعمل بنجاح!\n\nفي الخطوة التالية سنضيف منطق التنزيل الفعلي."
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"حسناً"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];

    [self presentViewController:alert animated:YES completion:nil];
}

%end
