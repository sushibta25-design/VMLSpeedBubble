#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>
#import <math.h>

#pragma mark - Globals

static UIWindow *gPhoneWindow = nil;

static __weak UIWindow *gCarPlayRoot = nil;

static NSInteger gCurrentSpeed = 0;
static int gSpeedNotifyToken = 0;

static BOOL gDumpScheduled = NO;

static const NSInteger kPhoneBubbleTag = 990099;
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

    NSLog(@"[VMLV9.2] %@", msg);

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

static BOOL VMLLooksLikeCarPlaySize(
    CGSize size
) {
    BOOL landscape =
        VMLNear(size.width, 640.0, 40.0) &&
        VMLNear(size.height, 240.0, 40.0);

    BOOL rotated =
        VMLNear(size.width, 240.0, 40.0) &&
        VMLNear(size.height, 640.0, 40.0);

    return landscape || rotated;
}

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

#pragma mark - Phone bubble

static UIView *VMLMakePhoneBubble(
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
        kPhoneBubbleTag;

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

    [bubble addSubview:label];

    return bubble;
}

static void VMLUpdatePhoneBubble(void) {
    if (!gPhoneWindow)
        return;

    UIView *bubble =
        [gPhoneWindow
            viewWithTag:
                kPhoneBubbleTag];

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

    if (status != NOTIFY_STATUS_OK)
        return;

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

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            VMLUpdatePhoneBubble();
        }
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

    VMLLog(
        @"SPEED RECEIVER ACTIVE token=%d",
        token
    );

    VMLReadSpeed();
}

#pragma mark - Interesting class filter

static BOOL VMLInterestingClassName(
    NSString *className
) {
    if (!className)
        return NO;

    NSArray<NSString *> *tokens =
        @[
            @"Scene",
            @"Presentation",
            @"Application",
            @"Host",
            @"VisualEffect",
            @"Root",
            @"CarPlay",
            @"Dashboard"
        ];

    for (NSString *token
         in tokens) {

        if ([className
                containsString:
                    token]) {

            return YES;
        }
    }

    return NO;
}

#pragma mark - Responder chain

static void VMLLogResponderChain(
    UIResponder *responder,
    NSString *prefix
) {
    UIResponder *current =
        responder;

    NSInteger depth =
        0;

    while (current &&
           depth < 20) {

        VMLLog(
            @"%@ RESPONDER depth=%ld class=%@",
            prefix,
            (long)depth,
            NSStringFromClass(
                current.class
            )
        );

        current =
            current.nextResponder;

        depth++;
    }
}

#pragma mark - Tree mapper

static void VMLDumpTreeRecursive(
    UIView *view,
    NSInteger depth
) {
    if (!view)
        return;

    if (depth > 20)
        return;

    NSString *className =
        NSStringFromClass(
            view.class
        );

    BOOL interesting =
        VMLInterestingClassName(
            className
        );

    /*
     Root-level view vẫn log để không mất cấu trúc.
    */

    if (depth <= 3 ||
        interesting) {

        VMLLog(
            @"TREE depth=%ld class=%@ frame=%@ bounds=%@ hidden=%d alpha=%.3f clips=%d super=%@ window=%@ subviews=%lu",
            (long)depth,
            className,
            NSStringFromCGRect(
                view.frame
            ),
            NSStringFromCGRect(
                view.bounds
            ),
            view.hidden,
            view.alpha,
            view.clipsToBounds,
            view.superview
                ? NSStringFromClass(
                    view.superview.class
                )
                : @"nil",
            view.window
                ? NSStringFromClass(
                    view.window.class
                )
                : @"nil",
            (unsigned long)
                view.subviews.count
        );
    }

    /*
     Với class đáng chú ý, log responder chain.
    */

    if (interesting) {
        VMLLog(
            @"*** INTERESTING VIEW class=%@ depth=%ld ***",
            className,
            (long)depth
        );

        VMLLogResponderChain(
            view,
            [NSString stringWithFormat:
                @"VIEW:%@",
                className]
        );
    }

    for (UIView *child
         in view.subviews) {

        VMLDumpTreeRecursive(
            child,
            depth + 1
        );
    }
}

#pragma mark - Root diagnostics

static void VMLDumpCarPlayRoot(
    UIWindow *root,
    NSString *reason
) {
    if (!VMLIsCarPlayRootWindow(root))
        return;

    VMLLog(
        @"================================================"
    );

    VMLLog(
        @"*** CARPLAY ROOT TREE DUMP reason=%@ ***",
        reason
    );

    VMLLog(
        @"ROOT class=%@ frame=%@ bounds=%@ hidden=%d alpha=%.3f level=%f subviews=%lu",
        NSStringFromClass(
            root.class
        ),
        NSStringFromCGRect(
            root.frame
        ),
        NSStringFromCGRect(
            root.bounds
        ),
        root.hidden,
        root.alpha,
        root.windowLevel,
        (unsigned long)
            root.subviews.count
    );

    UIScreen *screen =
        root.screen;

    if (screen) {
        VMLLog(
            @"ROOT SCREEN bounds=%@ nativeBounds=%@ scale=%.3f nativeScale=%.3f",
            NSStringFromCGRect(
                screen.bounds
            ),
            NSStringFromCGRect(
                screen.nativeBounds
            ),
            screen.scale,
            screen.nativeScale
        );
    }

    VMLLogResponderChain(
        root,
        @"ROOT"
    );

    VMLDumpTreeRecursive(
        root,
        0
    );

    VMLLog(
        @"*** CARPLAY ROOT TREE DUMP COMPLETE ***"
    );
}

#pragma mark - Capture root

static void VMLCaptureRoot(
    UIWindow *root,
    NSString *reason
) {
    if (!VMLIsSpringBoard())
        return;

    if (!VMLIsCarPlayRootWindow(root))
        return;

    BOOL changed =
        gCarPlayRoot != root;

    gCarPlayRoot =
        root;

    VMLLog(
        @"*** CARPLAY ROOT CAPTURED reason=%@ frame=%@ bounds=%@ hidden=%d changed=%d ***",
        reason,
        NSStringFromCGRect(
            root.frame
        ),
        NSStringFromCGRect(
            root.bounds
        ),
        root.hidden,
        changed
    );

    if (gDumpScheduled)
        return;

    gDumpScheduled =
        YES;

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            300 * NSEC_PER_MSEC
        ),
        dispatch_get_main_queue(),
        ^{
            gDumpScheduled =
                NO;

            UIWindow *w =
                gCarPlayRoot;

            if (!w)
                return;

            VMLDumpCarPlayRoot(
                w,
                @"capture+300ms"
            );
        }
    );

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            2 * NSEC_PER_SEC
        ),
        dispatch_get_main_queue(),
        ^{
            UIWindow *w =
                gCarPlayRoot;

            if (!w)
                return;

            VMLDumpCarPlayRoot(
                w,
                @"capture+2s"
            );
        }
    );
}

#pragma mark - UIView trigger

%hook UIView

- (void)didMoveToWindow {
    %orig;

    if (!VMLIsSpringBoard())
        return;

    UIWindow *window =
        self.window;

    if (!window)
        return;

    if (!VMLIsCarPlayRootWindow(
            window)) {

        return;
    }

    NSString *className =
        NSStringFromClass(
            self.class
        );

    BOOL interesting =
        self.bounds.size.width >= 400.0 ||
        VMLInterestingClassName(
            className
        );

    if (interesting) {
        VMLLog(
            @"DIDMOVE-CARPLAY class=%@ frame=%@ bounds=%@ super=%@ rootHidden=%d",
            className,
            NSStringFromCGRect(
                self.frame
            ),
            NSStringFromCGRect(
                self.bounds
            ),
            self.superview
                ? NSStringFromClass(
                    self.superview.class
                )
                : @"nil",
            window.hidden
        );
    }

    VMLCaptureRoot(
        window,
        [NSString stringWithFormat:
            @"didMove:%@",
            className]
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

        if (VMLLooksLikeCarPlaySize(
                ws.screen.bounds.size)) {

            continue;
        }

        return ws;
    }

    return nil;
}

#pragma mark - Create phone bubble

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
        VMLMakePhoneBubble(
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
            @"VML CARPLAY ROOT TREE MAPPER V9.2"
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
                3 * NSEC_PER_SEC
            ),
            dispatch_get_main_queue(),
            ^{
                VMLCreatePhoneBubble();
            }
        );

        VMLLog(
            @"V9.2 ACTIVE"
        );
    }
}
