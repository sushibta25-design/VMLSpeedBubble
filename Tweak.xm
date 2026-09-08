#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>

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
        [[NSString alloc] initWithFormat:format
                              arguments:args];

    va_end(args);

    NSString *line =
        [NSString stringWithFormat:@"%@\n", msg];

    NSLog(@"[VML] %@", msg);

    const char *path =
        "/var/mobile/VMLHostSniffer.txt";

    FILE *f = fopen(path, "a");

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

#pragma mark - Update bubble

static void VMLUpdateOneBubble(
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
                VMLUpdateOneBubble(
                    gVMLCarPlayBubble
                );
            }

            if (gPhoneWindow) {
                UIView *phoneBubble =
                    [gPhoneWindow
                        viewWithTag:
                            kVMLBubbleTag];

                if (phoneBubble) {
                    VMLUpdateOneBubble(
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

#pragma mark - View search helpers

static BOOL VMLApprox(
    CGFloat a,
    CGFloat b,
    CGFloat tolerance
) {
    return
        fabs(a - b) <= tolerance;
}

static BOOL VMLLooksLikeCarPlayWindow(
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

    CGSize size =
        window.bounds.size;

    BOOL normal =
        VMLApprox(
            size.width,
            640.0,
            30.0
        ) &&
        VMLApprox(
            size.height,
            240.0,
            30.0
        );

    BOOL rotated =
        VMLApprox(
            size.width,
            240.0,
            30.0
        ) &&
        VMLApprox(
            size.height,
            640.0,
            30.0
        );

    return
        normal || rotated;
}

static UIView *VMLFindClassRecursive(
    UIView *root,
    NSString *wantedClass
) {
    if (!root)
        return nil;

    NSString *className =
        NSStringFromClass(
            root.class
        );

    if ([className
            isEqualToString:
                wantedClass]) {

        return root;
    }

    for (UIView *child
         in root.subviews) {

        UIView *found =
            VMLFindClassRecursive(
                child,
                wantedClass
            );

        if (found)
            return found;
    }

    return nil;
}

#pragma mark - Find CarPlay window

static UIWindow *VMLFindCarPlayWindow(void) {
    UIApplication *app =
        UIApplication.sharedApplication;

    for (UIScene *scene
         in app.connectedScenes) {

        if (![scene
                isKindOfClass:
                    UIWindowScene.class]) {

            continue;
        }

        UIWindowScene *windowScene =
            (UIWindowScene *)scene;

        for (UIWindow *window
             in windowScene.windows) {

            if (VMLLooksLikeCarPlayWindow(
                    window)) {

                VMLLog(
                    @"CARPLAY WINDOW FOUND class=%@ frame=%@ bounds=%@ role=%@",
                    NSStringFromClass(
                        window.class
                    ),
                    NSStringFromCGRect(
                        window.frame
                    ),
                    NSStringFromCGRect(
                        window.bounds
                    ),
                    windowScene.session.role
                );

                return window;
            }
        }
    }

    return nil;
}

#pragma mark - Find real host

static UIView *VMLFindCarPlayHost(
    UIWindow *window
) {
    if (!window)
        return nil;

    /*
     Host đã quan sát được:
     
     _UIVisualEffectContentView
       -> UIVisualEffectView
       -> UIRootSceneWindow
     
     Ưu tiên đúng content view này.
    */

    UIView *content =
        VMLFindClassRecursive(
            window,
            @"_UIVisualEffectContentView"
        );

    if (content) {
        VMLLog(
            @"CARPLAY CONTENT HOST FOUND class=%@ frame=%@ bounds=%@",
            NSStringFromClass(
                content.class
            ),
            NSStringFromCGRect(
                content.frame
            ),
            NSStringFromCGRect(
                content.bounds
            )
        );

        return content;
    }

    /*
     Fallback:
     tìm UIVisualEffectView rồi lấy contentView.
    */

    UIView *effect =
        VMLFindClassRecursive(
            window,
            @"UIVisualEffectView"
        );

    if (effect &&
        [effect
            isKindOfClass:
                UIVisualEffectView.class]) {

        UIVisualEffectView *visual =
            (UIVisualEffectView *)effect;

        UIView *fallback =
            visual.contentView;

        if (fallback) {
            VMLLog(
                @"CARPLAY FALLBACK CONTENT HOST frame=%@",
                NSStringFromCGRect(
                    fallback.frame
                )
            );

            return fallback;
        }
    }

    /*
     Fallback cuối:
     dùng trực tiếp SpringBoard UIRootSceneWindow.
    */

    VMLLog(
        @"CARPLAY FALLBACK TO ROOT WINDOW"
    );

    return window;
}

#pragma mark - Attach CarPlay bubble

static void VMLAttachCarPlayBubble(
    UIView *host
) {
    if (!host)
        return;

    /*
     Nếu bubble đang ở đúng host rồi,
     chỉ đưa lên trước + cập nhật số.
    */

    if (gVMLCarPlayBubble &&
        gVMLCarPlayBubble.superview == host) {

        VMLUpdateOneBubble(
            gVMLCarPlayBubble
        );

        return;
    }

    /*
     Nếu CarPlay đổi host/window,
     bỏ bubble khỏi host cũ.
    */

    if (gVMLCarPlayBubble &&
        gVMLCarPlayBubble.superview) {

        [gVMLCarPlayBubble
            removeFromSuperview];

        gVMLCarPlayBubble =
            nil;
    }

    UIView *existing =
        [host viewWithTag:
            kVMLBubbleTag];

    if (existing) {
        gVMLCarPlayBubble =
            existing;

        gVMLCarPlayHost =
            host;

        VMLUpdateOneBubble(
            existing
        );

        return;
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

    /*
     Vị trí ban đầu độc lập DuoDash.
     
     Host quan sát trước đây là 595x240,
     nên đặt sát trái + khoảng giữa chiều cao.
    */

    CGFloat x =
        16.0;

    CGFloat y =
        122.0;

    if (host.bounds.size.height > 0) {
        CGFloat maxY =
            host.bounds.size.height
            - size
            - 8.0;

        if (y > maxY)
            y = maxY;

        if (y < 8.0)
            y = 8.0;
    }

    if (host.bounds.size.width > 0) {
        CGFloat maxX =
            host.bounds.size.width
            - size
            - 8.0;

        if (x > maxX)
            x = maxX;

        if (x < 8.0)
            x = 8.0;
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
        @"*** INDEPENDENT CARPLAY BUBBLE ADDED host=%@ frame=%@ speed=%ld text=%@ ***",
        NSStringFromClass(
            host.class
        ),
        NSStringFromCGRect(
            bubble.frame
        ),
        (long)gVMLCurrentSpeed,
        VMLSpeedText()
    );
}

#pragma mark - CarPlay scan

static void VMLScanForCarPlay(void) {
    if (!VMLIsSpringBoard())
        return;

    UIWindow *window =
        VMLFindCarPlayWindow();

    if (!window) {
        return;
    }

    UIView *host =
        VMLFindCarPlayHost(
            window
        );

    if (!host)
        return;

    VMLAttachCarPlayBubble(
        host
    );
}

#pragma mark - Repeating scanner

static void VMLScheduleCarPlayScanner(void) {
    if (!VMLIsSpringBoard())
        return;

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            NSTimer *timer =
                [NSTimer
                    scheduledTimerWithTimeInterval:
                        1.0
                    repeats:
                        YES
                    block:
                        ^(
                            NSTimer *timer
                        ) {
                            VMLScanForCarPlay();
                        }];

            [[NSRunLoop mainRunLoop]
                addTimer:
                    timer
                forMode:
                    NSRunLoopCommonModes];

            VMLLog(
                @"CARPLAY INDEPENDENT SCANNER STARTED"
            );

            VMLScanForCarPlay();
        }
    );
}

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

        UIWindowScene *windowScene =
            (UIWindowScene *)scene;

        /*
         Bỏ qua scene giống CarPlay.
        */

        BOOL hasCarPlayWindow =
            NO;

        for (UIWindow *window
             in windowScene.windows) {

            if (VMLLooksLikeCarPlayWindow(
                    window)) {

                hasCarPlayWindow =
                    YES;

                break;
            }
        }

        if (hasCarPlayWindow)
            continue;

        return windowScene;
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
            @"Injected bundle=%@ process=%@",
            bundle,
            process
        );

        if (!VMLIsSpringBoard())
            return;

        /*
         1. Nhận speed từ VietMap.
        */
        VMLStartSpeedReceiver();

        /*
         2. Bubble iPhone.
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

        /*
         3. Tự tìm CarPlay.
            Không phụ thuộc DuoDash.
        */
        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                1 * NSEC_PER_SEC
            ),
            dispatch_get_main_queue(),
            ^{
                VMLScheduleCarPlayScanner();
            }
        );
    }
}
