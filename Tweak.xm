#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>
#import <math.h>

#pragma mark - Globals

static UIWindow *gPhoneWindow = nil;

static UIView *gVMLCarPlayBubble = nil;
static __weak UIView *gVMLCarPlayHost = nil;

static BOOL gVMLAddingOwnView = NO;

static const NSInteger kVMLBubbleTag = 990099;
static const NSInteger kVMLLabelTag  = 990100;

static NSInteger gVMLCurrentSpeed = 0;
static int gVMLSpeedNotifyToken = 0;

#pragma mark - Logging

static void VMLLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);

    NSString *msg =
        [[NSString alloc]
            initWithFormat:format
                 arguments:args];

    va_end(args);

    NSString *line =
        [NSString stringWithFormat:@"%@\n", msg];

    NSLog(@"[VMLV3] %@", msg);

    FILE *f =
        fopen(
            "/var/mobile/VMLHostSniffer.txt",
            "a"
        );

    if (f) {
        fprintf(
            f,
            "%s",
            [line UTF8String]
        );

        fclose(f);
    }
}

#pragma mark - Process

static BOOL VMLIsSpringBoard(void) {
    NSString *bundle =
        NSBundle.mainBundle.bundleIdentifier ?: @"";

    return
        [bundle isEqualToString:
            @"com.apple.springboard"];
}

#pragma mark - Speed

static NSString *VMLSpeedText(void) {
    if (gVMLCurrentSpeed > 0 &&
        gVMLCurrentSpeed <= 200) {

        return
            [NSString stringWithFormat:
                @"%ld",
                (long)gVMLCurrentSpeed];
    }

    return @"--";
}

#pragma mark - Bubble

static UIView *VMLMakeBubble(
    NSString *text,
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
        kVMLLabelTag;

    label.autoresizingMask =
        UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;

    label.text =
        text;

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

#pragma mark - Bubble update

static void VMLUpdateBubble(
    UIView *bubble
) {
    if (!bubble)
        return;

    UILabel *label =
        (UILabel *)
        [bubble viewWithTag:
            kVMLLabelTag];

    if (!label)
        return;

    label.text =
        VMLSpeedText();

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
            if (gVMLCarPlayBubble) {
                VMLUpdateBubble(
                    gVMLCarPlayBubble
                );
            }

            if (gPhoneWindow) {
                UIView *phoneBubble =
                    [gPhoneWindow
                        viewWithTag:
                            kVMLBubbleTag];

                if (phoneBubble) {
                    VMLUpdateBubble(
                        phoneBubble
                    );
                }
            }

            VMLLog(
                @"BUBBLES UPDATED speed=%ld text=%@",
                (long)gVMLCurrentSpeed,
                VMLSpeedText()
            );
        }
    );
}

#pragma mark - IPC

static void VMLReadPublishedSpeed(void) {
    if (gVMLSpeedNotifyToken == 0)
        return;

    uint64_t state = 0;

    uint32_t status =
        notify_get_state(
            gVMLSpeedNotifyToken,
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

        VMLLog(
            @"IGNORE INVALID SPEED=%ld",
            (long)speed
        );

        return;
    }

    gVMLCurrentSpeed =
        speed;

    VMLLog(
        @"*** SPEED RECEIVED = %ld ***",
        (long)gVMLCurrentSpeed
    );

    VMLUpdateAllBubbles();
}

static void VMLStartSpeedReceiver(void) {
    if (!VMLIsSpringBoard())
        return;

    if (gVMLSpeedNotifyToken != 0)
        return;

    int token = 0;

    uint32_t status =
        notify_register_dispatch(
            "com.sushibta.vmlspeedbubble.speed",
            &token,
            dispatch_get_main_queue(),
            ^(int incomingToken) {

                gVMLSpeedNotifyToken =
                    incomingToken;

                VMLReadPublishedSpeed();
            }
        );

    if (status != NOTIFY_STATUS_OK) {
        VMLLog(
            @"notify_register_dispatch failed=%u",
            status
        );

        return;
    }

    gVMLSpeedNotifyToken =
        token;

    VMLLog(
        @"SPEED RECEIVER ACTIVE token=%d",
        token
    );

    VMLReadPublishedSpeed();
}

#pragma mark - Geometry

static BOOL VMLNear(
    CGFloat a,
    CGFloat b,
    CGFloat tolerance
) {
    return
        fabs(a - b) <= tolerance;
}

static BOOL VMLLooksLikeCarPlaySize(
    CGSize size
) {
    BOOL landscape =
        VMLNear(
            size.width,
            640.0,
            50.0
        ) &&
        VMLNear(
            size.height,
            240.0,
            50.0
        );

    BOOL rotated =
        VMLNear(
            size.width,
            240.0,
            50.0
        ) &&
        VMLNear(
            size.height,
            640.0,
            50.0
        );

    return
        landscape ||
        rotated;
}

#pragma mark - Global CarPlay root window

static BOOL VMLIsCarPlayRootWindow(
    UIWindow *window
) {
    if (!window)
        return NO;

    NSString *className =
        NSStringFromClass(
            window.class
        );

    if (![className
            isEqualToString:
                @"UIRootSceneWindow"]) {

        return NO;
    }

    return
        VMLLooksLikeCarPlaySize(
            window.bounds.size
        );
}

static void VMLAttachDirectlyToRootWindow(
    UIWindow *window,
    NSString *reason
) {
    if (!VMLIsSpringBoard())
        return;

    if (!VMLIsCarPlayRootWindow(
            window)) {

        return;
    }

    UIView *existing =
        [window viewWithTag:
            kVMLBubbleTag];

    if (existing) {
        gVMLCarPlayBubble =
            existing;

        gVMLCarPlayHost =
            window;

        VMLUpdateBubble(
            existing
        );

        VMLLog(
            @"ROOT BUBBLE EXISTS reason=%@ frame=%@ speed=%ld",
            reason,
            NSStringFromCGRect(
                existing.frame
            ),
            (long)gVMLCurrentSpeed
        );

        return;
    }

    if (gVMLCarPlayBubble &&
        gVMLCarPlayBubble.superview &&
        gVMLCarPlayBubble.superview != window) {

        [gVMLCarPlayBubble
            removeFromSuperview];

        gVMLCarPlayBubble =
            nil;

        gVMLCarPlayHost =
            nil;
    }

    gVMLAddingOwnView =
        YES;

    CGFloat size =
        46.0;

    UIView *bubble =
        VMLMakeBubble(
            VMLSpeedText(),
            size
        );

    bubble.tag =
        kVMLBubbleTag;

    CGFloat x =
        70.0;

    CGFloat y =
        120.0;

    CGFloat maxX =
        window.bounds.size.width
        - size
        - 8.0;

    CGFloat maxY =
        window.bounds.size.height
        - size
        - 8.0;

    if (maxX < 8.0)
        maxX = 8.0;

    if (maxY < 8.0)
        maxY = 8.0;

    if (x > maxX)
        x = maxX;

    if (y > maxY)
        y = maxY;

    if (x < 8.0)
        x = 8.0;

    if (y < 8.0)
        y = 8.0;

    bubble.frame =
        CGRectMake(
            x,
            y,
            size,
            size
        );

    bubble.layer.zPosition =
        CGFLOAT_MAX;

    [window addSubview:
        bubble];

    [window bringSubviewToFront:
        bubble];

    gVMLCarPlayBubble =
        bubble;

    gVMLCarPlayHost =
        window;

    gVMLAddingOwnView =
        NO;

    VMLLog(
        @"*** ROOT CARPLAY BUBBLE ADDED reason=%@ class=%@ frame=%@ bounds=%@ speed=%ld text=%@ ***",
        reason,
        NSStringFromClass(
            window.class
        ),
        NSStringFromCGRect(
            window.frame
        ),
        NSStringFromCGRect(
            window.bounds
        ),
        (long)gVMLCurrentSpeed,
        VMLSpeedText()
    );
}

#pragma mark - Delayed root probe

static void VMLProbeRootWindowLater(
    UIWindow *window,
    NSString *reason
) {
    if (!window)
        return;

    __weak UIWindow *weakWindow =
        window;

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            UIWindow *w =
                weakWindow;

            if (w) {
                VMLAttachDirectlyToRootWindow(
                    w,
                    reason
                );
            }
        }
    );

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            250 * NSEC_PER_MSEC
        ),
        dispatch_get_main_queue(),
        ^{
            UIWindow *w =
                weakWindow;

            if (w) {
                VMLAttachDirectlyToRootWindow(
                    w,
                    [reason
                        stringByAppendingString:
                            @"+250ms"]
                );
            }
        }
    );

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            1 * NSEC_PER_SEC
        ),
        dispatch_get_main_queue(),
        ^{
            UIWindow *w =
                weakWindow;

            if (w) {
                VMLAttachDirectlyToRootWindow(
                    w,
                    [reason
                        stringByAppendingString:
                            @"+1s"]
                );
            }
        }
    );
}

#pragma mark - DuoDash fallback

static void VMLAttachDuoDashFallback(
    UIView *duoBubble
) {
    if (!duoBubble)
        return;

    UIView *host =
        duoBubble.superview;

    if (!host)
        return;

    NSString *hostClass =
        NSStringFromClass(
            host.class
        );

    if (![hostClass
            isEqualToString:
                @"_UIVisualEffectContentView"]) {

        return;
    }

    VMLLog(
        @"DUODASH FALLBACK TRIGGER host=%@ frame=%@",
        hostClass,
        NSStringFromCGRect(
            host.frame
        )
    );

    UIView *existing =
        [host viewWithTag:
            kVMLBubbleTag];

    if (existing) {
        gVMLCarPlayBubble =
            existing;

        gVMLCarPlayHost =
            host;

        VMLUpdateBubble(
            existing
        );

        return;
    }

    /*
     Nếu root-window test chưa thành công,
     giữ đường đã chứng minh chạy với DuoDash.
    */

    if (gVMLCarPlayBubble &&
        gVMLCarPlayBubble.superview) {

        [gVMLCarPlayBubble
            removeFromSuperview];

        gVMLCarPlayBubble =
            nil;
    }

    gVMLAddingOwnView =
        YES;

    CGFloat size =
        46.0;

    UIView *bubble =
        VMLMakeBubble(
            VMLSpeedText(),
            size
        );

    bubble.tag =
        kVMLBubbleTag;

    CGRect duoFrame =
        duoBubble.frame;

    CGFloat x =
        CGRectGetMaxX(
            duoFrame
        ) + 8.0;

    CGFloat y =
        CGRectGetMinY(
            duoFrame
        );

    if (x + size >
        host.bounds.size.width) {

        x =
            CGRectGetMinX(
                duoFrame
            )
            - size
            - 8.0;
    }

    if (x < 4.0)
        x = 4.0;

    if (y < 4.0)
        y = 4.0;

    if (y + size >
        host.bounds.size.height) {

        y =
            MAX(
                4.0,
                host.bounds.size.height
                - size
                - 4.0
            );
    }

    bubble.frame =
        CGRectMake(
            x,
            y,
            size,
            size
        );

    bubble.layer.zPosition =
        CGFLOAT_MAX;

    [host addSubview:
        bubble];

    [host bringSubviewToFront:
        bubble];

    gVMLCarPlayBubble =
        bubble;

    gVMLCarPlayHost =
        host;

    gVMLAddingOwnView =
        NO;

    VMLLog(
        @"*** DUODASH FALLBACK BUBBLE ADDED speed=%ld text=%@ ***",
        (long)gVMLCurrentSpeed,
        VMLSpeedText()
    );
}

#pragma mark - UIView hook

%hook UIView

- (void)addSubview:(UIView *)view {
    %orig;

    if (!VMLIsSpringBoard())
        return;

    if (gVMLAddingOwnView)
        return;

    if (!view)
        return;

    NSString *className =
        NSStringFromClass(
            view.class
        );

    /*
     Fallback cũ đã chứng minh hoạt động.
    */

    if ([className
            isEqualToString:
                @"CNABBubbleView"]) {

        dispatch_async(
            dispatch_get_main_queue(),
            ^{
                VMLAttachDuoDashFallback(
                    view
                );
            }
        );

        return;
    }

    /*
     Nếu bất kỳ view nào vừa được add vào
     UIRootSceneWindow, kiểm tra root đó.
    */

    UIView *superview =
        view.superview;

    if (superview &&
        [superview
            isKindOfClass:
                UIWindow.class]) {

        UIWindow *window =
            (UIWindow *)superview;

        NSString *windowClass =
            NSStringFromClass(
                window.class
            );

        if ([windowClass
                isEqualToString:
                    @"UIRootSceneWindow"]) {

            VMLLog(
                @"VIEW ADDED TO UIRootSceneWindow child=%@ rootFrame=%@ rootBounds=%@",
                className,
                NSStringFromCGRect(
                    window.frame
                ),
                NSStringFromCGRect(
                    window.bounds
                )
            );

            VMLProbeRootWindowLater(
                window,
                @"childAddedToRoot"
            );
        }
    }
}

%end

#pragma mark - UIWindow hooks

%hook UIWindow

- (void)setWindowScene:(UIWindowScene *)windowScene {
    %orig(windowScene);

    if (!VMLIsSpringBoard())
        return;

    NSString *className =
        NSStringFromClass(
            self.class
        );

    if (![className
            isEqualToString:
                @"UIRootSceneWindow"]) {

        return;
    }

    NSString *role =
        windowScene
        ? windowScene.session.role
        : @"nil";

    VMLLog(
        @"UIRootSceneWindow setWindowScene frame=%@ bounds=%@ role=%@",
        NSStringFromCGRect(
            self.frame
        ),
        NSStringFromCGRect(
            self.bounds
        ),
        role
    );

    VMLProbeRootWindowLater(
        self,
        @"setWindowScene"
    );
}

- (void)setHidden:(BOOL)hidden {
    %orig(hidden);

    if (!VMLIsSpringBoard())
        return;

    NSString *className =
        NSStringFromClass(
            self.class
        );

    if (![className
            isEqualToString:
                @"UIRootSceneWindow"]) {

        return;
    }

    VMLLog(
        @"UIRootSceneWindow setHidden=%d frame=%@ bounds=%@",
        hidden,
        NSStringFromCGRect(
            self.frame
        ),
        NSStringFromCGRect(
            self.bounds
        )
    );

    if (!hidden) {
        VMLProbeRootWindowLater(
            self,
            @"setHidden:NO"
        );
    }
}

- (void)makeKeyAndVisible {
    %orig;

    if (!VMLIsSpringBoard())
        return;

    NSString *className =
        NSStringFromClass(
            self.class
        );

    if (![className
            isEqualToString:
                @"UIRootSceneWindow"]) {

        return;
    }

    VMLLog(
        @"UIRootSceneWindow makeKeyAndVisible frame=%@ bounds=%@",
        NSStringFromCGRect(
            self.frame
        ),
        NSStringFromCGRect(
            self.bounds
        )
    );

    VMLProbeRootWindowLater(
        self,
        @"makeKeyAndVisible"
    );
}

%end

#pragma mark - Phone bubble

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

        CGSize size =
            ws.screen.bounds.size;

        /*
         Không chọn screen có kích thước CarPlay.
        */

        if (VMLLooksLikeCarPlaySize(
                size)) {

            continue;
        }

        return ws;
    }

    return nil;
}

static void VMLCreatePhoneBubble(void) {
    if (gPhoneWindow)
        return;

    UIWindowScene *scene =
        VMLPhoneScene();

    if (!scene)
        return;

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
            VMLSpeedText(),
            size
        );

    bubble.tag =
        kVMLBubbleTag;

    [vc.view addSubview:
        bubble];

    gPhoneWindow.hidden =
        NO;

    VMLLog(
        @"PHONE BUBBLE CREATED text=%@",
        VMLSpeedText()
    );
}

#pragma mark - Constructor

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
            @"VML GLOBAL ROOT TEST V3"
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

        /*
         VietMap -> SpringBoard IPC.
        */
        VMLStartSpeedReceiver();

        /*
         Bubble test trên iPhone.
        */
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
            @"GLOBAL CARPLAY ROOT HOOKS ACTIVE"
        );
    }
}
