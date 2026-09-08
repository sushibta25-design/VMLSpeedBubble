#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

static UIWindow *gVMLWindow = nil;
static UIView *gVMLBubble = nil;
static UILabel *gVMLLabel = nil;

@interface VMLPassthroughWindow : UIWindow
@end

@implementation VMLPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return nil; // không chặn touch của app phía dưới
}
@end

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

    gVMLWindow =
        [[VMLPassthroughWindow alloc] initWithWindowScene:scene];

    gVMLWindow.frame = UIScreen.mainScreen.bounds;
    gVMLWindow.backgroundColor = UIColor.clearColor;
    gVMLWindow.windowLevel = UIWindowLevelAlert + 1000.0;

    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.clearColor;
    gVMLWindow.rootViewController = vc;

    CGFloat size = 64.0;

    gVMLBubble =
        [[UIView alloc] initWithFrame:
            CGRectMake(18, 110, size, size)];

    gVMLBubble.backgroundColor = UIColor.whiteColor;
    gVMLBubble.layer.cornerRadius = size / 2.0;
    gVMLBubble.layer.borderWidth = 6.0;
    gVMLBubble.layer.borderColor = UIColor.systemRedColor.CGColor;
    gVMLBubble.userInteractionEnabled = NO;

    gVMLLabel =
        [[UILabel alloc] initWithFrame:gVMLBubble.bounds];

    gVMLLabel.autoresizingMask =
        UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;

    gVMLLabel.text = @"50";
    gVMLLabel.textAlignment = NSTextAlignmentCenter;
    gVMLLabel.textColor = UIColor.blackColor;
    gVMLLabel.font =
        [UIFont systemFontOfSize:27.0 weight:UIFontWeightBold];
    gVMLLabel.userInteractionEnabled = NO;

    [gVMLBubble addSubview:gVMLLabel];
    [vc.view addSubview:gVMLBubble];

    gVMLWindow.hidden = NO;
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
