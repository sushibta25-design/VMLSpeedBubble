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

    NSLog(@"[VMLV4] %@", msg);

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

#pragma mark - Geometry

static BOOL VMLNear(
    CGFloat a,
    CGFloat b,
    CGFloat tolerance
) {
    return fabs(a - b) <= tolerance;
}

static BOOL VMLLooksLikeCarPlaySize(
    CGSize size
) {
    BOOL landscape =
        VMLNear(size.width, 640.0, 60.0) &&
        VMLNear(size.height, 240.0, 60.0);

    BOOL rotated =
        VMLNear(size.width, 240.0, 60.0) &&
        VMLNear(size.height, 640.0, 60.0);

    return landscape || rotated;
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

#pragma mark - Bubble creator

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

    bubble.clipsToBounds = YES;

    /*
     Không chặn thao tác CarPlay.
    */
    bubble.userInteractionEnabled = NO;

    UILabel *label =
        [[UILabel alloc]
            initWithFrame:
                bubble.bounds];

    label.tag =
        kVMLLabelTag;

    label.autoresizingMask =
        UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;

    label.text = text;

    label.textColor =
        UIColor.blackColor;

    label.textAlignment =
        NSTextAlignmentCenter;

    label.font =
        [UIFont systemFontOfSize:
            size * 0.40
                         weight:
            UIFontWeightBold];

    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.5;

    [bubble addSubview:label];

    return bubble;
}

#pragma mark - Update bubble

static void VMLUpdateBubble(
    UIView *bubble
) {
    if (!bubble)
        return;

    UILabel *label =
        (UILabel *)
        [bubble viewWithTag:
            kVMLLabelTag];

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

#pragma mark - IPC receiver

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

        return;
    }

    gVMLCurrentSpeed = speed;

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

    gVMLSpeedNotifyToken = token;

    VMLLog(
        @"SPEED RECEIVER ACTIVE token=%d",
        token
    );

    VMLReadPublishedSpeed();
}

#pragma mark - Attach to CarPlay window

static void VMLAttachToCarPlayWindow(
    UIWindow *window,
    NSString *reason
) {
    if (!window)
        return;

    if (!VMLLooksLikeCarPlaySize(
            window.bounds.size)) {

        return;
    }

    /*
     Nếu bubble hiện tại đã nằm chính
     trong window này thì chỉ update.
    */
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

        return;
    }

    /*
     Bubble cũ đang nằm trên một host khác.
     Chuyển sang window mới tìm được.
    */
    if (gVMLCarPlayBubble &&
        gVMLCarPlayBubble.superview &&
        gVMLCarPlayBubble.superview != window) {

        [gVMLCarPlayBubble
            removeFromSuperview];

        gVMLCarPlayBubble = nil;
        gVMLCarPlayHost = nil;
    }

    gVMLAddingOwnView = YES;

    CGFloat size = 46.0;

    UIView *bubble =
        VMLMakeBubble(
            VMLSpeedText(),
            size
        );

    bubble.tag =
        kVMLBubbleTag;

    /*
     Vị trí test.
     Window CarPlay đã biết là 640x240.
    */
    CGFloat x = 70.0;
    CGFloat y = 120.0;

    CGFloat maxX =
        window.bounds.size.width -
        size -
        8.0;

    CGFloat maxY =
        window.bounds.size.height -
        size -
        8.0;

    x =
        MAX(
            8.0,
            MIN(x, maxX)
        );

    y =
        MAX(
            8.0,
            MIN(y, maxY)
        );

    bubble.frame =
        CGRectMake(
            x,
            y,
            size,
            size
        );

    bubble.layer.zPosition =
        CGFLOAT_MAX;

    [window addSubview:bubble];

    [window bringSubviewToFront:
        bubble];

    gVMLCarPlayBubble =
        bubble;

    gVMLCarPlayHost =
        window;

    gVMLAddingOwnView = NO;

    VMLLog(
        @"*** GLOBAL CARPLAY BUBBLE ADDED reason=%@ window=%@ frame=%@ bounds=%@ level=%f hidden=%d speed=%ld ***",
        reason,
        NSStringFromClass(window.class),
        NSStringFromCGRect(window.frame),
        NSStringFromCGRect(window.bounds),
        window.windowLevel,
        window.hidden,
        (long)gVMLCurrentSpeed
    );
}

#pragma mark - Scan SpringBoard scenes

static void VMLScanForCarPlayWindow(void) {
    if (!VMLIsSpringBoard())
        return;

    UIApplication *app =
        UIApplication.sharedApplication;

    NSSet *scenes =
        app.connectedScenes;

    VMLLog(
        @"SCAN connectedScenes=%lu",
        (unsigned long)scenes.count
    );

    for (UIScene *scene in scenes) {
        if (![scene
                isKindOfClass:
                    UIWindowScene.class]) {

            continue;
        }

        UIWindowScene *windowScene =
            (UIWindowScene *)scene;

        NSString *role =
            windowScene.session.role
            ?: @"nil";

        CGSize screenSize =
            windowScene.screen.bounds.size;

        NSArray<UIWindow *> *windows =
            windowScene.windows;

        VMLLog(
            @"SCENE role=%@ screen=%@ windows=%lu",
            role,
            NSStringFromCGSize(screenSize),
            (unsigned long)windows.count
        );

        /*
         Đây là filter chính:
         scene sử dụng màn hình logic ~640x240.
        */
        if (!VMLLooksLikeCarPlaySize(
                screenSize)) {

            continue;
        }

        VMLLog(
            @"*** CARPLAY-SIZED SCENE FOUND role=%@ screen=%@ ***",
            role,
            NSStringFromCGSize(screenSize)
        );

        for (UIWindow *window in windows) {
            VMLLog(
                @"CARPLAY WINDOW class=%@ frame=%@ bounds=%@ hidden=%d level=%f",
                NSStringFromClass(
                    window.class
                ),
                NSStringFromCGRect(
                    window.frame
                ),
                NSStringFromCGRect(
                    window.bounds
                ),
                window.hidden,
                window.windowLevel
            );

            if (window.hidden)
                continue;

            if (!VMLLooksLikeCarPlaySize(
                    window.bounds.size)) {

                continue;
            }

            VMLAttachToCarPlayWindow(
                window,
                @"sceneScan"
            );

            /*
             Chỉ cần một window phù hợp
             trong lần test này.
            */
            return;
        }
    }
}

#pragma mark - Repeated scanner

static void VMLScheduleScanner(void) {
    if (!VMLIsSpringBoard())
        return;

    /*
     Không phụ thuộc callback lifecycle.
     Cứ quét lại hierarchy đang tồn tại.
    */

    VMLScanForCarPlayWindow();

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            2 * NSEC_PER_SEC
        ),
        dispatch_get_main_queue(),
        ^{
            VMLScheduleScanner();
        }
    );
}

#pragma mark - DuoDash fallback

static void VMLAttachDuoFallback(
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

    /*
     Nếu global bubble đã có host,
     không để DuoDash giành lại nó.
    */
    if (gVMLCarPlayBubble &&
        gVMLCarPlayBubble.superview) {

        VMLUpdateBubble(
            gVMLCarPlayBubble
        );

        return;
    }

    gVMLAddingOwnView = YES;

    CGFloat size = 46.0;

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

    [host addSubview:bubble];

    [host bringSubviewToFront:
        bubble];

    gVMLCarPlayBubble =
        bubble;

    gVMLCarPlayHost =
        host;

    gVMLAddingOwnView = NO;

    VMLLog(
        @"*** DUODASH FALLBACK ADDED host=%@ speed=%ld ***",
        hostClass,
        (long)gVMLCurrentSpeed
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

    if ([className
            isEqualToString:
                @"CNABBubbleView"]) {

        dispatch_async(
            dispatch_get_main_queue(),
            ^{
                VMLAttachDuoFallback(
                    view
                );
            }
        );
    }
}

%end

#pragma mark - Phone bubble

static UIWindowScene *VMLFindPhoneScene(void) {
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

        if (VMLLooksLikeCarPlaySize(
                ws.screen.bounds.size)) {

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
        VMLFindPhoneScene();

    if (!scene)
        return;

    CGFloat size = 64.0;

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

    [vc.view addSubview:bubble];

    gPhoneWindow.hidden = NO;

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
            @"VML GLOBAL SCENE SCANNER V4"
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
                2 * NSEC_PER_SEC
            ),
            dispatch_get_main_queue(),
            ^{
                VMLScheduleScanner();
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
            @"GLOBAL SCENE SCANNER STARTED"
        );
    }
}
