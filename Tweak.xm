#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

static UIWindow *gVMLWindow = nil;
static UIView *gVMLBubble = nil;
static UILabel *gVMLLabel = nil;
// ===== CHỈNH KÍCH THƯỚC Ở ĐÂY =====
static CGFloat kIPhoneBubbleSize = 64.0;
static CGFloat kCarPlayBubbleSize = 100.0;

@interface VMLBubbleController : NSObject
- (void)handlePan:(UIPanGestureRecognizer *)pan;
@end

@implementation VMLBubbleController

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if (!gVMLWindow) return;

    CGPoint translation = [pan translationInView:gVMLWindow];

    CGRect frame = gVMLWindow.frame;
    frame.origin.x += translation.x;
    frame.origin.y += translation.y;

    CGRect screen = UIScreen.mainScreen.bounds;

    frame.origin.x = MAX(0,
        MIN(screen.size.width - frame.size.width,
            frame.origin.x));

    frame.origin.y = MAX(30,
        MIN(screen.size.height - frame.size.height,
            frame.origin.y));

    gVMLWindow.frame = frame;

    [pan setTranslation:CGPointZero inView:gVMLWindow];
}

@end

static VMLBubbleController *gVMLBubbleController = nil;

static NSInteger VMLFindSpeed(id obj) {
    if (!obj || obj == [NSNull null]) return -1;

    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)obj;

        for (id key in dict) {
            NSString *k = [[key description] lowercaseString];
            id value = dict[key];

            BOOL match =
                [k containsString:@"speedlimit"] ||
                [k containsString:@"speed_limit"] ||
                [k containsString:@"maxspeed"];

            if (match && [value respondsToSelector:@selector(integerValue)]) {
                NSInteger v = [value integerValue];
                if (v >= 5 && v <= 200) return v;
            }

            NSInteger nested = VMLFindSpeed(value);
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
            NSInteger v = VMLFindSpeed(item);
            if (v > 0) return v;
        }
    }

    return -1;
}

static void VMLSendSpeed(NSInteger speed) {
    if (speed < 5 || speed > 200) return;

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

static UIWindowScene *VMLGetScene(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] &&
            scene.activationState != UISceneActivationStateUnattached) {
            return (UIWindowScene *)scene;
        }
    }
    return nil;
}

static void VMLSetSpeed(NSInteger speed) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gVMLBubble || !gVMLLabel) return;

        if (speed <= 0) {
            gVMLBubble.hidden = YES;
            return;
        }

        gVMLBubble.hidden = NO;
        gVMLLabel.text =
            [NSString stringWithFormat:@"%ld", (long)speed];
    });
}

static void VMLCreateBubble(void) {
    if (gVMLWindow) return;

    UIWindowScene *scene = VMLGetScene();
    if (!scene) return;

    CGFloat size = kIPhoneBubbleSize;

    // Window CHỈ bằng kích thước bong bóng
    // nên không còn phủ/chặn cảm ứng toàn màn hình.
    gVMLWindow =
        [[UIWindow alloc] initWithWindowScene:scene];

    gVMLWindow.frame =
        CGRectMake(18.0,
                   110.0,
                   size,
                   size);

    gVMLWindow.backgroundColor =
        UIColor.clearColor;

    gVMLWindow.windowLevel =
        UIWindowLevelAlert + 1000.0;

    UIViewController *vc =
        [UIViewController new];

    vc.view.backgroundColor =
        UIColor.clearColor;

    gVMLWindow.rootViewController = vc;

    gVMLBubble =
        [[UIView alloc] initWithFrame:
            CGRectMake(0.0,
                       0.0,
                       size,
                       size)];

    gVMLBubble.backgroundColor =
        UIColor.whiteColor;

    gVMLBubble.layer.cornerRadius =
        size / 2.0;

    gVMLBubble.layer.borderWidth =
        MAX(4.0, size * 0.09);

    gVMLBubble.layer.borderColor =
        UIColor.systemRedColor.CGColor;

    gVMLBubble.clipsToBounds = YES;

    // Chỉ bong bóng nhận touch để kéo
    gVMLBubble.userInteractionEnabled = YES;

    gVMLLabel =
        [[UILabel alloc] initWithFrame:
            gVMLBubble.bounds];

    gVMLLabel.autoresizingMask =
        UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;

    gVMLLabel.text = @"50";

    gVMLLabel.textAlignment =
        NSTextAlignmentCenter;

    gVMLLabel.textColor =
        UIColor.blackColor;

    gVMLLabel.font =
        [UIFont systemFontOfSize:
            size * 0.42
                         weight:UIFontWeightBold];

    // Label không cản gesture của bong bóng
    gVMLLabel.userInteractionEnabled = NO;

    [gVMLBubble addSubview:gVMLLabel];
    [vc.view addSubview:gVMLBubble];

    gVMLBubbleController =
        [VMLBubbleController new];

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc]
            initWithTarget:gVMLBubbleController
                    action:@selector(handlePan:)];

    [gVMLBubble addGestureRecognizer:pan];

    gVMLWindow.hidden = NO;

    NSLog(@"[VMLSpeedBubble] bubble created size=%.0f",
          size);
}

static void VMLCallback(
    CFNotificationCenterRef center,
    void *observer,
    CFStringRef name,
    const void *object,
    CFDictionaryRef userInfo)
{
    NSString *n = (__bridge NSString *)name;
    NSString *prefix =
        @"com.sushibta.vmlspeedbubble.speed.";

    if (![n hasPrefix:prefix]) return;

    NSInteger speed =
        [[n substringFromIndex:prefix.length] integerValue];

    VMLSetSpeed(speed);
}

static void VMLRegister(void) {
    for (NSInteger speed = 5; speed <= 200; speed += 5) {
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

- (void)invokeMethod:(NSString *)method arguments:(id)arguments {
    NSString *lower = method.lowercaseString;

    if ([lower containsString:@"speed"] ||
        [lower containsString:@"limit"] ||
        [lower containsString:@"road"] ||
        [lower containsString:@"warning"] ||
        [lower containsString:@"navigation"]) {

        NSLog(@"[VMLSpeed] %@ -> %@", method, arguments);

        NSInteger speed = VMLFindSpeed(arguments);
        if (speed > 0) VMLSendSpeed(speed);
    }

    %orig;
}

- (void)invokeMethod:(NSString *)method
           arguments:(id)arguments
              result:(id)callback {

    NSString *lower = method.lowercaseString;

    if ([lower containsString:@"speed"] ||
        [lower containsString:@"limit"] ||
        [lower containsString:@"road"] ||
        [lower containsString:@"warning"] ||
        [lower containsString:@"navigation"]) {

        NSLog(@"[VMLSpeed] %@ -> %@", method, arguments);

        NSInteger speed = VMLFindSpeed(arguments);
        if (speed > 0) VMLSendSpeed(speed);
    }

    %orig;
}

%end

%ctor {
    @autoreleasepool {
        NSString *bundle =
            NSBundle.mainBundle.bundleIdentifier;

        if ([bundle isEqualToString:@"com.apple.springboard"]) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                dispatch_get_main_queue(),
                ^{
                    VMLRegister();
                    VMLCreateBubble();
                }
            );
        }
    }
}
