#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>


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
static int gVMLForegroundNotifyToken = 0;
static BOOL gVMLForeground = NO;

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


#pragma mark - VietMap foreground state

static void VMLReadForegroundState(void) {
    if (gVMLForegroundNotifyToken == 0) return;

    uint64_t state = 0;
    uint32_t status = notify_get_state(gVMLForegroundNotifyToken, &state);
    if (status != NOTIFY_STATUS_OK) return;

    BOOL newValue = (state != 0);

    if (gVMLForeground != newValue) {
        gVMLForeground = newValue;
        VMLLog(@"*** VML FOREGROUND STATE = %d ***", gVMLForeground);
    }

    if (gCarPlayOverlayWindow) {
        gCarPlayOverlayWindow.hidden = gVMLForeground;
    }
}

static void VMLStartForegroundReceiver(void) {
    if (gVMLForegroundNotifyToken != 0) return;

    int token = 0;
    uint32_t status = notify_register_dispatch(
        "com.sushibta.vmlspeedbubble.vmlforeground",
        &token,
        dispatch_get_main_queue(),
        ^(int incomingToken) {
            gVMLForegroundNotifyToken = incomingToken;
            VMLReadForegroundState();
        }
    );

    if (status != NOTIFY_STATUS_OK) {
        VMLLog(@"foreground notify_register_dispatch failed=%u", status);
        return;
    }

    gVMLForegroundNotifyToken = token;
    VMLReadForegroundState();
    VMLLog(@"VML FOREGROUND RECEIVER ACTIVE token=%d", token);
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

    VMLReadSpeed();
    VMLReadForegroundState();

    UIWindowScene *scene =
        VMLFindCarPlayScene();

    if (!scene) {
        VMLLog(@"[overlay] no CarPlay scene");
        return;
    }

    VMLDestroyOldOverlayIfNeeded(scene);

    CGRect sceneBounds = scene.coordinateSpace.bounds;
    if (CGRectIsEmpty(sceneBounds)) {
        sceneBounds = scene.screen.bounds;
    }

    CGFloat sceneW = MAX(sceneBounds.size.width, 1.0);
    CGFloat sceneH = MAX(sceneBounds.size.height, 1.0);

    CGFloat size = MAX(42.0, MIN(56.0, sceneH * 0.20));

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
        CGRectMake(x, y, size, size);

    if (!gCarPlayOverlayWindow) {
        gCarPlayOverlayWindow =
            [[VMLPassthroughWindow alloc] initWithWindowScene:scene];

        gCarPlayOverlayWindow.backgroundColor =
            UIColor.clearColor;

        // High enough to remain visible, but this is only a tiny non-key
        // window covering the bubble area instead of the whole CarPlay screen.
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

        [vc.view addSubview:bubble];

        gCarPlayBubble = bubble;

        VMLLog(
            @"*** SMALL PASS-THROUGH CARPLAY WINDOW CREATED V12.4 scene=%@ ***",
            NSStringFromCGRect(sceneBounds)
        );
    }

    gCarPlayOverlayWindow.frame =
        bubbleWindowFrame;

    gCarPlayOverlayWindow.rootViewController.view.frame =
        CGRectMake(0, 0, size, size);

    if (gCarPlayBubble) {
        gCarPlayBubble.frame =
            CGRectMake(0, 0, size, size);

        VMLUpdateBubble(gCarPlayBubble);
    }

    // Automatically hide our sign while VietMap Live is the active app.
    gCarPlayOverlayWindow.hidden =
        gVMLForeground ? YES : NO;

    gCarPlayOverlayWindow.alpha = 1.0;

    VMLLog(
        @"[overlay] frame=%@ hiddenForVML=%d speed=%ld",
        NSStringFromCGRect(gCarPlayOverlayWindow.frame),
        gVMLForeground,
        (long)gCurrentSpeed
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
        @"[overlay] V12.4 SAFE SMALL-WINDOW LOOP STARTED"
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
        VMLLog(@"VML SPEED BUBBLE V12.4 SAFE GLOBAL");
        VMLLog(@"bundle=%@ process=%@", VMLBundle(), VMLProcess());
        VMLLog(@"========================================");

        if (VMLIsSpringBoard()) {
            VMLLog(
                @"*** SPRINGBOARD INJECTION CONFIRMED V12.4 ***"
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

            VMLLog(@"V12.4 SPRINGBOARD ACTIVE");
            return;
        }

        if (VMLIsCarPlayApp()) {
            VMLLog(
                @"*** CARPLAY.APP INJECTION CONFIRMED V12.4 ***"
            );

            VMLStartSpeedReceiver();
            VMLStartForegroundReceiver();
            VMLStartOverlayLoop();

            VMLLog(
                @"V12.4 CARPLAY ACTIVE"
            );

            return;
        }
    }
}
