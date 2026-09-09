#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>
#import <math.h>

#pragma mark - Globals

static UIWindow *gPhoneWindow = nil;

static __weak UIWindow *gCarPlayRoot = nil;
static __weak UIView *gCarPlayHost = nil;

static UIView *gCarPlayBubble = nil;

static NSInteger gCurrentSpeed = 0;
static int gSpeedNotifyToken = 0;

static BOOL gAddingOwnView = NO;
static BOOL gScannerRunning = NO;

static const NSInteger kPhoneBubbleTag = 990099;
static const NSInteger kCarPlayBubbleTag = 990199;
static const NSInteger kLabelTag = 990100;

#pragma mark - Logging

static void VMLLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);

    NSString *msg =
        [[NSString alloc]
            initWithFormat:format
                 arguments:args];

    va_end(args);

    NSLog(@"[VMLV12] %@", msg);

    NSString *line =
        [NSString stringWithFormat:@"%@\n", msg];

    FILE *f =
        fopen(
            "/var/mobile/VMLHostSniffer.txt",
            "a"
        );

    if (f) {
        fprintf(
            f,
            "%s",
            line.UTF8String
        );

        fclose(f);
    }
}

#pragma mark - Environment

static BOOL VMLIsSpringBoard(void) {
    NSString *bundle =
        NSBundle.mainBundle.bundleIdentifier ?: @"";

    return
        [bundle isEqualToString:
            @"com.apple.springboard"];
}

static BOOL VMLNear(
    CGFloat a,
    CGFloat b,
    CGFloat tolerance
) {
    return fabs(a - b) <= tolerance;
}

// Legacy heuristic kept ONLY as a last-resort fallback. This hardcoded size
// (~640x240pt) matches some head units over wireless CarPlay but is NOT
// reliable for wired CarPlay, where reported window/point size can differ
// a lot depending on the head unit and cable/adapter. Do not rely on this
// as the primary detector anymore.
static BOOL VMLLooksLikeCarPlaySize(
    CGSize size
) {
    BOOL landscape =
        VMLNear(size.width, 640.0, 45.0) &&
        VMLNear(size.height, 240.0, 45.0);

    BOOL rotated =
        VMLNear(size.width, 240.0, 45.0) &&
        VMLNear(size.height, 640.0, 45.0);

    return landscape || rotated;
}

// A CarPlay root window always lives on the CarPlay UIScreen, which is a
// screen distinct from the phone's own UIScreen.mainScreen. This is true
// for BOTH wired and wireless CarPlay and does not depend on resolution,
// so it is a far more reliable signal than guessing pixel dimensions.
static BOOL VMLIsExternalCarPlayScreen(
    UIScreen *screen
) {
    if (!screen)
        return NO;

    if (screen == UIScreen.mainScreen)
        return NO;

    return YES;
}

static BOOL VMLIsCarPlayRootWindow(
    UIWindow *window
) {
    if (!window)
        return NO;

    NSString *className =
        NSStringFromClass(window.class);

    if (![className
            isEqualToString:
                @"UIRootSceneWindow"]) {

        return NO;
    }

    // Primary check: window is hosted on a non-main (i.e. CarPlay) screen.
    // Works identically for wired and wireless CarPlay, on any head unit
    // resolution/orientation.
    if (VMLIsExternalCarPlayScreen(window.screen)) {
        return YES;
    }

    // Fallback for edge cases where `window.screen` isn't populated yet
    // (e.g. very early lifecycle callbacks): fall back to the old size
    // heuristic so we don't regress previously-working wireless behavior.
    return
        VMLLooksLikeCarPlaySize(
            window.bounds.size
        ) ||
        VMLLooksLikeCarPlaySize(
            window.frame.size
        );
}

#pragma mark - Speed

static NSString *VMLSpeedText(void) {
    if (gCurrentSpeed > 0 &&
        gCurrentSpeed <= 200) {

        return
            [NSString stringWithFormat:
                @"%ld",
                (long)gCurrentSpeed];
    }

    return @"--";
}

#pragma mark - Bubble creator

static UIView *VMLMakeBubble(
    NSInteger tag,
    CGFloat size
) {
    UIView *bubble =
        [[UIView alloc]
            initWithFrame:
                CGRectMake(
                    0,
                    0,
                    size,
                    size
                )];

    bubble.tag =
        tag;

    bubble.backgroundColor =
        UIColor.whiteColor;

    bubble.layer.cornerRadius =
        size / 2.0;

    bubble.layer.borderWidth =
        5.0;

    bubble.layer.borderColor =
        UIColor.systemRedColor.CGColor;

    bubble.clipsToBounds =
        YES;

    bubble.userInteractionEnabled =
        NO;

    UILabel *label =
        [[UILabel alloc]
            initWithFrame:
                bubble.bounds];

    label.tag =
        kLabelTag;

    label.autoresizingMask =
        UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;

    label.text =
        VMLSpeedText();

    label.textColor =
        UIColor.blackColor;

    label.textAlignment =
        NSTextAlignmentCenter;

    label.font =
        [UIFont systemFontOfSize:
            size * 0.40
                         weight:
            UIFontWeightBold];

    label.adjustsFontSizeToFitWidth =
        YES;

    label.minimumScaleFactor =
        0.5;

    [bubble addSubview:
        label];

    return bubble;
}

static void VMLUpdateBubble(
    UIView *bubble
) {
    if (!bubble)
        return;

    UILabel *label =
        (UILabel *)
        [bubble
            viewWithTag:
                kLabelTag];

    if (label) {
        label.text =
            VMLSpeedText();
    }

    bubble.layer.zPosition =
        CGFLOAT_MAX;

    if (bubble.superview) {
        [bubble.superview
            bringSubviewToFront:
                bubble];
    }
}

static void VMLUpdateAllBubbles(void) {
    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            if (gPhoneWindow) {
                UIView *phoneBubble =
                    [gPhoneWindow
                        viewWithTag:
                            kPhoneBubbleTag];

                if (phoneBubble) {
                    VMLUpdateBubble(
                        phoneBubble
                    );
                }
            }

            if (gCarPlayBubble) {
                VMLUpdateBubble(
                    gCarPlayBubble
                );
            }

            VMLLog(
                @"BUBBLES UPDATED speed=%ld text=%@",
                (long)gCurrentSpeed,
                VMLSpeedText()
            );
        }
    );
}

#pragma mark - IPC

static void VMLReadSpeed(void) {
    if (gSpeedNotifyToken == 0)
        return;

    uint64_t state = 0;

    uint32_t status =
        notify_get_state(
            gSpeedNotifyToken,
            &state
        );

    if (status != NOTIFY_STATUS_OK) {
        VMLLog(
            @"notify_get_state failed=%u",
            status
        );

        return;
    }

    NSInteger speed =
        (NSInteger)state;

    if (speed < 0 ||
        speed > 200) {

        return;
    }

    gCurrentSpeed =
        speed;

    VMLLog(
        @"*** SPEED RECEIVED = %ld ***",
        (long)gCurrentSpeed
    );

    VMLUpdateAllBubbles();
}

static void VMLStartSpeedReceiver(void) {
    if (!VMLIsSpringBoard())
        return;

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

    gSpeedNotifyToken =
        token;

    VMLLog(
        @"SPEED RECEIVER ACTIVE token=%d",
        token
    );

    VMLReadSpeed();
}

#pragma mark - Host detection

static BOOL VMLLooksLikeKnownHost(
    UIView *view
) {
    if (!view)
        return NO;

    NSString *className =
        NSStringFromClass(
            view.class
        );

    if (![className
            isEqualToString:
                @"_UIVisualEffectContentView"]) {

        return NO;
    }

    CGSize size =
        view.bounds.size;

    BOOL sizeMatch =
        VMLNear(
            size.width,
            595.0,
            45.0
        ) &&
        VMLNear(
            size.height,
            240.0,
            35.0
        );

    if (!sizeMatch)
        return NO;

    UIView *parent =
        view.superview;

    if (!parent)
        return NO;

    NSString *parentClass =
        NSStringFromClass(
            parent.class
        );

    if (![parentClass
            isEqualToString:
                @"UIVisualEffectView"]) {

        return NO;
    }

    UIWindow *window =
        view.window;

    if (!VMLIsCarPlayRootWindow(window))
        return NO;

    return YES;
}

static UIView *VMLFindKnownHostRecursive(
    UIView *view
) {
    if (!view)
        return nil;

    if (VMLLooksLikeKnownHost(view)) {
        return view;
    }

    for (UIView *child
         in view.subviews) {

        UIView *found =
            VMLFindKnownHostRecursive(
                child
            );

        if (found)
            return found;
    }

    return nil;
}

static UIView *VMLFindFallbackHostRecursive(
    UIView *view
) {
    if (!view)
        return nil;

    NSString *className =
        NSStringFromClass(
            view.class
        );

    if ([className
            isEqualToString:
                @"_UIVisualEffectContentView"]) {

        UIWindow *window =
            view.window;

        CGSize size =
            view.bounds.size;

        if (VMLIsCarPlayRootWindow(window) &&
            size.width > 400.0 &&
            size.height > 180.0) {

            return view;
        }
    }

    for (UIView *child
         in view.subviews) {

        UIView *found =
            VMLFindFallbackHostRecursive(
                child
            );

        if (found)
            return found;
    }

    return nil;
}

// Last-resort host: if neither the known VisualEffect host nor the
// size-based fallback matched (e.g. a wired head unit with a very
// different internal view hierarchy), just use the CarPlay root
// window's own root view controller view as the host so the bubble
// still has somewhere to attach.
static UIView *VMLFindLastResortHost(
    UIWindow *root
) {
    if (!root)
        return nil;

    UIView *view =
        root.rootViewController.view ?:
        (root.subviews.firstObject ?: root);

    if (!view)
        return nil;

    if (view.bounds.size.width < 100.0 ||
        view.bounds.size.height < 60.0) {

        return nil;
    }

    return view;
}

#pragma mark - Attach CarPlay bubble

static void VMLAttachCarPlayBubble(
    UIView *host,
    NSString *reason
) {
    if (!host)
        return;

    UIWindow *window =
        host.window;

    if (!VMLIsCarPlayRootWindow(window))
        return;

    UIView *existing =
        [host
            viewWithTag:
                kCarPlayBubbleTag];

    if (existing) {
        gCarPlayHost =
            host;

        gCarPlayBubble =
            existing;

        VMLUpdateBubble(
            existing
        );

        return;
    }

    if (gCarPlayBubble &&
        gCarPlayBubble.superview &&
        gCarPlayBubble.superview != host) {

        [gCarPlayBubble
            removeFromSuperview];

        gCarPlayBubble =
            nil;
    }

    gAddingOwnView =
        YES;

    CGFloat size =
        46.0;

    UIView *bubble =
        VMLMakeBubble(
            kCarPlayBubbleTag,
            size
        );

    CGFloat x =
        62.0;

    CGFloat y =
        122.0;

    CGFloat maxX =
        host.bounds.size.width -
        size -
        4.0;

    CGFloat maxY =
        host.bounds.size.height -
        size -
        4.0;

    if (maxX < 4.0)
        maxX = 4.0;

    if (maxY < 4.0)
        maxY = 4.0;

    x =
        MAX(
            4.0,
            MIN(
                x,
                maxX
            )
        );

    y =
        MAX(
            4.0,
            MIN(
                y,
                maxY
            )
        );

    bubble.frame =
        CGRectMake(
            x,
            y,
            size,
            size
        );

    bubble.hidden =
        NO;

    bubble.alpha =
        1.0;

    bubble.layer.hidden =
        NO;

    bubble.layer.opacity =
        1.0;

    bubble.layer.zPosition =
        CGFLOAT_MAX;

    [host addSubview:
        bubble];

    [host bringSubviewToFront:
        bubble];

    gCarPlayHost =
        host;

    gCarPlayBubble =
        bubble;

    gAddingOwnView =
        NO;

    VMLLog(
        @"*** CARPLAY BUBBLE ADDED reason=%@ host=%@ hostFrame=%@ root=%@ rootHidden=%d speed=%ld text=%@ ***",
        reason,
        NSStringFromClass(
            host.class
        ),
        NSStringFromCGRect(
            host.frame
        ),
        NSStringFromClass(
            window.class
        ),
        window.hidden,
        (long)gCurrentSpeed,
        VMLSpeedText()
    );
}

#pragma mark - Scan one root

static void VMLProcessCarPlayRoot(
    UIWindow *root,
    NSString *reason
) {
    if (!VMLIsCarPlayRootWindow(root))
        return;

    gCarPlayRoot =
        root;

    UIView *host =
        VMLFindKnownHostRecursive(
            root
        );

    if (host) {
        VMLLog(
            @"*** KNOWN HOST FOUND reason=%@ class=%@ frame=%@ bounds=%@ rootHidden=%d ***",
            reason,
            NSStringFromClass(
                host.class
            ),
            NSStringFromCGRect(
                host.frame
            ),
            NSStringFromCGRect(
                host.bounds
            ),
            root.hidden
        );

        VMLAttachCarPlayBubble(
            host,
            @"knownHost"
        );

        return;
    }

    UIView *fallback =
        VMLFindFallbackHostRecursive(
            root
        );

    if (fallback) {
        VMLLog(
            @"*** FALLBACK HOST FOUND reason=%@ class=%@ frame=%@ bounds=%@ rootHidden=%d ***",
            reason,
            NSStringFromClass(
                fallback.class
            ),
            NSStringFromCGRect(
                fallback.frame
            ),
            NSStringFromCGRect(
                fallback.bounds
            ),
            root.hidden
        );

        VMLAttachCarPlayBubble(
            fallback,
            @"fallbackHost"
        );

        return;
    }

    UIView *lastResort =
        VMLFindLastResortHost(
            root
        );

    if (lastResort) {
        VMLLog(
            @"*** LAST-RESORT HOST USED reason=%@ class=%@ frame=%@ rootHidden=%d ***",
            reason,
            NSStringFromClass(
                lastResort.class
            ),
            NSStringFromCGRect(
                lastResort.frame
            ),
            root.hidden
        );

        VMLAttachCarPlayBubble(
            lastResort,
            @"lastResortHost"
        );

        return;
    }

    VMLLog(
        @"CARPLAY ROOT FOUND BUT HOST NOT FOUND reason=%@ rootFrame=%@ rootBounds=%@ hidden=%d subviews=%lu",
        reason,
        NSStringFromCGRect(
            root.frame
        ),
        NSStringFromCGRect(
            root.bounds
        ),
        root.hidden,
        (unsigned long)
            root.subviews.count
    );
}

#pragma mark - Active scanner

static void VMLScanScenes(void) {
    if (!VMLIsSpringBoard())
        return;

    UIApplication *app =
        UIApplication.sharedApplication;

    NSSet<UIScene *> *scenes =
        app.connectedScenes;

    BOOL found =
        NO;

    for (UIScene *scene
         in scenes) {

        if (![scene
                isKindOfClass:
                    UIWindowScene.class]) {

            continue;
        }

        UIWindowScene *ws =
            (UIWindowScene *)scene;

        NSArray<UIWindow *> *windows =
            ws.windows;

        for (UIWindow *window
             in windows) {

            if (!VMLIsCarPlayRootWindow(
                    window)) {

                continue;
            }

            found =
                YES;

            VMLProcessCarPlayRoot(
                window,
                @"connectedScenes"
            );
        }
    }

    if (!found) {
        VMLLog(
            @"SCANNER no CarPlay root in connectedScenes"
        );
    }
}

static void VMLScannerTick(void) {
    if (!VMLIsSpringBoard()) {
        gScannerRunning =
            NO;

        return;
    }

    VMLScanScenes();

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            1 * NSEC_PER_SEC
        ),
        dispatch_get_main_queue(),
        ^{
            VMLScannerTick();
        }
    );
}

static void VMLStartScanner(void) {
    if (gScannerRunning)
        return;

    gScannerRunning =
        YES;

    VMLLog(
        @"CARPLAY ACTIVE SCANNER STARTED"
    );

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            VMLScannerTick();
        }
    );
}

#pragma mark - Lifecycle fallback

%hook UIView

- (void)didMoveToWindow {
    %orig;

    if (!VMLIsSpringBoard())
        return;

    if (gAddingOwnView)
        return;

    UIWindow *window =
        self.window;

    if (!window)
        return;

    if (!VMLIsCarPlayRootWindow(
            window)) {

        return;
    }

    VMLProcessCarPlayRoot(
        window,
        @"UIView.didMoveToWindow"
    );
}

%end

#pragma mark - Phone scene

static UIWindowScene *VMLPhoneScene(void) {
    UIApplication *app =
        UIApplication.sharedApplication;

    for (UIScene *scene
         in app.connectedScenes) {

        if (![scene
                isKindOfClass:
                    UIWindowScene.class]) {

            continue;
        }

        UIWindowScene *ws =
            (UIWindowScene *)scene;

        // Skip any scene that lives on a non-main (CarPlay) screen,
        // regardless of wired/wireless connection or resolution.
        if (VMLIsExternalCarPlayScreen(
                ws.screen)) {

            continue;
        }

        return ws;
    }

    return nil;
}

#pragma mark - Phone bubble

static void VMLCreatePhoneBubble(void) {
    if (gPhoneWindow)
        return;

    UIWindowScene *scene =
        VMLPhoneScene();

    if (!scene) {
        VMLLog(
            @"PHONE SCENE NOT FOUND"
        );

        return;
    }

    CGFloat size =
        64.0;

    gPhoneWindow =
        [[UIWindow alloc]
            initWithWindowScene:
                scene];

    gPhoneWindow.frame =
        CGRectMake(
            18,
            110,
            size,
            size
        );

    gPhoneWindow.backgroundColor =
        UIColor.clearColor;

    gPhoneWindow.windowLevel =
        UIWindowLevelAlert + 1000;

    UIViewController *vc =
        [UIViewController new];

    vc.view.backgroundColor =
        UIColor.clearColor;

    gPhoneWindow.rootViewController =
        vc;

    UIView *bubble =
        VMLMakeBubble(
            kPhoneBubbleTag,
            size
        );

    [vc.view addSubview:
        bubble];

    gPhoneWindow.hidden =
        NO;

    VMLLog(
        @"PHONE BUBBLE CREATED text=%@",
        VMLSpeedText()
    );
}

#pragma mark - Start

%ctor {
    @autoreleasepool {
        NSString *bundle =
            NSBundle.mainBundle
                .bundleIdentifier ?: @"";

        NSString *process =
            NSProcessInfo.processInfo
                .processName ?: @"";

        VMLLog(
            @"========================================"
        );

        VMLLog(
            @"VML CARPLAY RENDER + ACTIVE SCANNER V12 (wired+wireless, stable)"
        );

        VMLLog(
            @"bundle=%@ process=%@",
            bundle,
            process
        );

        VMLLog(
            @"========================================"
        );

        if (!VMLIsSpringBoard())
            return;

        VMLStartSpeedReceiver();

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                1 * NSEC_PER_SEC
            ),
            dispatch_get_main_queue(),
            ^{
                VMLStartScanner();
            }
        );

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                3 * NSEC_PER_SEC
            ),
            dispatch_get_main_queue(),
            ^{
                VMLCreatePhoneBubble();
            }
        );

        VMLLog(
            @"V12 ACTIVE"
        );
    }
}
