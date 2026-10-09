#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <Photos/Photos.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

static NSString *const kSTGuardVersion = @"0.9.1";
static const NSInteger kSTCrashLimit = 3;
static const double kSTSurviveSeconds = 6.0;

static NSString *const kSTAVHeadersKey = @"AVURLAssetHTTPHeaderFieldsKey";

static char kSTInstalledKey;
static char kSTMessageHandlerKey;

typedef void (^STDecisionHandler)(WKNavigationActionPolicy, WKWebpagePreferences *);

static id ST_GlobalVal(NSString *key) {
    CFPropertyListRef cf = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                    kCFPreferencesAnyApplication);
    if (!cf) return nil;
    return CFBridgingRelease(cf);
}

static id ST_RawPref(NSString *key) {
    id v = nil;
    @try {
        v = ST_GlobalVal(key);
        if (v) return v;
        v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    } @catch (NSException *e) {}
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
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) { keyWindow = w; break; }
            }
            if (keyWindow) break;
        }
    }
    return keyWindow;
}

static UIWindowScene *ST_ActiveWindowScene(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.activationState == UISceneActivationStateForegroundActive) {
                return ws;
            }
        }
    }
    return nil;
}

static UIViewController *ST_SafeTopViewController(void) {
    UIWindow *kw = ST_KeyWindow();
    if (!kw) return nil;
    UIViewController *vc = kw.rootViewController;
    if (!vc) return nil;
    while (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) {
        vc = vc.presentedViewController;
    }
    return vc;
}

static void ST_ShowResultAlert(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = ST_SafeTopViewController();
        if (!top) return;
        if (top.presentedViewController) return;

        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:title
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
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(kSTSurviveSeconds * NSEC_PER_SEC)),
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
        if ([ov respondsToSelector:@selector(boolValue)]) return [ov boolValue];
    } @catch (NSException *e) {}
    return ST_Pref(@"SafariTool_Desktop", NO);
}

static void ST_PatchDelegateClass(Class cls) {
    if (!cls) return;
    static NSMutableSet *done = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ done = [NSMutableSet set]; });
    NSString *name = NSStringFromClass(cls);
    @synchronized (done) {
        if ([done containsObject:name]) return;
        [done addObject:name];
    }

    SEL sel = @selector(webView:decidePolicyForNavigationAction:preferences:decisionHandler:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP orig = method_getImplementation(m);
    const char *types = method_getTypeEncoding(m);
    if (!orig || !types) return;

    IMP newImp = imp_implementationWithBlock(
        ^(id self_, WKWebView *wv, WKNavigationAction *action,
          WKWebpagePreferences *prefs, STDecisionHandler handler) {
            BOOL should = NO;
            @try {
                BOOL isMain = (!action.targetFrame || action.targetFrame.isMainFrame);
                NSString *scheme = [action.request.URL.scheme lowercaseString];
                BOOL web = ([scheme isEqualToString:@"http"] ||
                            [scheme isEqualToString:@"https"]);
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

            ((void (*)(id, SEL, WKWebView *, WKNavigationAction *,
                       WKWebpagePreferences *, STDecisionHandler))orig)(
                self_, sel, wv, action, prefs, wrapped);
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

static NSString *ST_StreamCaptureJS(void) {
    static NSString *js = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableString *s = [NSMutableString string];
        [s appendString:@"(function(){"];
        [s appendString:@"if(window.__stStreamHook){return;}"];
        [s appendString:@"window.__stStreamHook=true;"];
        [s appendString:@"window.__stCaptured=[];"];
        [s appendString:@"function __stAdd(u){"];
        [s appendString:@"try{"];
        [s appendString:@"if(!u)return;"];
        [s appendString:@"u=String(u);"];
        [s appendString:@"if(u.indexOf('blob:')===0)return;"];
        [s appendString:@"if(u.indexOf('data:')===0)return;"];
        [s appendString:@"var l=u.toLowerCase();"];
        [s appendString:@"if(l.indexOf('.m3u8')<0 && l.indexOf('.mpd')<0)return;"];
        [s appendString:@"if(window.__stCaptured.indexOf(u)<0){"];
        [s appendString:@"window.__stCaptured.push(u);"];
        [s appendString:@"if(window.__stCaptured.length>15)window.__stCaptured.shift();"];
        [s appendString:@"}"];
        [s appendString:@"}catch(e){}"];
        [s appendString:@"}"];
        [s appendString:@"try{"];
        [s appendString:@"var __stOpen=XMLHttpRequest.prototype.open;"];
        [s appendString:@"XMLHttpRequest.prototype.open=function(m,url){"];
        [s appendString:@"__stAdd(url);"];
        [s appendString:@"return __stOpen.apply(this,arguments);"];
        [s appendString:@"};"];
        [s appendString:@"}catch(e){}"];
        [s appendString:@"try{"];
        [s appendString:@"if(window.fetch){"];
        [s appendString:@"var __stFetch=window.fetch;"];
        [s appendString:@"window.fetch=function(input,init){"];
        [s appendString:@"try{"];
        [s appendString:@"if(typeof input==='string')__stAdd(input);"];
        [s appendString:@"else if(input&&input.url)__stAdd(input.url);"];
        [s appendString:@"}catch(e){}"];
        [s appendString:@"return __stFetch.apply(this,arguments);"];
        [s appendString:@"};"];
        [s appendString:@"}"];
        [s appendString:@"}catch(e){}"];
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
        [s appendString:@"var ID_ATTR='data-st-id';"];
        [s appendString:@"function isHLS(u){"];
        [s appendString:@"if(!u)return false;"];
        [s appendString:@"var l=u.toLowerCase();"];
        [s appendString:@"if(l.indexOf('blob:')===0)return true;"];
        [s appendString:@"if(l.indexOf('.m3u8')>=0)return true;"];
        [s appendString:@"if(l.indexOf('/hls/')>=0)return true;"];
        [s appendString:@"return false;"];
        [s appendString:@"}"];
        [s appendString:@"function isBlob(u){return u && u.indexOf('blob:')===0;}"];
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
        [s appendString:@"function ensureId(v){"];
        [s appendString:@"var id=v.getAttribute(ID_ATTR);"];
        [s appendString:@"if(!id){id='st'+Math.random().toString(36).substr(2,9);v.setAttribute(ID_ATTR,id);}"];
        [s appendString:@"return id;"];
        [s appendString:@"}"];
        [s appendString:@"var svgArrow='<svg width=\"13\" height=\"13\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"3\" stroke-linecap=\"round\" stroke-linejoin=\"round\" style=\"display:block;\"><path d=\"M12 4v14M5 11l7 7 7-7\"/></svg>';"];
        [s appendString:@"function makeButton(id,url,isHLSStream,isBlobStream){"];
        [s appendString:@"var btn=document.getElementById('st-btn-'+id);"];
        [s appendString:@"if(!btn){"];
        [s appendString:@"btn=document.createElement('div');"];
        [s appendString:@"btn.id='st-btn-'+id;"];
        [s appendString:@"btn.setAttribute('data-st-btn','1');"];
        [s appendString:@"btn.style.cssText='position:fixed;z-index:2147483647;padding:7px 13px;border-radius:18px;box-shadow:0 2px 8px rgba(0,0,0,0.35);cursor:pointer;font-size:13px;font-weight:600;color:#fff;font-family:-apple-system;user-select:none;-webkit-user-select:none;display:flex;align-items:center;gap:5px;white-space:nowrap;line-height:1;letter-spacing:0.2px;';"];
        [s appendString:@"btn.innerHTML=svgArrow+'<span>download</span>';"];
        [s appendString:@"btn.addEventListener('click',function(e){"];
        [s appendString:@"e.stopPropagation();e.preventDefault();"];
        [s appendString:@"var u=btn.getAttribute('data-st-url');"];
        [s appendString:@"var blob=btn.getAttribute('data-st-blob')==='1';"];
        [s appendString:@"var streams=(window.__stCaptured||[]).slice();"];
        [s appendString:@"btn.style.opacity='0.5';"];
        [s appendString:@"btn.innerHTML='<span style=\"font-size:11px;\">...</span>';"];
        [s appendString:@"try{window.webkit.messageHandlers.stDownload.postMessage({url:u,referer:window.location.href,ua:navigator.userAgent,blob:blob,streams:streams});}catch(err){}"];
        [s appendString:@"},true);"];
        [s appendString:@"(document.body||document.documentElement).appendChild(btn);"];
        [s appendString:@"}"];
        [s appendString:@"btn.style.background=isHLSStream?'#FF9500':'#007AFF';"];
        [s appendString:@"btn.setAttribute('data-st-url',url||'');"];
        [s appendString:@"btn.setAttribute('data-st-blob',isBlobStream?'1':'0');"];
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
        [s appendString:@"var blob=isBlob(url);"];
        [s appendString:@"if(!url){"];
        [s appendString:@"var captured=(window.__stCaptured||[]);"];
        [s appendString:@"if(captured.length===0)continue;"];
        [s appendString:@"url=captured[0];"];
        [s appendString:@"blob=false;"];
        [s appendString:@"}"];
        [s appendString:@"var id=ensureId(v);"];
        [s appendString:@"activeIds[id]=true;"];
        [s appendString:@"var isH=isHLS(url)||blob;"];
        [s appendString:@"var btn=makeButton(id,url,isH,blob);"];
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

@interface STFloatingView : UIView
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, copy) void (^onTap)(void);
@property (nonatomic, copy) void (^onCancel)(void);
@end

@implementation STFloatingView

- (instancetype)init {
    self = [super initWithFrame:CGRectMake(0, 0, 130, 40)];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.12 alpha:0.95];
        self.layer.cornerRadius = 20.0;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.4;
        self.layer.shadowRadius = 6.0;
        self.layer.shadowOffset = CGSizeMake(0, 2);
        self.userInteractionEnabled = YES;

        _label = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, 90, 40)];
        _label.textColor = [UIColor whiteColor];
        _label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        _label.textAlignment = NSTextAlignmentCenter;
        _label.text = @"0%";
        [self addSubview:_label];

        UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        closeBtn.frame = CGRectMake(100, 6, 28, 28);
        [closeBtn setTitle:@"\u00D7" forState:UIControlStateNormal];
        [closeBtn setTitleColor:[UIColor colorWithWhite:0.8 alpha:1.0]
                       forState:UIControlStateNormal];
        closeBtn.titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
        [closeBtn addTarget:self action:@selector(cancelTapped)
           forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:closeBtn];

        UITapGestureRecognizer *tap =
            [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapTapped)];
        [self addGestureRecognizer:tap];

        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panMoved:)];
        [self addGestureRecognizer:pan];
    }
    return self;
}

- (void)tapTapped { if (self.onTap) self.onTap(); }
- (void)cancelTapped { if (self.onCancel) self.onCancel(); }

- (void)panMoved:(UIPanGestureRecognizer *)g {
    UIView *sv = self.superview;
    if (!sv) return;
    CGPoint t = [g translationInView:sv];
    self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    [g setTranslation:CGPointZero inView:sv];
}

@end

@interface STFloatingProgress : NSObject
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) STFloatingView *view;
@property (nonatomic, copy) void (^onTap)(void);
@property (nonatomic, copy) void (^onCancel)(void);
+ (instancetype)shared;
- (void)showWithText:(NSString *)text;
- (void)updateText:(NSString *)text;
- (void)hide;
@end

@implementation STFloatingProgress

+ (instancetype)shared {
    static STFloatingProgress *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [[STFloatingProgress alloc] init];
    });
    return inst;
}

- (void)showWithText:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!self.view) {
                self.view = [[STFloatingView alloc] init];
                STFloatingProgress *weakSelf = self;
                self.view.onTap = ^{
                    if (weakSelf.onTap) weakSelf.onTap();
                };
                self.view.onCancel = ^{
                    if (weakSelf.onCancel) weakSelf.onCancel();
                };
            }

            self.view.label.text = text;

            UIWindowScene *scene = ST_ActiveWindowScene();
            if (!scene) return;

            if (!self.window) {
                self.window = [[UIWindow alloc] initWithWindowScene:scene];
                self.window.windowLevel = UIWindowLevelAlert + 100;
                self.window.backgroundColor = [UIColor clearColor];
                UIViewController *root = [[UIViewController alloc] init];
                root.view.backgroundColor = [UIColor clearColor];
                self.window.rootViewController = root;
            }

            UIViewController *root = self.window.rootViewController;
            if (!self.view.superview) {
                [root.view addSubview:self.view];
            }

            CGRect bounds = scene.coordinateSpace.bounds;
            CGFloat w = 130;
            CGFloat h = 40;
            CGFloat x = bounds.size.width - w - 15;
            CGFloat y = bounds.size.height - h - 160;
            if (x < 15) x = 15;
            if (y < 15) y = 15;
            self.view.frame = CGRectMake(x, y, w, h);

            self.window.hidden = NO;
        } @catch (NSException *e) {}
    });
}

- (void)updateText:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (self.view) self.view.label.text = text;
        } @catch (NSException *e) {}
    });
}

- (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (self.view && self.view.superview) {
                [self.view removeFromSuperview];
            }
            if (self.window) {
                self.window.hidden = YES;
                self.window.rootViewController = nil;
                self.window = nil;
            }
        } @catch (NSException *e) {}
    });
}

@end

static void ST_FindVideoFileInMovpkg(NSString *movpkgPath, void (^completion)(NSString *videoPath)) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *err = nil;
    NSArray *contents = [fm contentsOfDirectoryAtPath:movpkgPath error:&err];
    if (!contents) {
        completion(nil);
        return;
    }

    __block NSString *bestPath = nil;
    __block unsigned long long bestSize = 0;

    for (NSString *name in contents) {
        if ([name hasPrefix:@"."]) continue;

        NSString *fullPath = [movpkgPath stringByAppendingPathComponent:name];
        NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
        unsigned long long size = [attrs fileSize];

        NSString *lower = [name lowercaseString];
        BOOL isVideo = ([lower hasSuffix:@".mov"] ||
                        [lower hasSuffix:@".mp4"] ||
                        [lower hasSuffix:@".m4v"] ||
                        [lower hasSuffix:@".fmp4"]);

        if (!isVideo) {
            BOOL isDir = NO;
            [fm fileExistsAtPath:fullPath isDirectory:&isDir];
            if (isDir) {
                __block NSString *nested = nil;
                ST_FindVideoFileInMovpkg(fullPath, ^(NSString *p) {
                    nested = p;
                });
                if (nested) {
                    NSDictionary *nAttrs = [fm attributesOfItemAtPath:nested error:nil];
                    unsigned long long nSize = [nAttrs fileSize];
                    if (nSize > bestSize) {
                        bestSize = nSize;
                        bestPath = nested;
                    }
                }
            }
            continue;
        }

        if (size > bestSize) {
            bestSize = size;
            bestPath = fullPath;
        }
    }

    completion(bestPath);
}

@interface STHLSDownloader : NSObject <AVAssetDownloadDelegate>
@property (nonatomic, strong) AVAssetDownloadURLSession *session;
@property (nonatomic, strong) AVAssetDownloadTask *task;
@property (nonatomic, strong) UIAlertController *progressAlert;
@property (nonatomic, copy) NSString *filename;
@property (nonatomic, copy) NSString *referer;
@property (nonatomic, copy) NSString *ua;
@property (nonatomic, assign) double currentProgress;
@property (nonatomic, assign) BOOL inBackgroundMode;
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, assign) BOOL finished;
@end

@implementation STHLSDownloader

+ (instancetype)shared {
    static STHLSDownloader *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [[STHLSDownloader alloc] init];
    });
    return inst;
}

- (void)finishWithTitle:(NSString *)title message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[STFloatingProgress shared] hide];
        UIAlertController *alert = self.progressAlert;
        self.progressAlert = nil;
        if (alert) {
            [alert dismissViewControllerAnimated:YES completion:^{
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(0.4 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    ST_ShowResultAlert(title, message);
                });
            }];
        } else {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                ST_ShowResultAlert(title, message);
            });
        }
    });
}

- (void)startWithURL:(NSString *)urlString
             referer:(NSString *)referer
                  ua:(NSString *)ua
             webView:(WKWebView *)webView {

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        ST_ShowResultAlert(@"SafariTool", @"Invalid URL");
        return;
    }

    self.referer = referer ?: @"";
    self.ua = ua ?: @"";
    self.currentProgress = 0.0;
    self.inBackgroundMode = NO;
    self.cancelled = NO;
    self.finished = NO;

    NSString *base = url.lastPathComponent;
    if (base.length == 0) base = @"video";
    base = [base stringByDeletingPathExtension];
    if (base.length == 0) base = @"video";
    NSString *ts = [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]];
    self.filename = [NSString stringWithFormat:@"%@_%@", base, ts];

    [self showAlert];

    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    if (referer.length > 0) {
        headers[@"Referer"] = referer;
        NSURL *refURL = [NSURL URLWithString:referer];
        if (refURL.scheme.length > 0 && refURL.host.length > 0) {
            headers[@"Origin"] = [NSString stringWithFormat:@"%@://%@",
                                  refURL.scheme, refURL.host];
        }
    }
    if (ua.length > 0) {
        headers[@"User-Agent"] = ua;
    }

    NSDictionary *options = @{ kSTAVHeadersKey: headers };
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:options];

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.allowsCellularAccess = YES;
    cfg.timeoutIntervalForRequest = 60.0;
    cfg.timeoutIntervalForResource = 7200.0;

    self.session = [AVAssetDownloadURLSession sessionWithConfiguration:cfg
                                                  assetDownloadDelegate:self
                                                        delegateQueue:[NSOperationQueue mainQueue]];

    self.task = [self.session assetDownloadTaskWithURLAsset:asset
                                                 assetTitle:self.filename
                                           assetArtworkData:nil
                                                    options:nil];
    if (!self.task) {
        [self cleanupSession];
        [self finishWithTitle:@"HLS Download Failed"
                      message:@"Could not create download task."];
        return;
    }

    NSLog(@"[SafariTool] Starting AVAssetDownloadTask for %@", urlString);
    [self.task resume];
}

- (void)cleanupSession {
    if (self.session) {
        [self.session invalidateAndCancel];
        self.session = nil;
    }
    self.task = nil;
}

- (void)showAlert {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.progressAlert) return;

        UIViewController *top = ST_SafeTopViewController();
        if (!top) return;
        if (top.presentedViewController) return;

        NSString *msg = [NSString stringWithFormat:@"Downloading HLS...\n\n%@\n%.0f%%",
                         self.filename, self.currentProgress * 100.0];
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"SafariTool (HLS)"
                                                message:msg
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Background"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(0.35 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self enterBackgroundMode];
            });
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                  style:UIAlertActionStyleCancel
                                                handler:^(UIAlertAction *action) {
            [self cancel];
        }]];
        self.progressAlert = alert;
        self.inBackgroundMode = NO;
        [top presentViewController:alert animated:YES completion:nil];
    });
}

- (void)enterBackgroundMode {
    self.inBackgroundMode = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.finished || self.cancelled) return;
        NSString *pct = [NSString stringWithFormat:@"%.0f%%", self.currentProgress * 100.0];
        STFloatingProgress *fp = [STFloatingProgress shared];
        fp.onTap = ^{ [self showAlert]; };
        fp.onCancel = ^{ [self cancel]; };
        [fp showWithText:pct];
    });
}

- (void)URLSession:(NSURLSession *)session
      assetDownloadTask:(AVAssetDownloadTask *)assetDownloadTask
 didLoadTimeRange:(CMTimeRange)timeRange
totalTimeRangesLoaded:(NSArray<NSValue *> *)loadedTimeRanges
timeRangeExpectedToLoad:(CMTimeRange)timeRangeExpectedToLoad {

    if (self.cancelled || self.finished) return;
    double expected = CMTimeGetSeconds(timeRangeExpectedToLoad.duration);
    if (expected <= 0) return;

    double loaded = 0;
    for (NSValue *v in loadedTimeRanges) {
        CMTimeRange r = v.CMTimeRangeValue;
        loaded += CMTimeGetSeconds(r.duration);
    }
    double progress = loaded / expected;
    if (progress > 1.0) progress = 1.0;
    if (progress < 0) progress = 0;
    self.currentProgress = progress;

    if (self.inBackgroundMode) {
        NSString *pct = [NSString stringWithFormat:@"%.0f%%", progress * 100.0];
        [[STFloatingProgress shared] updateText:pct];
    } else if (self.progressAlert) {
        NSString *msg = [NSString stringWithFormat:@"Downloading HLS...\n\n%@\n%.0f%%",
                         self.filename, progress * 100.0];
        self.progressAlert.message = msg;
    }
}

- (void)URLSession:(NSURLSession *)session
      assetDownloadTask:(AVAssetDownloadTask *)assetDownloadTask
 didFinishDownloadingToURL:(NSURL *)location {

    if (self.cancelled || self.finished) return;
    self.finished = YES;

    NSLog(@"[SafariTool] HLS download finished at: %@", location.path);

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                          NSUserDomainMask, YES);
    NSString *docs = paths.firstObject ?: NSTemporaryDirectory();
    NSString *dir = [docs stringByAppendingPathComponent:@"SafariTool"];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *dstPath = [dir stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"%@.movpkg", self.filename]];
    [fm removeItemAtPath:dstPath error:nil];

    NSError *moveErr = nil;
    BOOL moved = [fm moveItemAtURL:location
                             toURL:[NSURL fileURLWithPath:dstPath]
                             error:&moveErr];

    [self cleanupSession];

    if (!moved) {
        [self finishWithTitle:@"Save Failed"
                      message:moveErr.localizedDescription ?: @"Unknown error"];
        return;
    }

    [self updateProgressMessage:@"Converting to MP4..."];
    [self convertMovpkgAndSaveToPhotos:dstPath];
}

- (void)updateProgressMessage:(NSString *)text {
    if (self.inBackgroundMode) {
        [[STFloatingProgress shared] updateText:text];
    } else if (self.progressAlert) {
        self.progressAlert.message = text;
    }
}

- (void)convertMovpkgAndSaveToPhotos:(NSString *)movpkgPath {
    ST_FindVideoFileInMovpkg(movpkgPath, ^(NSString *videoPath) {
        if (!videoPath) {
            [self fallbackToPhotosFromMovpkg:movpkgPath];
            return;
        }

        NSURL *fileURL = [NSURL fileURLWithPath:videoPath];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:fileURL options:nil];

        [asset loadValuesAsynchronouslyForKeys:@[@"tracks", @"duration"]
                             completionHandler:^{
            dispatch_async(dispatch_get_main_queue(), ^{
                NSError *err = nil;
                AVKeyValueStatus status = [asset statusOfValueForKey:@"tracks" error:&err];
                if (status != AVKeyValueStatusLoaded) {
                    [self fallbackToPhotosFromMovpkg:movpkgPath];
                    return;
                }

                [self runExportWithAsset:asset movpkgPath:movpkgPath];
            });
        }];
    });
}

- (void)runExportWithAsset:(AVAsset *)asset movpkgPath:(NSString *)movpkgPath {
    NSString *outName = [NSString stringWithFormat:@"%@.mp4", self.filename];
    NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:outName];
    [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];

    NSArray *presets = [AVAssetExportSession exportPresetsCompatibleWithAsset:asset];
    NSString *preset = nil;
    if ([presets containsObject:AVAssetExportPresetPassthrough]) {
        preset = AVAssetExportPresetPassthrough;
    } else if ([presets containsObject:AVAssetExportPresetHighestQuality]) {
        preset = AVAssetExportPresetHighestQuality;
    } else if ([presets containsObject:AVAssetExportPresetMediumQuality]) {
        preset = AVAssetExportPresetMediumQuality;
    } else if (presets.count > 0) {
        preset = presets.firstObject;
    }

    if (!preset) {
        [self fallbackToPhotosFromMovpkg:movpkgPath];
        return;
    }

    AVAssetExportSession *session =
        [[AVAssetExportSession alloc] initWithAsset:asset presetName:preset];
    session.outputURL = [NSURL fileURLWithPath:outPath];

    NSArray *supported = session.supportedFileTypes;
    if ([supported containsObject:AVFileTypeMPEG4]) {
        session.outputFileType = AVFileTypeMPEG4;
    } else if ([supported containsObject:AVFileTypeQuickTimeMovie]) {
        session.outputFileType = AVFileTypeQuickTimeMovie;
    } else if (supported.count > 0) {
        session.outputFileType = supported.firstObject;
    } else {
        [self fallbackToPhotosFromMovpkg:movpkgPath];
        return;
    }

    session.shouldOptimizeForNetworkUse = YES;

    [session exportAsynchronouslyWithCompletionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (session.status == AVAssetExportSessionStatusCompleted) {
                [self saveMP4ToPhotos:outPath movpkgPath:movpkgPath];
            } else {
                NSLog(@"[SafariTool] Conversion failed: %@", session.error);
                [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
                [self fallbackToPhotosFromMovpkg:movpkgPath];
            }
        });
    }];
}

- (void)saveMP4ToPhotos:(NSString *)mp4Path movpkgPath:(NSString *)movpkgPath {
    NSURL *fileURL = [NSURL fileURLWithPath:mp4Path];

    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:fileURL];
    } completionHandler:^(BOOL success, NSError *error) {
        if (success) {
            [[NSFileManager defaultManager] removeItemAtPath:mp4Path error:nil];
            [[NSFileManager defaultManager] removeItemAtPath:movpkgPath error:nil];
            NSString *msg = [NSString stringWithFormat:@"Video saved to Photos:\n%@", self.filename];
            [self finishWithTitle:@"Saved to Photos" message:msg];
        } else {
            NSLog(@"[SafariTool] Photos save failed: %@", error);
            [self fallbackToSaveMP4ToFiles:mp4Path movpkgPath:movpkgPath];
        }
    }];
}

- (void)fallbackToSaveMP4ToFiles:(NSString *)mp4Path movpkgPath:(NSString *)movpkgPath {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                          NSUserDomainMask, YES);
    NSString *docs = paths.firstObject ?: NSTemporaryDirectory();
    NSString *dir = [docs stringByAppendingPathComponent:@"SafariTool"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *mp4Name = [NSString stringWithFormat:@"%@.mp4", self.filename];
    NSString *dst = [dir stringByAppendingPathComponent:mp4Name];
    [fm removeItemAtPath:dst error:nil];

    NSError *moveErr = nil;
    [fm moveItemAtPath:mp4Path toPath:dst error:&moveErr];

    [fm removeItemAtPath:movpkgPath error:nil];

    if (moveErr) {
        [self finishWithTitle:@"Save Failed" message:moveErr.localizedDescription];
    } else {
        NSString *msg = [NSString stringWithFormat:@"Saved as %@", mp4Name];
        [self finishWithTitle:@"Saved to Files" message:msg];
    }
}

- (void)fallbackToPhotosFromMovpkg:(NSString *)movpkgPath {
    NSURL *movpkgURL = [NSURL fileURLWithPath:movpkgPath];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:movpkgURL options:nil];

    [asset loadValuesAsynchronouslyForKeys:@[@"tracks", @"duration"]
                         completionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            NSError *err = nil;
            AVKeyValueStatus status = [asset statusOfValueForKey:@"tracks" error:&err];
            if (status != AVKeyValueStatusLoaded) {
                [self keepMovpkgInFiles:movpkgPath];
                return;
            }
            [self runExportWithAsset:asset movpkgPath:movpkgPath];
        });
    }];
}

- (void)keepMovpkgInFiles:(NSString *)movpkgPath {
    NSString *msg = [NSString stringWithFormat:
                     @"HLS video saved as .movpkg.\n\nCould not convert to MP4.\n\nFile: %@.movpkg",
                     self.filename];
    [self finishWithTitle:@"Saved to Files" message:msg];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (!error) return;
    if (self.cancelled || self.finished) return;
    if (error.code == NSURLErrorCancelled) return;

    self.finished = YES;
    [self cleanupSession];
    NSString *msg = error.localizedDescription ?: @"Unknown error";
    [self finishWithTitle:@"HLS Download Failed" message:msg];
}

- (void)cancel {
    if (self.cancelled) return;
    self.cancelled = YES;
    [[STFloatingProgress shared] hide];
    if (self.progressAlert) {
        [self.progressAlert dismissViewControllerAnimated:YES completion:^{
            self.progressAlert = nil;
        }];
    }
    if (self.task) [self.task cancel];
    [self cleanupSession];
}

@end

@interface STDownloadManager : NSObject <NSURLSessionDownloadDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) UIAlertController *progressAlert;
@property (nonatomic, copy) NSString *filename;
@property (nonatomic, assign) double currentProgress;
@property (nonatomic, assign) BOOL inBackgroundMode;
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, assign) BOOL finished;
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
    if (self) [self recreateSession];
    return self;
}

- (void)recreateSession {
    if (self.session) {
        [self.session invalidateAndCancel];
        self.session = nil;
    }
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 30.0;
    cfg.timeoutIntervalForResource = 3600.0;
    self.session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
}

- (void)finishWithTitle:(NSString *)title message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[STFloatingProgress shared] hide];
        UIAlertController *alert = self.progressAlert;
        self.progressAlert = nil;
        if (alert) {
            [alert dismissViewControllerAnimated:YES completion:^{
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(0.4 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    ST_ShowResultAlert(title, message);
                });
            }];
        } else {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                ST_ShowResultAlert(title, message);
            });
        }
    });
}

- (void)startDownload:(NSString *)urlString referer:(NSString *)referer ua:(NSString *)ua {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        ST_ShowResultAlert(@"SafariTool", @"Invalid URL");
        return;
    }

    self.currentProgress = 0.0;
    self.inBackgroundMode = NO;
    self.cancelled = NO;
    self.finished = NO;

    NSString *name = url.lastPathComponent;
    if (name.length == 0) name = @"video";
    NSString *ts = [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]];
    NSString *base = [name stringByDeletingPathExtension];
    NSString *ext = [name pathExtension];
    if (base.length == 0) base = @"video";
    if (ext.length == 0) ext = @"mp4";
    self.filename = [NSString stringWithFormat:@"%@_%@.%@", base, ts, ext];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    if (referer.length > 0) [req setValue:referer forHTTPHeaderField:@"Referer"];
    if (ua.length > 0) [req setValue:ua forHTTPHeaderField:@"User-Agent"];

    [self showAlert];

    NSURLSessionDownloadTask *task = [self.session downloadTaskWithRequest:req];
    [task resume];
}

- (void)showAlert {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.progressAlert) return;
        UIViewController *top = ST_SafeTopViewController();
        if (!top) return;
        if (top.presentedViewController) return;

        NSString *msg = [NSString stringWithFormat:@"Downloading %@...\n\n%.0f%%",
                         self.filename, self.currentProgress * 100.0];
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"SafariTool"
                                                message:msg
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Background"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(0.35 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self enterBackgroundMode];
            });
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                  style:UIAlertActionStyleCancel
                                                handler:^(UIAlertAction *action) {
            [self cancel];
        }]];
        self.progressAlert = alert;
        self.inBackgroundMode = NO;
        [top presentViewController:alert animated:YES completion:nil];
    });
}

- (void)enterBackgroundMode {
    self.inBackgroundMode = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.finished || self.cancelled) return;
        NSString *pct = [NSString stringWithFormat:@"%.0f%%", self.currentProgress * 100.0];
        STFloatingProgress *fp = [STFloatingProgress shared];
        fp.onTap = ^{ [self showAlert]; };
        fp.onCancel = ^{ [self cancel]; };
        [fp showWithText:pct];
    });
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    if (self.cancelled || self.finished) return;
    if (totalBytesExpectedToWrite <= 0) return;
    double progress = (double)totalBytesWritten / (double)totalBytesExpectedToWrite;
    self.currentProgress = progress;

    if (self.inBackgroundMode) {
        NSString *pct = [NSString stringWithFormat:@"%.0f%%", progress * 100.0];
        [[STFloatingProgress shared] updateText:pct];
    } else if (self.progressAlert) {
        NSString *msg = [NSString stringWithFormat:@"Downloading %@...\n\n%.0f%%",
                         self.filename, progress * 100.0];
        self.progressAlert.message = msg;
    }
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    if (self.cancelled || self.finished) return;
    self.finished = YES;

    NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:self.filename];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:tmpPath error:nil];

    NSError *copyErr = nil;
    BOOL copied = [fm copyItemAtURL:location
                              toURL:[NSURL fileURLWithPath:tmpPath]
                              error:&copyErr];
    if (!copied) {
        NSString *msg = copyErr.localizedDescription ?: @"Could not copy";
        [self finishWithTitle:@"Save Failed" message:msg];
        return;
    }

    [self saveVideoToPhotos:tmpPath];
}

- (void)saveVideoToPhotos:(NSString *)path {
    NSURL *fileURL = [NSURL fileURLWithPath:path];

    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:fileURL];
    } completionHandler:^(BOOL success, NSError *error) {
        if (success) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            NSString *msg = [NSString stringWithFormat:@"Video saved: %@", self.filename];
            [self finishWithTitle:@"Saved to Photos" message:msg];
            return;
        }
        [self saveVideoToDocuments:path];
    }];
}

- (void)saveVideoToDocuments:(NSString *)path {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                          NSUserDomainMask, YES);
    NSString *docs = paths.firstObject ?: NSTemporaryDirectory();
    NSString *dir = [docs stringByAppendingPathComponent:@"SafariTool"];

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *dst = [dir stringByAppendingPathComponent:self.filename];
    NSError *moveErr = nil;
    [fm moveItemAtPath:path toPath:dst error:&moveErr];

    if (moveErr) {
        [self finishWithTitle:@"Save Failed" message:moveErr.localizedDescription];
    } else {
        NSString *msg = [NSString stringWithFormat:@"Saved as %@", self.filename];
        [self finishWithTitle:@"Saved to Files" message:msg];
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (!error) return;
    if (self.cancelled || self.finished) return;
    if (error.code == NSURLErrorCancelled) return;
    self.finished = YES;
    NSString *msg = error.localizedDescription ?: @"Unknown error";
    [self finishWithTitle:@"Download Failed" message:msg];
}

- (void)cancel {
    if (self.cancelled) return;
    self.cancelled = YES;
    [[STFloatingProgress shared] hide];
    if (self.progressAlert) {
        [self.progressAlert dismissViewControllerAnimated:YES completion:^{
            self.progressAlert = nil;
        }];
    }
    if (self.session) {
        [self.session invalidateAndCancel];
        self.session = nil;
    }
    [self recreateSession];
}

@end

static BOOL ST_IsHLSURL(NSString *urlString) {
    if (urlString.length == 0) return NO;
    NSString *lower = urlString.lowercaseString;
    if ([lower containsString:@".m3u8"]) return YES;
    if ([lower containsString:@"/hls/"]) return YES;
    return NO;
}

@interface STMessageHandler : NSObject <WKScriptMessageHandler>
@end

@implementation STMessageHandler

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    @try {
        if (![message.name isEqualToString:@"stDownload"]) return;

        NSDictionary *body = message.body;
        NSString *urlStr = body[@"url"];
        NSString *referer = body[@"referer"];
        NSString *ua = body[@"ua"];
        BOOL isBlob = [body[@"blob"] boolValue];
        NSArray *streams = body[@"streams"];
        WKWebView *wv = message.webView;

        if (![referer isKindOfClass:[NSString class]]) referer = @"";
        if (![ua isKindOfClass:[NSString class]]) ua = @"";

        if (isBlob || !urlStr || urlStr.length == 0 || [urlStr hasPrefix:@"blob:"]) {
            [self handleStreamingChoice:streams referer:referer ua:ua webView:wv];
            return;
        }

        if (![urlStr isKindOfClass:[NSString class]]) return;

        if (ST_IsHLSURL(urlStr)) {
            [[STHLSDownloader shared] startWithURL:urlStr
                                            referer:referer
                                                 ua:ua
                                            webView:wv];
        } else {
            [[STDownloadManager shared] startDownload:urlStr referer:referer ua:ua];
        }
    } @catch (NSException *e) {
        NSLog(@"[SafariTool] Exception: %@", e);
    }
}

- (void)handleStreamingChoice:(NSArray *)streams
                     referer:(NSString *)referer
                          ua:(NSString *)ua
                     webView:(WKWebView *)wv {
    NSMutableArray *valid = [NSMutableArray array];
    if ([streams isKindOfClass:[NSArray class]]) {
        for (id s in streams) {
            if ([s isKindOfClass:[NSString class]] && [s length] > 0) {
                [valid addObject:s];
            }
        }
    }

    if (valid.count == 0) {
        ST_ShowResultAlert(@"No stream captured",
                           @"Please PLAY the video for 2-3 seconds first, then press download again.");
        return;
    }

    if (valid.count == 1) {
        [[STHLSDownloader shared] startWithURL:valid.firstObject
                                        referer:referer
                                             ua:ua
                                        webView:wv];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = ST_SafeTopViewController();
        if (!top) return;
        if (top.presentedViewController) return;

        UIAlertController *sheet =
            [UIAlertController alertControllerWithTitle:@"Choose a stream"
                                                message:@"Try option 1 first:"
                                         preferredStyle:UIAlertControllerStyleActionSheet];

        NSInteger idx = 1;
        for (NSString *url in valid) {
            NSString *shortName = url.lastPathComponent;
            if (shortName.length > 50) shortName = [shortName substringToIndex:50];
            NSString *title = [NSString stringWithFormat:@"%ld. %@", (long)idx, shortName];
            [sheet addAction:[UIAlertAction actionWithTitle:title
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction *action) {
                [[STHLSDownloader shared] startWithURL:url
                                                referer:referer
                                                     ua:ua
                                                webView:wv];
            }]];
            idx++;
        }

        [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];

        if (sheet.popoverPresentationController) {
            sheet.popoverPresentationController.sourceView = top.view;
            sheet.popoverPresentationController.sourceRect =
                CGRectMake(top.view.bounds.size.width / 2.0,
                           top.view.bounds.size.height / 2.0, 1, 1);
        }
        [top presentViewController:sheet animated:YES completion:nil];
    });
}

@end

static void ST_InstallScripts(WKWebView *wv) {
    @try {
        WKUserContentController *ucc = wv.configuration.userContentController;
        if (!ucc) return;
        if (objc_getAssociatedObject(ucc, &kSTInstalledKey)) return;
        objc_setAssociatedObject(ucc, &kSTInstalledKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        WKUserScript *captureScript =
            [[WKUserScript alloc] initWithSource:ST_StreamCaptureJS()
                                   injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                forMainFrameOnly:NO];
        [ucc addUserScript:captureScript];

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
    } @catch (NSException *e) {}
}

%group STWebKit

%hook WKWebView

- (id)initWithFrame:(CGRect)frame configuration:(id)configuration {
    id r = %orig;
    if (r) ST_InstallScripts((WKWebView *)r);
    return r;
}

- (void)setNavigationDelegate:(id<WKNavigationDelegate>)delegate {
    %orig;
    if (delegate) ST_PatchDelegateClass([(NSObject *)delegate class]);
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
