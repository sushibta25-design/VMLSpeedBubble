#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

#pragma mark - Globals

static UIWindow *gPhoneWindow = nil;
static BOOL gVMLAddingOwnView = NO;

static const NSInteger kVMLTestTag = 990099;

#pragma mark - Logging

static void VMLLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);

    NSString *msg =
        [[NSString alloc] initWithFormat:format
                              arguments:args];

    va_end(args);

    NSString *line =
        [NSString stringWithFormat:
            @"%@\n", msg];

    NSLog(@"[VMLHOST] %@", msg);

    const char *path =
        "/var/mobile/VMLHostSniffer.txt";

    FILE *f = fopen(path, "a");

    if (f) {
        fprintf(f, "%s",
                [line UTF8String]);
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

#pragma mark - Bubble creator

static UIView *VMLMakeBubble(NSString *text,
                             CGFloat size)
{
    UIView *bubble =
        [[UIView alloc]
            initWithFrame:
                CGRectMake(0, 0, size, size)];

    bubble.backgroundColor =
        UIColor.whiteColor;

    bubble.layer.cornerRadius =
        size / 2.0;

    bubble.layer.borderWidth =
        5.0;

    bubble.layer.borderColor =
        UIColor.systemRedColor.CGColor;

    bubble.clipsToBounds = YES;

    bubble.userInteractionEnabled = NO;

    UILabel *label =
        [[UILabel alloc]
            initWithFrame:bubble.bounds];

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

    [bubble addSubview:label];

    return bubble;
}

#pragma mark - Host inspection

static NSString *VMLViewChain(UIView *view) {
    NSMutableArray *parts =
        [NSMutableArray array];

    UIView *current = view;

    NSInteger count = 0;

    while (current &&
           count < 12) {

        NSString *part =
            [NSString stringWithFormat:
                @"%@ %@",
                NSStringFromClass(current.class),
                NSStringFromCGRect(current.frame)];

        [parts addObject:part];

        current =
            current.superview;

        count++;
    }

    return
        [parts componentsJoinedByString:
            @" -> "];
}

static void VMLDumpHost(UIView *host,
                        UIView *duoBubble)
{
    UIWindow *window =
        host.window;

    UIViewController *root =
        window.rootViewController;

    NSString *windowClass =
        window
        ? NSStringFromClass(window.class)
        : @"nil";

    NSString *rootClass =
        root
        ? NSStringFromClass(root.class)
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
        NSStringFromClass(host.class)
    );

    VMLLog(
        @"HOST FRAME = %@",
        NSStringFromCGRect(host.frame)
    );

    VMLLog(
        @"HOST BOUNDS = %@",
        NSStringFromCGRect(host.bounds)
    );

    VMLLog(
        @"DUO BUBBLE FRAME = %@",
        NSStringFromCGRect(duoBubble.frame)
    );

    VMLLog(
        @"WINDOW CLASS = %@",
        windowClass
    );

    VMLLog(
        @"WINDOW FRAME = %@",
        window
            ? NSStringFromCGRect(window.frame)
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
        VMLViewChain(host)
    );

    VMLLog(
        @"========================================"
    );
}

#pragma mark - Put 99 beside DuoDash

static void VMLAttach99ToDuoHost(
    UIView *host,
    UIView *duoBubble)
{
    if (!host ||
        !duoBubble)
        return;

    if ([host
            viewWithTag:kVMLTestTag])
        return;

    gVMLAddingOwnView = YES;

    CGFloat size = 46.0;

    UIView *bubble =
        VMLMakeBubble(@"99", size);

    bubble.tag =
        kVMLTestTag;

    /*
     Try to place 99 near DuoDash's own
     bubble, but keep it inside host bounds.
    */

    CGRect duoFrame =
        duoBubble.frame;

    CGFloat x =
        CGRectGetMaxX(duoFrame) + 8.0;

    CGFloat y =
        CGRectGetMinY(duoFrame);

    if (x + size >
        host.bounds.size.width) {

        x =
            CGRectGetMinX(duoFrame)
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

    [host bringSubviewToFront:bubble];

    gVMLAddingOwnView = NO;

    VMLLog(
        @"99 ADDED host=%@ frame=%@",
        NSStringFromClass(host.class),
        NSStringFromCGRect(bubble.frame)
    );
}

#pragma mark - IMPORTANT HOOK

%hook UIView

- (void)addSubview:(UIView *)view {

    %orig;

    if (!VMLIsCarPlay())
        return;

    if (gVMLAddingOwnView)
        return;

    if (!view)
        return;

    NSString *className =
        NSStringFromClass(view.class);

    /*
     This is the key:
     detect DuoDash's real CarPlay bubble.
    */

    if (![className
            isEqualToString:
                @"CNABBubbleView"]) {

        return;
    }

    UIView *host =
        view.superview;

    VMLLog(
        @"INTERCEPTED CNABBubbleView"
    );

    VMLDumpHost(
        host,
        view
    );

    dispatch_async(
        dispatch_get_main_queue(),
        ^{

        VMLAttach99ToDuoHost(
            host,
            view
        );

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                1 * NSEC_PER_SEC),
            dispatch_get_main_queue(),
            ^{

            UIView *test =
                [host
                    viewWithTag:
                        kVMLTestTag];

            if (test) {
                test.layer.zPosition =
                    CGFLOAT_MAX;

                [host
                    bringSubviewToFront:
                        test];

                VMLLog(
                    @"99 RE-BROUGHT TO FRONT"
                );
            }
        });
    });
}

%end

#pragma mark - iPhone test bubble 50

static UIWindowScene *VMLPhoneScene(void) {
    for (UIScene *scene
         in UIApplication
            .sharedApplication
            .connectedScenes) {

        if (![scene
                isKindOfClass:
                    UIWindowScene.class])
            continue;

        UIWindowScene *ws =
            (UIWindowScene *)scene;

        NSString *role =
            ws.session.role ?: @"";

        if ([role
                containsString:
                    @"CarPlay"])
            continue;

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
            @"50",
            size
        );

    bubble.userInteractionEnabled =
        NO;

    [vc.view addSubview:bubble];

    gPhoneWindow.hidden = NO;
}

#pragma mark - Constructor

%ctor {
    @autoreleasepool {

        NSString *bundle =
            NSBundle.mainBundle
                .bundleIdentifier ?: @"";

        NSString *process =
            NSProcessInfo
                .processInfo
                .processName ?: @"";

        VMLLog(
            @"Injected bundle=%@ process=%@",
            bundle,
            process
        );

        if (VMLIsSpringBoard()) {

            dispatch_after(
                dispatch_time(
                    DISPATCH_TIME_NOW,
                    3 * NSEC_PER_SEC),
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

            /*
             No UIWindow is created here.

             We wait for DuoDash itself
             to reveal the real host.
            */
        }
    }
}
