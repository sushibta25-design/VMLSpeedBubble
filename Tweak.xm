#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <math.h>

#pragma mark - Globals

static UIWindow *gPhoneWindow = nil;

static NSInteger gCurrentSpeed = 0;
static int gSpeedNotifyToken = 0;

static BOOL gInstalledPresentationHook = NO;
static BOOL gInstalledSceneVCHook = NO;

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

    NSLog(@"[VMLV9.1] %@", msg);

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
        VMLNear(
            size.width,
            640.0,
            60.0
        ) &&
        VMLNear(
            size.height,
            240.0,
            60.0
        );

    BOOL rotated =
        VMLNear(
            size.width,
            240.0,
            60.0
        ) &&
        VMLNear(
            size.height,
            640.0,
            60.0
        );

    return landscape || rotated;
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

#pragma mark - Safe dynamic getters

static id VMLCallObjectGetter(
    id object,
    NSString *selectorName
) {
    if (!object)
        return nil;

    SEL selector =
        NSSelectorFromString(
            selectorName
        );

    if (![object
            respondsToSelector:
                selector]) {

        return nil;
    }

    return
        ((id (*)(id, SEL))
         objc_msgSend)(
            object,
            selector
        );
}

static void VMLLogObjectGetter(
    NSString *prefix,
    id object,
    NSString *selectorName
) {
    id value =
        VMLCallObjectGetter(
            object,
            selectorName
        );

    if (!value)
        return;

    VMLLog(
        @"%@ getter=%@ valueClass=%@ value=%@",
        prefix,
        selectorName,
        NSStringFromClass(
            [value class]
        ),
        value
    );
}

#pragma mark - Screen / window diagnostics

static void VMLLogScreen(
    NSString *prefix,
    UIScreen *screen
) {
    if (!screen) {
        VMLLog(
            @"%@ SCREEN=nil",
            prefix
        );

        return;
    }

    VMLLog(
        @"%@ SCREEN class=%@ bounds=%@ nativeBounds=%@ scale=%.3f nativeScale=%.3f",
        prefix,
        NSStringFromClass(
            screen.class
        ),
        NSStringFromCGRect(
            screen.bounds
        ),
        NSStringFromCGRect(
            screen.nativeBounds
        ),
        screen.scale,
        screen.nativeScale
    );

    if (VMLLooksLikeCarPlaySize(
            screen.bounds.size)) {

        VMLLog(
            @"*** %@ SCREEN LOOKS LIKE CARPLAY ***",
            prefix
        );
    }
}

static void VMLLogWindow(
    NSString *prefix,
    UIWindow *window
) {
    if (!window) {
        VMLLog(
            @"%@ WINDOW=nil",
            prefix
        );

        return;
    }

    NSString *role =
        @"nil";

    UIWindowScene *windowScene =
        window.windowScene;

    if (windowScene &&
        windowScene.session) {

        role =
            windowScene.session.role
            ?: @"nil";
    }

    VMLLog(
        @"%@ WINDOW class=%@ frame=%@ bounds=%@ hidden=%d alpha=%.3f level=%f role=%@",
        prefix,
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
        role
    );

    VMLLogScreen(
        prefix,
        window.screen
    );
}

#pragma mark - View chain

static void VMLLogViewChain(
    UIView *view,
    NSString *prefix
) {
    UIView *current =
        view;

    NSInteger depth =
        0;

    while (current &&
           depth < 18) {

        VMLLog(
            @"%@ CHAIN depth=%ld class=%@ frame=%@ bounds=%@ hidden=%d alpha=%.3f super=%@ window=%@",
            prefix,
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
            current.superview
                ? NSStringFromClass(
                    current.superview.class
                )
                : @"nil",
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

#pragma mark - Presentation diagnostics

static void VMLInspectPresentationView(
    UIView *view,
    NSString *reason
) {
    if (!view)
        return;

    UIWindow *window =
        view.window;

    VMLLog(
        @"================================================"
    );

    VMLLog(
        @"*** PRESENTATION INSTANCE reason=%@ class=%@ frame=%@ bounds=%@ hidden=%d alpha=%.3f super=%@ ***",
        reason,
        NSStringFromClass(
            view.class
        ),
        NSStringFromCGRect(
            view.frame
        ),
        NSStringFromCGRect(
            view.bounds
        ),
        view.hidden,
        view.alpha,
        view.superview
            ? NSStringFromClass(
                view.superview.class
            )
            : @"nil"
    );

    VMLLogWindow(
        @"PRESENTATION",
        window
    );

    VMLLogViewChain(
        view,
        @"PRESENTATION"
    );

    VMLLogObjectGetter(
        @"PRESENTATION",
        view,
        @"scene"
    );

    VMLLogObjectGetter(
        @"PRESENTATION",
        view,
        @"screen"
    );

    VMLLogObjectGetter(
        @"PRESENTATION",
        view,
        @"display"
    );

    VMLLogObjectGetter(
        @"PRESENTATION",
        view,
        @"displayConfiguration"
    );

    if (window) {
        VMLLogObjectGetter(
            @"WINDOW",
            window,
            @"scene"
        );

        VMLLogObjectGetter(
            @"WINDOW",
            window,
            @"screen"
        );

        VMLLogObjectGetter(
            @"WINDOW",
            window,
            @"display"
        );

        VMLLogObjectGetter(
            @"WINDOW",
            window,
            @"displayConfiguration"
        );
    }

    BOOL viewLooksCarPlay =
        VMLLooksLikeCarPlaySize(
            view.bounds.size
        );

    BOOL windowLooksCarPlay =
        window &&
        VMLLooksLikeCarPlaySize(
            window.bounds.size
        );

    BOOL screenLooksCarPlay =
        window &&
        window.screen &&
        VMLLooksLikeCarPlaySize(
            window.screen.bounds.size
        );

    if (viewLooksCarPlay ||
        windowLooksCarPlay ||
        screenLooksCarPlay) {

        VMLLog(
            @"************************************************"
        );

        VMLLog(
            @"*** POSSIBLE CARPLAY PRESENTATION MATCH ***"
        );

        VMLLog(
            @"viewMatch=%d windowMatch=%d screenMatch=%d",
            viewLooksCarPlay,
            windowLooksCarPlay,
            screenLooksCarPlay
        );

        VMLLog(
            @"************************************************"
        );
    }
}

#pragma mark - Scene VC diagnostics

static void VMLInspectSceneVC(
    UIViewController *vc,
    NSString *reason
) {
    if (!vc)
        return;

    UIView *view =
        vc.view;

    UIWindow *window =
        view.window;

    VMLLog(
        @"================================================"
    );

    VMLLog(
        @"*** SCENE VC INSTANCE reason=%@ class=%@ view=%@ frame=%@ ***",
        reason,
        NSStringFromClass(
            vc.class
        ),
        view
            ? NSStringFromClass(
                view.class
            )
            : @"nil",
        view
            ? NSStringFromCGRect(
                view.frame
            )
            : @"nil"
    );

    VMLLogWindow(
        @"SCENEVC",
        window
    );

    if (view) {
        VMLLogViewChain(
            view,
            @"SCENEVC"
        );
    }

    VMLLogObjectGetter(
        @"SCENEVC",
        vc,
        @"scene"
    );

    VMLLogObjectGetter(
        @"SCENEVC",
        vc,
        @"screen"
    );

    VMLLogObjectGetter(
        @"SCENEVC",
        vc,
        @"display"
    );

    VMLLogObjectGetter(
        @"SCENEVC",
        vc,
        @"displayConfiguration"
    );
}

#pragma mark - Runtime hook IMPs

static IMP gOrigPresentationDidMove = NULL;

static void VMLPresentationDidMove(
    id self,
    SEL _cmd
) {
    if (gOrigPresentationDidMove) {
        ((void (*)(id, SEL))
         gOrigPresentationDidMove)(
            self,
            _cmd
        );
    }

    if (!VMLIsSpringBoard())
        return;

    if (![self
            isKindOfClass:
                UIView.class]) {

        return;
    }

    UIView *view =
        (UIView *)self;

    VMLInspectPresentationView(
        view,
        @"_UIScenePresentationView.didMoveToWindow"
    );
}

static IMP gOrigSceneVCViewDidAppear = NULL;

static void VMLSceneVCViewDidAppear(
    id self,
    SEL _cmd,
    BOOL animated
) {
    if (gOrigSceneVCViewDidAppear) {
        ((void (*)(id, SEL, BOOL))
         gOrigSceneVCViewDidAppear)(
            self,
            _cmd,
            animated
        );
    }

    if (!VMLIsSpringBoard())
        return;

    if (![self
            isKindOfClass:
                UIViewController.class]) {

        return;
    }

    VMLInspectSceneVC(
        (UIViewController *)self,
        @"viewDidAppear:"
    );
}

#pragma mark - Install hooks

static void VMLInstallPrivateHooks(void) {
    if (!VMLIsSpringBoard())
        return;

    Class presentationClass =
        objc_getClass(
            "_UIScenePresentationView"
        );

    if (presentationClass) {
        if (!gInstalledPresentationHook) {
            SEL selector =
                @selector(didMoveToWindow);

            Method method =
                class_getInstanceMethod(
                    presentationClass,
                    selector
                );

            if (method) {
                IMP current =
                    method_getImplementation(
                        method
                    );

                if (current !=
                    (IMP)VMLPresentationDidMove) {

                    gOrigPresentationDidMove =
                        current;

                    method_setImplementation(
                        method,
                        (IMP)VMLPresentationDidMove
                    );

                    gInstalledPresentationHook =
                        YES;

                    VMLLog(
                        @"HOOKED _UIScenePresentationView didMoveToWindow"
                    );
                }
            } else {
                VMLLog(
                    @"_UIScenePresentationView didMoveToWindow method missing"
                );
            }
        }
    } else {
        VMLLog(
            @"_UIScenePresentationView class not loaded"
        );
    }

    Class sceneVCClass =
        objc_getClass(
            "SBDeviceApplicationSceneViewController"
        );

    if (sceneVCClass) {
        if (!gInstalledSceneVCHook) {
            SEL selector =
                @selector(viewDidAppear:);

            Method method =
                class_getInstanceMethod(
                    sceneVCClass,
                    selector
                );

            if (method) {
                IMP current =
                    method_getImplementation(
                        method
                    );

                if (current !=
                    (IMP)VMLSceneVCViewDidAppear) {

                    gOrigSceneVCViewDidAppear =
                        current;

                    method_setImplementation(
                        method,
                        (IMP)VMLSceneVCViewDidAppear
                    );

                    gInstalledSceneVCHook =
                        YES;

                    VMLLog(
                        @"HOOKED SBDeviceApplicationSceneViewController viewDidAppear:"
                    );
                }
            } else {
                VMLLog(
                    @"SBDeviceApplicationSceneViewController viewDidAppear: missing"
                );
            }
        }
    } else {
        VMLLog(
            @"SBDeviceApplicationSceneViewController class not loaded"
        );
    }
}

#pragma mark - Generic fallback

%hook UIView

- (void)didMoveToWindow {
    %orig;

    if (!VMLIsSpringBoard())
        return;

    NSString *className =
        NSStringFromClass(
            self.class
        );

    BOOL interesting =
        [className
            containsString:
                @"ScenePresentation"] ||
        [className
            containsString:
                @"ApplicationScene"] ||
        [className
            containsString:
                @"PresentationView"];

    if (!interesting)
        return;

    /*
     _UIScenePresentationView đã có runtime hook riêng,
     tránh log hai lần.
    */

    if ([className
            isEqualToString:
                @"_UIScenePresentationView"]) {

        return;
    }

    VMLInspectPresentationView(
        self,
        @"generic.didMoveToWindow"
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
            @"VML PRESENTATION SCREEN MAPPER V9.1"
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

        VMLInstallPrivateHooks();

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                1 * NSEC_PER_SEC
            ),
            dispatch_get_main_queue(),
            ^{
                VMLInstallPrivateHooks();
            }
        );

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                3 * NSEC_PER_SEC
            ),
            dispatch_get_main_queue(),
            ^{
                VMLInstallPrivateHooks();
                VMLCreatePhoneBubble();
            }
        );

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                6 * NSEC_PER_SEC
            ),
            dispatch_get_main_queue(),
            ^{
                VMLInstallPrivateHooks();
            }
        );

        VMLLog(
            @"V9.1 ACTIVE"
        );
    }
}
