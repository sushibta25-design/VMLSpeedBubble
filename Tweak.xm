#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>
#import <objc/message.h>


@interface VMLPassthroughWindow : UIWindow
@property (nonatomic, weak) UIView *interactiveBubble;
@end

@implementation VMLPassthroughWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *bubble =
        self.interactiveBubble;

    if (!bubble ||
        bubble.hidden ||
        bubble.alpha <= 0.01) {

        return nil;
    }

    CGPoint p =
        [bubble convertPoint:point fromView:self];

    if (CGRectContainsPoint(
            bubble.bounds,
            p
        )) {

        return [bubble hitTest:p
                     withEvent:event] ?: bubble;
    }

    return nil;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return ([self hitTest:point withEvent:event] != nil);
}

@end

#pragma mark - Globals

static NSInteger gCurrentSpeed = 0;
static void VMLTrace(NSString *format, ...);
static NSString *VMLBundle(void);


static int gSpeedNotifyToken = 0;
static int gVMLCarPlaySceneToken = 0;
static BOOL gVMLCarPlaySceneActive = NO;

static UIWindow *gCarPlayOverlayWindow = nil;
static CGPoint gCarPlayBubbleCenterRatio = {0.0, 0.0};
static BOOL gCarPlayBubblePositionLoaded = NO;
static UIView *gCarPlayBubble = nil;

static BOOL gOverlayLoopRunning = NO;
static BOOL gCarPlayDragging = NO;

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


static void VMLTrace(NSString *format, ...) {
    va_list args;
    va_start(args, format);

    NSString *msg =
        [[NSString alloc] initWithFormat:format arguments:args];

    va_end(args);

    NSString *line =
        [NSString stringWithFormat:@"%@\n", msg];

    FILE *f =
        fopen("/var/mobile/VMLSpeedTrace.txt", "a");

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

        VMLTrace(
            @"TRACE LABEL text=%@ bundle=%@",
            label.text ?: @"nil",
            VMLBundle()
        );
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



#pragma mark - Speed IPC

static void VMLBroadcastEncodedSpeed(NSInteger speed) {
    if (speed <= 0 || speed > 200)
        return;

    NSString *name =
        [NSString stringWithFormat:
            @"com.sushibta.vmlspeedbubble.speed.%ld",
            (long)speed];

    notify_post(
        name.UTF8String
    );

    VMLTrace(
        @"TRACE SB ENCODED RELAY speed=%ld",
        (long)speed
    );
}

static void VMLReadSpeed(void) {
    // SpringBoard can see the fixed-name state correctly (proven by trace).
    // It caches the latest valid speed and rebroadcasts it using the
    // speed-encoded notification name.
    if (!VMLIsSpringBoard())
        return;

    if (gSpeedNotifyToken == 0)
        return;

    uint64_t state = 0;

    uint32_t status =
        notify_get_state(
            gSpeedNotifyToken,
            &state
        );

    if (status != NOTIFY_STATUS_OK)
        return;

    NSInteger speed =
        (NSInteger)state;

    if (speed <= 0 || speed > 200)
        return;

    gCurrentSpeed =
        speed;

    VMLTrace(
        @"TRACE SB CACHE speed=%ld",
        (long)speed
    );

    VMLBroadcastEncodedSpeed(
        speed
    );
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

    VMLReadSpeed();
}







#pragma mark - Encoded speed IPC

static NSMutableArray *gEncodedSpeedTokens = nil;
static BOOL gSpringBoardRebroadcastRunning = NO;

static void VMLApplyCarPlayEncodedSpeed(NSInteger speed) {
    if (!VMLIsCarPlayApp())
        return;

    if (speed <= 0 || speed > 200)
        return;

    gCurrentSpeed =
        speed;

    if (gCarPlayBubble) {
        UILabel *label =
            (UILabel *)[gCarPlayBubble viewWithTag:kLabelTag];

        if (label) {
            label.text =
                [NSString stringWithFormat:@"%ld", (long)speed];
        }
    }

    VMLTrace(
        @"CP TRACE ENCODED ACCEPT speed=%ld",
        (long)speed
    );
}

static void VMLStartEncodedSpeedReceiver(void) {
    if (!VMLIsCarPlayApp())
        return;

    if (gEncodedSpeedTokens)
        return;

    gEncodedSpeedTokens =
        [NSMutableArray arrayWithCapacity:200];

    for (NSInteger speed = 1;
         speed <= 200;
         speed++) {

        NSString *name =
            [NSString stringWithFormat:
                @"com.sushibta.vmlspeedbubble.speed.%ld",
                (long)speed];

        int token = 0;
        NSInteger capturedSpeed =
            speed;

        uint32_t status =
            notify_register_dispatch(
                name.UTF8String,
                &token,
                dispatch_get_main_queue(),
                ^(__unused int incomingToken) {
                    VMLApplyCarPlayEncodedSpeed(
                        capturedSpeed
                    );
                }
            );

        if (status == NOTIFY_STATUS_OK) {
            [gEncodedSpeedTokens addObject:
                @(token)];
        }
    }

    VMLTrace(
        @"CP TRACE ENCODED RECEIVER count=%lu",
        (unsigned long)gEncodedSpeedTokens.count
    );
}

static void VMLSpringBoardRebroadcastTick(void) {
    if (!VMLIsSpringBoard()) {
        gSpringBoardRebroadcastRunning =
            NO;
        return;
    }

    // Refresh the cached fixed-channel state, then rebroadcast the
    // latest valid value using the encoded channel.
    VMLReadSpeed();

    if (gCurrentSpeed > 0 &&
        gCurrentSpeed <= 200) {

        VMLBroadcastEncodedSpeed(
            gCurrentSpeed
        );
    }

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            1 * NSEC_PER_SEC
        ),
        dispatch_get_main_queue(),
        ^{
            VMLSpringBoardRebroadcastTick();
        }
    );
}

static void VMLStartSpringBoardRebroadcast(void) {
    if (!VMLIsSpringBoard() ||
        gSpringBoardRebroadcastRunning) {

        return;
    }

    gSpringBoardRebroadcastRunning =
        YES;

    VMLSpringBoardRebroadcastTick();
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
        !gCarPlayBubble) {

        return;
    }

    UIView *canvas =
        gCarPlayOverlayWindow.rootViewController.view;

    if (!canvas)
        return;

    UIGestureRecognizerState state =
        pan.state;

    if (state == UIGestureRecognizerStateBegan) {
        gCarPlayDragging = YES;

        // From here until release, the overlay watchdog will not touch
        // the bubble's geometry.
        gCarPlayBubble.layer.actions =
            @{
                @"position": [NSNull null],
                @"bounds": [NSNull null],
                @"frame": [NSNull null]
            };
    }

    if (state == UIGestureRecognizerStateBegan ||
        state == UIGestureRecognizerStateChanged) {

        CGPoint finger =
            [pan locationInView:canvas];

        CGFloat halfW =
            gCarPlayBubble.bounds.size.width / 2.0;

        CGFloat halfH =
            gCarPlayBubble.bounds.size.height / 2.0;

        CGFloat W =
            MAX(canvas.bounds.size.width, 1.0);

        CGFloat H =
            MAX(canvas.bounds.size.height, 1.0);

        finger.x =
            MAX(
                halfW + 4.0,
                MIN(
                    W - halfW - 4.0,
                    finger.x
                )
            );

        finger.y =
            MAX(
                halfH + 4.0,
                MIN(
                    H - halfH - 4.0,
                    finger.y
                )
            );

        [UIView performWithoutAnimation:^{
            gCarPlayBubble.center =
                finger;
        }];

        gCarPlayBubbleCenterRatio =
            CGPointMake(
                finger.x / W,
                finger.y / H
            );

        gCarPlayBubblePositionLoaded =
            YES;
    }

    if (state == UIGestureRecognizerStateEnded ||
        state == UIGestureRecognizerStateCancelled ||
        state == UIGestureRecognizerStateFailed) {

        VMLSaveCarPlayBubblePosition();

        gCarPlayDragging =
            NO;

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
            84.0,
            MIN(
                112.0,
                sceneH * 0.40
            )
        );

    CGRect bubbleFrame =
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

        // Full-screen pass-through window: only the bubble itself receives touches.
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

        bubble.frame = bubbleFrame;

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

        pan.delaysTouchesBegan =
            NO;

        pan.delaysTouchesEnded =
            NO;

        pan.minimumNumberOfTouches =
            1;

        pan.maximumNumberOfTouches =
            1;

        [bubble addGestureRecognizer:pan];


        gCarPlayBubble =
            bubble;

        ((VMLPassthroughWindow *)gCarPlayOverlayWindow).interactiveBubble =
            bubble;

        VMLLog(
            @"*** CLEAN CARPLAY OVERLAY CREATED V14.6.1 scene=%@ frame=%@ ***",
            NSStringFromCGRect(sceneBounds),
            NSStringFromCGRect(bubbleFrame)
        );
    }

    gCarPlayOverlayWindow.frame =
        sceneBounds;

    gCarPlayOverlayWindow.rootViewController.view.frame =
        CGRectMake(
            0,
            0,
            sceneBounds.size.width,
            sceneBounds.size.height
        );

    if (gCarPlayBubble) {
        if (!gCarPlayDragging) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            gCarPlayBubble.frame =
                bubbleFrame;
            [CATransaction commit];
        }

        VMLUpdateBubble(
            gCarPlayBubble
        );
    }

    // Hide ONLY when VietMap itself owns a visible CarPlay-sized scene.
    // Opening VietMap on the iPhone screen alone does not satisfy this.
    gCarPlayOverlayWindow.hidden = gVMLCarPlaySceneActive;

    gCarPlayOverlayWindow.alpha =
        1.0;
}

static void VMLOverlayTick(void) {
    if (!VMLIsCarPlayApp()) {
        gOverlayLoopRunning = NO;
        return;
    }

    // Critical for smooth drag: do zero overlay/layout work while the finger
    // owns the bubble. Speed notify callbacks still update independently.
    if (!gCarPlayDragging) {
        VMLCreateOrRefreshSingleOverlay();
    }

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            500 * NSEC_PER_MSEC
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
        VMLLog(@"VML SPEED BUBBLE V14.6.1 BUILD FIX");
        VMLLog(@"bundle=%@ process=%@", VMLBundle(), VMLProcess());
        VMLLog(@"========================================");

        if (VMLIsSpringBoard()) {
            VMLLog(
                @"*** SPRINGBOARD INJECTION CONFIRMED V12.6 ***"
            );

            VMLStartSpeedReceiver();
            VMLStartSpringBoardRebroadcast();

            
            VMLLog(@"V14.6.1 SPRINGBOARD ACTIVE");
            return;
        }

        if (VMLIsCarPlayApp()) {
            VMLStartEncodedSpeedReceiver();
            VMLStartCarPlaySceneReceiver();
            
            VMLLog(
                @"*** CARPLAY.APP INJECTION CONFIRMED V12.6 ***"
            );

            VMLStartSpeedReceiver();
            VMLStartOverlayLoop();

            VMLLog(
                @"V14.6.1 CARPLAY ACTIVE"
            );

            return;
        }
    }
}
