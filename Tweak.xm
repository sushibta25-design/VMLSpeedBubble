#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>

#pragma mark - Globals

static UIWindow *gPhoneWindow = nil;
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

    NSLog(@"[VMLHOST] %@", msg);

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

#pragma mark - Process checks

static BOOL VMLIsCarPlay(void) {
    NSString *bundle =
        NSBundle.mainBundle.bundleIdentifier ?: @"";

    return
        [bundle isEqualToString:
            @"com.apple.CarPlayApp"];
}

static BOOL VMLIsSpringBoard(void) {
    NSString *bundle =
        NSBundle.mainBundle.bundleIdentifier ?: @"";

    return
        [bundle isEqualToString:
            @"com.apple.springboard"];
}

#pragma mark - Speed text

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
     Keep passthrough behavior for now.
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

    label.adjustsFontSizeToFitWidth =
        YES;

    label.minimumScaleFactor =
        0.5;

    [bubble addSubview:label];

    return bubble;
}

#pragma mark - Update existing bubbles

static void VMLUpdateBubbleInView(
    UIView *root
) {
    if (!root)
        return;

    UIView *bubble =
        [root viewWithTag:
            kVMLBubbleTag];

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

    [bubble.superview
        bringSubviewToFront:
            bubble];

    VMLLog(
        @"BUBBLE UPDATED speed=%ld text=%@",
        (long)gVMLCurrentSpeed,
        label.text
    );
}

static void VMLUpdateAllKnownBubbles(void) {
    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            UIApplication *app =
                UIApplication.sharedApplication;

            for (UIWindow *window
                 in app.windows) {

                VMLUpdateBubbleInView(
                    window
                );
            }
        }
    );
}

#pragma mark - Speed IPC receiver

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
            @"IGNORE RECEIVED SPEED=%ld",
            (long)speed
        );

        return;
    }

    gVMLCurrentSpeed = speed;

    VMLLog(
        @"*** SPEED RECEIVED FROM VIETMAP = %ld ***",
        (long)gVMLCurrentSpeed
    );

    VMLUpdateAllKnownBubbles();
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

    /*
     Read state immediately in case VietMap
     published before CarPlay bubble appeared.
    */
    VMLReadPublishedSpeed();
}

#pragma mark - Host inspection

static NSString *VMLViewChain(
    UIView *view
) {
    NSMutableArray *parts =
        [NSMutableArray array];

    UIView *current = view;

    NSInteger count = 0;

    while (current &&
           count < 12) {

        NSString *part =
            [NSString stringWithFormat:
                @"%@ %@",
                NSStringFromClass(
                    current.class
                ),
                NSStringFromCGRect(
                    current.frame
                )];

        [parts addObject:
            part];

        current =
            current.superview;

        count++;
    }

    return
        [parts componentsJoinedByString:
            @" -> "];
}

static void VMLDumpHost(
    UIView *host,
    UIView *duoBubble
) {
    UIWindow *window =
        host.window;

    UIViewController *root =
        window.rootViewController;

    NSString *windowClass =
        window
        ? NSStringFromClass(
            window.class
        )
        : @"nil";

    NSString *rootClass =
        root
        ? NSStringFromClass(
            root.class
        )
        : @"nil";

    NSString *sceneRole =
        @"nil";

    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene =
            window.windowScene;

        if (scene) {
            sceneRole =
                scene.session.role ?: @"nil";
        }
    }

    VMLLog(
        @"========== DUODASH HOST FOUND =========="
    );

    VMLLog(
        @"HOST CLASS = %@",
        NSStringFromClass(
            host.class
        )
    );

    VMLLog(
        @"HOST FRAME = %@",
        NSStringFromCGRect(
            host.frame
        )
    );

    VMLLog(
        @"HOST BOUNDS = %@",
        NSStringFromCGRect(
            host.bounds
        )
    );

    VMLLog(
        @"DUO BUBBLE FRAME = %@",
        NSStringFromCGRect(
            duoBubble.frame
        )
    );

    VMLLog(
        @"WINDOW CLASS = %@",
        windowClass
    );

    VMLLog(
        @"WINDOW FRAME = %@",
        window
            ? NSStringFromCGRect(
                window.frame
            )
            : @"nil"
    );

    VMLLog(
        @"ROOT VC = %@",
        rootClass
    );

    VMLLog(
        @"SCENE ROLE = %@",
        sceneRole
    );

    VMLLog(
        @"SUPERVIEW CHAIN = %@",
        VMLViewChain(
            host
        )
    );

    VMLLog(
        @"========================================"
    );
}

#pragma mark - Put runtime speed beside DuoDash

static void VMLAttachSpeedToDuoHost(
    UIView *host,
    UIView *duoBubble
) {
    if (!host ||
        !duoBubble) {

        return;
    }

    UIView *existing =
        [host viewWithTag:
            kVMLBubbleTag];

    if (existing) {
        UILabel *label =
            (UILabel *)
            [existing viewWithTag:
                kVMLLabelTag];

        if (label) {
            label.text =
                VMLSpeedText();
        }

        existing.layer.zPosition =
            CGFLOAT_MAX;

        [host bringSubviewToFront:
            existing];

        VMLLog(
            @"EXISTING BUBBLE UPDATED speed=%ld",
            (long)gVMLCurrentSpeed
        );

        return;
    }

    gVMLAddingOwnView = YES;

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

    gVMLAddingOwnView = NO;

    VMLLog(
        @"RUNTIME BUBBLE ADDED host=%@ frame=%@ speed=%ld text=%@",
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

#pragma mark - IMPORTANT HOOK

%hook UIView

- (void)addSubview:(UIView *)view {
    %orig;

    if (!(VMLIsCarPlay() ||
          VMLIsSpringBoard())) {

        return;
    }

    if (gVMLAddingOwnView)
        return;

    if (!view)
        return;

    NSString *className =
        NSStringFromClass(
            view.class
        );

    if (![className
            isEqualToString:
                @"CNABBubbleView"]) {

        return;
    }

    UIView *host =
        view.superview;

    NSString *bundle =
        NSBundle.mainBundle
            .bundleIdentifier ?: @"";

    NSString *process =
        NSProcessInfo.processInfo
            .processName ?: @"";

    VMLLog(
        @"INTERCEPTED CNABBubbleView bundle=%@ process=%@",
        bundle,
        process
    );

    VMLDumpHost(
        host,
        view
    );

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            VMLAttachSpeedToDuoHost(
                host,
                view
            );

            dispatch_after(
                dispatch_time(
                    DISPATCH_TIME_NOW,
                    1 * NSEC_PER_SEC
                ),
                dispatch_get_main_queue(),
                ^{
                    UIView *test =
                        [host viewWithTag:
                            kVMLBubbleTag];

                    if (test) {
                        UILabel *label =
                            (UILabel *)
                            [test viewWithTag:
                                kVMLLabelTag];

                        if (label) {
                            label.text =
                                VMLSpeedText();
                        }

                        test.layer.zPosition =
                            CGFLOAT_MAX;

                        [host
                            bringSubviewToFront:
                                test];

                        VMLLog(
                            @"RUNTIME BUBBLE RE-BROUGHT speed=%ld",
                            (long)gVMLCurrentSpeed
                        );
                    }
                }
            );
        }
    );
}

%end

#pragma mark - iPhone test bubble

static UIWindowScene *VMLPhoneScene(void) {
    for (UIScene *scene
         in UIApplication
            .sharedApplication
            .connectedScenes) {

        if (![scene
                isKindOfClass:
                    UIWindowScene.class]) {

            continue;
        }

        UIWindowScene *ws =
            (UIWindowScene *)scene;

        NSString *role =
            ws.session.role ?: @"";

        if ([role
                containsString:
                    @"CarPlay"]) {

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
            @"Injected bundle=%@ process=%@",
            bundle,
            process
        );

        if (VMLIsSpringBoard()) {
            /*
             Start IPC receiver immediately.
            */
            VMLStartSpeedReceiver();

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
        }

        if (VMLIsCarPlay()) {
            VMLLog(
                @"CARPLAY HOST SNIFFER ACTIVE"
            );
        }
    }
}
