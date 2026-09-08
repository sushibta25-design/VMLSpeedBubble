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

    NSLog(@"[VMLV2] %@", msg);

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

#pragma mark - Bubble creation

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

    /*
     Không chặn thao tác trên CarPlay.
    */
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

    UIView *host =
        bubble.superview;

    if (host) {
        [host bringSubviewToFront:
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
                UIView *bubble =
                    [gPhoneWindow
                        viewWithTag:
                            kVMLBubbleTag];

                if (bubble) {
                    VMLUpdateBubble(
                        bubble
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

#pragma mark - Geometry helpers

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
            40.0
        ) &&
        VMLNear(
            size.height,
            240.0,
            40.0
        );

    BOOL portraitEquivalent =
        VMLNear(
            size.width,
            240.0,
            40.0
        ) &&
        VMLNear(
            size.height,
            640.0,
            40.0
        );

    return
        landscape ||
        portraitEquivalent;
}

static BOOL VMLLooksLikeKnownHostSize(
    CGSize size
) {
    /*
     Host đã đo thực tế:
     595 x 240
    */

    BOOL landscape =
        VMLNear(
            size.width,
            595.0,
            50.0
        ) &&
        VMLNear(
            size.height,
            240.0,
            40.0
        );

    return landscape;
}

#pragma mark - Hierarchy helpers

static UIView *VMLAncestorNamed(
    UIView *view,
    NSString *wantedClass
) {
    UIView *current =
        view;

    NSInteger count =
        0;

    while (current &&
           count < 30) {

        NSString *name =
            NSStringFromClass(
                current.class
            );

        if ([name isEqualToString:
                wantedClass]) {

            return current;
        }

        current =
            current.superview;

        count++;
    }

    return nil;
}

static UIWindow *VMLCarPlayRootWindowForView(
    UIView *view
) {
    if (!view)
        return nil;

    UIWindow *window =
        view.window;

    if (window) {
        NSString *windowClass =
            NSStringFromClass(
                window.class
            );

        if ([windowClass
                isEqualToString:
                    @"UIRootSceneWindow"] &&
            VMLLooksLikeCarPlaySize(
                window.bounds.size)) {

            return window;
        }
    }

    UIView *ancestor =
        VMLAncestorNamed(
            view,
            @"UIRootSceneWindow"
        );

    if (ancestor &&
        [ancestor isKindOfClass:
            UIWindow.class]) {

        UIWindow *root =
            (UIWindow *)ancestor;

        if (VMLLooksLikeCarPlaySize(
                root.bounds.size)) {

            return root;
        }
    }

    return nil;
}

#pragma mark - Host validation

static BOOL VMLHostLooksValid(
    UIView *host
) {
    if (!host)
        return NO;

    NSString *hostClass =
        NSStringFromClass(
            host.class
        );

    if (![hostClass
            isEqualToString:
                @"_UIVisualEffectContentView"]) {

        return NO;
    }

    /*
     Trường hợp tốt nhất:
     host đã nằm trong đúng root CarPlay.
    */

    UIWindow *window =
        VMLCarPlayRootWindowForView(
            host
        );

    if (window) {
        return YES;
    }

    /*
     Trường hợp host vừa được tạo,
     window chưa attach kịp.
     Cho phép dựa vào kích thước đã đo.
    */

    if (VMLLooksLikeKnownHostSize(
            host.bounds.size)) {

        UIView *parent =
            host.superview;

        if (parent) {
            NSString *parentClass =
                NSStringFromClass(
                    parent.class
                );

            if ([parentClass
                    isEqualToString:
                        @"UIVisualEffectView"]) {

                return YES;
            }
        }
    }

    return NO;
}

#pragma mark - Attach CarPlay bubble

static void VMLAttachToHost(
    UIView *host,
    NSString *reason
) {
    if (!VMLIsSpringBoard())
        return;

    if (!host)
        return;

    if (!VMLHostLooksValid(
            host)) {

        return;
    }

    if (gVMLCarPlayBubble &&
        gVMLCarPlayBubble.superview == host) {

        VMLUpdateBubble(
            gVMLCarPlayBubble
        );

        return;
    }

    /*
     Nếu host CarPlay đổi, bỏ bubble cũ.
    */

    if (gVMLCarPlayBubble &&
        gVMLCarPlayBubble.superview &&
        gVMLCarPlayBubble.superview != host) {

        VMLLog(
            @"CARPLAY HOST CHANGED old=%@ new=%@",
            NSStringFromClass(
                gVMLCarPlayBubble.superview.class
            ),
            NSStringFromClass(
                host.class
            )
        );

        [gVMLCarPlayBubble
            removeFromSuperview];

        gVMLCarPlayBubble =
            nil;

        gVMLCarPlayHost =
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

        VMLUpdateBubble(
            existing
        );

        VMLLog(
            @"EXISTING CARPLAY BUBBLE FOUND reason=%@",
            reason
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
     Giữ gần vị trí test đã thành công trước:
     host 595x240
     bubble cũ ở khoảng x=62, y=122.
    */

    CGFloat x =
        62.0;

    CGFloat y =
        122.0;

    CGFloat maxX =
        host.bounds.size.width
        - size
        - 6.0;

    CGFloat maxY =
        host.bounds.size.height
        - size
        - 6.0;

    if (maxX < 6.0)
        maxX = 6.0;

    if (maxY < 6.0)
        maxY = 6.0;

    if (x > maxX)
        x = maxX;

    if (y > maxY)
        y = maxY;

    if (x < 6.0)
        x = 6.0;

    if (y < 6.0)
        y = 6.0;

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

    UIWindow *root =
        VMLCarPlayRootWindowForView(
            host
        );

    VMLLog(
        @"*** CARPLAY BUBBLE ADDED reason=%@ host=%@ hostFrame=%@ window=%@ windowFrame=%@ speed=%ld text=%@ ***",
        reason,
        NSStringFromClass(
            host.class
        ),
        NSStringFromCGRect(
            host.frame
        ),
        root
            ? NSStringFromClass(
                root.class
            )
            : @"nil",
        root
            ? NSStringFromCGRect(
                root.frame
            )
            : @"nil",
        (long)gVMLCurrentSpeed,
        VMLSpeedText()
    );
}

#pragma mark - Probe candidate

static void VMLProbeView(
    UIView *view,
    NSString *reason
) {
    if (!VMLIsSpringBoard())
        return;

    if (!view)
        return;

    if (gVMLAddingOwnView)
        return;

    NSString *className =
        NSStringFromClass(
            view.class
        );

    /*
     Case 1:
     chính view là content host.
    */

    if ([className
            isEqualToString:
                @"_UIVisualEffectContentView"]) {

        if (VMLHostLooksValid(
                view)) {

            VMLLog(
                @"HOST CANDIDATE reason=%@ class=%@ frame=%@",
                reason,
                className,
                NSStringFromCGRect(
                    view.frame
                )
            );

            VMLAttachToHost(
                view,
                reason
            );

            return;
        }
    }

    /*
     Case 2:
     view nằm bên dưới content host.
    */

    UIView *content =
        VMLAncestorNamed(
            view,
            @"_UIVisualEffectContentView"
        );

    if (content &&
        VMLHostLooksValid(
            content)) {

        VMLAttachToHost(
            content,
            reason
        );

        return;
    }

    /*
     Case 3:
     UIVisualEffectView mới được dựng,
     lấy contentView của nó.
    */

    if ([view
            isKindOfClass:
                UIVisualEffectView.class]) {

        UIVisualEffectView *effect =
            (UIVisualEffectView *)view;

        UIView *effectContent =
            effect.contentView;

        if (effectContent &&
            VMLHostLooksValid(
                effectContent)) {

            VMLAttachToHost(
                effectContent,
                reason
            );

            return;
        }
    }
}

#pragma mark - Delayed probe

static void VMLProbeWithDelays(
    UIView *view,
    NSString *reason
) {
    if (!view)
        return;

    VMLProbeView(
        view,
        reason
    );

    __weak UIView *weakView =
        view;

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            100 * NSEC_PER_MSEC
        ),
        dispatch_get_main_queue(),
        ^{
            UIView *strongView =
                weakView;

            if (strongView) {
                VMLProbeView(
                    strongView,
                    [reason
                        stringByAppendingString:
                            @"+100ms"]
                );
            }
        }
    );

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            500 * NSEC_PER_MSEC
        ),
        dispatch_get_main_queue(),
        ^{
            UIView *strongView =
                weakView;

            if (strongView) {
                VMLProbeView(
                    strongView,
                    [reason
                        stringByAppendingString:
                            @"+500ms"]
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
            UIView *strongView =
                weakView;

            if (strongView) {
                VMLProbeView(
                    strongView,
                    [reason
                        stringByAppendingString:
                            @"+1s"]
                );
            }
        }
    );
}

#pragma mark - UIView lifecycle hook

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
     ĐƯỜNG CHÍNH:
     bắt các lớp liên quan CarPlay host
     ngay lúc chúng được add.
    */

    BOOL interesting =
        [className
            isEqualToString:
                @"_UIVisualEffectContentView"] ||
        [className
            isEqualToString:
                @"UIVisualEffectView"] ||
        [className
            isEqualToString:
                @"UIRootSceneWindow"];

    if (interesting) {
        VMLLog(
            @"LIFECYCLE addSubview class=%@ frame=%@ super=%@",
            className,
            NSStringFromCGRect(
                view.frame
            ),
            view.superview
                ? NSStringFromClass(
                    view.superview.class
                )
                : @"nil"
        );

        VMLProbeWithDelays(
            view,
            @"addSubview"
        );
    }

    /*
     FALLBACK DUODASH:
     không dùng dữ liệu hay bubble của DuoDash.
     Chỉ nếu CNABBubbleView xuất hiện thì
     lấy superview đã được chứng minh là host.
    */

    if ([className
            isEqualToString:
                @"CNABBubbleView"]) {

        UIView *host =
            view.superview;

        VMLLog(
            @"DUODASH FALLBACK TRIGGER host=%@ frame=%@",
            host
                ? NSStringFromClass(
                    host.class
                )
                : @"nil",
            host
                ? NSStringFromCGRect(
                    host.frame
                )
                : @"nil"
        );

        if (host) {
            VMLAttachToHost(
                host,
                @"DuoDashFallback"
            );
        }
    }
}

- (void)didMoveToWindow {
    %orig;

    if (!VMLIsSpringBoard())
        return;

    if (gVMLAddingOwnView)
        return;

    NSString *className =
        NSStringFromClass(
            self.class
        );

    if ([className
            isEqualToString:
                @"_UIVisualEffectContentView"] ||
        [className
            isEqualToString:
                @"UIVisualEffectView"]) {

        VMLProbeWithDelays(
            self,
            @"didMoveToWindow"
        );
    }
}

%end

#pragma mark - UIWindow hook

%hook UIWindow

- (void)didMoveToScreen {
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
        @"WINDOW didMoveToScreen class=%@ frame=%@ bounds=%@",
        className,
        NSStringFromCGRect(
            self.frame
        ),
        NSStringFromCGRect(
            self.bounds
        )
    );

    /*
     Probe các subview hiện có.
    */

    for (UIView *child
         in self.subviews) {

        VMLProbeWithDelays(
            child,
            @"windowDidMoveToScreen"
        );
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

        CGSize size =
            ws.screen.bounds.size;

        /*
         Bỏ qua màn có kích thước giống CarPlay.
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
            @"VML HOST LIFECYCLE V2"
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
         Speed IPC đang chạy tốt,
         giữ nguyên.
        */
        VMLStartSpeedReceiver();

        /*
         Phone bubble test.
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
            @"CARPLAY LIFECYCLE HOOKS ACTIVE"
        );
    }
}
