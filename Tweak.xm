#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>
#import <objc/message.h>


@interface VMLPassthroughWindow : UIWindow
@end

@implementation VMLPassthroughWindow
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return NO;
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return nil;
}
@end

#pragma mark - Globals

static NSInteger gCurrentSpeed = 0;
static int gSpeedNotifyToken = 0;

static UIWindow *gPhoneWindow = nil;
static UIWindow *gCarPlayOverlayWindow = nil;
static UIView *gCarPlayBubble = nil;

static BOOL gOverlayLoopRunning = NO;
static BOOL gCarPlayShowsVietMap = NO;
static NSString *gLastForegroundEvidence = nil;

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

    NSLog(@"[VMLV12.3] %@", msg);

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

    bubble.hidden = NO;
    bubble.alpha = 1.0;
    bubble.layer.hidden = NO;
    bubble.layer.opacity = 1.0;
    bubble.layer.zPosition = CGFLOAT_MAX;

    if (bubble.superview) {
        [bubble.superview bringSubviewToFront:bubble];
    }
}

static void VMLUpdateAllBubbles(void) {
    if (gPhoneWindow) {
        UIView *phoneBubble =
            [gPhoneWindow viewWithTag:kPhoneBubbleTag];

        if (phoneBubble) {
            VMLUpdateBubble(phoneBubble);
        }
    }

    if (gCarPlayBubble) {
        VMLUpdateBubble(gCarPlayBubble);
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

    NSInteger speed = (NSInteger)state;

    // V12.3: only a valid limit can replace the current displayed value.
    if (speed <= 0 || speed > 200) {
        VMLLog(
            @"[speed] state=%ld -> keep current=%ld",
            (long)speed,
            (long)gCurrentSpeed
        );
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
                gSpeedNotifyToken = incomingToken;
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

    // Read immediately; RuntimeSniffer no longer replaces the shared
    // state with 0, so this can return the latest valid limit at once.
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

    if (!scene) {
        VMLLog(@"PHONE SCENE NOT FOUND");
        return;
    }

    CGFloat size = 64.0;

    gPhoneWindow =
        [[UIWindow alloc] initWithWindowScene:scene];

    gPhoneWindow.frame =
        CGRectMake(18, 110, size, size);

    gPhoneWindow.backgroundColor =
        UIColor.clearColor;

    gPhoneWindow.windowLevel =
        UIWindowLevelAlert + 1000.0;

    gPhoneWindow.userInteractionEnabled = NO;

    UIViewController *vc =
        [UIViewController new];

    vc.view.backgroundColor =
        UIColor.clearColor;

    vc.view.userInteractionEnabled = NO;

    gPhoneWindow.rootViewController = vc;

    UIView *bubble =
        VMLMakeBubble(kPhoneBubbleTag, size);

    [vc.view addSubview:bubble];

    gPhoneWindow.hidden = NO;

    VMLUpdateBubble(bubble);

    VMLLog(
        @"*** PHONE BUBBLE CREATED text=%@ ***",
        VMLSpeedText()
    );
}


#pragma mark - Active CarPlay app detector

static BOOL VMLStringLooksLikeVietMap(NSString *s) {
    if (!s.length) return NO;

    NSString *lower = s.lowercaseString;

    return [lower containsString:@"vn.vietmap.live"] ||
           [lower containsString:@"vietmaplive"] ||
           [lower containsString:@"vietmap live"];
}

static id VMLSafeObjectSelector(id obj, NSString *selectorName) {
    if (!obj || !selectorName.length) return nil;

    SEL sel = NSSelectorFromString(selectorName);
    if (![obj respondsToSelector:sel]) return nil;

    return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
}

static BOOL VMLObjectContainsVietMapEvidence(id obj, NSInteger depth) {
    if (!obj || depth > 2) return NO;

    NSString *desc = nil;

    @try {
        desc = [obj description];
    } @catch (__unused NSException *e) {
        desc = nil;
    }

    if (VMLStringLooksLikeVietMap(desc)) {
        gLastForegroundEvidence = desc;
        return YES;
    }

    NSArray<NSString *> *stringSelectors = @[
        @"bundleIdentifier",
        @"applicationBundleIdentifier",
        @"clientBundleIdentifier",
        @"appBundleIdentifier",
        @"identifier",
        @"sceneIdentifier",
        @"displayIdentifier"
    ];

    for (NSString *name in stringSelectors) {
        id value = nil;

        @try {
            value = VMLSafeObjectSelector(obj, name);
        } @catch (__unused NSException *e) {
            value = nil;
        }

        if ([value isKindOfClass:NSString.class] &&
            VMLStringLooksLikeVietMap((NSString *)value)) {

            gLastForegroundEvidence =
                [NSString stringWithFormat:@"%@=%@", name, value];

            return YES;
        }
    }

    NSArray<NSString *> *objectSelectors = @[
        @"application",
        @"representedApplication",
        @"clientApplication",
        @"scene",
        @"sceneIdentity",
        @"identity",
        @"host",
        @"contentViewController",
        @"presentedViewController",
        @"selectedViewController",
        @"topViewController"
    ];

    for (NSString *name in objectSelectors) {
        id value = nil;

        @try {
            value = VMLSafeObjectSelector(obj, name);
        } @catch (__unused NSException *e) {
            value = nil;
        }

        if (value &&
            value != obj &&
            VMLObjectContainsVietMapEvidence(value, depth + 1)) {

            return YES;
        }
    }

    return NO;
}

static BOOL VMLViewTreeContainsVietMap(UIView *view, NSInteger depth) {
    if (!view || depth > 8) return NO;

    if (VMLObjectContainsVietMapEvidence(view, 0))
        return YES;

    for (UIView *child in view.subviews) {
        if (VMLViewTreeContainsVietMap(child, depth + 1))
            return YES;
    }

    return NO;
}

static BOOL VMLControllerTreeContainsVietMap(UIViewController *vc, NSInteger depth) {
    if (!vc || depth > 10) return NO;

    if (VMLObjectContainsVietMapEvidence(vc, 0))
        return YES;

    if (vc.view && VMLViewTreeContainsVietMap(vc.view, 0))
        return YES;

    if (vc.presentedViewController &&
        VMLControllerTreeContainsVietMap(vc.presentedViewController, depth + 1)) {

        return YES;
    }

    for (UIViewController *child in vc.childViewControllers) {
        if (VMLControllerTreeContainsVietMap(child, depth + 1))
            return YES;
    }

    return NO;
}

static BOOL VMLDetectVietMapOnCarPlay(void) {
    if (!VMLIsCarPlayApp()) return NO;

    gLastForegroundEvidence = nil;

    UIApplication *app = UIApplication.sharedApplication;

    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class])
            continue;

        UIWindowScene *ws = (UIWindowScene *)scene;

        for (UIWindow *window in ws.windows) {
            if (window.hidden || window.alpha <= 0.01)
                continue;

            UIViewController *root = window.rootViewController;

            if (root &&
                VMLControllerTreeContainsVietMap(root, 0)) {

                return YES;
            }

            if (VMLObjectContainsVietMapEvidence(window, 0))
                return YES;
        }
    }

    return NO;
}

static void VMLRefreshActiveCarPlayApp(void) {
    BOOL now = VMLDetectVietMapOnCarPlay();

    if (now != gCarPlayShowsVietMap) {
        gCarPlayShowsVietMap = now;

        VMLLog(
            @"*** ACTIVE CARPLAY VIETMAP = %d evidence=%@ ***",
            gCarPlayShowsVietMap,
            gLastForegroundEvidence ?: @"none"
        );
    }
}

#pragma mark - CarPlay Scene

static BOOL VMLSceneLooksCarPlay(UIWindowScene *scene) {
    if (!scene)
        return NO;

    NSString *role =
        scene.session.role ?: @"";

    if ([role localizedCaseInsensitiveContainsString:@"CarPlay"]) {
        return YES;
    }

    CGSize size =
        scene.screen.bounds.size;

    // Fallback for this iOS/CarPlay implementation where role can be
    // _UIScreenBasedSceneSession rather than a literal CarPlay role.
    if (size.width > size.height &&
        size.width >= 300.0 &&
        size.height <= 500.0) {

        return YES;
    }

    return NO;
}

static UIWindowScene *VMLFindCarPlayScene(void) {
    UIApplication *app =
        UIApplication.sharedApplication;

    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class])
            continue;

        UIWindowScene *ws =
            (UIWindowScene *)scene;

        if (VMLSceneLooksCarPlay(ws)) {
            return ws;
        }
    }

    return nil;
}

#pragma mark - Single CarPlay Overlay

static void VMLDestroyOldOverlayIfNeeded(UIWindowScene *wantedScene) {
    if (!gCarPlayOverlayWindow)
        return;

    if (gCarPlayOverlayWindow.windowScene == wantedScene)
        return;

    gCarPlayOverlayWindow.hidden = YES;
    gCarPlayOverlayWindow.rootViewController = nil;
    gCarPlayOverlayWindow = nil;
    gCarPlayBubble = nil;

    VMLLog(@"[overlay] discarded stale overlay window");
}

static void VMLCreateOrRefreshSingleOverlay(void) {
    if (!VMLIsCarPlayApp())
        return;

    // Pull the latest shared valid speed every tick.
    VMLReadSpeed();
    VMLRefreshActiveCarPlayApp();

    UIWindowScene *scene =
        VMLFindCarPlayScene();

    if (!scene) {
        VMLLog(@"[overlay] no CarPlay scene");
        return;
    }

    VMLDestroyOldOverlayIfNeeded(scene);

    CGRect sceneBounds =
        scene.coordinateSpace.bounds;

    if (CGRectIsEmpty(sceneBounds)) {
        sceneBounds =
            scene.screen.bounds;
    }

    CGFloat sceneW =
        MAX(sceneBounds.size.width, 1.0);

    CGFloat sceneH =
        MAX(sceneBounds.size.height, 1.0);

    CGFloat size =
        MAX(
            42.0,
            MIN(
                56.0,
                sceneH * 0.20
            )
        );

    CGFloat x =
        MAX(
            8.0,
            MIN(
                sceneW - size - 8.0,
                sceneW * 0.08
            )
        );

    CGFloat y =
        MAX(
            8.0,
            MIN(
                sceneH - size - 8.0,
                sceneH * 0.50
            )
        );

    CGRect bubbleWindowFrame =
        CGRectMake(
            x,
            y,
            size,
            size
        );

    if (!gCarPlayOverlayWindow) {
        gCarPlayOverlayWindow =
            [[VMLPassthroughWindow alloc]
                initWithWindowScene:scene];

        gCarPlayOverlayWindow.backgroundColor =
            UIColor.clearColor;

        // Tiny non-key window only around the sign.
        gCarPlayOverlayWindow.windowLevel =
            UIWindowLevelAlert + 100.0;

        gCarPlayOverlayWindow.userInteractionEnabled =
            NO;

        UIViewController *vc =
            [UIViewController new];

        vc.view.backgroundColor =
            UIColor.clearColor;

        vc.view.userInteractionEnabled =
            NO;

        gCarPlayOverlayWindow.rootViewController =
            vc;

        UIView *bubble =
            VMLMakeBubble(
                kCarPlayBubbleTag,
                size
            );

        bubble.frame =
            CGRectMake(
                0,
                0,
                size,
                size
            );

        bubble.userInteractionEnabled =
            NO;

        [vc.view addSubview:bubble];

        gCarPlayBubble =
            bubble;

        VMLLog(
            @"*** CLEAN CARPLAY OVERLAY CREATED V12.8 scene=%@ frame=%@ ***",
            NSStringFromCGRect(sceneBounds),
            NSStringFromCGRect(bubbleWindowFrame)
        );
    }

    gCarPlayOverlayWindow.frame =
        bubbleWindowFrame;

    gCarPlayOverlayWindow.rootViewController.view.frame =
        CGRectMake(
            0,
            0,
            size,
            size
        );

    if (gCarPlayBubble) {
        gCarPlayBubble.frame =
            CGRectMake(
                0,
                0,
                size,
                size
            );

        VMLUpdateBubble(
            gCarPlayBubble
        );
    }

    // Hide ONLY when VietMap itself owns a visible CarPlay-sized scene.
    // Opening VietMap on the iPhone screen alone does not satisfy this.
    gCarPlayOverlayWindow.hidden =
        gCarPlayShowsVietMap;

    gCarPlayOverlayWindow.alpha =
        1.0;

    VMLLog(
        @"[overlay] V12.8 frame=%@ speed=%ld activeVML=%d",
        NSStringFromCGRect(
            gCarPlayOverlayWindow.frame
        ),
        (long)gCurrentSpeed,
        gCarPlayShowsVietMap
    );
}

static void VMLOverlayTick(void) {
    if (!VMLIsCarPlayApp()) {
        gOverlayLoopRunning = NO;
        return;
    }

    VMLCreateOrRefreshSingleOverlay();

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            250 * NSEC_PER_MSEC
        ),
        dispatch_get_main_queue(),
        ^{
            VMLOverlayTick();
        }
    );
}

static void VMLStartOverlayLoop(void) {
    if (!VMLIsCarPlayApp() ||
        gOverlayLoopRunning) {

        return;
    }

    gOverlayLoopRunning = YES;

    VMLLog(
        @"[overlay] V12.8 ACTIVE-APP SMALL-WINDOW LOOP STARTED"
    );

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            VMLOverlayTick();
        }
    );
}

#pragma mark - Start

%ctor {
    @autoreleasepool {
        VMLLog(@"========================================");
        VMLLog(@"VML SPEED BUBBLE V12.8 ACTIVE-APP GLOBAL OVERLAY");
        VMLLog(@"bundle=%@ process=%@", VMLBundle(), VMLProcess());
        VMLLog(@"========================================");

        if (VMLIsSpringBoard()) {
            VMLLog(
                @"*** SPRINGBOARD INJECTION CONFIRMED V12.6 ***"
            );

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

            VMLLog(@"V12.8 SPRINGBOARD ACTIVE");
            return;
        }

        if (VMLIsCarPlayApp()) {
            VMLLog(
                @"*** CARPLAY.APP INJECTION CONFIRMED V12.6 ***"
            );

            VMLStartSpeedReceiver();
            VMLStartOverlayLoop();

            VMLLog(
                @"V12.8 CARPLAY ACTIVE"
            );

            return;
        }
    }
}
