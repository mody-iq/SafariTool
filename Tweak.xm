#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>

static NSString *const kSTGuardVersion = @"2.0.0";
static const NSInteger kSTCrashLimit = 3;
static const double kSTSurviveSeconds = 6.0;
static char kSTInstalledKey;
static char kSTMessageHandlerKey;
typedef void (^STDecisionHandler)(WKNavigationActionPolicy, WKWebpagePreferences *);

static id ST_GlobalVal(NSString *key) {
    CFPropertyListRef cf = CFPreferencesCopyAppValue((__bridge CFStringRef)key, kCFPreferencesAnyApplication);
    if (!cf) return nil;
    return CFBridgingRelease(cf);
}
static id ST_RawPref(NSString *key) {
    id v = nil;
    @try { v = ST_GlobalVal(key); if (v) return v; v = [[NSUserDefaults standardUserDefaults] objectForKey:key]; } @catch (NSException *e) {}
    return v;
}
static BOOL ST_Pref(NSString *key, BOOL def) {
    id v = ST_RawPref(key);
    if ([v respondsToSelector:@selector(boolValue)]) return [v boolValue];
    return def;
}
static UIWindow *ST_KeyWindow(void) {
    UIWindow *keyWindow = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *w in ws.windows) { if (w.isKeyWindow) { keyWindow = w; break; } }
            if (keyWindow) break;
        }
    }
    return keyWindow;
}
static UIViewController *ST_SafeTopViewController(void) {
    UIWindow *kw = ST_KeyWindow(); if (!kw) return nil;
    UIViewController *vc = kw.rootViewController; if (!vc) return nil;
    while (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) vc = vc.presentedViewController;
    return vc;
}
static void ST_ShowResultAlert(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = ST_SafeTopViewController();
        if (!top || top.presentedViewController) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
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
        if ([std boolForKey:@"STTripped"]) { [std synchronize]; return NO; }
        if ([std boolForKey:@"STPending"]) {
            NSInteger count = [std integerForKey:@"STCrashCount"] + 1;
            [std setInteger:count forKey:@"STCrashCount"];
            if (count >= kSTCrashLimit) { [std setBool:YES forKey:@"STTripped"]; [std setBool:NO forKey:@"STPending"]; [std synchronize]; return NO; }
        }
        [std setBool:YES forKey:@"STPending"];
        [std synchronize];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSTSurviveSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSUserDefaults *s = [NSUserDefaults standardUserDefaults];
            [s setBool:NO forKey:@"STPending"]; [s setInteger:0 forKey:@"STCrashCount"]; [s synchronize];
        });
        return YES;
    } @catch (NSException *e) { return NO; }
}
static BOOL ST_DesktopEffective(void) {
    @try { id ov = [[NSUserDefaults standardUserDefaults] objectForKey:@"STDesktopOverride"]; if ([ov respondsToSelector:@selector(boolValue)]) return [ov boolValue]; } @catch (NSException *e) {}
    return ST_Pref(@"SafariTool_Desktop", NO);
}
static void ST_PatchDelegateClass(Class cls) {
    if (!cls) return;
    static NSMutableSet *done = nil; static dispatch_once_t once;
    dispatch_once(&once, ^{ done = [NSMutableSet set]; });
    NSString *name = NSStringFromClass(cls);
    @synchronized (done) { if ([done containsObject:name]) return; [done addObject:name]; }
    SEL sel = @selector(webView:decidePolicyForNavigationAction:preferences:decisionHandler:);
    Method m = class_getInstanceMethod(cls, sel); if (!m) return;
    IMP orig = method_getImplementation(m);
    const char *types = method_getTypeEncoding(m);
    if (!orig || !types) return;
    IMP newImp = imp_implementationWithBlock(^(id self_, WKWebView *wv, WKNavigationAction *action, WKWebpagePreferences *prefs, STDecisionHandler handler) {
        BOOL should = NO;
        @try {
            BOOL isMain = (!action.targetFrame || action.targetFrame.isMainFrame);
            NSString *scheme = [action.request.URL.scheme lowercaseString];
            BOOL web = ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]);
            should = (isMain && web && ST_DesktopEffective());
        } @catch (NSException *e) { should = NO; }
        STDecisionHandler wrapped = handler;
        if (should && handler) {
            wrapped = ^(WKNavigationActionPolicy policy, WKWebpagePreferences *pp) {
                WKWebpagePreferences *use = pp ?: prefs;
                if (!use) use = [[WKWebpagePreferences alloc] init];
                use.preferredContentMode = WKContentModeDesktop;
                handler(policy, use);
            };
        }
        ((void (*)(id, SEL, WKWebView *, WKNavigationAction *, WKWebpagePreferences *, STDecisionHandler))orig)(self_, sel, wv, action, prefs, wrapped);
    });
    class_replaceMethod(cls, sel, newImp, types);
}
static NSString *ST_ForceCopyJS(void) {
    static NSString *js = nil; static dispatch_once_t once;
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
    static NSString *js = nil; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableString *s = [NSMutableString string];
        [s appendString:@"(function(){"];
        [s appendString:@"if(window.__stVideoDetector){return;}"];
        [s appendString:@"window.__stVideoDetector=true;"];
        [s appendString:@"var ID_ATTR='data-st-id';"];
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
        [s appendString:@"if(v.currentSrc && v.currentSrc.indexOf('blob:')!==0 && v.currentSrc.indexOf('.m3u8')<0)return v.currentSrc;"];
        [s appendString:@"if(v.src && v.src.indexOf('blob:')!==0 && v.src.indexOf('.m3u8')<0)return v.src;"];
        [s appendString:@"}catch(e){}"];
        [s appendString:@"return null;"];
        [s appendString:@"}"];
        [s appendString:@"function ensureId(v){"];
        [s appendString:@"var id=v.getAttribute(ID_ATTR);"];
        [s appendString:@"if(!id){id='st'+Math.random().toString(36).substr(2,9);v.setAttribute(ID_ATTR,id);}"];
        [s appendString:@"return id;"];
        [s appendString:@"}"];
        [s appendString:@"var svgArrow='<svg width=\"13\" height=\"13\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"3\" stroke-linecap=\"round\" stroke-linejoin=\"round\" style=\"display:block;\"><path d=\"M12 4v14M5 11l7 7 7-7\"/></svg>';"];
        [s appendString:@"function makeButton(id,url){"];
        [s appendString:@"var btn=document.getElementById('st-btn-'+id);"];
        [s appendString:@"if(!btn){"];
        [s appendString:@"btn=document.createElement('div');"];
        [s appendString:@"btn.id='st-btn-'+id;"];
        [s appendString:@"btn.setAttribute('data-st-btn','1');"];
        [s appendString:@"btn.style.cssText='position:fixed;z-index:2147483647;padding:7px 13px;border-radius:18px;box-shadow:0 2px 8px rgba(0,0,0,0.35);cursor:pointer;font-size:13px;font-weight:600;color:#fff;font-family:-apple-system;user-select:none;-webkit-user-select:none;display:flex;align-items:center;gap:5px;white-space:nowrap;line-height:1;letter-spacing:0.2px;background:#007AFF;';"];
        [s appendString:@"btn.innerHTML=svgArrow+'<span>download</span>';"];
        [s appendString:@"btn.addEventListener('click',function(e){"];
        [s appendString:@"e.stopPropagation();e.preventDefault();"];
        [s appendString:@"var u=btn.getAttribute('data-st-url');"];
        [s appendString:@"btn.style.opacity='0.5';"];
        [s appendString:@"btn.innerHTML='<span style=\"font-size:11px;\">...</span>';"];
        [s appendString:@"try{window.webkit.messageHandlers.stDownload.postMessage({url:u,referer:window.location.href,ua:navigator.userAgent});}catch(err){}"];
        [s appendString:@"},true);"];
        [s appendString:@"(document.body||document.documentElement).appendChild(btn);"];
        [s appendString:@"}"];
        [s appendString:@"btn.setAttribute('data-st-url',url||'');"];
        [s appendString:@"return btn;"];
        [s appendString:@"}"];
        [s appendString:@"function positionButton(btn,v){"];
        [s appendString:@"try{"];
        [s appendString:@"var r=v.getBoundingClientRect();"];
        [s appendString:@"if(r.width<100||r.height<100){btn.style.display='none';return;}"];
        [s appendString:@"if(r.bottom<0||r.top>window.innerHeight){btn.style.display='none';return;}"];
        [s appendString:@"btn.style.display='flex';"];
        [s appendString:@"var bw=btn.offsetWidth||110;"];
        [s appendString:@"var bh=btn.offsetHeight||32;"];
        [s appendString:@"var top=r.top+8;"];
        [s appendString:@"if(top<8)top=8;"];
        [s appendString:@"if(top+bh>window.innerHeight-8)top=window.innerHeight-bh-8;"];
        [s appendString:@"var left=r.right-bw-8;"];
        [s appendString:@"if(left<8)left=8;"];
        [s appendString:@"if(left+bw>window.innerWidth-8)left=window.innerWidth-bw-8;"];
        [s appendString:@"btn.style.top=top+'px';"];
        [s appendString:@"btn.style.left=left+'px';"];
        [s appendString:@"}catch(e){btn.style.display='none';}"];
        [s appendString:@"}"];
        [s appendString:@"var activeIds={};"];
        [s appendString:@"function scan(){"];
        [s appendString:@"activeIds={};"];
        [s appendString:@"try{"];
        [s appendString:@"var videos=document.querySelectorAll('video');"];
        [s appendString:@"for(var i=0;i<videos.length;i++){"];
        [s appendString:@"var v=videos[i];"];
        [s appendString:@"var url=pickBestSource(v);"];
        [s appendString:@"if(!url)continue;"];
        [s appendString:@"var id=ensureId(v);"];
        [s appendString:@"activeIds[id]=true;"];
        [s appendString:@"var btn=makeButton(id,url);"];
        [s appendString:@"positionButton(btn,v);"];
        [s appendString:@"}"];
        [s appendString:@"var existing=document.querySelectorAll('[data-st-btn]');"];
        [s appendString:@"for(var j=0;j<existing.length;j++){"];
        [s appendString:@"var b=existing[j];"];
        [s appendString:@"var bid=b.id.replace('st-btn-','');"];
        [s appendString:@"if(!activeIds[bid]){b.remove();}"];
        [s appendString:@"}"];
        [s appendString:@"}catch(e){}"];
        [s appendString:@"}"];
        [s appendString:@"function onScrollOrResize(){"];
        [s appendString:@"try{"];
        [s appendString:@"var videos=document.querySelectorAll('video');"];
        [s appendString:@"for(var i=0;i<videos.length;i++){"];
        [s appendString:@"var v=videos[i];"];
        [s appendString:@"var id=v.getAttribute(ID_ATTR);"];
        [s appendString:@"if(!id)continue;"];
        [s appendString:@"var b=document.getElementById('st-btn-'+id);"];
        [s appendString:@"if(b)positionButton(b,v);"];
        [s appendString:@"}"];
        [s appendString:@"}catch(e){}"];
        [s appendString:@"}"];
        [s appendString:@"window.addEventListener('scroll',onScrollOrResize,true);"];
        [s appendString:@"window.addEventListener('resize',onScrollOrResize,true);"];
        [s appendString:@"setInterval(scan,1000);"];
        [s appendString:@"scan();"];
        [s appendString:@"})();"];
        js = [s copy];
    });
    return js;
}

@interface STFloatingProgress : UIView
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, copy) void (^onCancel)(void);
+ (instancetype)shared;
- (void)showWithText:(NSString *)text;
- (void)updateText:(NSString *)text;
- (void)hide;
@end
@implementation STFloatingProgress
+ (instancetype)shared {
    static STFloatingProgress *inst = nil; static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[STFloatingProgress alloc] initWithFrame:CGRectMake(0, 0, 140, 40)]; });
    return inst;
}
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.12 alpha:0.95];
        self.layer.cornerRadius = 20.0;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.4; self.layer.shadowRadius = 6.0;
        self.layer.shadowOffset = CGSizeMake(0, 2);
        self.userInteractionEnabled = YES;
        _label = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, 100, 40)];
        _label.textColor = [UIColor whiteColor];
        _label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        _label.textAlignment = NSTextAlignmentCenter;
        _label.text = @"0%";
        [self addSubview:_label];
        UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        closeBtn.frame = CGRectMake(110, 6, 28, 28);
        [closeBtn setTitle:@"\u00D7" forState:UIControlStateNormal];
        [closeBtn setTitleColor:[UIColor colorWithWhite:0.85 alpha:1.0] forState:UIControlStateNormal];
        closeBtn.titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
        [closeBtn addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:closeBtn];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panMoved:)];
        [self addGestureRecognizer:pan];
    }
    return self;
}
- (void)cancelTapped { if (self.onCancel) self.onCancel(); }
- (void)panMoved:(UIPanGestureRecognizer *)g {
    UIView *sv = self.superview; if (!sv) return;
    CGPoint t = [g translationInView:sv];
    self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    [g setTranslation:CGPointZero inView:sv];
}
- (void)showWithText:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            self.label.text = text;
            UIWindow *kw = ST_KeyWindow(); if (!kw) return;
            if (self.superview != kw) { [self removeFromSuperview]; [kw addSubview:self]; }
            CGRect bounds = kw.bounds;
            CGFloat w = 140; CGFloat h = 40;
            CGFloat x = bounds.size.width - w - 15;
            CGFloat y = bounds.size.height - h - 100;
            if (x < 15) x = 15; if (y < 15) y = 15;
            self.frame = CGRectMake(x, y, w, h);
            self.hidden = NO; self.alpha = 1.0;
            [kw bringSubviewToFront:self];
        } @catch (NSException *e) {}
    });
}
- (void)updateText:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{ @try { self.label.text = text; } @catch (NSException *e) {} });
}
- (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{ @try { [self removeFromSuperview]; } @catch (NSException *e) {} });
}
@end

@interface STDownloadManager : NSObject <NSURLSessionDownloadDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, copy) NSString *filename;
@property (nonatomic, assign) double currentProgress;
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, assign) BOOL finished;
@end
@implementation STDownloadManager
+ (instancetype)shared {
    static STDownloadManager *inst = nil; static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[STDownloadManager alloc] init]; });
    return inst;
}
- (instancetype)init {
    self = [super init];
    if (self) [self recreateSession];
    return self;
}
- (void)recreateSession {
    if (self.session) { [self.session invalidateAndCancel]; self.session = nil; }
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 30.0; cfg.timeoutIntervalForResource = 3600.0;
    self.session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
}
- (void)startDownload:(NSString *)urlString referer:(NSString *)referer ua:(NSString *)ua {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) { ST_ShowResultAlert(@"SafariTool", @"Invalid URL"); return; }
    self.currentProgress = 0.0; self.cancelled = NO; self.finished = NO;
    NSString *name = url.lastPathComponent; if (name.length == 0) name = @"video";
    NSString *ts = [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]];
    NSString *base = [name stringByDeletingPathExtension];
    NSString *ext = [name pathExtension];
    if (base.length == 0) base = @"video";
    if (ext.length == 0) ext = @"mp4";
    self.filename = [NSString stringWithFormat:@"%@_%@.%@", base, ts, ext];
    STFloatingProgress *fp = [STFloatingProgress shared];
    fp.onCancel = ^{ [[STDownloadManager shared] cancel]; };
    [fp showWithText:@"0%"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    if (referer.length > 0) [req setValue:referer forHTTPHeaderField:@"Referer"];
    if (ua.length > 0) [req setValue:ua forHTTPHeaderField:@"User-Agent"];
    NSURLSessionDownloadTask *task = [self.session downloadTaskWithRequest:req];
    [task resume];
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    if (self.cancelled || self.finished) return;
    if (totalBytesExpectedToWrite <= 0) return;
    double progress = (double)totalBytesWritten / (double)totalBytesExpectedToWrite;
    self.currentProgress = progress;
    NSString *pct = [NSString stringWithFormat:@"%.0f%%", progress * 100.0];
    [[STFloatingProgress shared] updateText:pct];
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location {
    if (self.cancelled || self.finished) return;
    self.finished = YES;
    [[STFloatingProgress shared] updateText:@"Saving..."];
    NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:self.filename];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:tmpPath error:nil];
    NSError *copyErr = nil;
    BOOL copied = [fm copyItemAtURL:location toURL:[NSURL fileURLWithPath:tmpPath] error:&copyErr];
    if (!copied) {
        [[STFloatingProgress shared] hide];
        ST_ShowResultAlert(@"Save Failed", copyErr.localizedDescription ?: @"Copy failed");
        return;
    }
    NSURL *fileURL = [NSURL fileURLWithPath:tmpPath];
    __weak STDownloadManager *weakSelf = self;
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:fileURL];
    } completionHandler:^(BOOL success, NSError *error) {
        STDownloadManager *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (success) {
            [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];
            [[STFloatingProgress shared] hide];
            ST_ShowResultAlert(@"Saved to Photos", [NSString stringWithFormat:@"Video saved: %@", strongSelf.filename]);
            return;
        }
        [strongSelf saveToDocuments:tmpPath];
    }];
}
- (void)saveToDocuments:(NSString *)path {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docs = paths.firstObject ?: NSTemporaryDirectory();
    NSString *dir = [docs stringByAppendingPathComponent:@"SafariTool"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dst = [dir stringByAppendingPathComponent:self.filename];
    NSError *moveErr = nil;
    [fm moveItemAtPath:path toPath:dst error:&moveErr];
    [[STFloatingProgress shared] hide];
    if (moveErr) ST_ShowResultAlert(@"Save Failed", moveErr.localizedDescription);
    else ST_ShowResultAlert(@"Saved to Files", [NSString stringWithFormat:@"Saved as %@", self.filename]);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (!error) return;
    if (self.cancelled || self.finished) return;
    if (error.code == NSURLErrorCancelled) return;
    self.finished = YES;
    [[STFloatingProgress shared] hide];
    ST_ShowResultAlert(@"Download Failed", error.localizedDescription ?: @"Unknown");
}
- (void)cancel {
    if (self.cancelled) return;
    self.cancelled = YES;
    [[STFloatingProgress shared] hide];
    if (self.session) { [self.session invalidateAndCancel]; self.session = nil; }
    [self recreateSession];
}
@end

@interface STMessageHandler : NSObject <WKScriptMessageHandler>
@end
@implementation STMessageHandler
- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)message {
    @try {
        if (![message.name isEqualToString:@"stDownload"]) return;
        NSDictionary *body = message.body;
        NSString *urlStr = body[@"url"];
        NSString *referer = body[@"referer"];
        NSString *ua = body[@"ua"];
        if (![urlStr isKindOfClass:[NSString class]] || urlStr.length == 0) return;
        if (![referer isKindOfClass:[NSString class]]) referer = @"";
        if (![ua isKindOfClass:[NSString class]]) ua = @"";
        NSString *lower = urlStr.lowercaseString;
        if ([lower containsString:@".m3u8"] || [lower hasPrefix:@"blob:"]) {
            ST_ShowResultAlert(@"HLS not supported", @"This video uses HLS streaming which is not supported. Only direct MP4/MOV/M4V links work.");
            return;
        }
        [[STDownloadManager shared] startDownload:urlStr referer:referer ua:ua];
    } @catch (NSException *e) { NSLog(@"[SafariTool] %@", e); }
}
@end

static void ST_InstallScripts(WKWebView *wv) {
    @try {
        WKUserContentController *ucc = wv.configuration.userContentController;
        if (!ucc) return;
        if (objc_getAssociatedObject(ucc, &kSTInstalledKey)) return;
        objc_setAssociatedObject(ucc, &kSTInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (ST_Pref(@"SafariTool_ForceCopy", YES)) {
            WKUserScript *script = [[WKUserScript alloc] initWithSource:ST_ForceCopyJS() injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO];
            [ucc addUserScript:script];
        }
        if (ST_Pref(@"SafariTool_DownloadButton", YES)) {
            STMessageHandler *handler = [[STMessageHandler alloc] init];
            [ucc addScriptMessageHandler:handler name:@"stDownload"];
            objc_setAssociatedObject(ucc, &kSTMessageHandlerKey, handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            WKUserScript *script = [[WKUserScript alloc] initWithSource:ST_VideoDetectorJS() injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:NO];
            [ucc addUserScript:script];
        }
    } @catch (NSException *e) {}
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
        if (![[[NSProcessInfo processInfo] processName] isEqualToString:@"MobileSafari"]) return;
        if (![[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){16, 0, 0}]) return;
        if (!objc_getClass("WKWebView")) return;
        if (!ST_GuardBegin()) return;
        if (!ST_Pref(@"SafariTool_Enabled", YES)) return;
        %init(STWebKit);
    }
}
