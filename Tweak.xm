#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <Photos/Photos.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

static NSString *const kSTGuardVersion = @"0.7.5";
static const NSInteger kSTCrashLimit = 3;
static const double kSTSurviveSeconds = 6.0;

static NSString *const kSTAVHeadersKey = @"AVURLAssetHTTPHeaderFieldsKey";

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
        ^(id self_, WKWebView *wv, WKNavigationAction *action,
          WKWebpagePreferences *prefs, STDecisionHandler handler) {
            BOOL should = NO;
            @try {
                BOOL isMain = (!action.targetFrame || action.targetFrame.isMainFrame);
                NSString *scheme = [action.request.URL.scheme lowercaseString];
                BOOL web = ([scheme isEqualToString:@"http"] ||
                            [scheme isEqualToString:@"https"]);
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
        [s appendString:@"function isBlob(u){"];
        [s appendString:@"return u && u.indexOf('blob:')===0;"];
        [s appendString:@"}"];
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
        [s appendString:@"if(!id){"];
        [s appendString:@"id='st'+Math.random().toString(36).substr(2,9);"];
        [s appendString:@"v.setAttribute(ID_ATTR,id);"];
        [s appendString:@"}"];
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

@interface STHLSDownloader : NSObject
@property (nonatomic, strong) AVAssetExportSession *exportSession;
@property (nonatomic, strong) AVURLAsset *asset;
@property (nonatomic, strong) UIAlertController *progressAlert;
@property (nonatomic, copy) NSString *urlString;
@property (nonatomic, copy) NSString *referer;
@property (nonatomic, copy) NSString *ua;
@property (nonatomic, copy) NSString *filename;
@property (nonatomic, strong) NSTimer *progressTimer;
@property (nonatomic, strong) WKWebView *webView;
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

- (void)startWithURL:(NSString *)urlString
             referer:(NSString *)referer
                  ua:(NSString *)ua
             webView:(WKWebView *)webView {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        ST_ShowResultAlert(@"SafariTool", @"Invalid URL");
        return;
    }

    self.urlString = urlString;
    self.referer = referer;
    self.ua = ua;
    self.webView = webView;

    NSString *base = url.lastPathComponent;
    if (base.length == 0) {
        base = @"video";
    }
    base = [base stringByDeletingPathExtension];
    if (base.length == 0) {
        base = @"video";
    }
    NSString *ts = [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]];
    self.filename = [NSString stringWithFormat:@"%@_%@.mp4", base, ts];

    __weak STHLSDownloader *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        STHLSDownloader *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        UIViewController *top = ST_TopViewController();
        if (!top) {
            return;
        }
        NSString *msg = [NSString stringWithFormat:@"Preparing HLS stream...\n\n%@\n0%%",
                         strongSelf.filename];
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"SafariTool (HLS)"
                                                message:msg
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                  style:UIAlertActionStyleCancel
                                                handler:^(UIAlertAction *action) {
            [strongSelf cancel];
        }]];
        strongSelf.progressAlert = alert;
        [top presentViewController:alert animated:YES completion:nil];
    });

    [self fetchCookiesAndBegin];
}

- (void)fetchCookiesAndBegin {
    __weak STHLSDownloader *weakSelf = self;

    WKWebView *wv = self.webView;
    if (!wv) {
        [self beginWithCookieHeader:@""];
        return;
    }

    WKHTTPCookieStore *store = wv.configuration.websiteDataStore.httpCookieStore;
    if (!store) {
        [self beginWithCookieHeader:@""];
        return;
    }

    [store getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        dispatch_async(dispatch_get_main_queue(), ^{
            STHLSDownloader *strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            NSMutableArray *parts = [NSMutableArray array];
            for (NSHTTPCookie *cookie in cookies) {
                if (cookie.name.length == 0) continue;
                [parts addObject:[NSString stringWithFormat:@"%@=%@",
                                  cookie.name, cookie.value ?: @""]];
            }
            NSString *cookieHeader = [parts componentsJoinedByString:@"; "];
            NSLog(@"[SafariTool] Passing %lu cookies", (unsigned long)cookies.count);
            [strongSelf beginWithCookieHeader:cookieHeader];
        });
    }];
}

- (void)beginWithCookieHeader:(NSString *)cookieHeader {
    NSURL *url = [NSURL URLWithString:self.urlString];

    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    if (self.referer.length > 0) {
        headers[@"Referer"] = self.referer;
    }
    if (self.ua.length > 0) {
        headers[@"User-Agent"] = self.ua;
    }
    if (cookieHeader.length > 0) {
        headers[@"Cookie"] = cookieHeader;
    }
    headers[@"Accept"] = @"*/*";

    NSDictionary *options = @{ kSTAVHeadersKey: headers };
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:options];
    self.asset = asset;

    __weak STHLSDownloader *weakSelf = self;
    [asset loadValuesAsynchronouslyForKeys:@[@"tracks", @"duration"]
                         completionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            STHLSDownloader *strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            NSError *err = nil;
            AVKeyValueStatus status = [asset statusOfValueForKey:@"tracks" error:&err];
            if (status != AVKeyValueStatusLoaded) {
                NSString *detail = err.localizedDescription ?: @"Unknown";
                [strongSelf.progressAlert dismissViewControllerAnimated:YES completion:^{
                    strongSelf.progressAlert = nil;
                    ST_ShowResultAlert(@"HLS Load Failed", detail);
                }];
                return;
            }
            [strongSelf beginExportWithAsset:asset];
        });
    }];
}

- (void)beginExportWithAsset:(AVAsset *)asset {
    NSArray *presets = [AVAssetExportSession exportPresetsCompatibleWithAsset:asset];
    NSLog(@"[SafariTool] Compatible presets: %@", presets);

    NSString *preset = nil;

    if ([presets containsObject:AVAssetExportPresetPassthrough]) {
        preset = AVAssetExportPresetPassthrough;
        NSLog(@"[SafariTool] Using Passthrough (fast remux)");
    } else if ([presets containsObject:AVAssetExportPresetHighestQuality]) {
        preset = AVAssetExportPresetHighestQuality;
    } else if ([presets containsObject:AVAssetExportPresetMediumQuality]) {
        preset = AVAssetExportPresetMediumQuality;
    } else if (presets.count > 0) {
        preset = presets.firstObject;
    }

    if (!preset) {
        [self.progressAlert dismissViewControllerAnimated:YES completion:^{
            self.progressAlert = nil;
            ST_ShowResultAlert(@"HLS Download Failed",
                               @"No compatible export preset found for this HLS stream.");
        }];
        return;
    }

    NSString *outputPath =
        [NSTemporaryDirectory() stringByAppendingPathComponent:self.filename];
    [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];

    AVAssetExportSession *session =
        [[AVAssetExportSession alloc] initWithAsset:asset presetName:preset];
    session.outputURL = [NSURL fileURLWithPath:outputPath];

    NSArray *supportedTypes = session.supportedFileTypes;
    if ([supportedTypes containsObject:AVFileTypeMPEG4]) {
        session.outputFileType = AVFileTypeMPEG4;
    } else if ([supportedTypes containsObject:AVFileTypeQuickTimeMovie]) {
        session.outputFileType = AVFileTypeQuickTimeMovie;
    } else if (supportedTypes.count > 0) {
        session.outputFileType = supportedTypes.firstObject;
    }

    session.shouldOptimizeForNetworkUse = YES;
    self.exportSession = session;

    self.progressTimer =
        [NSTimer scheduledTimerWithTimeInterval:0.5
                                         target:self
                                       selector:@selector(updateProgress)
                                       userInfo:nil
                                        repeats:YES];

    __weak STHLSDownloader *weakSelf = self;
    [session exportAsynchronouslyWithCompletionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            STHLSDownloader *strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            [strongSelf.progressTimer invalidate];
            strongSelf.progressTimer = nil;
            [strongSelf handleExportComplete:session outputPath:outputPath];
        });
    }];
}

- (void)updateProgress {
    if (!self.exportSession || !self.progressAlert) {
        return;
    }
    float progress = self.exportSession.progress;
    NSString *msg =
        [NSString stringWithFormat:@"Downloading HLS stream...\n\n%@\n%.0f%%",
         self.filename, progress * 100.0];
    self.progressAlert.message = msg;
}

- (void)handleExportComplete:(AVAssetExportSession *)session outputPath:(NSString *)outputPath {
    AVAssetExportSessionStatus status = session.status;

    NSLog(@"[SafariTool] Export status: %ld, error: %@", (long)status, session.error);

    if (status == AVAssetExportSessionStatusCompleted) {
        [self saveToPhotos:outputPath];
        return;
    }

    NSString *errMsg = nil;
    if (status == AVAssetExportSessionStatusFailed) {
        errMsg = session.error.localizedDescription ?: @"Unknown failure";
    } else if (status == AVAssetExportSessionStatusCancelled) {
        errMsg = [NSString stringWithFormat:
            @"The stream was cancelled by iOS.\n\nPossible reasons:\n- Video is too long\n- Memory pressure\n- Stream requires DRM"];
    } else {
        errMsg = [NSString stringWithFormat:@"Status: %ld", (long)status];
    }
    [self.progressAlert dismissViewControllerAnimated:YES completion:^{
        self.progressAlert = nil;
        ST_ShowResultAlert(@"HLS Download Failed", errMsg);
    }];
}

- (void)saveToPhotos:(NSString *)path {
    NSURL *fileURL = [NSURL fileURLWithPath:path];
    __weak STHLSDownloader *weakSelf = self;

    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:fileURL];
    } completionHandler:^(BOOL success, NSError *error) {
        STHLSDownloader *strongSelf = weakSelf;
        if (success) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf.progressAlert dismissViewControllerAnimated:YES
                                                             completion:^{
                    strongSelf.progressAlert = nil;
                    ST_ShowResultAlert(@"Saved to Photos",
                                       [NSString stringWithFormat:@"HLS video saved: %@",
                                        strongSelf.filename]);
                }];
            });
            return;
        }
        [strongSelf saveToDocuments:path];
    }];
}

- (void)saveToDocuments:(NSString *)path {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                          NSUserDomainMask, YES);
    NSString *docs = paths.firstObject ?: NSTemporaryDirectory();
    NSString *dir = [docs stringByAppendingPathComponent:@"SafariTool"];

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *dst = [dir stringByAppendingPathComponent:self.filename];
    NSError *moveErr = nil;
    [fm moveItemAtPath:path toPath:dst error:&moveErr];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.progressAlert dismissViewControllerAnimated:YES completion:^{
            self.progressAlert = nil;
            if (moveErr) {
                ST_ShowResultAlert(@"Save Failed", moveErr.localizedDescription);
                return;
            }
            ST_ShowResultAlert(@"Saved to Files",
                               [NSString stringWithFormat:@"Saved as %@", self.filename]);
        }];
    });
}

- (void)cancel {
    if (self.exportSession) {
        [self.exportSession cancelExport];
    }
    [self.progressTimer invalidate];
    self.progressTimer = nil;
}

@end

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

- (void)startDownload:(NSString *)urlString referer:(NSString *)referer ua:(NSString *)ua {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        ST_ShowResultAlert(@"SafariTool", @"Invalid URL");
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    if (referer.length > 0) {
        [req setValue:referer forHTTPHeaderField:@"Referer"];
    }
    if (ua.length > 0) {
        [req setValue:ua forHTTPHeaderField:@"User-Agent"];
    }

    __weak STDownloadManager *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        STDownloadManager *strongSelf = weakSelf;
        if (!strongSelf) return;
        UIViewController *top = ST_TopViewController();
        if (!top) return;
        NSString *name = url.lastPathComponent;
        if (name.length == 0) name = @"video";
        NSString *msg = [NSString stringWithFormat:@"Downloading %@...\n\n0%%", name];
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"SafariTool"
                                                message:msg
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                  style:UIAlertActionStyleCancel
                                                handler:^(UIAlertAction *action) {
            [strongSelf.session invalidateAndCancel];
            [strongSelf recreateSession];
        }]];
        strongSelf.progressAlert = alert;
        [top presentViewController:alert animated:YES completion:nil];
    });

    NSURLSessionDownloadTask *task = [self.session downloadTaskWithRequest:req];
    [task resume];
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    if (totalBytesExpectedToWrite <= 0) return;
    double progress = (double)totalBytesWritten / (double)totalBytesExpectedToWrite;
    NSString *name = downloadTask.originalRequest.URL.lastPathComponent;
    if (name.length == 0) name = @"video";
    NSString *msg = [NSString stringWithFormat:@"Downloading %@...\n\n%.0f%%",
                     name, progress * 100.0];
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
    if (filename.length == 0) filename = @"video.mp4";

    NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:filename];

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:tmpPath error:nil];

    NSError *copyErr = nil;
    BOOL copied = [fm copyItemAtURL:location
                              toURL:[NSURL fileURLWithPath:tmpPath]
                              error:&copyErr];
    if (!copied) {
        NSString *msg = copyErr.localizedDescription ?: @"Could not copy";
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
    __weak STDownloadManager *weakSelf = self;

    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:fileURL];
    } completionHandler:^(BOOL success, NSError *error) {
        STDownloadManager *strongSelf = weakSelf;
        if (success) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf.progressAlert dismissViewControllerAnimated:YES completion:^{
                    strongSelf.progressAlert = nil;
                    ST_ShowResultAlert(@"Saved to Photos",
                                       [NSString stringWithFormat:@"Video saved: %@", name]);
                }];
            });
            return;
        }
        [strongSelf saveVideoToDocuments:path originalName:name];
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
    NSError *moveErr = nil;
    [fm moveItemAtPath:path toPath:dst error:&moveErr];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.progressAlert dismissViewControllerAnimated:YES completion:^{
            self.progressAlert = nil;
            if (moveErr) {
                ST_ShowResultAlert(@"Save Failed", moveErr.localizedDescription);
            } else {
                ST_ShowResultAlert(@"Saved to Files",
                                   [NSString stringWithFormat:@"Saved as %@", name]);
            }
        }];
    });
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (!error) return;
    if (error.code == NSURLErrorCancelled) return;
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
        UIViewController *top = ST_TopViewController();
        if (!top) return;
        UIAlertController *sheet =
            [UIAlertController alertControllerWithTitle:@"Choose a stream"
                                                message:@"Try option 1 first:"
                                         preferredStyle:UIAlertControllerStyleActionSheet];

        NSInteger idx = 1;
        for (NSString *url in valid) {
            NSString *shortName = url.lastPathComponent;
            if (shortName.length > 50) {
                shortName = [shortName substringToIndex:50];
            }
            NSString *title = [NSString stringWithFormat:@"%ld. %@", (long)idx, shortName];
            [sheet addAction:[UIAlertAction actionWithTitle:title
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction *action) {
                [[STHLSDownloader shared] startWithURL:url referer:referer ua:ua webView:wv];
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
