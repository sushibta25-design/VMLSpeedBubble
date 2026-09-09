// =====================================================================
// VMLSpeedBubble - combined single-file tweak
//
// Runs in TWO processes (see filter in VMLSpeedBubble.plist):
//   1. vn.vietmap.live  -> captures the speed limit from the app and
//                          publishes it via a Darwin notification.
//   2. com.apple.springboard -> receives the speed and draws:
//          - a floating bubble on the phone screen
//          - a floating bubble on the CarPlay screen (wired OR wireless)
//
// Log file: /var/mobile/VMLSpeedBubble.log
// =====================================================================

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>
#import <objc/runtime.h>
#import <math.h>

#define VML_NOTIFY_NAME "com.sushibta.vmlspeedbubble.speed"
#define VML_LOG_PATH "/var/mobile/VMLSpeedBubble.log"

#pragma mark - Logging (shared)

static void VMLLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"[VMLSpeedBubble] %@", msg);

    NSString *line = [NSString stringWithFormat:@"%@\n", msg];
    FILE *f = fopen(VML_LOG_PATH, "a");
    if (f) {
        fprintf(f, "%s", line.UTF8String);
        fclose(f);
    }
}

static BOOL VMLBundleIs(NSString *identifier) {
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"";
    return [bundle isEqualToString:identifier];
}

// =====================================================================
// MARK: - PART 1: Speed capture (runs inside vn.vietmap.live)
// =====================================================================

static IMP gOrigMethodCallInit = NULL;
static int gPublishToken = 0;

static NSInteger VMLSpeedFromObject(id obj) {
    if (!obj) return -1;
    if ([obj respondsToSelector:@selector(integerValue)]) {
        return [obj integerValue];
    }
    return -1;
}

static void VMLPublishSpeed(NSInteger speed) {
    if (speed < 0 || speed > 200) {
        return;
    }

    if (gPublishToken == 0) {
        int token = 0;
        uint32_t status = notify_register_check(VML_NOTIFY_NAME, &token);
        if (status != NOTIFY_STATUS_OK) {
            VMLLog(@"[capture] notify_register_check failed=%u", status);
            return;
        }
        gPublishToken = token;
    }

    notify_set_state(gPublishToken, (uint64_t)speed);
    notify_post(VML_NOTIFY_NAME);

    VMLLog(@"[capture] published speed=%ld", (long)speed);
}

static id VMLHookMethodCallInit(id self, SEL _cmd, NSString *methodName, id arguments) {
    id result = nil;

    if (gOrigMethodCallInit) {
        result = ((id (*)(id, SEL, NSString *, id))gOrigMethodCallInit)(self, _cmd, methodName, arguments);
    }

    if ([methodName isEqualToString:@"updateSpeedLimit"]) {
        NSInteger speed = VMLSpeedFromObject(arguments);
        VMLLog(@"[capture] updateSpeedLimit arguments=%@ parsed=%ld", arguments, (long)speed);
        VMLPublishSpeed(speed);
    }

    return result;
}

static void VMLInstallCaptureHook(void) {
    Class cls = objc_getClass("FlutterMethodCall");
    if (!cls) {
        VMLLog(@"[capture] FlutterMethodCall not loaded yet");
        return;
    }

    SEL sel = NSSelectorFromString(@"initWithMethodName:arguments:");
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        VMLLog(@"[capture] FlutterMethodCall method missing");
        return;
    }

    IMP current = method_getImplementation(method);
    if (current == (IMP)VMLHookMethodCallInit) {
        return; // already hooked
    }

    gOrigMethodCallInit = current;
    method_setImplementation(method, (IMP)VMLHookMethodCallInit);
    VMLLog(@"[capture] hooked FlutterMethodCall initWithMethodName:arguments:");
}

static void VMLStartCapture(void) {
    if (!VMLBundleIs(@"vn.vietmap.live")) return;

    VMLLog(@"[capture] ===== VML SPEED CAPTURE STARTED (bundle=vn.vietmap.live) =====");

    for (NSInteger i = 1; i <= 8; i += 3) {
        int64_t delay = i;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            VMLInstallCaptureHook();
        });
    }
}

// =====================================================================
// MARK: - PART 2: Bubble rendering (runs inside com.apple.springboard)
// =====================================================================

static UIWindow *gPhoneWindow = nil;
static UIView *gCarPlayBubble = nil;
static NSInteger gCurrentSpeed = 0;
static int gSpeedNotifyToken = 0;
static BOOL gAddingOwnView = NO;
static BOOL gScannerRunning = NO;

static const NSInteger kPhoneBubbleTag = 990099;
static const NSInteger kCarPlayBubbleTag = 990199;
static const NSInteger kLabelTag = 990100;

static BOOL VMLNear(CGFloat a, CGFloat b, CGFloat tolerance) {
    return fabs(a - b) <= tolerance;
}

// Legacy size-based heuristic, kept ONLY as a last-resort fallback.
static BOOL VMLLooksLikeCarPlaySize(CGSize size) {
    BOOL landscape = VMLNear(size.width, 640.0, 45.0) && VMLNear(size.height, 240.0, 45.0);
    BOOL rotated   = VMLNear(size.width, 240.0, 45.0) && VMLNear(size.height, 640.0, 45.0);
    return landscape || rotated;
}

// A CarPlay root window lives on a screen that is NOT UIScreen.mainScreen.
// True for BOTH wired and wireless CarPlay, at any resolution.
static BOOL VMLIsExternalCarPlayScreen(UIScreen *screen) {
    if (!screen) return NO;
    return screen != UIScreen.mainScreen;
}

static BOOL VMLIsCarPlayRootWindow(UIWindow *window) {
    if (!window) return NO;

    NSString *className = NSStringFromClass(window.class);
    if (![className isEqualToString:@"UIRootSceneWindow"]) {
        return NO;
    }

    if (VMLIsExternalCarPlayScreen(window.screen)) {
        return YES;
    }

    // Fallback for early lifecycle timing where window.screen isn't set yet.
    return VMLLooksLikeCarPlaySize(window.bounds.size) || VMLLooksLikeCarPlaySize(window.frame.size);
}

static NSString *VMLSpeedText(void) {
    if (gCurrentSpeed > 0 && gCurrentSpeed <= 200) {
        return [NSString stringWithFormat:@"%ld", (long)gCurrentSpeed];
    }
    return @"--";
}

static UIView *VMLMakeBubble(NSInteger tag, CGFloat size) {
    UIView *bubble = [[UIView alloc] initWithFrame:CGRectMake(0, 0, size, size)];
    bubble.tag = tag;
    bubble.backgroundColor = UIColor.whiteColor;
    bubble.layer.cornerRadius = size / 2.0;
    bubble.layer.borderWidth = 5.0;
    bubble.layer.borderColor = UIColor.systemRedColor.CGColor;
    bubble.clipsToBounds = YES;
    bubble.userInteractionEnabled = NO;

    UILabel *label = [[UILabel alloc] initWithFrame:bubble.bounds];
    label.tag = kLabelTag;
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    label.text = VMLSpeedText();
    label.textColor = UIColor.blackColor;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont systemFontOfSize:size * 0.40 weight:UIFontWeightBold];
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.5;

    [bubble addSubview:label];
    return bubble;
}

static void VMLUpdateBubble(UIView *bubble) {
    if (!bubble) return;

    UILabel *label = (UILabel *)[bubble viewWithTag:kLabelTag];
    if (label) label.text = VMLSpeedText();

    bubble.layer.zPosition = CGFLOAT_MAX;
    if (bubble.superview) {
        [bubble.superview bringSubviewToFront:bubble];
    }
}

static void VMLUpdateAllBubbles(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gPhoneWindow) {
            UIView *phoneBubble = [gPhoneWindow viewWithTag:kPhoneBubbleTag];
            VMLUpdateBubble(phoneBubble);
        }
        if (gCarPlayBubble) {
            VMLUpdateBubble(gCarPlayBubble);
        }
    });
}

static void VMLReadSpeed(void) {
    if (gSpeedNotifyToken == 0) return;

    uint64_t state = 0;
    uint32_t status = notify_get_state(gSpeedNotifyToken, &state);
    if (status != NOTIFY_STATUS_OK) return;

    NSInteger speed = (NSInteger)state;
    if (speed < 0 || speed > 200) return;

    gCurrentSpeed = speed;
    VMLLog(@"[render] speed received=%ld", (long)gCurrentSpeed);
    VMLUpdateAllBubbles();
}

static void VMLStartSpeedReceiver(void) {
    if (gSpeedNotifyToken != 0) return;

    int token = 0;
    uint32_t status = notify_register_dispatch(VML_NOTIFY_NAME, &token, dispatch_get_main_queue(), ^(int incomingToken) {
        gSpeedNotifyToken = incomingToken;
        VMLReadSpeed();
    });

    if (status != NOTIFY_STATUS_OK) {
        VMLLog(@"[render] notify_register_dispatch failed=%u", status);
        return;
    }

    gSpeedNotifyToken = token;
    VMLLog(@"[render] speed receiver active token=%d", token);
    VMLReadSpeed();
}

#pragma mark - Host detection

static BOOL VMLLooksLikeKnownHost(UIView *view) {
    if (!view) return NO;

    NSString *className = NSStringFromClass(view.class);
    if (![className isEqualToString:@"_UIVisualEffectContentView"]) return NO;

    CGSize size = view.bounds.size;
    BOOL sizeMatch = VMLNear(size.width, 595.0, 45.0) && VMLNear(size.height, 240.0, 35.0);
    if (!sizeMatch) return NO;

    UIView *parent = view.superview;
    if (!parent) return NO;

    NSString *parentClass = NSStringFromClass(parent.class);
    if (![parentClass isEqualToString:@"UIVisualEffectView"]) return NO;

    return VMLIsCarPlayRootWindow(view.window);
}

static UIView *VMLFindKnownHostRecursive(UIView *view) {
    if (!view) return nil;
    if (VMLLooksLikeKnownHost(view)) return view;

    for (UIView *child in view.subviews) {
        UIView *found = VMLFindKnownHostRecursive(child);
        if (found) return found;
    }
    return nil;
}

static UIView *VMLFindFallbackHostRecursive(UIView *view) {
    if (!view) return nil;

    NSString *className = NSStringFromClass(view.class);
    if ([className isEqualToString:@"_UIVisualEffectContentView"]) {
        CGSize size = view.bounds.size;
        if (VMLIsCarPlayRootWindow(view.window) && size.width > 400.0 && size.height > 180.0) {
            return view;
        }
    }

    for (UIView *child in view.subviews) {
        UIView *found = VMLFindFallbackHostRecursive(child);
        if (found) return found;
    }
    return nil;
}

// Last-resort: attach directly to the root view controller's view so the
// bubble always has *somewhere* to go, even on an unrecognized layout.
static UIView *VMLFindLastResortHost(UIWindow *root) {
    if (!root) return nil;

    UIView *view = root.rootViewController.view ?: (root.subviews.firstObject ?: root);
    if (!view) return nil;
    if (view.bounds.size.width < 100.0 || view.bounds.size.height < 60.0) return nil;

    return view;
}

#pragma mark - Attach

static void VMLAttachCarPlayBubble(UIView *host, NSString *reason) {
    if (!host) return;
    if (!VMLIsCarPlayRootWindow(host.window)) return;

    UIView *existing = [host viewWithTag:kCarPlayBubbleTag];
    if (existing) {
        gCarPlayBubble = existing;
        VMLUpdateBubble(existing);
        return;
    }

    if (gCarPlayBubble && gCarPlayBubble.superview && gCarPlayBubble.superview != host) {
        [gCarPlayBubble removeFromSuperview];
        gCarPlayBubble = nil;
    }

    gAddingOwnView = YES;

    CGFloat size = 46.0;
    UIView *bubble = VMLMakeBubble(kCarPlayBubbleTag, size);

    CGFloat maxX = MAX(4.0, host.bounds.size.width - size - 4.0);
    CGFloat maxY = MAX(4.0, host.bounds.size.height - size - 4.0);
    CGFloat x = MAX(4.0, MIN(62.0, maxX));
    CGFloat y = MAX(4.0, MIN(122.0, maxY));

    bubble.frame = CGRectMake(x, y, size, size);
    bubble.layer.zPosition = CGFLOAT_MAX;

    [host addSubview:bubble];
    [host bringSubviewToFront:bubble];

    gCarPlayBubble = bubble;
    gAddingOwnView = NO;

    VMLLog(@"[render] *** CARPLAY BUBBLE ADDED *** reason=%@ host=%@ hostFrame=%@", reason, NSStringFromClass(host.class), NSStringFromCGRect(host.frame));
}

static void VMLProcessCarPlayRoot(UIWindow *root, NSString *reason) {
    if (!VMLIsCarPlayRootWindow(root)) return;

    UIView *host = VMLFindKnownHostRecursive(root);
    if (host) {
        VMLAttachCarPlayBubble(host, [reason stringByAppendingString:@"/knownHost"]);
        return;
    }

    UIView *fallback = VMLFindFallbackHostRecursive(root);
    if (fallback) {
        VMLAttachCarPlayBubble(fallback, [reason stringByAppendingString:@"/fallbackHost"]);
        return;
    }

    UIView *lastResort = VMLFindLastResortHost(root);
    if (lastResort) {
        VMLAttachCarPlayBubble(lastResort, [reason stringByAppendingString:@"/lastResortHost"]);
        return;
    }

    VMLLog(@"[render] CarPlay root found but NO host at all. reason=%@ rootFrame=%@ subviews=%lu",
           reason, NSStringFromCGRect(root.frame), (unsigned long)root.subviews.count);
}

static void VMLScanScenes(void) {
    UIApplication *app = UIApplication.sharedApplication;
    BOOL found = NO;

    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;

        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *window in ws.windows) {
            if (!VMLIsCarPlayRootWindow(window)) continue;
            found = YES;
            VMLProcessCarPlayRoot(window, @"scan");
        }
    }

    if (!found) {
        // Uncomment for verbose debugging - very chatty:
        // VMLLog(@"[render] scan: no CarPlay root window found");
    }
}

static void VMLScannerTick(void) {
    if (!VMLBundleIs(@"com.apple.springboard")) {
        gScannerRunning = NO;
        return;
    }

    VMLScanScenes();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        VMLScannerTick();
    });
}

static void VMLStartScanner(void) {
    if (gScannerRunning) return;
    gScannerRunning = YES;
    VMLLog(@"[render] active scanner started");
    dispatch_async(dispatch_get_main_queue(), ^{
        VMLScannerTick();
    });
}

%hook UIView

- (void)didMoveToWindow {
    %orig;

    if (!VMLBundleIs(@"com.apple.springboard")) return;
    if (gAddingOwnView) return;

    UIWindow *window = self.window;
    if (!window) return;
    if (!VMLIsCarPlayRootWindow(window)) return;

    VMLProcessCarPlayRoot(window, @"didMoveToWindow");
}

%end

#pragma mark - Phone bubble

static UIWindowScene *VMLPhoneScene(void) {
    UIApplication *app = UIApplication.sharedApplication;

    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        if (VMLIsExternalCarPlayScreen(ws.screen)) continue; // skip CarPlay screen
        return ws;
    }
    return nil;
}

static void VMLCreatePhoneBubble(void) {
    if (gPhoneWindow) return;

    UIWindowScene *scene = VMLPhoneScene();
    if (!scene) {
        VMLLog(@"[render] phone scene not found yet, will retry");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            VMLCreatePhoneBubble();
        });
        return;
    }

    CGFloat size = 64.0;

    gPhoneWindow = [[UIWindow alloc] initWithWindowScene:scene];
    gPhoneWindow.frame = CGRectMake(18, 110, size, size);
    gPhoneWindow.backgroundColor = UIColor.clearColor;
    gPhoneWindow.windowLevel = UIWindowLevelAlert + 1000;

    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.clearColor;
    gPhoneWindow.rootViewController = vc;

    UIView *bubble = VMLMakeBubble(kPhoneBubbleTag, size);
    [vc.view addSubview:bubble];

    gPhoneWindow.hidden = NO;

    VMLLog(@"[render] phone bubble created");
}

static void VMLStartRender(void) {
    if (!VMLBundleIs(@"com.apple.springboard")) return;

    VMLLog(@"[render] ===== VML RENDER STARTED (bundle=com.apple.springboard) =====");

    VMLStartSpeedReceiver();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        VMLStartScanner();
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        VMLCreatePhoneBubble();
    });
}

// =====================================================================
// MARK: - Entry point
// =====================================================================

%ctor {
    @autoreleasepool {
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"(nil)";
        NSString *process = NSProcessInfo.processInfo.processName ?: @"(nil)";

        VMLLog(@"================================================");
        VMLLog(@"VMLSpeedBubble ctor fired. bundle=%@ process=%@", bundle, process);
        VMLLog(@"================================================");

        VMLStartCapture();
        VMLStartRender();
    }
}
