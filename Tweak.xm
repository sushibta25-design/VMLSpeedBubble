#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>
#import <objc/message.h>
#import <math.h>

#pragma mark - Globals

static UIWindow *gPhoneWindow = nil;
static UIWindow *gCarPlayOverlayWindow = nil;
static UIView *gCarPlayOverlayBubble = nil;
static UIView *gCarPlayHostBubble = nil;
static __weak UIWindow *gCarPlayRoot = nil;
static __weak UIView *gCarPlayHost = nil;
static NSInteger gCurrentSpeed = 0;
static int gSpeedNotifyToken = 0;
static BOOL gAddingOwnView = NO;
static BOOL gScannerRunning = NO;
static BOOL gProcessScheduled = NO;

static const NSInteger kPhoneBubbleTag = 990099;
static const NSInteger kCarPlayOverlayBubbleTag = 990199;
static const NSInteger kCarPlayHostBubbleTag = 990299;
static const NSInteger kLabelTag = 990100;

#pragma mark - Logging

static void VMLLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"[VMLV11] %@", msg);

    NSString *line = [NSString stringWithFormat:@"%@\n", msg];
    FILE *f = fopen("/var/mobile/VMLHostSniffer.txt", "a");
    if (f) {
        fprintf(f, "%s", line.UTF8String);
        fclose(f);
    }
}

#pragma mark - Environment

static BOOL VMLIsSpringBoard(void) {
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"";
    return [bundle isEqualToString:@"com.apple.springboard"];
}

static BOOL VMLContainsCI(NSString *value, NSString *needle) {
    if (!value || !needle) return NO;
    return [value rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL VMLLooksLandscapeDisplay(CGSize size) {
    if (size.width <= 0.0 || size.height <= 0.0) return NO;
    if (size.width < 400.0) return NO;
    if (size.height < 150.0) return NO;
    return (size.width / size.height) >= 1.55;
}

static BOOL VMLSceneRoleLooksCarPlay(UIWindowScene *scene) {
    if (!scene) return NO;
    NSString *role = scene.session.role ?: @"";
    return VMLContainsCI(role, @"carplay");
}

static BOOL VMLIsExternalScreen(UIScreen *screen) {
    if (!screen) return NO;
    UIScreen *main = UIScreen.mainScreen;
    if (screen != main) return YES;

    CGSize mainNative = main.nativeBounds.size;
    CGSize native = screen.nativeBounds.size;
    if (!CGSizeEqualToSize(native, mainNative) && VMLLooksLandscapeDisplay(screen.bounds.size)) {
        return YES;
    }
    return NO;
}

static BOOL VMLIsCarPlayCandidateWindow(UIWindow *window) {
    if (!window || window == gPhoneWindow || window == gCarPlayOverlayWindow) return NO;

    NSString *className = NSStringFromClass(window.class);
    UIWindowScene *scene = window.windowScene;
    UIScreen *screen = window.screen;

    BOOL rootClass = [className isEqualToString:@"UIRootSceneWindow"];
    BOOL carPlayRole = VMLSceneRoleLooksCarPlay(scene);
    BOOL external = VMLIsExternalScreen(screen);
    BOOL landscape = VMLLooksLandscapeDisplay(window.bounds.size) || VMLLooksLandscapeDisplay(window.frame.size);

    if (carPlayRole) return YES;
    if (rootClass && external) return YES;
    if (rootClass && landscape) return YES;

    return NO;
}

#pragma mark - Speed bubble

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
    bubble.layer.borderWidth = MAX(4.0, size * 0.10);
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
    label.minimumScaleFactor = 0.45;
    [bubble addSubview:label];

    return bubble;
}

static void VMLUpdateBubble(UIView *bubble) {
    if (!bubble) return;
    UILabel *label = (UILabel *)[bubble viewWithTag:kLabelTag];
    if (label) label.text = VMLSpeedText();
    bubble.hidden = NO;
    bubble.alpha = 1.0;
    bubble.layer.zPosition = CGFLOAT_MAX;
    if (bubble.superview) [bubble.superview bringSubviewToFront:bubble];
}

static void VMLUpdateAllBubbles(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gPhoneWindow) {
            VMLUpdateBubble([gPhoneWindow viewWithTag:kPhoneBubbleTag]);
        }
        VMLUpdateBubble(gCarPlayOverlayBubble);
        VMLUpdateBubble(gCarPlayHostBubble);
    });
}

#pragma mark - IPC

static void VMLReadSpeed(void) {
    if (gSpeedNotifyToken == 0) return;

    uint64_t state = 0;
    uint32_t status = notify_get_state(gSpeedNotifyToken, &state);
    if (status != NOTIFY_STATUS_OK) return;

    NSInteger speed = (NSInteger)state;
    if (speed < 0 || speed > 200) return;

    gCurrentSpeed = speed;
    VMLLog(@"*** SPEED RECEIVED = %ld ***", (long)gCurrentSpeed);
    VMLUpdateAllBubbles();
}

static void VMLStartSpeedReceiver(void) {
    if (!VMLIsSpringBoard() || gSpeedNotifyToken != 0) return;

    int token = 0;
    uint32_t status = notify_register_dispatch(
        "com.sushibta.vmlspeedbubble.speed",
        &token,
        dispatch_get_main_queue(),
        ^(int incomingToken) {
            gSpeedNotifyToken = incomingToken;
            VMLReadSpeed();
        }
    );

    if (status != NOTIFY_STATUS_OK) {
        VMLLog(@"notify_register_dispatch failed=%u", status);
        return;
    }

    gSpeedNotifyToken = token;
    VMLLog(@"SPEED RECEIVER ACTIVE token=%d", token);
    VMLReadSpeed();
}

#pragma mark - Host discovery

static BOOL VMLHostIsLargeEnough(UIView *view, UIWindow *root) {
    if (!view || !root) return NO;
    CGFloat rw = MAX(root.bounds.size.width, 1.0);
    CGFloat rh = MAX(root.bounds.size.height, 1.0);
    CGFloat vw = view.bounds.size.width;
    CGFloat vh = view.bounds.size.height;
    return vw >= rw * 0.55 && vh >= rh * 0.65;
}

static UIView *VMLFindKnownHostRecursive(UIView *view, UIWindow *root) {
    if (!view) return nil;

    NSString *className = NSStringFromClass(view.class);
    if ([className isEqualToString:@"_UIVisualEffectContentView"] && VMLHostIsLargeEnough(view, root)) {
        NSString *parentClass = view.superview ? NSStringFromClass(view.superview.class) : @"";
        if ([parentClass isEqualToString:@"UIVisualEffectView"] || VMLContainsCI(parentClass, @"VisualEffect")) {
            return view;
        }
    }

    NSArray<UIView *> *children = [view.subviews copy];
    for (UIView *child in children) {
        UIView *found = VMLFindKnownHostRecursive(child, root);
        if (found) return found;
    }
    return nil;
}

static UIView *VMLFindFallbackHostRecursive(UIView *view, UIWindow *root) {
    if (!view) return nil;

    NSString *className = NSStringFromClass(view.class);
    BOOL interesting =
        VMLContainsCI(className, @"VisualEffectContent") ||
        VMLContainsCI(className, @"Presentation") ||
        VMLContainsCI(className, @"Dashboard") ||
        VMLContainsCI(className, @"Host");

    if (interesting && VMLHostIsLargeEnough(view, root) && !view.hidden && view.alpha > 0.01) {
        return view;
    }

    NSArray<UIView *> *children = [view.subviews copy];
    for (UIView *child in children) {
        UIView *found = VMLFindFallbackHostRecursive(child, root);
        if (found) return found;
    }
    return nil;
}

static CGRect VMLBubbleFrameForBounds(CGRect bounds) {
    CGFloat h = MAX(bounds.size.height, 1.0);
    CGFloat w = MAX(bounds.size.width, 1.0);
    CGFloat size = h * 0.19;
    size = MAX(42.0, MIN(size, 82.0));

    CGFloat x = w * 0.104;
    CGFloat y = h * 0.508;

    x = MAX(4.0, MIN(x, w - size - 4.0));
    y = MAX(4.0, MIN(y, h - size - 4.0));
    return CGRectMake(x, y, size, size);
}

#pragma mark - Overlay window path

static void VMLDestroyOldOverlayIfNeeded(UIWindowScene *scene) {
    if (!gCarPlayOverlayWindow) return;
    if (gCarPlayOverlayWindow.windowScene == scene) return;

    gCarPlayOverlayWindow.hidden = YES;
    gCarPlayOverlayWindow.rootViewController = nil;
    gCarPlayOverlayWindow = nil;
    gCarPlayOverlayBubble = nil;
}

static void VMLEnsureOverlayWindow(UIWindow *root) {
    if (!root) return;
    UIWindowScene *scene = root.windowScene;
    if (!scene) {
        VMLLog(@"[overlay] root has no UIWindowScene");
        return;
    }

    VMLDestroyOldOverlayIfNeeded(scene);

    if (!gCarPlayOverlayWindow) {
        gAddingOwnView = YES;

        UIWindow *overlay = [[UIWindow alloc] initWithWindowScene:scene];
        CGRect screenBounds = scene.screen.bounds;
        if (CGRectIsEmpty(screenBounds)) screenBounds = root.bounds;
        overlay.frame = screenBounds;
        overlay.backgroundColor = UIColor.clearColor;
        overlay.windowLevel = UIWindowLevelAlert + 500.0;

        UIViewController *vc = [UIViewController new];
        vc.view.backgroundColor = UIColor.clearColor;
        vc.view.userInteractionEnabled = NO;
        overlay.rootViewController = vc;

        CGRect bubbleFrame = VMLBubbleFrameForBounds(vc.view.bounds.size.width > 0 ? vc.view.bounds : overlay.bounds);
        CGFloat size = bubbleFrame.size.width;
        UIView *bubble = VMLMakeBubble(kCarPlayOverlayBubbleTag, size);
        bubble.frame = bubbleFrame;
        [vc.view addSubview:bubble];

        overlay.hidden = NO;
        gCarPlayOverlayWindow = overlay;
        gCarPlayOverlayBubble = bubble;
        gAddingOwnView = NO;

        VMLLog(@"[overlay] *** CARPLAY OVERLAY WINDOW CREATED *** role=%@ screen=%@ root=%@ overlay=%@ bubble=%@",
               scene.session.role ?: @"nil",
               NSStringFromCGRect(scene.screen.bounds),
               NSStringFromCGRect(root.bounds),
               NSStringFromCGRect(overlay.bounds),
               NSStringFromCGRect(bubble.frame));
    } else {
        gCarPlayOverlayWindow.hidden = NO;
        if (gCarPlayOverlayWindow.rootViewController) {
            UIView *container = gCarPlayOverlayWindow.rootViewController.view;
            CGRect bubbleFrame = VMLBubbleFrameForBounds(container.bounds.size.width > 0 ? container.bounds : gCarPlayOverlayWindow.bounds);
            gCarPlayOverlayBubble.frame = bubbleFrame;
            VMLUpdateBubble(gCarPlayOverlayBubble);
        }
    }
}

#pragma mark - Host insertion path

static void VMLAttachHostBubble(UIView *host, UIWindow *root, NSString *reason) {
    if (!host || !root) return;

    if (gCarPlayHostBubble && gCarPlayHostBubble.superview && gCarPlayHostBubble.superview != host) {
        [gCarPlayHostBubble removeFromSuperview];
        gCarPlayHostBubble = nil;
    }

    UIView *existing = [host viewWithTag:kCarPlayHostBubbleTag];
    if (existing) {
        gCarPlayHost = host;
        gCarPlayHostBubble = existing;
        existing.frame = VMLBubbleFrameForBounds(host.bounds);
        VMLUpdateBubble(existing);
        return;
    }

    gAddingOwnView = YES;
    CGRect frame = VMLBubbleFrameForBounds(host.bounds);
    UIView *bubble = VMLMakeBubble(kCarPlayHostBubbleTag, frame.size.width);
    bubble.frame = frame;
    [host addSubview:bubble];
    [host bringSubviewToFront:bubble];
    gAddingOwnView = NO;

    gCarPlayHost = host;
    gCarPlayHostBubble = bubble;

    VMLLog(@"[host] *** CARPLAY HOST BUBBLE ADDED *** reason=%@ host=%@ hostBounds=%@ root=%@ rootBounds=%@ bubble=%@",
           reason,
           NSStringFromClass(host.class),
           NSStringFromCGRect(host.bounds),
           NSStringFromClass(root.class),
           NSStringFromCGRect(root.bounds),
           NSStringFromCGRect(bubble.frame));
}

#pragma mark - Root processing

static void VMLProcessCarPlayRoot(UIWindow *root, NSString *reason) {
    if (!VMLIsSpringBoard() || !VMLIsCarPlayCandidateWindow(root)) return;

    gCarPlayRoot = root;

    UIWindowScene *scene = root.windowScene;
    VMLLog(@"[root] candidate reason=%@ class=%@ frame=%@ bounds=%@ hidden=%d level=%.1f role=%@ screen=%@ native=%@",
           reason,
           NSStringFromClass(root.class),
           NSStringFromCGRect(root.frame),
           NSStringFromCGRect(root.bounds),
           root.hidden,
           root.windowLevel,
           scene.session.role ?: @"nil",
           NSStringFromCGRect(root.screen.bounds),
           NSStringFromCGRect(root.screen.nativeBounds));

    VMLEnsureOverlayWindow(root);

    UIView *host = VMLFindKnownHostRecursive(root, root);
    if (host) {
        VMLLog(@"[host] KNOWN HOST FOUND class=%@ frame=%@ bounds=%@", NSStringFromClass(host.class), NSStringFromCGRect(host.frame), NSStringFromCGRect(host.bounds));
        VMLAttachHostBubble(host, root, @"knownHost");
        return;
    }

    host = VMLFindFallbackHostRecursive(root, root);
    if (host) {
        VMLLog(@"[host] FALLBACK HOST FOUND class=%@ frame=%@ bounds=%@", NSStringFromClass(host.class), NSStringFromCGRect(host.frame), NSStringFromCGRect(host.bounds));
        VMLAttachHostBubble(host, root, @"fallbackHost");
    } else {
        VMLLog(@"[host] NO HOST YET rootSubviews=%lu", (unsigned long)root.subviews.count);
    }
}

static void VMLScheduleProcess(UIWindow *window, NSString *reason) {
    if (!window || !VMLIsCarPlayCandidateWindow(window)) return;
    if (gProcessScheduled) return;

    gProcessScheduled = YES;
    __weak UIWindow *weakWindow = window;
    NSString *copiedReason = [reason copy];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        UIWindow *w = weakWindow;
        gProcessScheduled = NO;
        if (w) VMLProcessCarPlayRoot(w, copiedReason);
    });
}

#pragma mark - Active scanner

static NSArray<UIWindow *> *VMLApplicationWindowsDynamic(void) {
    UIApplication *app = UIApplication.sharedApplication;
    SEL sel = NSSelectorFromString(@"windows");
    if (![app respondsToSelector:sel]) return @[];

    NSArray *(*sendWindows)(id, SEL) = (NSArray *(*)(id, SEL))objc_msgSend;
    NSArray *windows = sendWindows(app, sel);
    return [windows isKindOfClass:NSArray.class] ? windows : @[];
}

static void VMLScanAllKnownWindows(void) {
    if (!VMLIsSpringBoard()) return;

    NSMutableSet<UIWindow *> *seen = [NSMutableSet set];

    for (UIWindow *window in VMLApplicationWindowsDynamic()) {
        if (![window isKindOfClass:UIWindow.class]) continue;
        [seen addObject:window];
    }

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *window in ws.windows) {
            if (window) [seen addObject:window];
        }
    }

    NSUInteger candidates = 0;
    for (UIWindow *window in seen) {
        if (!VMLIsCarPlayCandidateWindow(window)) continue;
        candidates++;
        VMLProcessCarPlayRoot(window, @"scanner");
    }

    if (candidates == 0) {
        NSArray<UIScreen *> *screens = UIScreen.screens;
        NSMutableArray<NSString *> *desc = [NSMutableArray array];
        for (UIScreen *screen in screens) {
            [desc addObject:[NSString stringWithFormat:@"%@ native=%@ scale=%.2f",
                             NSStringFromCGRect(screen.bounds),
                             NSStringFromCGRect(screen.nativeBounds),
                             screen.scale]];
        }
        VMLLog(@"[scanner] no candidate windows. screens=%lu %@", (unsigned long)screens.count, desc);
    }
}

static void VMLScannerTick(void) {
    if (!VMLIsSpringBoard()) {
        gScannerRunning = NO;
        return;
    }

    VMLScanAllKnownWindows();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        VMLScannerTick();
    });
}

static void VMLStartScanner(void) {
    if (gScannerRunning) return;
    gScannerRunning = YES;
    VMLLog(@"[scanner] V11 ACTIVE SCANNER STARTED");
    dispatch_async(dispatch_get_main_queue(), ^{ VMLScannerTick(); });
}

#pragma mark - Lifecycle catchers

%hook UIView

- (void)didMoveToWindow {
    %orig;

    if (!VMLIsSpringBoard() || gAddingOwnView) return;
    UIWindow *window = self.window;
    if (!window || !VMLIsCarPlayCandidateWindow(window)) return;

    VMLScheduleProcess(window, [NSString stringWithFormat:@"UIView.didMove:%@", NSStringFromClass(self.class)]);
}

%end

%hook UIWindow

- (void)didAddSubview:(UIView *)subview {
    %orig(subview);

    if (!VMLIsSpringBoard() || gAddingOwnView) return;
    if (!VMLIsCarPlayCandidateWindow(self)) return;
    VMLScheduleProcess(self, @"UIWindow.didAddSubview");
}

- (void)setHidden:(BOOL)hidden {
    %orig(hidden);

    if (!VMLIsSpringBoard() || gAddingOwnView) return;
    if (!VMLIsCarPlayCandidateWindow(self)) return;
    VMLScheduleProcess(self, hidden ? @"UIWindow.hidden:YES" : @"UIWindow.hidden:NO");
}

%end

#pragma mark - Phone bubble

static UIWindowScene *VMLPhoneScene(void) {
    UIScreen *main = UIScreen.mainScreen;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        if (ws.screen == main && !VMLSceneRoleLooksCarPlay(ws)) return ws;
    }
    return nil;
}

static void VMLCreatePhoneBubble(void) {
    if (gPhoneWindow) return;

    UIWindowScene *scene = VMLPhoneScene();
    if (!scene) {
        VMLLog(@"PHONE SCENE NOT FOUND");
        return;
    }

    CGFloat size = 64.0;
    gAddingOwnView = YES;
    gPhoneWindow = [[UIWindow alloc] initWithWindowScene:scene];
    gPhoneWindow.frame = CGRectMake(18, 110, size, size);
    gPhoneWindow.backgroundColor = UIColor.clearColor;
    gPhoneWindow.windowLevel = UIWindowLevelAlert + 1000;

    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.clearColor;
    vc.view.userInteractionEnabled = NO;
    gPhoneWindow.rootViewController = vc;

    UIView *bubble = VMLMakeBubble(kPhoneBubbleTag, size);
    [vc.view addSubview:bubble];
    gPhoneWindow.hidden = NO;
    gAddingOwnView = NO;

    VMLLog(@"PHONE BUBBLE CREATED text=%@", VMLSpeedText());
}

#pragma mark - Start

%ctor {
    @autoreleasepool {
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"";
        NSString *process = NSProcessInfo.processInfo.processName ?: @"";

        VMLLog(@"========================================");
        VMLLog(@"VML CARPLAY MULTI-DISPLAY RENDER V11");
        VMLLog(@"bundle=%@ process=%@", bundle, process);
        VMLLog(@"========================================");

        if (!VMLIsSpringBoard()) return;

        VMLStartSpeedReceiver();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            VMLStartScanner();
        });

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            VMLCreatePhoneBubble();
        });

        VMLLog(@"V11 ACTIVE");
    }
}
