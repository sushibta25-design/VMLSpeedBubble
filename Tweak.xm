#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <QuartzCore/QuartzCore.h>

#pragma mark - Globals

static UIWindow *gIPhoneWindow = nil;
static UILabel *gIPhoneLabel = nil;
static UIView *gIPhoneBubble = nil;

static CGFloat kIPhoneBubbleSize = 64.0;
static CGFloat kCarPlayBubbleSize = 46.0;

static NSMutableArray<UIView *> *gCarPlayTestBubbles = nil;

#pragma mark - Helpers

static BOOL VMLIsSpringBoard(void) {
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"";
    return [bundle isEqualToString:@"com.apple.springboard"];
}

static BOOL VMLIsCarPlayProcess(void) {
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"";
    return [bundle isEqualToString:@"com.apple.CarPlayApp"];
}

static UIView *VMLCreateCircle(NSString *text,
                               CGFloat size,
                               CGPoint origin)
{
    UIView *bubble =
        [[UIView alloc] initWithFrame:
            CGRectMake(origin.x,
                       origin.y,
                       size,
                       size)];

    bubble.backgroundColor = UIColor.whiteColor;
    bubble.layer.cornerRadius = size / 2.0;
    bubble.layer.borderWidth = MAX(4.0, size * 0.09);
    bubble.layer.borderColor = UIColor.systemRedColor.CGColor;
    bubble.clipsToBounds = YES;

    UILabel *label =
        [[UILabel alloc] initWithFrame:bubble.bounds];

    label.autoresizingMask =
        UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;

    label.text = text;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = UIColor.blackColor;

    label.font =
        [UIFont systemFontOfSize:size * 0.40
                         weight:UIFontWeightBold];

    [bubble addSubview:label];

    return bubble;
}

#pragma mark - iPhone Bubble

@interface VMLBubbleController : NSObject
- (void)handlePan:(UIPanGestureRecognizer *)pan;
@end

@implementation VMLBubbleController

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if (!gIPhoneWindow)
        return;

    CGPoint translation =
        [pan translationInView:gIPhoneWindow];

    CGRect frame = gIPhoneWindow.frame;

    frame.origin.x += translation.x;
    frame.origin.y += translation.y;

    CGRect screen =
        UIScreen.mainScreen.bounds;

    frame.origin.x =
        MAX(0,
            MIN(screen.size.width - frame.size.width,
                frame.origin.x));

    frame.origin.y =
        MAX(30,
            MIN(screen.size.height - frame.size.height,
                frame.origin.y));

    gIPhoneWindow.frame = frame;

    [pan setTranslation:CGPointZero
                 inView:gIPhoneWindow];
}

@end

static VMLBubbleController *gBubbleController = nil;

static UIWindowScene *VMLGetIPhoneScene(void) {
    for (UIScene *scene
         in UIApplication.sharedApplication.connectedScenes) {

        if (![scene isKindOfClass:[UIWindowScene class]])
            continue;

        UIWindowScene *ws =
            (UIWindowScene *)scene;

        NSString *role =
            ws.session.role ?: @"";

        if ([role containsString:@"CarPlay"])
            continue;

        if (scene.activationState ==
            UISceneActivationStateUnattached)
            continue;

        return ws;
    }

    return nil;
}

static void VMLCreateIPhoneBubble(void) {
    if (gIPhoneWindow)
        return;

    UIWindowScene *scene =
        VMLGetIPhoneScene();

    if (!scene)
        return;

    CGFloat size =
        kIPhoneBubbleSize;

    gIPhoneWindow =
        [[UIWindow alloc]
            initWithWindowScene:scene];

    gIPhoneWindow.frame =
        CGRectMake(18,
                   110,
                   size,
                   size);

    gIPhoneWindow.backgroundColor =
        UIColor.clearColor;

    gIPhoneWindow.windowLevel =
        UIWindowLevelAlert + 1000.0;

    UIViewController *vc =
        [UIViewController new];

    vc.view.backgroundColor =
        UIColor.clearColor;

    gIPhoneWindow.rootViewController =
        vc;

    gIPhoneBubble =
        VMLCreateCircle(@"50",
                        size,
                        CGPointZero);

    gIPhoneLabel =
        (UILabel *)gIPhoneBubble.subviews.firstObject;

    gIPhoneBubble.userInteractionEnabled =
        YES;

    gBubbleController =
        [VMLBubbleController new];

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc]
            initWithTarget:gBubbleController
                    action:@selector(handlePan:)];

    [gIPhoneBubble addGestureRecognizer:pan];

    [vc.view addSubview:gIPhoneBubble];

    gIPhoneWindow.hidden = NO;

    NSLog(@"[VMLTEST] iPhone bubble created");
}

#pragma mark - CarPlay Test

static BOOL VMLViewAlreadyHasTag(UIView *view,
                                 NSInteger tag)
{
    if (!view)
        return YES;

    return [view viewWithTag:tag] != nil;
}

static void VMLAddTestBubble(UIView *host,
                             NSString *number,
                             NSInteger tag,
                             CGPoint point,
                             NSString *targetName)
{
    if (!host)
        return;

    if (VMLViewAlreadyHasTag(host, tag))
        return;

    CGFloat size =
        kCarPlayBubbleSize;

    UIView *bubble =
        VMLCreateCircle(number,
                        size,
                        point);

    bubble.tag = tag;

    // Test only: don't block CarPlay touches
    bubble.userInteractionEnabled = NO;

    [host addSubview:bubble];

    [host bringSubviewToFront:bubble];

    if (!gCarPlayTestBubbles)
        gCarPlayTestBubbles =
            [NSMutableArray array];

    [gCarPlayTestBubbles
        addObject:bubble];

    NSLog(
        @"[VMLTEST] ADDED %@ target=%@ host=%@ frame=%@",
        number,
        targetName,
        NSStringFromClass(host.class),
        NSStringFromCGRect(host.bounds)
    );
}

static void VMLRunCarPlayMultiTest(void) {
    if (!VMLIsCarPlayProcess())
        return;

    dispatch_async(
        dispatch_get_main_queue(),
        ^{

        UIApplication *app =
            UIApplication.sharedApplication;

        NSLog(
            @"[VMLTEST] ===== CARPLAY MULTI TEST ====="
        );

        for (UIScene *scene in app.connectedScenes) {

            if (![scene
                    isKindOfClass:[UIWindowScene class]])
                continue;

            UIWindowScene *ws =
                (UIWindowScene *)scene;

            NSString *role =
                ws.session.role ?: @"";

            if (![role containsString:@"CarPlay"])
                continue;

            NSLog(
                @"[VMLTEST] CarPlay scene role=%@ screen=%@",
                role,
                NSStringFromCGRect(ws.screen.bounds)
            );

            for (UIWindow *window in ws.windows) {

                NSString *windowClass =
                    NSStringFromClass(window.class);

                UIViewController *root =
                    window.rootViewController;

                NSString *rootClass =
                    root
                    ? NSStringFromClass(root.class)
                    : @"";

                NSLog(
                    @"[VMLTEST] window=%@ root=%@ frame=%@ hidden=%d level=%.1f",
                    windowClass,
                    rootClass,
                    NSStringFromCGRect(window.frame),
                    window.hidden,
                    window.windowLevel
                );

                /*
                 * TEST 51
                 *
                 * Directly inside
                 * DBDashboardRootViewController.view
                 */

                if ([rootClass
                        isEqualToString:
                            @"DBDashboardRootViewController"]) {

                    UIView *rootView =
                        root.view;

                    VMLAddTestBubble(
                        rootView,
                        @"51",
                        510051,
                        CGPointMake(12, 12),
                        @"DBDashboardRootVC.view"
                    );

                    /*
                     * TEST 52
                     *
                     * Directly on dashboard UIWindow
                     */

                    VMLAddTestBubble(
                        window,
                        @"52",
                        510052,
                        CGPointMake(70, 12),
                        @"Dashboard UIWindow"
                    );
                }

                /*
                 * TEST 53
                 *
                 * DBNotificationWindow
                 */

                if ([windowClass
                        containsString:
                            @"DBNotificationWindow"]) {

                    VMLAddTestBubble(
                        window,
                        @"53",
                        510053,
                        CGPointMake(128, 12),
                        @"DBNotificationWindow"
                    );
                }

                /*
                 * TEST 54
                 *
                 * DBCornerRadiusWindow
                 */

                if ([windowClass
                        containsString:
                            @"DBCornerRadiusWindow"]) {

                    VMLAddTestBubble(
                        window,
                        @"54",
                        510054,
                        CGPointMake(186, 12),
                        @"DBCornerRadiusWindow"
                    );
                }
            }
        }

        NSLog(
            @"[VMLTEST] ===== TEST FINISHED ====="
        );
    });
}

#pragma mark - Speed IPC

static NSInteger VMLFindSpeed(id obj) {
    if (!obj ||
        obj == [NSNull null])
        return -1;

    if ([obj
            isKindOfClass:[NSDictionary class]]) {

        NSDictionary *dict =
            (NSDictionary *)obj;

        for (id key in dict) {

            NSString *k =
                [[key description]
                    lowercaseString];

            id value =
                dict[key];

            BOOL match =
                [k containsString:@"speedlimit"] ||
                [k containsString:@"speed_limit"] ||
                [k containsString:@"maxspeed"];

            if (match &&
                [value
                    respondsToSelector:
                        @selector(integerValue)]) {

                NSInteger v =
                    [value integerValue];

                if (v >= 5 &&
                    v <= 200)
                    return v;
            }

            NSInteger nested =
                VMLFindSpeed(value);

            if (nested > 0 &&
                ([k containsString:@"speed"] ||
                 [k containsString:@"limit"] ||
                 [k containsString:@"road"] ||
                 [k containsString:@"warning"])) {

                return nested;
            }
        }
    }

    if ([obj
            isKindOfClass:[NSArray class]]) {

        for (id item in (NSArray *)obj) {

            NSInteger v =
                VMLFindSpeed(item);

            if (v > 0)
                return v;
        }
    }

    return -1;
}

static void VMLSendSpeed(NSInteger speed) {
    if (speed < 5 ||
        speed > 200)
        return;

    NSString *name =
        [NSString stringWithFormat:
            @"com.sushibta.vmlspeedbubble.speed.%ld",
            (long)speed];

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)name,
        NULL,
        NULL,
        true
    );
}

static void VMLSetIPhoneSpeed(NSInteger speed) {
    dispatch_async(
        dispatch_get_main_queue(),
        ^{

        if (!gIPhoneLabel)
            return;

        gIPhoneLabel.text =
            [NSString stringWithFormat:
                @"%ld",
                (long)speed];
    });
}

static void VMLCallback(
    CFNotificationCenterRef center,
    void *observer,
    CFStringRef name,
    const void *object,
    CFDictionaryRef userInfo)
{
    NSString *n =
        (__bridge NSString *)name;

    NSString *prefix =
        @"com.sushibta.vmlspeedbubble.speed.";

    if (![n hasPrefix:prefix])
        return;

    NSInteger speed =
        [[n substringFromIndex:
            prefix.length]
            integerValue];

    VMLSetIPhoneSpeed(speed);
}

static void VMLRegister(void) {
    for (NSInteger speed = 5;
         speed <= 200;
         speed += 5) {

        NSString *name =
            [NSString stringWithFormat:
                @"com.sushibta.vmlspeedbubble.speed.%ld",
                (long)speed];

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            VMLCallback,
            (__bridge CFStringRef)name,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );
    }
}

#pragma mark - VietMap Flutter hook

%hook FlutterMethodChannel

- (void)invokeMethod:(NSString *)method
           arguments:(id)arguments {

    NSString *lower =
        method.lowercaseString;

    if ([lower containsString:@"speed"] ||
        [lower containsString:@"limit"] ||
        [lower containsString:@"road"] ||
        [lower containsString:@"warning"] ||
        [lower containsString:@"navigation"]) {

        NSLog(
            @"[VMLSpeed] %@ -> %@",
            method,
            arguments
        );

        NSInteger speed =
            VMLFindSpeed(arguments);

        if (speed > 0)
            VMLSendSpeed(speed);
    }

    %orig;
}

- (void)invokeMethod:(NSString *)method
           arguments:(id)arguments
              result:(id)callback {

    NSString *lower =
        method.lowercaseString;

    if ([lower containsString:@"speed"] ||
        [lower containsString:@"limit"] ||
        [lower containsString:@"road"] ||
        [lower containsString:@"warning"] ||
        [lower containsString:@"navigation"]) {

        NSLog(
            @"[VMLSpeed] %@ -> %@",
            method,
            arguments
        );

        NSInteger speed =
            VMLFindSpeed(arguments);

        if (speed > 0)
            VMLSendSpeed(speed);
    }

    %orig;
}

%end

#pragma mark - Constructor

%ctor {
    @autoreleasepool {

        NSString *bundle =
            NSBundle.mainBundle.bundleIdentifier ?: @"";

        NSString *process =
            NSProcessInfo.processInfo.processName ?: @"";

        NSLog(
            @"[VMLTEST] injected bundle=%@ process=%@",
            bundle,
            process
        );

        if (VMLIsSpringBoard()) {

            VMLRegister();

            dispatch_after(
                dispatch_time(
                    DISPATCH_TIME_NOW,
                    3 * NSEC_PER_SEC),
                dispatch_get_main_queue(),
                ^{
                    VMLCreateIPhoneBubble();
                }
            );
        }

        if (VMLIsCarPlayProcess()) {

            dispatch_after(
                dispatch_time(
                    DISPATCH_TIME_NOW,
                    2 * NSEC_PER_SEC),
                dispatch_get_main_queue(),
                ^{
                    VMLRunCarPlayMultiTest();
                }
            );

            dispatch_after(
                dispatch_time(
                    DISPATCH_TIME_NOW,
                    5 * NSEC_PER_SEC),
                dispatch_get_main_queue(),
                ^{
                    VMLRunCarPlayMultiTest();
                }
            );

            dispatch_after(
                dispatch_time(
                    DISPATCH_TIME_NOW,
                    10 * NSEC_PER_SEC),
                dispatch_get_main_queue(),
                ^{
                    VMLRunCarPlayMultiTest();
                }
            );

            [[NSNotificationCenter defaultCenter]
                addObserverForName:
                    UISceneDidActivateNotification
                            object:nil
                             queue:
                    [NSOperationQueue mainQueue]
                        usingBlock:
                    ^(NSNotification *note) {

                        NSLog(
                            @"[VMLTEST] scene activated %@",
                            note.object
                        );

                        VMLRunCarPlayMultiTest();
                    }];
        }
    }
}
