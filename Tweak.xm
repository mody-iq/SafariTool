#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>

static NSString *const kSTGuardVersion = @"0.4.3";
static const NSInteger kSTCrashLimit = 3;
static const double kSTSurviveSeconds = 6.0;

static char kSTInstalledKey;
static char kSTMessageHandlerKey;

typedef void (^STDecisionHandler)(WKNavigationActionPolicy, WKWebpagePreferences *);

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

static UIViewController *ST_TopViewController(void) {
    UIWindow *keyWindow = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) {
                    keyWindow = w;
                    break;
                }
            }
            if (keyWindow) {
                break;
            }
        }
    }
    if (!keyWindow) {
        keyWindow = [UIApplication sharedApplication].keyWindow;
    }
    UIViewController *vc = keyWindow.rootViewController;
    while (vc.presentedViewController) {
        vc = vc.presentedViewController;
    }
    return vc;
}

static void ST_ShowResultAlert(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = ST_TopViewController();
        if (!top) {
            return;
        }
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [top presentViewController:alert animated:YES completion:nil];
    });
}

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

static NSString *ST_ForceCopyJS(void) {
    static NSString *js = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableString *s = [NSMutableString string];
        [s appendString:@"(function(){"];
        [s appendString:@"if(window.__stForceCopy){return;}"];
        [s appendString:@"window.__stForceCopy=true;"];
        [s appendString:@"var css='*,*::before,*::after{-webkit-user-select:text !important;user-select:text !important;-webkit-touch-callout:default !important;}';"];
        [s appendString:@"function injectStyle(){try{var st=document.createElement('style');st.setAttribute('data-st','forcecopy');st.textContent=css;(document.head||document.documentElement).appendChild(st);}catch(e){}}"];
        [s appendString:@"injectStyle();"];
        [s appendString:@"var evts=['copy','cut','contextmenu','selectstart','dragstart'];"];
        [s appendString:@"evts.forEach(function(n){window.addEventListener(n,function(e){e.stopImmediatePropagation();},true);});"];
        [s appendString:@"var attrs=['oncopy','oncut','oncontextmenu','onselectstart','ondragstart'];"];
        [s appendString:@"function clean(el){try{attrs.forEach(function(a){if(el&&el.hasAttribute&&el.hasAttribute(a)){el.removeAttribute(a);}});}catch(e){}}"];
        [s appendString:@"function cleanAll(){try{clean(document.documentElement);if(document.body){clean(document.body);}attrs.forEach(function(a){document[a]=null;});var list=document.querySelectorAll('[oncopy],[oncut],[oncontextmenu],[onselectstart],[ondragstart]');for(var i=0;i<list.length;i++){clean(list[i]);}}catch(e){}}"];
        [s appendString:@"cleanAll();"];
        [s appendString:@"var timer=null;"];
        [s appendString:@"function schedule(){if(timer){return;}timer=setTimeout(function(){timer=null;cleanAll();},300);}"];
        [s appendString:@"document.addEventListener('DOMContentLoaded',function(){injectStyle();cleanAll();});"];
        [s appendString:@"window.addEventListener('load',cleanAll);"];
        [s appendString:@"try{new MutationObserver(schedule).observe(document.documentElement,{childList:true,subtree:true,attributes:true,attributeFilter:attrs});}catch(e){}"];
        [s appendString:@"})();"];
        js = [s copy];
    });
    return js;
}

static NSString *ST_VideoDetectorJS(void) {
    static NSString *js = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableString *s = [NSMutableString string];
        [s appendString:@"(function(){"];
        [s appendString:@"if(window.__stVideoDetector){return;}"];
        [s appendString:@"window.__stVideoDetector=true;"];
        [s appendString:@"var btn=null;var lastUrl=null;"];
        [s appendString:@"function pickBestSource(v){"];
        [s appendString:@"try{"];
        [s appendString:@"var sources=v.querySelectorAll('source');"];
        [s appendString:@"for(var i=0;i<sources.length;i++){"];
        [s appendString:@"var t=(sources[i].type||'').toLowerCase();"];
        [s appendString:@"var sr=(sources[i].src||'').toLowerCase();"];
        [s appendString:@"if(t.indexOf('mp4')>=0||sr.indexOf('.mp4')>=0){return sources[i].src;}"];
        [s appendString:@"}"];
        [s appendString:@"for(var i=0;i<sources.length;i++){"];
        [s appendString:@"var t=(sources[i].type||'').toLowerCase();"];
        [s appendString:@"var sr=(sources[i].src||'').toLowerCase();"];
        [s appendString:@"if(t.indexOf('mov')>=0||sr.indexOf('.mov')>=0){return sources[i].src;}"];
        [s appendString:@"}"];
        [s appendString:@"for(var i=0;i<sources.length;i++){"];
        [s appendString:@"var t=(sources[i].type||'').toLowerCase();"];
        [s appendString:@"var sr=(sources[i].src||'').toLowerCase();"];
        [s appendString:@"if(t.indexOf('m4v')>=0||sr.indexOf('.m4v')>=0){return sources[i].src;}"];
        [s appendString:@"}"];
        [s appendString:@"if(v.currentSrc)return v.currentSrc;"];
        [s appendString:@"if(v.src)return v.src;"];
        [s appendString:@"for(var i=0;i<sources.length;i++){"];
        [s appendString:@"if(sources[i].src)return sources[i].src;"];
        [s appendString:@"}"];
        [s appendString:@"}catch(e){}"];
        [s appendString:@"return null;"];
        [s appendString:@"}"];
        [s appendString:@"function showButton(url){"];
        [s appendString:@"if(btn&&lastUrl===url){return;}"];
        [s appendString:@"if(btn){btn.remove();btn=null;}"];
        [s appendString:@"lastUrl=url;"];
        [s appendString:@"btn=document.createElement('div');"];
        [s appendString:@"btn.id='st-dl-btn';"];
        [s appendString:@"btn.style.cssText='position:fixed;bottom:100px;right:20px;z-index:2147483647;background:#007AFF;color:#fff;padding:12px 20px;border-radius:25px;font-size:16px;font-weight:bold;box-shadow:0 4px 12px rgba(0,0,0,0.3);cursor:pointer;font-family:-apple-system;';"];
        [s appendString:@"btn.textContent='Download Video';"];
        [s appendString:@"btn.onclick=function(){try{btn.textContent='Starting...';window.webkit.messageHandlers.stDownload.postMessage({url:lastUrl});}catch(e){}};"];
        [s appendString:@"document.body.appendChild(btn);"];
        [s appendString:@"}"];
        [s appendString:@"function hideButton(){if(btn){btn.remove();btn=null;}lastUrl=null;}"];
        [s appendString:@"function scan(){"];
        [s appendString:@"try{"];
        [s appendString:@"var videos=document.querySelectorAll('video');"];
        [s appendString:@"if(videos.length===0){hideButton();return;}"];
        [s appendString:@"var found=null;"];
        [s appendString:@"for(var i=0;i<videos.length;i++){"];
        [s appendString:@"found=pickBestSource(videos[i]);"];
        [s appendString:@"if(found)break;"];
        [s appendString:@"}"];
        [s appendString:@"if(found){showButton(found);}else{hideButton();}"];
        [s appendString:@"}catch(e){}"];
        [s appendString:@"}"];
        [s appendString:@"setInterval(scan,1500);"];
        [s appendString:@"scan();"];
        [s appendString:@"})();"];
        js = [s copy];
    });
    return js;
}

// ---------- Download Manager ----------

@interface STDownloadManager : NSObject <NSURLSessionDownloadDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) UIAlertController *progressAlert;
@end

@implementation STDownloadManager

+ (instancetype)shared {
    static STDownloadManager *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [[STDownloadManager alloc] init];
    });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self recreateSession];
    }
    return self;
}

- (void)recreateSession {
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 30.0;
    cfg.timeoutIntervalForResource = 3600.0;
    self.session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
}

- (void)startDownload:(NSString *)urlString {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        ST_ShowResultAlert(@"SafariTool", @"Invalid URL");
        return;
    }

    NSString *scheme = [url.scheme lowercaseString];
    if ([scheme isEqualToString:@"blob"] || [scheme isEqualToString:@"data"]) {
        ST_ShowResultAlert(@"SafariTool", @"This video type (blob/data) cannot be downloaded directly.");
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = ST_TopViewController();
        if (!top) {
            return;
        }
        NSString *name = url.lastPathComponent;
        if (name.length == 0) {
            name = @"video";
        }
        NSString *msg = [NSString stringWithFormat:@"Downloading %@...\n\n0%%", name];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"SafariTool"
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                  style:UIAlertActionStyleCancel
                                                handler:^(UIAlertAction *action) {
            [self.session invalidateAndCancel];
            [self recreateSession];
        }]];
        self.progressAlert = alert;
        [top presentViewController:alert animated:YES completion:nil];
    });

    NSURLSessionDownloadTask *task = [self.session downloadTaskWithURL:url];
    [task resume];
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    if (totalBytesExpectedToWrite <= 0) {
        return;
    }
    double progress = (double)totalBytesWritten / (double)totalBytesExpectedToWrite;
    NSString *name = downloadTask.originalRequest.URL.lastPathComponent;
    if (name.length == 0) {
        name = @"video";
    }
    NSString *msg = [NSString stringWithFormat:@"Downloading %@...\n\n%.0f%%", name, progress * 100.0];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.progressAlert) {
            self.progressAlert.message = msg;
        }
    });
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    NSString *filename = downloadTask.originalRequest.URL.lastPathComponent;
    if (filename.length == 0) {
        filename = @"video.mp4";
    }

    NSString *tmpDir = NSTemporaryDirectory();
    NSString *tmpPath = [tmpDir stringByAppendingPathComponent:filename];

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:tmpPath error:nil];

    NSError *copyErr = nil;
    BOOL copied = [fm copyItemAtURL:location
                              toURL:[NSURL fileURLWithPath:tmpPath]
                              error:&copyErr];
    if (!copied) {
        NSString *msg = copyErr.localizedDescription ?: @"Could not copy file";
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.progressAlert dismissViewControllerAnimated:YES completion:^{
                self.progressAlert = nil;
                ST_ShowResultAlert(@"Save Failed", msg);
            }];
        });
        return;
    }

    [self saveVideoToPhotos:tmpPath originalName:filename];
}

- (void)saveVideoToPhotos:(NSString *)path originalName:(NSString *)name {
    NSURL *fileURL = [NSURL fileURLWithPath:path];

    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:fileURL];
    } completionHandler:^(BOOL success, NSError *error) {
        if (success) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.progressAlert dismissViewControllerAnimated:YES completion:^{
                    self.progressAlert = nil;
                    ST_ShowResultAlert(@"Saved to Photos",
                                       [NSString stringWithFormat:@"Video saved: %@", name]);
                }];
            });
            return;
        }

        NSLog(@"[SafariTool] Photos save failed: %@", error);
        [self saveVideoToDocuments:path originalName:name];
    }];
}

- (void)saveVideoToDocuments:(NSString *)path originalName:(NSString *)name {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                          NSUserDomainMask, YES);
    NSString *docs = paths.firstObject ?: NSTemporaryDirectory();
    NSString *dir = [docs stringByAppendingPathComponent:@"SafariTool"];

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *dst = [dir stringByAppendingPathComponent:name];
    if ([fm fileExistsAtPath:dst]) {
        NSString *ext = [dst pathExtension];
        NSString *base = [dst stringByDeletingPathExtension];
        NSString *ts = [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]];
        if (ext.length > 0) {
            dst = [NSString stringWithFormat:@"%@_%@.%@", base, ts, ext];
        } else {
            dst = [NSString stringWithFormat:@"%@_%@", base, ts];
        }
    }

    NSError *moveErr = nil;
    [fm moveItemAtPath:path toPath:dst error:&moveErr];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.progressAlert dismissViewControllerAnimated:YES completion:^{
            self.progressAlert = nil;
            if (moveErr) {
                ST_ShowResultAlert(@"Save Failed", moveErr.localizedDescription);
            } else {
                ST_ShowResultAlert(@"Saved to Files",
                                   [NSString stringWithFormat:@"Saved as %@\n\nPhotos does not support this format (.webm). Use Filza to access it.", name]);
            }
        }];
    });
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (!error) {
        return;
    }
    if (error.code == NSURLErrorCancelled) {
        return;
    }
    NSString *msg = error.localizedDescription ?: @"Unknown error";
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.progressAlert) {
            [self.progressAlert dismissViewControllerAnimated:YES completion:^{
                self.progressAlert = nil;
                ST_ShowResultAlert(@"Download Failed", msg);
            }];
        } else {
            ST_ShowResultAlert(@"Download Failed", msg);
        }
    });
}

@end

// ---------- Message Handler ----------

@interface STMessageHandler : NSObject <WKScriptMessageHandler>
@end

@implementation STMessageHandler

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    @try {
        if (![message.name isEqualToString:@"stDownload"]) {
            return;
        }
        NSDictionary *body = message.body;
        NSString *urlStr = body[@"url"];
        if (![urlStr isKindOfClass:[NSString class]] || urlStr.length == 0) {
            return;
        }
        NSLog(@"[SafariTool] Download requested: %@", urlStr);
        [[STDownloadManager shared] startDownload:urlStr];
    } @catch (NSException *e) {
        NSLog(@"[SafariTool] Message handler exception: %@", e);
    }
}

@end

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

        if (ST_Pref(@"SafariTool_DownloadButton", YES)) {
            STMessageHandler *handler = [[STMessageHandler alloc] init];
            [ucc addScriptMessageHandler:handler name:@"stDownload"];
            objc_setAssociatedObject(ucc, &kSTMessageHandlerKey, handler,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            WKUserScript *script =
                [[WKUserScript alloc] initWithSource:ST_VideoDetectorJS()
                                       injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
                                    forMainFrameOnly:NO];
            [ucc addUserScript:script];
        }
    } @catch (NSException *e) {
    }
}

%group STWebKit

%hook WKWebView

- (id)initWithFrame:(CGRect)frame configuration:(id)configuration {
    id r = %orig;
    if (r) {
        ST_InstallScripts((WKWebView *)r);
    }
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
