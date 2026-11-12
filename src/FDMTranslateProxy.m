#import "FDMTranslateProxy.h"
#import "FDMCommon.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>

static NSString *const FDMEdgeUserAgent = @"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36 Edg/153.0.0.0";
static NSString *const FDMEdgeEndpoint = @"https://edge.microsoft.com/translate/translatetext";

static void (*orig_TranslateHelper_handleHttpRequest)(id, SEL, NSDictionary *);
static BOOL (*orig_PandaWebView_canPerformAction)(id, SEL, SEL, id);

// Forward declarations
static void fdm_TranslateHelper_sendResponse(id helper, NSString *reqId, BOOL succ, NSString *responseText);
static void fdm_TranslateHelper_fallbackEdge(id helper, NSString *reqId, NSURLRequest *origReq);
static void fdm_TranslateHelper_executeRequest(id helper, NSString *reqId, NSMutableURLRequest *request, BOOL fallbackOnFailure);

static NSString *fdm_normalizeLanguage(NSString *lang) {
    if (!lang || lang.length == 0) return @"zh-Hans";
    NSString *lower = [lang lowercaseString];
    if ([lower isEqualToString:@"zh-cn"] || [lower isEqualToString:@"zh-chs"] || [lower isEqualToString:@"zh"]) {
        return @"zh-Hans";
    }
    if ([lower isEqualToString:@"zh-tw"] || [lower isEqualToString:@"zh-hk"] || [lower isEqualToString:@"zh-cht"]) {
        return @"zh-Hant";
    }
    return lang;
}

static NSData *fdm_convertBodyToEdgeFormat(NSString *bodyStr) {
    if (!bodyStr || bodyStr.length == 0) return nil;
    NSData *data = [bodyStr dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return nil;
    
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([json isKindOfClass:NSArray.class]) {
        NSMutableArray<NSString *> *strArr = [NSMutableArray array];
        for (id item in (NSArray *)json) {
            if ([item isKindOfClass:NSDictionary.class]) {
                NSString *text = ((NSDictionary *)item)[@"Text"] ?: ((NSDictionary *)item)[@"text"];
                [strArr addObject:text ?: @""];
            } else if ([item isKindOfClass:NSString.class]) {
                [strArr addObject:item];
            }
        }
        if (strArr.count > 0) {
            return [NSJSONSerialization dataWithJSONObject:strArr options:0 error:nil];
        }
    }
    return data;
}

@implementation FDMTranslateProxy

#pragma mark - TranslateHelper HTTP Request Hook

static void fdm_TranslateHelper_sendResponse(id helper, NSString *reqId, BOOL succ, NSString *responseText) {
    if (!helper || !reqId) return;
    SEL sendSel = NSSelectorFromString(@"sendResponseToJavaScript:succ:responseText:");
    if ([helper respondsToSelector:sendSel]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(helper, sendSel, reqId, succ, responseText ?: @"");
        });
    }
}

static void fdm_TranslateHelper_executeRequest(id helper, NSString *reqId, NSMutableURLRequest *request, BOOL fallbackOnFailure) {
    NSURLSession *session = NSURLSession.sharedSession;
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
        if (!error && statusCode >= 200 && statusCode < 300 && data.length > 0) {
            NSString *respText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (respText.length > 0) {
                fdm_TranslateHelper_sendResponse(helper, reqId, YES, respText);
                return;
            }
        }
        
        if (fallbackOnFailure) {
            FDMLog(@"translate proxy: primary request failed (status=%ld, err=%@), attempting Edge failover", (long)statusCode, error);
            fdm_TranslateHelper_fallbackEdge(helper, reqId, request);
            return;
        }
        
        fdm_TranslateHelper_sendResponse(helper, reqId, NO, @"");
    }] resume];
}

static void fdm_TranslateHelper_fallbackEdge(id helper, NSString *reqId, NSURLRequest *origReq) {
    NSURL *url = origReq.URL;
    NSURLComponents *comps = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString *rawTarget = @"zh-Hans";
    NSMutableArray<NSString *> *queryTexts = [NSMutableArray array];
    
    for (NSURLQueryItem *item in comps.queryItems) {
        if ([item.name isEqualToString:@"tl"] || [item.name isEqualToString:@"to"]) {
            rawTarget = item.value ?: @"zh-Hans";
        } else if ([item.name isEqualToString:@"q"]) {
            if (item.value.length > 0) {
                [queryTexts addObject:item.value];
            }
        }
    }
    NSString *targetLang = fdm_normalizeLanguage(rawTarget);
    
    // Extract source text(s)
    NSMutableArray<NSString *> *textsToTranslate = [NSMutableArray array];
    if (queryTexts.count > 0) {
        [textsToTranslate addObjectsFromArray:queryTexts];
    } else if (origReq.HTTPBody.length > 0) {
        id bodyJson = [NSJSONSerialization JSONObjectWithData:origReq.HTTPBody options:0 error:nil];
        if ([bodyJson isKindOfClass:NSArray.class]) {
            for (id item in (NSArray *)bodyJson) {
                if ([item isKindOfClass:NSDictionary.class]) {
                    NSString *t = ((NSDictionary *)item)[@"Text"] ?: ((NSDictionary *)item)[@"text"];
                    if (t.length > 0) [textsToTranslate addObject:t];
                } else if ([item isKindOfClass:NSString.class] && [(NSString *)item length] > 0) {
                    [textsToTranslate addObject:item];
                }
            }
        } else {
            NSString *rawBody = [[NSString alloc] initWithData:origReq.HTTPBody encoding:NSUTF8StringEncoding];
            if (rawBody.length > 0) [textsToTranslate addObject:rawBody];
        }
    }
    
    if (textsToTranslate.count == 0) {
        fdm_TranslateHelper_sendResponse(helper, reqId, NO, @"");
        return;
    }
    
    // Call Edge translatetext endpoint
    NSString *edgeUrlStr = [NSString stringWithFormat:@"%@?to=%@&isEnterpriseClient=false", FDMEdgeEndpoint, targetLang];
    NSMutableURLRequest *edgeReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:edgeUrlStr]];
    edgeReq.HTTPMethod = @"POST";
    edgeReq.timeoutInterval = 15.0;
    [edgeReq setValue:@"application/json; charset=UTF-8" forHTTPHeaderField:@"Content-Type"];
    [edgeReq setValue:FDMEdgeUserAgent forHTTPHeaderField:@"User-Agent"];
    
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:textsToTranslate options:0 error:nil];
    edgeReq.HTTPBody = bodyData;
    
    [NSURLSession.sharedSession dataTaskWithRequest:edgeReq completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
        if (!error && statusCode == 200 && data.length > 0) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:NSArray.class] && [(NSArray *)json count] > 0) {
                NSArray *results = (NSArray *)json;
                NSMutableArray *chunks = [NSMutableArray array];
                for (NSUInteger i = 0; i < results.count; i++) {
                    NSDictionary *item = results[i];
                    NSArray *translations = item[@"translations"];
                    NSString *translated = @"";
                    if ([translations isKindOfClass:NSArray.class] && translations.count > 0) {
                        translated = translations[0][@"text"] ?: @"";
                    }
                    NSString *src = (i < textsToTranslate.count) ? textsToTranslate[i] : @"";
                    [chunks addObject:@[ translated, src, NSNull.null, NSNull.null, @(10) ]];
                }
                
                // Construct Google-compatible response: [[[trans, orig, null, null, 10]], null, "auto"]
                NSArray *outer = @[ chunks, NSNull.null, @"auto" ];
                NSData *mockResp = [NSJSONSerialization dataWithJSONObject:outer options:0 error:nil];
                NSString *mockStr = [[NSString alloc] initWithData:mockResp encoding:NSUTF8StringEncoding];
                fdm_TranslateHelper_sendResponse(helper, reqId, YES, mockStr);
                return;
            }
        }
        fdm_TranslateHelper_sendResponse(helper, reqId, NO, @"");
    }];
}

static void fdm_TranslateHelper_handleHttpRequest(id self, SEL _cmd, NSDictionary *dict) {
    if (![dict isKindOfClass:NSDictionary.class]) {
        if (orig_TranslateHelper_handleHttpRequest) {
            orig_TranslateHelper_handleHttpRequest(self, _cmd, dict);
        }
        return;
    }
    
    NSString *urlStr = FDMString(dict[@"url"]);
    NSString *reqId = FDMString(dict[@"requestId"]);
    NSString *method = FDMString(dict[@"method"]) ?: @"GET";
    NSDictionary *headers = [dict[@"headers"] isKindOfClass:NSDictionary.class] ? dict[@"headers"] : nil;
    NSString *bodyStr = FDMString(dict[@"body"]);
    
    // Case 1: Microsoft decommissioned /translate/auth endpoint (returns 404 on MS servers)
    // Return dummy token so translateHelper JS doesn't abort
    if ([urlStr containsString:@"edge.microsoft.com/translate/auth"]) {
        FDMLog(@"translate proxy: intercepted dead Edge auth request, returning mock token");
        NSString *mockAuth = @"\"Bearer fdm_mock_edge_token\"";
        fdm_TranslateHelper_sendResponse(self, reqId, YES, mockAuth);
        return;
    }
    
    // Case 2: api-edge.cognitive.microsofttranslator.com request -> route directly to Edge translatetext
    if ([urlStr containsString:@"api-edge.cognitive.microsofttranslator.com"]) {
        NSURLComponents *origComps = [NSURLComponents componentsWithString:urlStr];
        NSString *toLang = @"zh-Hans";
        NSString *fromLang = nil;
        for (NSURLQueryItem *item in origComps.queryItems) {
            if ([item.name isEqualToString:@"to"]) {
                toLang = fdm_normalizeLanguage(item.value);
            } else if ([item.name isEqualToString:@"from"] && item.value.length > 0) {
                fromLang = item.value;
            }
        }
        
        NSString *edgeQuery = [NSString stringWithFormat:@"to=%@&isEnterpriseClient=false", toLang];
        if (fromLang) {
            edgeQuery = [edgeQuery stringByAppendingFormat:@"&from=%@", fromLang];
        }
        NSString *targetUrl = [NSString stringWithFormat:@"%@?%@", FDMEdgeEndpoint, edgeQuery];
        
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:targetUrl]];
        req.HTTPMethod = @"POST";
        req.timeoutInterval = 15.0;
        [req setValue:FDMEdgeUserAgent forHTTPHeaderField:@"User-Agent"];
        [req setValue:@"application/json; charset=UTF-8" forHTTPHeaderField:@"Content-Type"];
        
        NSData *convertedBody = fdm_convertBodyToEdgeFormat(bodyStr);
        if (convertedBody) {
            req.HTTPBody = convertedBody;
        }
        
        FDMLog(@"translate proxy: routed Azure translator request to Edge free endpoint");
        fdm_TranslateHelper_executeRequest(self, reqId, req, NO);
        return;
    }
    
    // Case 3: Google Translate (translate.googleapis.com) -> try direct, failover to Edge on connection error
    if ([urlStr containsString:@"translate.googleapis.com"] || [urlStr containsString:@"translate.google.com"]) {
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
        req.HTTPMethod = method;
        req.timeoutInterval = 3.5; // Short timeout for China network fast-fail
        for (NSString *hKey in headers) {
            [req setValue:headers[hKey] forHTTPHeaderField:hKey];
        }
        if (bodyStr.length > 0) {
            req.HTTPBody = [bodyStr dataUsingEncoding:NSUTF8StringEncoding];
        }
        
        FDMLog(@"translate proxy: executing Google Translate request with domestic auto-failover");
        fdm_TranslateHelper_executeRequest(self, reqId, req, YES);
        return;
    }
    
    // Default: pass through to original
    if (orig_TranslateHelper_handleHttpRequest) {
        orig_TranslateHelper_handleHttpRequest(self, _cmd, dict);
    }
}

#pragma mark - PandaWebView Context Menu & System Translation

static void fdm_PandaWebView_safeTranslate(id self, SEL _cmd, id sender) {
    (void)_cmd;
    @try {
        // 1. Forward to super (WKWebView's native translate: method)
        struct objc_super sup = {
            .receiver = self,
            .super_class = class_getSuperclass([self class])
        };
        SEL transSel = @selector(translate:);
        if ([WKWebView instancesRespondToSelector:transSel]) {
            ((void (*)(struct objc_super *, SEL, id))objc_msgSendSuper)(&sup, transSel, sender);
            return;
        }
    } @catch (NSException *e) {
        FDMLog(@"translate proxy: caught exception in [super translate:]: %@", e);
    }
    
    // 2. Direct fallback to contentView translateForWebView:
    @try {
        UIView *contentView = nil;
        UIScrollView *sv = [self valueForKey:@"scrollView"];
        if ([sv isKindOfClass:UIScrollView.class]) {
            for (UIView *sub in sv.subviews) {
                if ([NSStringFromClass(sub.class) containsString:@"WKContentView"]) {
                    contentView = sub;
                    break;
                }
            }
        }
        SEL transForWeb = NSSelectorFromString(@"translateForWebView:");
        if (contentView && [contentView respondsToSelector:transForWeb]) {
            ((void (*)(id, SEL, id))objc_msgSend)(contentView, transForWeb, sender);
            return;
        }
    } @catch (NSException *e) {
        FDMLog(@"translate proxy: caught exception in translateForWebView: %@", e);
    }
}

static BOOL fdm_PandaWebView_canPerformAction(id self, SEL _cmd, SEL action, id sender) {
    NSString *selName = NSStringFromSelector(action);
    if ([selName isEqualToString:@"translate:"] ||
        [selName isEqualToString:@"_translate:"] ||
        [selName isEqualToString:@"_systemTranslate:"] ||
        [selName isEqualToString:@"findInPageItem"]) {
        return YES;
    }
    
    if (orig_PandaWebView_canPerformAction && orig_PandaWebView_canPerformAction(self, _cmd, action, sender)) {
        return YES;
    }
    
    struct objc_super sup = {
        .receiver = self,
        .super_class = class_getSuperclass([self class])
    };
    if ([WKWebView instancesRespondToSelector:@selector(canPerformAction:withSender:)]) {
        return ((BOOL (*)(struct objc_super *, SEL, SEL, id))objc_msgSendSuper)(&sup, @selector(canPerformAction:withSender:), action, sender);
    }
    return NO;
}

#pragma mark - Hook Installation

+ (void)installHooks {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 1. Hook TranslateHelper handleHttpRequest:
        Class helperClass = NSClassFromString(@"TranslateHelper");
        if (helperClass) {
            SEL httpSel = NSSelectorFromString(@"handleHttpRequest:");
            Method httpMethod = class_getInstanceMethod(helperClass, httpSel);
            if (httpMethod) {
                orig_TranslateHelper_handleHttpRequest = (void (*)(id, SEL, NSDictionary *))method_getImplementation(httpMethod);
                method_setImplementation(httpMethod, (IMP)fdm_TranslateHelper_handleHttpRequest);
                FDMLog(@"translate proxy: hooked TranslateHelper handleHttpRequest:");
            }
        }
        
        // 2. Hook PandaWebView canPerformAction:withSender: & register translation selectors
        Class webViewClass = NSClassFromString(@"PandaWebView");
        if (webViewClass) {
            SEL canSel = @selector(canPerformAction:withSender:);
            Method canMethod = class_getInstanceMethod(webViewClass, canSel);
            if (canMethod) {
                orig_PandaWebView_canPerformAction = (BOOL (*)(id, SEL, SEL, id))method_getImplementation(canMethod);
                method_setImplementation(canMethod, (IMP)fdm_PandaWebView_canPerformAction);
                FDMLog(@"translate proxy: hooked PandaWebView canPerformAction:withSender:");
            }
            
            // Register safe translate handlers for translate:, _translate:, _systemTranslate:
            SEL transSel = @selector(translate:);
            SEL privTransSel = NSSelectorFromString(@"_translate:");
            SEL sysTransSel = NSSelectorFromString(@"_systemTranslate:");
            class_replaceMethod(webViewClass, transSel, (IMP)fdm_PandaWebView_safeTranslate, "v@:@");
            class_replaceMethod(webViewClass, privTransSel, (IMP)fdm_PandaWebView_safeTranslate, "v@:@");
            class_replaceMethod(webViewClass, sysTransSel, (IMP)fdm_PandaWebView_safeTranslate, "v@:@");
            FDMLog(@"translate proxy: registered safe translation handlers on PandaWebView");
        }
    });
}

@end
