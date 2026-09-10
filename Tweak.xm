#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>
#import <objc/message.h>


@interface VMLPassthroughWindow : UIWindow
@end

@implementation VMLPassthroughWindow

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return [super pointInside:point withEvent:event];
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return [super hitTest:point withEvent:event];
}

@end

#pragma mark - Globals

static NSInteger gCurrentSpeed = 0;
static int gSpeedNotifyToken = 0;
static int gVMLCarPlaySceneToken = 0;
static BOOL gVMLCarPlaySceneActive = NO;
static int gPhoneForegroundToken = 0;
static BOOL gPhoneForeground = NO;

static UIWindow *gPhoneWindow = nil;
static UIWindow *gCarPlayOverlayWindow = nil;
static CGPoint gCarPlayBubbleCenterRatio = {0.0, 0.0};
static BOOL gCarPlayBubblePositionLoaded = NO;
static UIView *gCarPlayBubble = nil;

static BOOL gOverlayLoopRunning = NO;

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






#pragma mark - VietMap CarPlay template scene receiver

static void VMLReadCarPlaySceneState(void) {
    if (gVMLCarPlaySceneToken == 0)
        return;

    uint64_t state = 0;

    uint32_t status =
        notify_get_state(
            gVMLCarPlaySceneToken,
            &state
        );

    if (status != NOTIFY_STATUS_OK)
        return;

    BOOL active =
        (state != 0);

    if (active != gVMLCarPlaySceneActive) {
        gVMLCarPlaySceneActive =
            active;

        VMLLog(
            @"*** VML CPTEMPLATE ACTIVE ON CARPLAY = %d ***",
            gVMLCarPlaySceneActive
        );
    }

    if (gCarPlayOverlayWindow) {
        gCarPlayOverlayWindow.hidden =
            gVMLCarPlaySceneActive;
    }
}

static void VMLStartCarPlaySceneReceiver(void) {
    if (gVMLCarPlaySceneToken != 0)
        return;

    int token = 0;

    uint32_t status =
        notify_register_dispatch(
            "com.sushibta.vmlspeedbubble.vmlcarplaysceneactive",
            &token,
            dispatch_get_main_queue(),
            ^(int incomingToken) {
                gVMLCarPlaySceneToken =
                    incomingToken;

                VMLReadCarPlaySceneState();
            }
        );

    if (status != NOTIFY_STATUS_OK) {
        VMLLog(
            @"cpscene receiver failed=%u",
            status
        );
        return;
    }

    gVMLCarPlaySceneToken =
        token;

    VMLReadCarPlaySceneState();

    VMLLog(
        @"CPTEMPLATE SCENE RECEIVER ACTIVE token=%d",
        token
    );
}

#pragma mark - Phone VietMap foreground receiver


static void VMLReadPhoneForeground(void) {
    if (gPhoneForegroundToken == 0)
        return;

    uint64_t state = 0;

    if (notify_get_state(
            gPhoneForegroundToken,
            &state
        ) != NOTIFY_STATUS_OK) {
        return;
    }

    BOOL foreground =
        (state != 0);

    if (foreground != gPhoneForeground) {
        gPhoneForeground =
            foreground;

        VMLLog(
            @"*** PHONE VML FOREGROUND = %d ***",
            gPhoneForeground
        );
    }
}

static void VMLStartPhoneForegroundReceiver(void) {
    if (gPhoneForegroundToken != 0)
        return;

    int token = 0;

    uint32_t status =
        notify_register_dispatch(
            "com.sushibta.vmlspeedbubble.phoneforeground",
            &token,
            dispatch_get_main_queue(),
            ^(int incomingToken) {
                gPhoneForegroundToken =
                    incomingToken;

                VMLReadPhoneForeground();
            }
        );

    if (status != NOTIFY_STATUS_OK) {
        VMLLog(
            @"phoneforeground receiver failed=%u",
            status
        );
        return;
    }

    gPhoneForegroundToken =
        token;

    VMLReadPhoneForeground();

    VMLLog(
        @"PHONE FOREGROUND RECEIVER ACTIVE token=%d",
        token
    );
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


static NSString *VMLCarPlayPosKeyX(void) {
    return @"VMLSpeedBubble.CarPlayPosX";
}

static NSString *VMLCarPlayPosKeyY(void) {
    return @"VMLSpeedBubble.CarPlayPosY";
}

static void VMLLoadCarPlayBubblePosition(void) {
    if (gCarPlayBubblePositionLoaded)
        return;

    NSUserDefaults *defaults =
        NSUserDefaults.standardUserDefaults;

    CGFloat x =
        [defaults doubleForKey:VMLCarPlayPosKeyX()];

    CGFloat y =
        [defaults doubleForKey:VMLCarPlayPosKeyY()];

    if (x > 0.0 && x < 1.0 &&
        y > 0.0 && y < 1.0) {

        gCarPlayBubbleCenterRatio =
            CGPointMake(x, y);
    } else {
        // Default close to the old V12/V13 location.
        gCarPlayBubbleCenterRatio =
            CGPointMake(0.08, 0.60);
    }

    gCarPlayBubblePositionLoaded =
        YES;
}

static void VMLSaveCarPlayBubblePosition(void) {
    if (!gCarPlayBubblePositionLoaded)
        return;

    NSUserDefaults *defaults =
        NSUserDefaults.standardUserDefaults;

    [defaults setDouble:gCarPlayBubbleCenterRatio.x
                 forKey:VMLCarPlayPosKeyX()];

    [defaults setDouble:gCarPlayBubbleCenterRatio.y
                 forKey:VMLCarPlayPosKeyY()];

    [defaults synchronize];
}

static CGRect VMLCarPlayBubbleFrameForScene(
    CGRect sceneBounds,
    CGFloat size
) {
    VMLLoadCarPlayBubblePosition();

    CGFloat W =
        MAX(sceneBounds.size.width, 1.0);

    CGFloat H =
        MAX(sceneBounds.size.height, 1.0);

    CGFloat centerX =
        gCarPlayBubbleCenterRatio.x * W;

    CGFloat centerY =
        gCarPlayBubbleCenterRatio.y * H;

    CGFloat half =
        size / 2.0;

    centerX =
        MAX(
            half + 4.0,
            MIN(
                W - half - 4.0,
                centerX
            )
        );

    centerY =
        MAX(
            half + 4.0,
            MIN(
                H - half - 4.0,
                centerY
            )
        );

    return CGRectMake(
        centerX - half,
        centerY - half,
        size,
        size
    );
}

static void VMLHandleCarPlayBubblePan(
    UIPanGestureRecognizer *pan
) {
    if (!gCarPlayOverlayWindow ||
        !gCarPlayOverlayWindow.windowScene) {

        return;
    }

    UIWindowScene *scene =
        gCarPlayOverlayWindow.windowScene;

    CGRect sceneBounds =
        scene.coordinateSpace.bounds;

    if (CGRectIsEmpty(sceneBounds)) {
        sceneBounds =
            scene.screen.bounds;
    }

    CGPoint translation =
        [pan translationInView:nil];

    CGRect frame =
        gCarPlayOverlayWindow.frame;

    frame.origin.x +=
        translation.x;

    frame.origin.y +=
        translation.y;

    CGFloat margin = 4.0;

    frame.origin.x =
        MAX(
            margin,
            MIN(
                sceneBounds.size.width -
                    frame.size.width -
                    margin,
                frame.origin.x
            )
        );

    frame.origin.y =
        MAX(
            margin,
            MIN(
                sceneBounds.size.height -
                    frame.size.height -
                    margin,
                frame.origin.y
            )
        );

    gCarPlayOverlayWindow.frame =
        frame;

    [pan setTranslation:CGPointZero
                 inView:nil];

    CGFloat centerX =
        CGRectGetMidX(frame);

    CGFloat centerY =
        CGRectGetMidY(frame);

    gCarPlayBubbleCenterRatio =
        CGPointMake(
            centerX /
                MAX(sceneBounds.size.width, 1.0),
            centerY /
                MAX(sceneBounds.size.height, 1.0)
        );

    gCarPlayBubblePositionLoaded =
        YES;

    if (pan.state ==
        UIGestureRecognizerStateEnded ||
        pan.state ==
        UIGestureRecognizerStateCancelled) {

        VMLSaveCarPlayBubblePosition();

        VMLLog(
            @"*** CARPLAY BUBBLE MOVED x=%.3f y=%.3f ***",
            gCarPlayBubbleCenterRatio.x,
            gCarPlayBubbleCenterRatio.y
        );
    }
}


@interface VMLCarPlayDragTarget : NSObject
- (void)handlePan:(UIPanGestureRecognizer *)pan;
@end

@implementation VMLCarPlayDragTarget

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    VMLHandleCarPlayBubblePan(pan);
}

@end

static VMLCarPlayDragTarget *gCarPlayDragTarget = nil;

static void VMLCreateOrRefreshSingleOverlay(void) {
    if (!VMLIsCarPlayApp())
        return;

    // Pull the latest shared valid speed every tick.
    VMLReadSpeed();
    VMLReadCarPlaySceneState();

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

    CGRect bubbleWindowFrame =
        VMLCarPlayBubbleFrameForScene(
            sceneBounds,
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
            YES;

        UIViewController *vc =
            [UIViewController new];

        vc.view.backgroundColor =
            UIColor.clearColor;

        vc.view.userInteractionEnabled =
            YES;

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
            YES;

        [vc.view addSubview:bubble];

        if (!gCarPlayDragTarget) {
            gCarPlayDragTarget =
                [VMLCarPlayDragTarget new];
        }

        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc]
                initWithTarget:gCarPlayDragTarget
                        action:@selector(handlePan:)];

        pan.cancelsTouchesInView =
            YES;

        [bubble addGestureRecognizer:pan];


        gCarPlayBubble =
            bubble;

        VMLLog(
            @"*** CLEAN CARPLAY OVERLAY CREATED V13.6.1 scene=%@ frame=%@ ***",
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
    gCarPlayOverlayWindow.hidden = gVMLCarPlaySceneActive;

    gCarPlayOverlayWindow.alpha =
        1.0;

    VMLLog(
        @"[overlay] V13.6.1 frame=%@ speed=%ld cpScene=%d",
        NSStringFromCGRect(gCarPlayOverlayWindow.frame),
        (long)gCurrentSpeed,
        gVMLCarPlaySceneActive
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
        @"[overlay] V13.6.1.1 CPTEMPLATE SMALL-WINDOW LOOP STARTED"
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
        VMLLog(@"VML SPEED BUBBLE V13.6.1 SAFE BUILD FIX");
        VMLLog(@"bundle=%@ process=%@", VMLBundle(), VMLProcess());
        VMLLog(@"========================================");

        if (VMLIsSpringBoard()) {
            VMLStartPhoneForegroundReceiver();
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

            VMLLog(@"V13.6.1 SPRINGBOARD ACTIVE");
            return;
        }

        if (VMLIsCarPlayApp()) {
            VMLStartCarPlaySceneReceiver();
            VMLLog(
                @"*** CARPLAY.APP INJECTION CONFIRMED V12.6 ***"
            );

            VMLStartSpeedReceiver();
            VMLStartOverlayLoop();

            VMLLog(
                @"V13.6.1 CARPLAY ACTIVE"
            );

            return;
        }
    }
}
