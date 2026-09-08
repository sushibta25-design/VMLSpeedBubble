#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

#pragma mark - Globals

static UIWindow *gVMLWindow = nil;
static UIView *gVMLBubble = nil;
static UILabel *gVMLLabel = nil;

#pragma mark - Pass-through root view

@interface VMLPassThroughView : UIView
@end

@implementation VMLPassThroughView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];

    if (hit == self) {
        return nil;
    }

    return hit;
}

@end

#pragma mark - Bubble drag controller

@interface VMLBubbleDragController : NSObject
- (void)handlePan:(UIPanGestureRecognizer *)pan;
@end

@implementation VMLBubbleDragController

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *bubble = pan.view;

    if (!bubble || !bubble.superview) {
        return;
    }

    CGPoint translation =
        [pan translationInView:bubble.superview];

    CGPoint center = bubble.center;

    center.x += translation.x;
    center.y += translation.y;

    CGRect bounds = bubble.superview.bounds;

    CGFloat halfW =
        bubble.bounds.size.width / 2.0;

    CGFloat halfH =
        bubble.bounds.size.height / 2.0;

    center.x =
        MAX(halfW + 5.0,
            MIN(bounds.size.width - halfW - 5.0,
                center.x));

    center.y =
        MAX(halfH + 35.0,
            MIN(bounds.size.height - halfH - 15.0,
                center.y));

    bubble.center = center;

    [pan setTranslation:CGPointZero
                 inView:bubble.superview];
}

@end

static VMLBubbleDragController *gVMLDragController = nil;

#pragma mark - Recursive speed finder

static NSInteger VMLFindSpeed(id obj) {
    if (!obj || obj == [NSNull null]) {
        return -1;
    }

    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict =
            (NSDictionary *)obj;

        for (id key in dict) {
            NSString *keyString =
                [[key description] lowercaseString];

            id value = dict[key];

            BOOL looksLikeSpeed =
                [keyString containsString:@"speedlimit"] ||
                [keyString containsString:@"speed_limit"] ||
                [keyString containsString:@"speed limit"] ||
                [keyString containsString:@"maxspeed"] ||
                [keyString containsString:@"speedlimitvalue"];

            if (looksLikeSpeed &&
                [value respondsToSelector:@selector(integerValue)]) {

                NSInteger speed =
                    [value integerValue];

                if (speed >= 5 &&
                    speed <= 200) {

                    return speed;
                }
            }

            NSInteger nested =
                VMLFindSpeed(value);

            if (nested > 0 &&
                ([keyString containsString:@"speed"] ||
                 [keyString containsString:@"limit"] ||
                 [keyString containsString:@"road"] ||
                 [keyString containsString:@"warning"])) {

                return nested;
            }
        }
    }

    if ([obj isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)obj) {
            NSInteger speed =
                VMLFindSpeed(item);

            if (speed > 0) {
                return speed;
            }
        }
    }

    return -1;
}

#pragma mark - IPC

static void VMLSendSpeed(NSInteger speed) {
    if (speed < 5 ||
        speed > 200) {

        return;
    }

    NSString *notificationName =
        [NSString stringWithFormat:
            @"com.sushibta.vmlspeedbubble.speed.%ld",
            (long)speed];

    NSLog(@"[VMLSpeed] send = %ld",
          (long)speed);

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)notificationName,
        NULL,
        NULL,
        true
    );
}

#pragma mark - Bubble UI

static UIWindowScene *VMLGetWindowScene(void) {
    NSSet *scenes =
        UIApplication.sharedApplication.connectedScenes;

    for (UIScene *scene in scenes) {
        if ([scene isKindOfClass:
                [UIWindowScene class]] &&
            scene.activationState !=
                UISceneActivationStateUnattached) {

            return (UIWindowScene *)scene;
        }
    }

    return nil;
}

static void VMLSetBubbleSpeed(NSInteger speed) {
    dispatch_async(
        dispatch_get_main_queue(),
        ^{

        if (!gVMLBubble ||
            !gVMLLabel) {

            return;
        }

        if (speed <= 0) {
            gVMLBubble.hidden = YES;
            return;
        }

        gVMLBubble.hidden = NO;

        gVMLLabel.text =
            [NSString stringWithFormat:
                @"%ld",
                (long)speed];

        NSLog(@"[VMLSpeedBubble] display = %ld",
              (long)speed);
    });
}

static void VMLCreateBubble(void) {
    if (gVMLWindow) {
        return;
    }

    UIWindowScene *scene =
        VMLGetWindowScene();

    if (!scene) {
        NSLog(@"[VMLSpeedBubble] UIWindowScene not found");
        return;
    }

    gVMLWindow =
        [[UIWindow alloc]
            initWithWindowScene:scene];

    gVMLWindow.frame =
        UIScreen.mainScreen.bounds;

    gVMLWindow.backgroundColor =
        UIColor.clearColor;

    gVMLWindow.windowLevel =
        UIWindowLevelAlert + 1000.0;

    UIViewController *root =
        [UIViewController new];

    VMLPassThroughView *rootView =
        [[VMLPassThroughView alloc]
            initWithFrame:
                gVMLWindow.bounds];

    rootView.backgroundColor =
        UIColor.clearColor;

    root.view = rootView;

    gVMLWindow.rootViewController =
        root;

    CGFloat size = 64.0;

    gVMLBubble =
        [[UIView alloc]
            initWithFrame:
                CGRectMake(
                    18.0,
                    110.0,
                    size,
                    size)];

    gVMLBubble.backgroundColor =
        UIColor.whiteColor;

    gVMLBubble.layer.cornerRadius =
        size / 2.0;

    gVMLBubble.layer.borderWidth =
        6.0;

    gVMLBubble.layer.borderColor =
        UIColor.systemRedColor.CGColor;

    gVMLBubble.clipsToBounds =
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
        [UIFont systemFontOfSize:27.0
                          weight:UIFontWeightBold];

    [gVMLBubble
        addSubview:gVMLLabel];

    gVMLDragController =
        [VMLBubbleDragController new];

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc]
            initWithTarget:gVMLDragController
                    action:@selector(handlePan:)];

    [gVMLBubble
        addGestureRecognizer:pan];

    [rootView
        addSubview:gVMLBubble];

    /*
     * Bản test đầu tiên cố tình hiện 50
     * để xác nhận UI + SpringBoard injection chạy.
     */
    gVMLBubble.hidden = NO;

    [gVMLWindow makeKeyAndVisible];

    NSLog(@"[VMLSpeedBubble] bubble created");
}

#pragma mark - Darwin callback

static void VMLSpeedNotificationCallback(
    CFNotificationCenterRef center,
    void *observer,
    CFStringRef name,
    const void *object,
    CFDictionaryRef userInfo)
{
    NSString *notification =
        (__bridge NSString *)name;

    NSString *prefix =
        @"com.sushibta.vmlspeedbubble.speed.";

    if (![notification
            hasPrefix:prefix]) {

        return;
    }

    NSString *value =
        [notification
            substringFromIndex:
                prefix.length];

    NSInteger speed =
        value.integerValue;

    if (speed >= 5 &&
        speed <= 200) {

        VMLSetBubbleSpeed(speed);
    }
}

static void VMLRegisterNotifications(void) {
    CFNotificationCenterRef center =
        CFNotificationCenterGetDarwinNotifyCenter();

    for (NSInteger speed = 5;
         speed <= 200;
         speed += 5) {

        NSString *name =
            [NSString stringWithFormat:
                @"com.sushibta.vmlspeedbubble.speed.%ld",
                (long)speed];

        CFNotificationCenterAddObserver(
            center,
            NULL,
            VMLSpeedNotificationCallback,
            (__bridge CFStringRef)name,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );
    }

    NSLog(@"[VMLSpeedBubble] notifications registered");
}

#pragma mark - VietMap / Flutter logger

%hook FlutterMethodChannel

- (void)invokeMethod:(NSString *)method
           arguments:(id)arguments
{
    NSString *lower =
        [method.lowercaseString copy];

    if ([lower containsString:@"speed"] ||
        [lower containsString:@"limit"] ||
        [lower containsString:@"road"] ||
        [lower containsString:@"warning"] ||
        [lower containsString:@"navigation"]) {

        NSLog(@"[VMLSpeed:channel] method=%@ args=%@",
              method,
              arguments);

        NSInteger speed =
            VMLFindSpeed(arguments);

        if (speed > 0) {
            NSLog(@"[VMLSpeed] detected=%ld",
                  (long)speed);

            VMLSendSpeed(speed);
        }
    }

    %orig;
}

- (void)invokeMethod:(NSString *)method
           arguments:(id)arguments
              result:(id)callback
{
    NSString *lower =
        [method.lowercaseString copy];

    if ([lower containsString:@"speed"] ||
        [lower containsString:@"limit"] ||
        [lower containsString:@"road"] ||
        [lower containsString:@"warning"] ||
        [lower containsString:@"navigation"]) {

        NSLog(@"[VMLSpeed:channel-result] method=%@ args=%@",
              method,
              arguments);

        NSInteger speed =
            VMLFindSpeed(arguments);

        if (speed > 0) {
            NSLog(@"[VMLSpeed] detected=%ld",
                  (long)speed);

            VMLSendSpeed(speed);
        }
    }

    %orig;
}

%end

#pragma mark - Constructor

%ctor {
    @autoreleasepool {
        NSString *bundleID =
            NSBundle.mainBundle.bundleIdentifier;

        NSLog(@"[VMLSpeedBubble] injected into %@",
              bundleID);

        if ([bundleID
                isEqualToString:
                    @"com.apple.springboard"]) {

            dispatch_after(
                dispatch_time(
                    DISPATCH_TIME_NOW,
                    (int64_t)(
                        3.0 *
                        NSEC_PER_SEC)),
                dispatch_get_main_queue(),
                ^{

                VMLRegisterNotifications();
                VMLCreateBubble();
            });
        }
    }
}
