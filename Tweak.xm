#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>
#import <objc/message.h>

#pragma mark - Globals

static NSInteger gCurrentSpeed = 0;
static int gSpeedNotifyToken = 0;

static UIWindow *gPhoneWindow = nil;

static __weak UIViewController *gLastNativeController = nil;
static __weak UIView *gNativeHost = nil;
static UIView *gNativeBubble = nil;

static BOOL gWatchdogRunning = NO;
static BOOL gCarPlayShowsVML = NO;

static const NSInteger kPhoneBubbleTag = 990099;
static const NSInteger kCarPlayBubbleTag = 990199;
static const NSInteger kLabelTag = 990100;

#pragma mark - Logging

static void VMLLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);

    NSString *msg =
        [[NSString alloc] initWithFormat:format arguments:args];

    va_end(args);

    NSLog(@"[VMLV12.5] %@", msg);

    NSString *line =
        [NSString stringWithFormat:@"%@\n", msg];

    FILE *f =
        fopen("/var/mobile/VMLHostSniffer.txt", "a");

    if (f) {
        fprintf(f, "%s", line.UTF8String);
        fclose(f);
    }
}

#pragma mark - Process

static NSString *VMLBundle(void) {
    return NSBundle.mainBundle.bundleIdentifier ?: @"";
}

static NSString *VMLProcess(void) {
    return NSProcessInfo.processInfo.processName ?: @"";
}

static BOOL VMLIsSpringBoard(void) {
    return [VMLBundle() isEqualToString:@"com.apple.springboard"];
}

static BOOL VMLIsCarPlayApp(void) {
    return [VMLBundle() isEqualToString:@"com.apple.CarPlayApp"];
}

#pragma mark - Bubble

static NSString *VMLSpeedText(void) {
    if (gCurrentSpeed > 0 && gCurrentSpeed <= 200) {
        return [NSString stringWithFormat:@"%ld", (long)gCurrentSpeed];
    }

    return @"--";
}

static UIView *VMLMakeBubble(NSInteger tag, CGFloat size) {
    UIView *bubble =
        [[UIView alloc] initWithFrame:CGRectMake(0, 0, size, size)];

    bubble.tag = tag;
    bubble.backgroundColor = UIColor.whiteColor;
    bubble.layer.cornerRadius = size / 2.0;
    bubble.layer.borderWidth = 5.0;
    bubble.layer.borderColor = UIColor.systemRedColor.CGColor;
    bubble.clipsToBounds = YES;
    bubble.userInteractionEnabled = NO;

    UILabel *label =
        [[UILabel alloc] initWithFrame:bubble.bounds];

    label.tag = kLabelTag;
    label.autoresizingMask =
        UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;

    label.text = VMLSpeedText();
    label.textColor = UIColor.blackColor;
    label.textAlignment = NSTextAlignmentCenter;
    label.font =
        [UIFont systemFontOfSize:size * 0.40
                         weight:UIFontWeightBold];

    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.5;

    [bubble addSubview:label];

    return bubble;
}

static void VMLUpdateBubble(UIView *bubble) {
    if (!bubble)
        return;

    UILabel *label =
        (UILabel *)[bubble viewWithTag:kLabelTag];

    if (label) {
        label.text = VMLSpeedText();
    }

    bubble.hidden = gCarPlayShowsVML;
    bubble.alpha = 1.0;
    bubble.layer.hidden = gCarPlayShowsVML;
    bubble.layer.opacity = 1.0;
    bubble.layer.zPosition = CGFLOAT_MAX;

    if (bubble.superview && !gCarPlayShowsVML) {
        [bubble.superview bringSubviewToFront:bubble];
    }
}

static void VMLUpdateAllBubbles(void) {
    if (gPhoneWindow) {
        UIView *phoneBubble =
            [gPhoneWindow viewWithTag:kPhoneBubbleTag];

        if (phoneBubble) {
            UILabel *label =
                (UILabel *)[phoneBubble viewWithTag:kLabelTag];

            if (label) {
                label.text = VMLSpeedText();
            }
        }
    }

    if (gNativeBubble) {
        VMLUpdateBubble(gNativeBubble);
    }
}

#pragma mark - Speed IPC

static void VMLReadSpeed(void) {
    if (gSpeedNotifyToken == 0)
        return;

    uint64_t state = 0;

    uint32_t status =
        notify_get_state(gSpeedNotifyToken, &state);

    if (status != NOTIFY_STATUS_OK)
        return;

    NSInteger speed =
        (NSInteger)state;

    // RuntimeSniffer V12.3+ never publishes 0, so state should remain the
    // most recent valid speed limit.
    if (speed <= 0 || speed > 200) {
        return;
    }

    if (gCurrentSpeed != speed) {
        gCurrentSpeed = speed;

        VMLLog(
            @"*** SPEED SYNC = %ld ***",
            (long)gCurrentSpeed
        );
    }

    VMLUpdateAllBubbles();
}

static void VMLStartSpeedReceiver(void) {
    if (gSpeedNotifyToken != 0)
        return;

    int token = 0;

    uint32_t status =
        notify_register_dispatch(
            "com.sushibta.vmlspeedbubble.speed",
            &token,
            dispatch_get_main_queue(),
            ^(int incomingToken) {
                gSpeedNotifyToken =
                    incomingToken;

                VMLReadSpeed();
            }
        );

    if (status != NOTIFY_STATUS_OK) {
        VMLLog(
            @"notify_register_dispatch failed=%u",
            status
        );
        return;
    }

    gSpeedNotifyToken = token;

    VMLLog(
        @"SPEED RECEIVER ACTIVE token=%d bundle=%@",
        token,
        VMLBundle()
    );

    VMLReadSpeed();
}

#pragma mark - Phone bubble

static UIWindowScene *VMLPhoneScene(void) {
    UIApplication *app =
        UIApplication.sharedApplication;

    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class])
            continue;

        UIWindowScene *ws =
            (UIWindowScene *)scene;

        CGSize size =
            ws.screen.bounds.size;

        if (size.width <= 430.0 &&
            size.height >= 600.0) {

            return ws;
        }
    }

    return nil;
}

static void VMLCreatePhoneBubble(void) {
    if (!VMLIsSpringBoard() || gPhoneWindow)
        return;

    UIWindowScene *scene =
        VMLPhoneScene();

    if (!scene)
        return;

    CGFloat size = 64.0;

    gPhoneWindow =
        [[UIWindow alloc] initWithWindowScene:scene];

    gPhoneWindow.frame =
        CGRectMake(18, 110, size, size);

    gPhoneWindow.backgroundColor =
        UIColor.clearColor;

    gPhoneWindow.windowLevel =
        UIWindowLevelAlert + 1000.0;

    gPhoneWindow.userInteractionEnabled =
        NO;

    UIViewController *vc =
        [UIViewController new];

    vc.view.backgroundColor =
        UIColor.clearColor;

    vc.view.userInteractionEnabled =
        NO;

    gPhoneWindow.rootViewController =
        vc;

    UIView *bubble =
        VMLMakeBubble(
            kPhoneBubbleTag,
            size
        );

    bubble.hidden = NO;
    bubble.layer.hidden = NO;

    [vc.view addSubview:bubble];

    gPhoneWindow.hidden = NO;

    VMLLog(
        @"*** PHONE BUBBLE CREATED text=%@ ***",
        VMLSpeedText()
    );
}

#pragma mark - Native CarPlay host discovery

static BOOL VMLClassLooksNativeCarPlayController(NSString *name) {
    if (!name.length)
        return NO;

    NSArray<NSString *> *tokens =
        @[
            @"CarPlay",
            @"Dashboard",
            @"AppDock",
            @"DockViewController",
            @"DBDashboardRootViewController",
            @"CARAppDockViewController"
        ];

    for (NSString *token in tokens) {
        if ([name containsString:token]) {
            return YES;
        }
    }

    return NO;
}

static UIView *VMLCallViewSelector(
    id obj,
    NSString *selectorName
) {
    if (!obj || !selectorName.length)
        return nil;

    SEL sel =
        NSSelectorFromString(selectorName);

    if (![obj respondsToSelector:sel])
        return nil;

    id result =
        ((id (*)(id, SEL))objc_msgSend)(
            obj,
            sel
        );

    if ([result isKindOfClass:UIView.class]) {
        return (UIView *)result;
    }

    return nil;
}

static UIView *VMLPreferredNativeHost(
    UIViewController *vc
) {
    if (!vc)
        return nil;

    NSArray<NSString *> *selectors =
        @[
            @"dockModeHostViewCreatingIfNeeded",
            @"splitHostView",
            @"host"
        ];

    for (NSString *selectorName in selectors) {
        UIView *view =
            VMLCallViewSelector(
                vc,
                selectorName
            );

        if (view && view.window) {
            VMLLog(
                @"[native] selector=%@ host=%@ frame=%@",
                selectorName,
                NSStringFromClass(view.class),
                NSStringFromCGRect(view.frame)
            );

            return view;
        }
    }

    if (vc.view && vc.view.window) {
        return vc.view;
    }

    return nil;
}

#pragma mark - CarPlay foreground detection

static NSString *VMLStringFromSelector(
    id obj,
    NSString *selectorName
) {
    if (!obj || !selectorName.length)
        return nil;

    SEL sel =
        NSSelectorFromString(selectorName);

    if (![obj respondsToSelector:sel])
        return nil;

    id result =
        ((id (*)(id, SEL))objc_msgSend)(
            obj,
            sel
        );

    if ([result isKindOfClass:NSString.class]) {
        return (NSString *)result;
    }

    return nil;
}

static BOOL VMLObjectReferencesVietMap(id obj) {
    if (!obj)
        return NO;

    NSArray<NSString *> *selectors =
        @[
            @"bundleIdentifier",
            @"applicationBundleIdentifier",
            @"clientBundleIdentifier",
            @"sceneIdentifier"
        ];

    for (NSString *selectorName in selectors) {
        NSString *value =
            VMLStringFromSelector(
                obj,
                selectorName
            );

        if ([value containsString:@"vn.vietmap.live"]) {
            return YES;
        }
    }

    NSString *description =
        [obj description];

    if ([description containsString:@"vn.vietmap.live"]) {
        return YES;
    }

    return NO;
}

static BOOL VMLControllerTreeReferencesVietMap(
    UIViewController *vc,
    NSInteger depth
) {
    if (!vc || depth > 8)
        return NO;

    if (VMLObjectReferencesVietMap(vc))
        return YES;

    if (VMLObjectReferencesVietMap(vc.view))
        return YES;

    if (vc.presentedViewController &&
        VMLControllerTreeReferencesVietMap(
            vc.presentedViewController,
            depth + 1
        )) {

        return YES;
    }

    for (UIViewController *child
         in vc.childViewControllers) {

        if (VMLControllerTreeReferencesVietMap(
                child,
                depth + 1
            )) {

            return YES;
        }
    }

    return NO;
}

static void VMLRefreshCarPlayForegroundState(void) {
    if (!VMLIsCarPlayApp())
        return;

    BOOL foundVietMap = NO;

    UIApplication *app =
        UIApplication.sharedApplication;

    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class])
            continue;

        UIWindowScene *ws =
            (UIWindowScene *)scene;

        for (UIWindow *window in ws.windows) {
            UIViewController *root =
                window.rootViewController;

            if (VMLControllerTreeReferencesVietMap(
                    root,
                    0
                )) {

                foundVietMap = YES;
                break;
            }
        }

        if (foundVietMap)
            break;
    }

    if (gCarPlayShowsVML != foundVietMap) {
        gCarPlayShowsVML =
            foundVietMap;

        VMLLog(
            @"*** CARPLAY SHOWS VIETMAP = %d ***",
            gCarPlayShowsVML
        );
    }

    if (gNativeBubble) {
        VMLUpdateBubble(gNativeBubble);
    }
}

#pragma mark - Native bubble

static void VMLAttachNativeBubble(
    UIView *host,
    NSString *reason
) {
    if (!VMLIsCarPlayApp() ||
        !host ||
        !host.window) {

        return;
    }

    if (gNativeBubble &&
        gNativeBubble.superview == host) {

        VMLUpdateBubble(gNativeBubble);
        return;
    }

    if (gNativeBubble &&
        gNativeBubble.superview) {

        [gNativeBubble removeFromSuperview];
        gNativeBubble = nil;
    }

    // Also remove stale VML bubble tags from this exact native host.
    NSArray<UIView *> *children =
        [host.subviews copy];

    for (UIView *child in children) {
        if (child.tag == kCarPlayBubbleTag) {
            [child removeFromSuperview];
        }
    }

    CGFloat W =
        MAX(host.bounds.size.width, 1.0);

    CGFloat H =
        MAX(host.bounds.size.height, 1.0);

    CGFloat size =
        MAX(
            42.0,
            MIN(
                56.0,
                H * 0.20
            )
        );

    UIView *bubble =
        VMLMakeBubble(
            kCarPlayBubbleTag,
            size
        );

    CGFloat x =
        MAX(
            8.0,
            MIN(
                W - size - 8.0,
                W * 0.08
            )
        );

    CGFloat y =
        MAX(
            8.0,
            MIN(
                H - size - 8.0,
                H * 0.50
            )
        );

    bubble.frame =
        CGRectMake(
            x,
            y,
            size,
            size
        );

    bubble.userInteractionEnabled =
        NO;

    bubble.layer.zPosition =
        CGFLOAT_MAX;

    [host addSubview:bubble];

    if (!gCarPlayShowsVML) {
        [host bringSubviewToFront:bubble];
    }

    gNativeHost = host;
    gNativeBubble = bubble;

    VMLUpdateBubble(gNativeBubble);

    VMLLog(
        @"*** NATIVE CARPLAY BUBBLE ADDED V12.5 reason=%@ host=%@ frame=%@ hiddenForVML=%d speed=%ld ***",
        reason,
        NSStringFromClass(host.class),
        NSStringFromCGRect(host.frame),
        gCarPlayShowsVML,
        (long)gCurrentSpeed
    );
}

static void VMLHandleNativeController(
    UIViewController *vc,
    NSString *reason
) {
    if (!VMLIsCarPlayApp() ||
        !vc) {

        return;
    }

    NSString *name =
        NSStringFromClass(vc.class);

    if (!VMLClassLooksNativeCarPlayController(
            name
        )) {

        return;
    }

    gLastNativeController =
        vc;

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            250 * NSEC_PER_MSEC
        ),
        dispatch_get_main_queue(),
        ^{
            VMLRefreshCarPlayForegroundState();

            UIView *host =
                VMLPreferredNativeHost(vc);

            if (host) {
                VMLAttachNativeBubble(
                    host,
                    [NSString stringWithFormat:
                        @"%@:%@",
                        reason,
                        name]
                );
            }
        }
    );
}

#pragma mark - Persistent host watchdog

static void VMLWatchdogTick(void) {
    if (!VMLIsCarPlayApp()) {
        gWatchdogRunning = NO;
        return;
    }

    VMLReadSpeed();
    VMLRefreshCarPlayForegroundState();

    UIViewController *vc =
        gLastNativeController;

    UIView *wantedHost =
        VMLPreferredNativeHost(vc);

    BOOL bubbleAlive =
        gNativeBubble &&
        gNativeBubble.superview &&
        gNativeBubble.window;

    BOOL wrongHost =
        wantedHost &&
        gNativeBubble &&
        gNativeBubble.superview != wantedHost;

    if (wantedHost &&
        (!bubbleAlive || wrongHost)) {

        VMLLog(
            @"[watchdog] reattach bubble alive=%d wrongHost=%d",
            bubbleAlive,
            wrongHost
        );

        VMLAttachNativeBubble(
            wantedHost,
            @"watchdog"
        );
    } else if (bubbleAlive) {
        VMLUpdateBubble(
            gNativeBubble
        );
    }

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            500 * NSEC_PER_MSEC
        ),
        dispatch_get_main_queue(),
        ^{
            VMLWatchdogTick();
        }
    );
}

static void VMLStartWatchdog(void) {
    if (!VMLIsCarPlayApp() ||
        gWatchdogRunning) {

        return;
    }

    gWatchdogRunning = YES;

    VMLLog(
        @"[watchdog] V12.5 native host watchdog started"
    );

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            VMLWatchdogTick();
        }
    );
}

#pragma mark - Hooks

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    VMLHandleNativeController(
        self,
        @"viewDidAppear"
    );
}

- (void)viewDidLayoutSubviews {
    %orig;

    VMLHandleNativeController(
        self,
        @"viewDidLayoutSubviews"
    );
}

%end

#pragma mark - Startup

%ctor {
    @autoreleasepool {
        VMLLog(@"========================================");
        VMLLog(@"VML SPEED BUBBLE V12.5 SAFE NATIVE HOST");
        VMLLog(
            @"bundle=%@ process=%@",
            VMLBundle(),
            VMLProcess()
        );
        VMLLog(@"========================================");

        if (VMLIsSpringBoard()) {
            VMLStartSpeedReceiver();

            dispatch_after(
                dispatch_time(
                    DISPATCH_TIME_NOW,
                    2 * NSEC_PER_SEC
                ),
                dispatch_get_main_queue(),
                ^{
                    VMLCreatePhoneBubble();
                }
            );

            VMLLog(
                @"V12.5 SPRINGBOARD ACTIVE"
            );

            return;
        }

        if (VMLIsCarPlayApp()) {
            VMLLog(
                @"*** CARPLAY.APP INJECTION CONFIRMED V12.5 ***"
            );

            VMLStartSpeedReceiver();
            VMLStartWatchdog();

            VMLLog(
                @"V12.5 CARPLAY ACTIVE"
            );

            return;
        }
    }
}
