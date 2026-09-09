#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>
#import <math.h>

#pragma mark - Globals

static UIWindow *gPhoneWindow = nil;

static __weak UIWindow *gVMLCarPlayWindow = nil;
static __weak UIView *gVMLCarPlayHost = nil;

static UIView *gVMLCarPlayBubble = nil;

static BOOL gVMLAddingOwnView = NO;

static const NSInteger kVMLBubbleTag = 990099;
static const NSInteger kVMLLabelTag  = 990100;

static NSInteger gVMLCurrentSpeed = 0;
static int gVMLSpeedNotifyToken = 0;
static void VMLCaptureRoot(UIWindow *window, NSString *reason);
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

    NSLog(@"[VMLV6] %@", msg);

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
        NSStringFromClass(window.class);

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

static BOOL VMLLooksLikeKnownHost(
    UIView *view
) {
    if (!view)
        return NO;

    NSString *className =
        NSStringFromClass(view.class);

    if (![className
            isEqualToString:
                @"_UIVisualEffectContentView"]) {
        return NO;
    }

    CGSize size =
        view.bounds.size;

    BOOL sizeMatch =
        VMLNear(size.width, 595.0, 40.0) &&
        VMLNear(size.height, 240.0, 30.0);

    if (!sizeMatch)
        return NO;

    UIView *parent =
        view.superview;

    if (!parent)
        return NO;

    NSString *parentClass =
        NSStringFromClass(parent.class);

    if (![parentClass
            isEqualToString:
                @"UIVisualEffectView"]) {
        return NO;
    }

    UIWindow *window =
        view.window;

    if (!window)
        return NO;

    if (!VMLIsCarPlayRootWindow(window))
        return NO;

    return YES;
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

#pragma mark - Tree dump

static void VMLDumpViewTree(
    UIView *view,
    NSInteger depth
) {
    if (!view)
        return;

    if (depth > 8)
        return;

    NSString *indent =
        [@"" stringByPaddingToLength:
            depth * 2
                          withString:@" "
                     startingAtIndex:0];

    NSString *className =
        NSStringFromClass(view.class);

    VMLLog(
        @"%@TREE class=%@ frame=%@ bounds=%@ hidden=%d alpha=%.2f subviews=%lu",
        indent,
        className,
        NSStringFromCGRect(view.frame),
        NSStringFromCGRect(view.bounds),
        view.hidden,
        view.alpha,
        (unsigned long)view.subviews.count
    );

    for (UIView *child in view.subviews) {
        VMLDumpViewTree(
            child,
            depth + 1
        );
    }
}

#pragma mark - Host search

static UIView *VMLFindKnownHostRecursive(
    UIView *view
) {
    if (!view)
        return nil;

    if (VMLLooksLikeKnownHost(view)) {
        return view;
    }

    for (UIView *child in view.subviews) {
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
        NSStringFromClass(view.class);

    if ([className
            isEqualToString:
                @"_UIVisualEffectContentView"]) {

        UIWindow *window =
            view.window;

        if (VMLIsCarPlayRootWindow(window)) {
            CGSize size =
                view.bounds.size;

            if (size.width > 400.0 &&
                size.height > 180.0) {

                return view;
            }
        }
    }

    for (UIView *child in view.subviews) {
        UIView *found =
            VMLFindFallbackHostRecursive(
                child
            );

        if (found)
            return found;
    }

    return nil;
}

#pragma mark - Attach bubble to host

static void VMLAttachToHost(
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
        [host viewWithTag:
            kVMLBubbleTag];

    if (existing) {
        gVMLCarPlayHost =
            host;

        gVMLCarPlayBubble =
            existing;

        VMLUpdateBubble(existing);

        VMLLog(
            @"HOST BUBBLE EXISTS reason=%@ host=%@ frame=%@",
            reason,
            NSStringFromClass(host.class),
            NSStringFromCGRect(
                existing.frame
            )
        );

        return;
    }

    if (gVMLCarPlayBubble &&
        gVMLCarPlayBubble.superview &&
        gVMLCarPlayBubble.superview != host) {

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

    /*
     Host cũ đã chứng minh render:
     DuoDash bubble x=10 y=122 width≈44
     bubble test 99 x=62 y=122
    */
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
            MIN(x, maxX)
        );

    y =
        MAX(
            4.0,
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

    [host addSubview:
        bubble];

    [host bringSubviewToFront:
        bubble];

    gVMLCarPlayHost =
        host;

    gVMLCarPlayBubble =
        bubble;

    gVMLAddingOwnView =
        NO;

    UIView *parent =
        host.superview;

    VMLLog(
        @"*** PRESENTATION HOST BUBBLE ADDED reason=%@ host=%@ hostFrame=%@ hostBounds=%@ parent=%@ parentFrame=%@ window=%@ windowBounds=%@ speed=%ld text=%@ ***",
        reason,
        NSStringFromClass(host.class),
        NSStringFromCGRect(host.frame),
        NSStringFromCGRect(host.bounds),
        parent
            ? NSStringFromClass(parent.class)
            : @"nil",
        parent
            ? NSStringFromCGRect(parent.frame)
            : @"nil",
        NSStringFromClass(window.class),
        NSStringFromCGRect(window.bounds),
        (long)gVMLCurrentSpeed,
        VMLSpeedText()
    );
}

#pragma mark - Inspect CarPlay root

static void VMLInspectCarPlayRoot(
    UIWindow *window,
    NSString *reason
) {
    if (!window)
        return;

    if (!VMLIsCarPlayRootWindow(window))
        return;

    gVMLCarPlayWindow =
        window;

    VMLLog(
        @"================================================"
    );

    VMLLog(
        @"*** INSPECT CARPLAY ROOT reason=%@ frame=%@ bounds=%@ subviews=%lu ***",
        reason,
        NSStringFromCGRect(window.frame),
        NSStringFromCGRect(window.bounds),
        (unsigned long)window.subviews.count
    );

    UIView *knownHost =
        VMLFindKnownHostRecursive(
            window
        );

    if (knownHost) {
        VMLLog(
            @"*** KNOWN HOST FOUND class=%@ frame=%@ bounds=%@ parent=%@ ***",
            NSStringFromClass(
                knownHost.class
            ),
            NSStringFromCGRect(
                knownHost.frame
            ),
            NSStringFromCGRect(
                knownHost.bounds
            ),
            knownHost.superview
                ? NSStringFromClass(
                    knownHost.superview.class
                )
                : @"nil"
        );

        VMLAttachToHost(
            knownHost,
            @"knownHost"
        );

        return;
    }

    UIView *fallbackHost =
        VMLFindFallbackHostRecursive(
            window
        );

    if (fallbackHost) {
        VMLLog(
            @"*** FALLBACK HOST FOUND class=%@ frame=%@ bounds=%@ parent=%@ ***",
            NSStringFromClass(
                fallbackHost.class
            ),
            NSStringFromCGRect(
                fallbackHost.frame
            ),
            NSStringFromCGRect(
                fallbackHost.bounds
            ),
            fallbackHost.superview
                ? NSStringFromClass(
                    fallbackHost.superview.class
                )
                : @"nil"
        );

        VMLAttachToHost(
            fallbackHost,
            @"fallbackHost"
        );

        return;
    }

    VMLLog(
        @"*** NO PRESENTATION HOST FOUND - DUMP TREE ***"
    );

    VMLDumpViewTree(
        window,
        0
    );
}

static void VMLInspectDelayed(
    UIWindow *window,
    NSString *reason
) {
    if (!window)
        return;

    __weak UIWindow *weakWindow =
        window;

    NSArray<NSNumber *> *delays =
        @[
            @0.0,
            @0.1,
            @0.5,
            @1.0,
            @2.0
        ];

    for (NSNumber *delayNum in delays) {
        NSTimeInterval delay =
            delayNum.doubleValue;

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                (int64_t)(
                    delay * NSEC_PER_SEC
                )
            ),
            dispatch_get_main_queue(),
            ^{
                UIWindow *w =
                    weakWindow;

                if (!w)
                    return;

                NSString *r =
                    [NSString stringWithFormat:
                        @"%@+%.1fs",
                        reason,
                        delay];

                VMLInspectCarPlayRoot(
                    w,
                    r
                );
            }
        );
    }
}

#pragma mark - Probe root window

static void VMLProbeWindow(
    UIWindow *window,
    NSString *reason
) {
    if (!VMLIsSpringBoard())
        return;

    if (!window)
        return;

    NSString *className =
        NSStringFromClass(
            window.class
        );

    if (![className
            isEqualToString:
                @"UIRootSceneWindow"]) {
        return;
    }

    VMLLog(
        @"ROOT WINDOW PROBE reason=%@ frame=%@ bounds=%@ hidden=%d level=%f",
        reason,
        NSStringFromCGRect(
            window.frame
        ),
        NSStringFromCGRect(
            window.bounds
        ),
        window.hidden,
        window.windowLevel
    );

    if (!VMLIsCarPlayRootWindow(window))
        return;

    VMLLog(
        @"*** CARPLAY ROOT DETECTED reason=%@ ***",
        reason
    );

    gVMLCarPlayWindow =
        window;

    VMLInspectDelayed(
        window,
        reason
    );
}

#pragma mark - UIWindow hooks
static void VMLCaptureRoot(
    UIWindow *window,
    NSString *reason
) {
    if (!window)
        return;

    VMLProbeWindow(
        window,
        reason
    );
}
%hook UIWindow

- (instancetype)initWithFrame:(CGRect)frame {
    id result = %orig(frame);

    if (VMLIsSpringBoard() &&
        [result isKindOfClass:UIWindow.class]) {

        UIWindow *window = (UIWindow *)result;

        dispatch_async(
            dispatch_get_main_queue(),
            ^{
                VMLCaptureRoot(
                    window,
                    @"initWithFrame"
                );
            }
        );
    }

    return result;
}

- (instancetype)initWithWindowScene:(UIWindowScene *)windowScene {
    id result = %orig(windowScene);

    if (VMLIsSpringBoard() &&
        [result isKindOfClass:UIWindow.class]) {

        UIWindow *window = (UIWindow *)result;

        dispatch_async(
            dispatch_get_main_queue(),
            ^{
                VMLCaptureRoot(
                    window,
                    @"initWithWindowScene"
                );
            }
        );
    }

    return result;
}

- (void)addSubview:(UIView *)view {
    %orig(view);

    if (!VMLIsSpringBoard())
        return;

    UIWindow *window = self;

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            100 * NSEC_PER_MSEC
        ),
        dispatch_get_main_queue(),
        ^{
            VMLCaptureRoot(
                window,
                @"childAddedToRoot+100ms"
            );
        }
    );
}

- (void)setFrame:(CGRect)frame {
    %orig(frame);

    if (VMLIsSpringBoard()) {
        VMLCaptureRoot(
            self,
            @"setFrame"
        );
    }
}

- (void)setBounds:(CGRect)bounds {
    %orig(bounds);

    if (VMLIsSpringBoard()) {
        VMLCaptureRoot(
            self,
            @"setBounds"
        );
    }
}

- (void)setHidden:(BOOL)hidden {
    %orig(hidden);

    if (VMLIsSpringBoard()) {
        VMLCaptureRoot(
            self,
            hidden
                ? @"setHidden:YES"
                : @"setHidden:NO"
        );
    }
}

%end
#pragma mark - UIView hooks

%hook UIView

- (void)addSubview:(UIView *)view {
    %orig;

    if (!VMLIsSpringBoard())
        return;

    if (gVMLAddingOwnView)
        return;

    if (!view)
        return;

    UIWindow *window =
        view.window;

    if (VMLIsCarPlayRootWindow(window)) {
        NSString *className =
            NSStringFromClass(
                view.class
            );

        if ([className
                isEqualToString:
                    @"_UIVisualEffectContentView"] ||
            [className
                isEqualToString:
                    @"UIVisualEffectView"] ||
            [className
                containsString:
                    @"ScenePresentation"] ||
            [className
                containsString:
                    @"ApplicationScene"]) {

            VMLLog(
                @"INTERESTING VIEW ADDED class=%@ frame=%@ bounds=%@ super=%@",
                className,
                NSStringFromCGRect(
                    view.frame
                ),
                NSStringFromCGRect(
                    view.bounds
                ),
                view.superview
                    ? NSStringFromClass(
                        view.superview.class
                    )
                    : @"nil"
            );

            VMLInspectDelayed(
                window,
                [NSString stringWithFormat:
                    @"interestingView:%@",
                    className]
            );
        }
    }

    /*
     Giữ DuoDash chỉ làm tín hiệu debug.
     Không attach bubble theo DuoDash nữa.
    */
    NSString *className =
        NSStringFromClass(
            view.class
        );

    if ([className
            isEqualToString:
                @"CNABBubbleView"]) {

        VMLLog(
            @"DUODASH VIEW SEEN frame=%@ super=%@ window=%@",
            NSStringFromCGRect(
                view.frame
            ),
            view.superview
                ? NSStringFromClass(
                    view.superview.class
                )
                : @"nil",
            view.window
                ? NSStringFromClass(
                    view.window.class
                )
                : @"nil"
        );

        UIWindow *duoWindow =
            view.window;

        if (VMLIsCarPlayRootWindow(
                duoWindow)) {

            VMLInspectDelayed(
                duoWindow,
                @"DuoDashSeen"
            );
        }
    }
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
            @"VML PRESENTATION HOST FINDER V6"
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
            @"PRESENTATION HOST FINDER ACTIVE"
        );
    }
}
