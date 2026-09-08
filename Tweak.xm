#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

static UIWindow *gVMLWindow = nil;
static UIView *gVMLBubble = nil;
static UILabel *gVMLLabel = nil;

static CGFloat kIPhoneBubbleSize = 64.0;
static CGFloat kCarPlayBubbleSize = 52.0;

@interface VMLBubbleController : NSObject
- (void)handlePan:(UIPanGestureRecognizer *)pan;
@end

@implementation VMLBubbleController

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if (!gVMLWindow) return;

    CGPoint translation =
        [pan translationInView:gVMLWindow];

    CGRect frame = gVMLWindow.frame;

    frame.origin.x += translation.x;
    frame.origin.y += translation.y;

    UIScreen *screen = gVMLWindow.screen;

    CGRect bounds =
        screen ? screen.bounds : UIScreen.mainScreen.bounds;

    frame.origin.x =
        MAX(0,
            MIN(bounds.size.width - frame.size.width,
                frame.origin.x));

    frame.origin.y =
        MAX(0,
            MIN(bounds.size.height - frame.size.height,
                frame.origin.y));

    gVMLWindow.frame = frame;

    [pan setTranslation:CGPointZero
                 inView:gVMLWindow];
}

@end

static VMLBubbleController *gVMLBubbleController = nil;

static NSInteger VMLFindSpeed(id obj) {
    if (!obj || obj == [NSNull null])
        return -1;

    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict =
            (NSDictionary *)obj;

        for (id key in dict) {
            NSString *k =
                [[key description] lowercaseString];

            id value = dict[key];

            BOOL match =
                [k containsString:@"speedlimit"] ||
                [k containsString:@"speed_limit"] ||
                [k containsString:@"maxspeed"];

            if (match &&
                [value respondsToSelector:@selector(integerValue)]) {

                NSInteger v =
                    [value integerValue];

                if (v >= 5 && v <= 200)
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

    if ([obj isKindOfClass:[NSArray class]]) {
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
    if (speed < 5 || speed > 200)
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

static BOOL VMLIsCarPlayProcess(void) {
    NSString *bundle =
        NSBundle.mainBundle.bundleIdentifier ?: @"";

    return
        [bundle isEqualToString:@"com.apple.CarPlayApp"];
}

static BOOL VMLSceneIsCarPlay(UIWindowScene *scene) {
    if (!scene)
        return NO;

    UISceneSession *session =
        scene.session;

    NSString *role =
        session.role ?: @"";

    if ([role containsString:@"CarPlay"])
        return YES;

    UIScreen *screen =
        scene.screen;

    if (screen &&
        screen != UIScreen.mainScreen &&
        screen.bounds.size.width >= 500) {

        return YES;
    }

    return NO;
}

static UIWindowScene *VMLGetIPhoneScene(void) {
    for (UIScene *scene
         in UIApplication.sharedApplication.connectedScenes) {

        if (![scene isKindOfClass:[UIWindowScene class]])
            continue;

        UIWindowScene *ws =
            (UIWindowScene *)scene;

        if (VMLSceneIsCarPlay(ws))
            continue;

        if (scene.activationState ==
            UISceneActivationStateUnattached)
            continue;

        return ws;
    }

    return nil;
}

static UIWindowScene *VMLGetCarPlayScene(void) {
    for (UIScene *scene
         in UIApplication.sharedApplication.connectedScenes) {

        if (![scene isKindOfClass:[UIWindowScene class]])
            continue;

        UIWindowScene *ws =
            (UIWindowScene *)scene;

        if (!VMLSceneIsCarPlay(ws))
            continue;

        NSLog(
            @"[VMLSpeedBubble] CarPlay scene found role=%@ screen=%@ bounds=%@",
            ws.session.role,
            ws.screen,
            NSStringFromCGRect(ws.screen.bounds)
        );

        return ws;
    }

    return nil;
}

static UIWindowScene *VMLGetTargetScene(void) {
    if (VMLIsCarPlayProcess()) {
        UIWindowScene *cp =
            VMLGetCarPlayScene();

        if (cp)
            return cp;
    }

    return VMLGetIPhoneScene();
}

static void VMLSetSpeed(NSInteger speed) {
    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            if (!gVMLBubble ||
                !gVMLLabel)
                return;

            if (speed <= 0) {
                gVMLBubble.hidden = YES;
                return;
            }

            gVMLBubble.hidden = NO;

            gVMLLabel.text =
                [NSString stringWithFormat:
                    @"%ld",
                    (long)speed];
        }
    );
}

static void VMLCreateBubble(void) {
    if (gVMLWindow)
        return;

    UIWindowScene *scene =
        VMLGetTargetScene();

    if (!scene) {
        NSLog(
            @"[VMLSpeedBubble] target scene NOT found"
        );
        return;
    }

    BOOL carPlay =
        VMLSceneIsCarPlay(scene);

    CGFloat size =
        carPlay
        ? kCarPlayBubbleSize
        : kIPhoneBubbleSize;

    CGRect screenBounds =
        scene.screen.bounds;

    CGFloat x =
        carPlay
        ? screenBounds.size.width - size - 18.0
        : 18.0;

    CGFloat y =
        carPlay
        ? 18.0
        : 110.0;

    gVMLWindow =
        [[UIWindow alloc]
            initWithWindowScene:scene];

    gVMLWindow.frame =
        CGRectMake(
            x,
            y,
            size,
            size
        );

    gVMLWindow.backgroundColor =
        UIColor.clearColor;

    gVMLWindow.windowLevel =
        UIWindowLevelAlert + 1000.0;

    UIViewController *vc =
        [UIViewController new];

    vc.view.backgroundColor =
        UIColor.clearColor;

    gVMLWindow.rootViewController =
        vc;

    gVMLBubble =
        [[UIView alloc]
            initWithFrame:
                CGRectMake(
                    0,
                    0,
                    size,
                    size
                )];

    gVMLBubble.backgroundColor =
        UIColor.whiteColor;

    gVMLBubble.layer.cornerRadius =
        size / 2.0;

    gVMLBubble.layer.borderWidth =
        MAX(
            4.0,
            size * 0.09
        );

    gVMLBubble.layer.borderColor =
        UIColor.systemRedColor.CGColor;

    gVMLBubble.clipsToBounds =
        YES;

    gVMLBubble.userInteractionEnabled =
        YES;

    gVMLLabel =
        [[UILabel alloc]
            initWithFrame:
                gVMLBubble.bounds];

    gVMLLabel.autoresizingMask =
        UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;

    gVMLLabel.text =
        @"50";

    gVMLLabel.textAlignment =
        NSTextAlignmentCenter;

    gVMLLabel.textColor =
        UIColor.blackColor;

    gVMLLabel.font =
        [UIFont systemFontOfSize:
            size * 0.42
                         weight:
            UIFontWeightBold];

    gVMLLabel.userInteractionEnabled =
        NO;

    [gVMLBubble addSubview:gVMLLabel];

    [vc.view addSubview:gVMLBubble];

    gVMLBubbleController =
        [VMLBubbleController new];

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc]
            initWithTarget:
                gVMLBubbleController
                    action:
                @selector(handlePan:)];

    [gVMLBubble
        addGestureRecognizer:pan];

    gVMLWindow.hidden =
        NO;

    [gVMLWindow makeKeyAndVisible];

    NSLog(
        @"[VMLSpeedBubble] bubble created carPlay=%d size=%.0f sceneRole=%@ screen=%@",
        carPlay,
        size,
        scene.session.role,
        NSStringFromCGRect(scene.screen.bounds)
    );
}

static void VMLTryCreateBubble(void) {
    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            if (gVMLWindow)
                return;

            VMLCreateBubble();

            if (gVMLWindow)
                VMLSetSpeed(50);
        }
    );
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

    VMLSetSpeed(speed);
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

%ctor {
    @autoreleasepool {
        NSString *bundle =
            NSBundle.mainBundle.bundleIdentifier ?: @"";

        NSString *process =
            NSProcessInfo.processInfo.processName ?: @"";

        NSLog(
            @"[VMLSpeedBubble] loaded bundle=%@ process=%@",
            bundle,
            process
        );

        BOOL isSpringBoard =
            [bundle isEqualToString:
                @"com.apple.springboard"];

        BOOL isCarPlay =
            [bundle isEqualToString:
                @"com.apple.CarPlayApp"];

        if (isSpringBoard ||
            isCarPlay) {

            VMLRegister();

            dispatch_after(
                dispatch_time(
                    DISPATCH_TIME_NOW,
                    3 * NSEC_PER_SEC
                ),
                dispatch_get_main_queue(),
                ^{
                    VMLTryCreateBubble();
                }
            );

            dispatch_after(
                dispatch_time(
                    DISPATCH_TIME_NOW,
                    8 * NSEC_PER_SEC
                ),
                dispatch_get_main_queue(),
                ^{
                    VMLTryCreateBubble();
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
                            @"[VMLSpeedBubble] scene activated %@",
                            note.object
                        );

                        VMLTryCreateBubble();
                    }];

            [[NSNotificationCenter defaultCenter]
                addObserverForName:
                    UISceneWillConnectNotification
                            object:nil
                             queue:
                    [NSOperationQueue mainQueue]
                        usingBlock:
                    ^(NSNotification *note) {

                        NSLog(
                            @"[VMLSpeedBubble] scene connected %@",
                            note.object
                        );

                        dispatch_after(
                            dispatch_time(
                                DISPATCH_TIME_NOW,
                                1 * NSEC_PER_SEC
                            ),
                            dispatch_get_main_queue(),
                            ^{
                                VMLTryCreateBubble();
                            }
                        );
                    }];
        }
    }
}
