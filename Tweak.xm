#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>
#import <math.h>

#pragma mark - Globals

static UIWindow *gPhoneWindow = nil;

static __weak UIWindow *gVMLCarPlayWindow = nil;
static __weak UIView *gVMLKnownHost = nil;

static NSInteger gVMLCurrentSpeed = 0;
static int gVMLSpeedNotifyToken = 0;

static BOOL gVMLAddingOwnView = NO;
static BOOL gVMLDiagnosticInstalled = NO;
static BOOL gVMLInspectScheduled = NO;

static const NSInteger kVMLPhoneBubbleTag = 990099;
static const NSInteger kVMLLabelTag = 990100;

static const NSInteger kVMLMarker71Tag = 997101;
static const NSInteger kVMLMarker72Tag = 997102;
static const NSInteger kVMLMarker73Tag = 997103;

#pragma mark - Logging

static void VMLLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);

    NSString *msg =
        [[NSString alloc]
            initWithFormat:format
                 arguments:args];

    va_end(args);

    NSLog(@"[VMLV8] %@", msg);

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

static UIView *VMLMakeCircle(
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
            size * 0.38
                         weight:
            UIFontWeightBold];

    label.adjustsFontSizeToFitWidth =
        YES;

    label.minimumScaleFactor =
        0.45;

    [bubble addSubview:label];

    return bubble;
}

#pragma mark - Phone speed bubble

static void VMLUpdatePhoneBubble(void) {
    if (!gPhoneWindow)
        return;

    UIView *bubble =
        [gPhoneWindow
            viewWithTag:
                kVMLPhoneBubbleTag];

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

#pragma mark - Known host detection

static BOOL VMLLooksLikeKnownHost(
    UIView *view
) {
    if (!view)
        return NO;

    NSString *className =
        NSStringFromClass(
            view.class
        );

    if (![className
            isEqualToString:
                @"_UIVisualEffectContentView"]) {

        return NO;
    }

    CGSize size =
        view.bounds.size;

    if (!VMLNear(
            size.width,
            595.0,
            40.0)) {

        return NO;
    }

    if (!VMLNear(
            size.height,
            240.0,
            30.0)) {

        return NO;
    }

    UIView *parent =
        view.superview;

    if (!parent)
        return NO;

    if (![NSStringFromClass(parent.class)
            isEqualToString:
                @"UIVisualEffectView"]) {

        return NO;
    }

    return
        VMLIsCarPlayRootWindow(
            view.window
        );
}

static UIView *VMLFindKnownHostRecursive(
    UIView *view
) {
    if (!view)
        return nil;

    if (VMLLooksLikeKnownHost(view)) {
        return view;
    }

    for (UIView *child
         in view.subviews) {

        UIView *found =
            VMLFindKnownHostRecursive(
                child
            );

        if (found)
            return found;
    }

    return nil;
}

#pragma mark - Layer diagnostics

static NSString *VMLMaskDescription(
    CALayer *layer
) {
    if (!layer)
        return @"nil";

    CALayer *mask =
        layer.mask;

    if (!mask)
        return @"nil";

    return
        [NSString stringWithFormat:
            @"%@ frame=%@ bounds=%@ hidden=%d opacity=%.2f",
            NSStringFromClass(mask.class),
            NSStringFromCGRect(mask.frame),
            NSStringFromCGRect(mask.bounds),
            mask.hidden,
            mask.opacity];
}

static void VMLLogViewState(
    NSString *name,
    UIView *view
) {
    if (!view) {
        VMLLog(
            @"STATE %@ = nil",
            name
        );
        return;
    }

    CALayer *layer =
        view.layer;

    VMLLog(
        @"STATE %@ class=%@ frame=%@ bounds=%@ hidden=%d alpha=%.3f opaque=%d clips=%d userInteraction=%d window=%@",
        name,
        NSStringFromClass(view.class),
        NSStringFromCGRect(view.frame),
        NSStringFromCGRect(view.bounds),
        view.hidden,
        view.alpha,
        view.opaque,
        view.clipsToBounds,
        view.userInteractionEnabled,
        view.window
            ? NSStringFromClass(
                view.window.class
            )
            : @"nil"
    );

    VMLLog(
        @"LAYER %@ class=%@ frame=%@ bounds=%@ hidden=%d opacity=%.3f z=%.3f masksToBounds=%d mask=%@ sublayers=%lu",
        name,
        NSStringFromClass(layer.class),
        NSStringFromCGRect(layer.frame),
        NSStringFromCGRect(layer.bounds),
        layer.hidden,
        layer.opacity,
        layer.zPosition,
        layer.masksToBounds,
        VMLMaskDescription(layer),
        (unsigned long)
            layer.sublayers.count
    );
}

static void VMLLogSuperviewChain(
    UIView *view
) {
    UIView *current =
        view;

    NSInteger depth =
        0;

    while (current &&
           depth < 15) {

        VMLLog(
            @"CHAIN depth=%ld class=%@ frame=%@ bounds=%@ hidden=%d alpha=%.3f window=%@",
            (long)depth,
            NSStringFromClass(
                current.class
            ),
            NSStringFromCGRect(
                current.frame
            ),
            NSStringFromCGRect(
                current.bounds
            ),
            current.hidden,
            current.alpha,
            current.window
                ? NSStringFromClass(
                    current.window.class
                )
                : @"nil"
        );

        current =
            current.superview;

        depth++;
    }
}

#pragma mark - Marker

static void VMLAddMarker(
    UIView *target,
    NSInteger tag,
    NSString *text,
    CGRect frame,
    NSString *name
) {
    if (!target)
        return;

    UIView *existing =
        [target
            viewWithTag:
                tag];

    if (existing) {
        existing.layer.zPosition =
            CGFLOAT_MAX;

        [target
            bringSubviewToFront:
                existing];

        VMLLog(
            @"MARKER %@ already exists frame=%@",
            name,
            NSStringFromCGRect(
                existing.frame
            )
        );

        return;
    }

    gVMLAddingOwnView =
        YES;

    UIView *marker =
        VMLMakeCircle(
            text,
            frame.size.width
        );

    marker.tag =
        tag;

    marker.frame =
        frame;

    marker.hidden =
        NO;

    marker.alpha =
        1.0;

    marker.layer.hidden =
        NO;

    marker.layer.opacity =
        1.0;

    marker.layer.zPosition =
        CGFLOAT_MAX;

    [target addSubview:
        marker];

    [target bringSubviewToFront:
        marker];

    gVMLAddingOwnView =
        NO;

    VMLLog(
        @"*** MARKER %@ ADDED target=%@ targetFrame=%@ markerFrame=%@ targetHidden=%d targetAlpha=%.2f targetLayerHidden=%d targetLayerOpacity=%.2f ***",
        name,
        NSStringFromClass(
            target.class
        ),
        NSStringFromCGRect(
            target.frame
        ),
        NSStringFromCGRect(
            marker.frame
        ),
        target.hidden,
        target.alpha,
        target.layer.hidden,
        target.layer.opacity
    );
}

#pragma mark - Install three markers

static void VMLInstallDiagnosticMarkers(
    UIView *host
) {
    if (!host)
        return;

    UIView *parent =
        host.superview;

    UIWindow *root =
        host.window;

    if (!VMLIsCarPlayRootWindow(root))
        return;

    gVMLKnownHost =
        host;

    VMLLog(
        @"================================================"
    );

    VMLLog(
        @"*** V8 DIAGNOSTIC HOST FOUND ***"
    );

    VMLLogViewState(
        @"HOST",
        host
    );

    VMLLogViewState(
        @"PARENT",
        parent
    );

    VMLLogViewState(
        @"ROOT",
        root
    );

    VMLLogSuperviewChain(
        host
    );

    /*
     71 = host
     72 = parent
     73 = root
    */

    VMLAddMarker(
        host,
        kVMLMarker71Tag,
        @"71",
        CGRectMake(
            62,
            122,
            46,
            46
        ),
        @"71-HOST"
    );

    if (parent) {
        VMLAddMarker(
            parent,
            kVMLMarker72Tag,
            @"72",
            CGRectMake(
                120,
                122,
                46,
                46
            ),
            @"72-PARENT"
        );
    }

    VMLAddMarker(
        root,
        kVMLMarker73Tag,
        @"73",
        CGRectMake(
            178,
            122,
            46,
            46
        ),
        @"73-ROOT"
    );

    gVMLDiagnosticInstalled =
        YES;

    VMLLog(
        @"*** V8 THREE MARKERS INSTALLED ***"
    );
}

#pragma mark - Inspect root

static void VMLInspectRoot(
    UIWindow *window,
    NSString *reason
) {
    if (!VMLIsCarPlayRootWindow(window))
        return;

    gVMLCarPlayWindow =
        window;

    VMLLog(
        @"*** INSPECT ROOT reason=%@ frame=%@ bounds=%@ hidden=%d alpha=%.2f subviews=%lu ***",
        reason,
        NSStringFromCGRect(
            window.frame
        ),
        NSStringFromCGRect(
            window.bounds
        ),
        window.hidden,
        window.alpha,
        (unsigned long)
            window.subviews.count
    );

    UIView *host =
        VMLFindKnownHostRecursive(
            window
        );

    if (!host) {
        VMLLog(
            @"*** V8 KNOWN HOST NOT FOUND ***"
        );

        return;
    }

    VMLLog(
        @"*** V8 KNOWN HOST FOUND class=%@ frame=%@ bounds=%@ parent=%@ ***",
        NSStringFromClass(
            host.class
        ),
        NSStringFromCGRect(
            host.frame
        ),
        NSStringFromCGRect(
            host.bounds
        ),
        host.superview
            ? NSStringFromClass(
                host.superview.class
            )
            : @"nil"
    );

    VMLInstallDiagnosticMarkers(
        host
    );
}

#pragma mark - Capture CarPlay root

static void VMLCaptureRoot(
    UIWindow *window,
    NSString *reason
) {
    if (!VMLIsSpringBoard())
        return;

    if (!VMLIsCarPlayRootWindow(window))
        return;

    BOOL changed =
        gVMLCarPlayWindow != window;

    if (changed) {
        gVMLDiagnosticInstalled =
            NO;

        gVMLKnownHost =
            nil;
    }

    gVMLCarPlayWindow =
        window;

    VMLLog(
        @"*** CARPLAY ROOT CAPTURED reason=%@ class=%@ frame=%@ bounds=%@ hidden=%d alpha=%.2f level=%f changed=%d ***",
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
        window.hidden,
        window.alpha,
        window.windowLevel,
        changed
    );

    if (gVMLInspectScheduled)
        return;

    gVMLInspectScheduled =
        YES;

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            100 * NSEC_PER_MSEC
        ),
        dispatch_get_main_queue(),
        ^{
            gVMLInspectScheduled =
                NO;

            UIWindow *w =
                gVMLCarPlayWindow;

            if (!w)
                return;

            VMLInspectRoot(
                w,
                @"capture+100ms"
            );
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
                gVMLCarPlayWindow;

            if (!w)
                return;

            VMLInspectRoot(
                w,
                @"capture+1s"
            );
        }
    );

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            3 * NSEC_PER_SEC
        ),
        dispatch_get_main_queue(),
        ^{
            UIWindow *w =
                gVMLCarPlayWindow;

            if (!w)
                return;

            VMLInspectRoot(
                w,
                @"capture+3s"
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

    if (gVMLAddingOwnView)
        return;

    UIWindow *window =
        self.window;

    if (!window)
        return;

    if (!VMLIsCarPlayRootWindow(window))
        return;

    NSString *className =
        NSStringFromClass(
            self.class
        );

    /*
     Không spam mọi view.
     Chỉ log view lớn hoặc view đáng chú ý.
    */

    BOOL interesting =
        self.bounds.size.width > 400.0 ||
        [className
            containsString:
                @"VisualEffect"] ||
        [className
            containsString:
                @"Presentation"] ||
        [className
            containsString:
                @"Scene"];

    if (interesting) {
        VMLLog(
            @"DIDMOVE view=%@ frame=%@ bounds=%@ super=%@ windowHidden=%d",
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

#pragma mark - Phone bubble

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
        VMLMakeCircle(
            VMLSpeedText(),
            size
        );

    bubble.tag =
        kVMLPhoneBubbleTag;

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
            @"VML CARPLAY 3-LAYER DIAGNOSTIC V8"
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
            @"V8 ACTIVE"
        );
    }
}
