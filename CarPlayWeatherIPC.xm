#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <notify.h>

static const char *kCPWWeatherNotify = "com.sushibta.vmlspeedbubble.weather";
static const char *kCPWTestNotify = "com.sushibta.vmlspeedbubble.weather.test";
static int gCPWToken = 0;
static int gCPWTestToken = 0;
static UIWindow *gCPWWindow = nil;
static UILabel *gCPWLabel = nil;

static BOOL CPWIsCarPlayApp(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.CarPlayApp"];
}

static BOOL CPWSceneLooksCarPlay(UIWindowScene *scene) {
    if (!scene) return NO;
    NSString *role = scene.session.role ?: @"";
    if ([role localizedCaseInsensitiveContainsString:@"CarPlay"]) return YES;
    CGSize size = scene.screen.bounds.size;
    return size.width > size.height && size.width >= 300 && size.height <= 500;
}

static UIWindowScene *CPWFindScene(void) {
    UIWindowScene *best = nil;
    CGFloat bestScore = -CGFLOAT_MAX;
    for (UIScene *raw in UIApplication.sharedApplication.connectedScenes) {
        if (![raw isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *scene = (UIWindowScene *)raw;
        if (!CPWSceneLooksCarPlay(scene)) continue;
        CGFloat highest = -10000.0;
        for (UIWindow *w in scene.windows) {
            if (w && !w.hidden && w.alpha > 0.01) highest = MAX(highest, w.windowLevel);
        }
        CGSize s = scene.screen.bounds.size;
        CGFloat score = s.width * s.height + highest;
        if (!best || score > bestScore) {
            best = scene;
            bestScore = score;
        }
    }
    return best;
}

static void CPWEnsureWindow(void) {
    if (!CPWIsCarPlayApp()) return;
    UIWindowScene *scene = CPWFindScene();
    if (!scene) return;

    if (gCPWWindow && gCPWWindow.windowScene != scene) {
        gCPWWindow.hidden = YES;
        gCPWWindow.rootViewController = nil;
        gCPWWindow = nil;
        gCPWLabel = nil;
    }

    CGRect bounds = scene.coordinateSpace.bounds;
    if (CGRectIsEmpty(bounds)) bounds = scene.screen.bounds;

    if (!gCPWWindow) {
        gCPWWindow = [[UIWindow alloc] initWithWindowScene:scene];
        gCPWWindow.backgroundColor = UIColor.clearColor;
        gCPWWindow.userInteractionEnabled = NO;
        gCPWWindow.windowLevel = UIWindowLevelAlert + 250.0;

        UIViewController *vc = [UIViewController new];
        vc.view.backgroundColor = UIColor.clearColor;
        vc.view.userInteractionEnabled = NO;
        gCPWWindow.rootViewController = vc;

        UILabel *label = [UILabel new];
        label.numberOfLines = 2;
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = UIColor.whiteColor;
        label.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.96];
        label.layer.cornerRadius = 16.0;
        label.layer.masksToBounds = YES;
        label.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
        label.hidden = YES;
        label.userInteractionEnabled = NO;
        [vc.view addSubview:label];
        gCPWLabel = label;
    }

    gCPWWindow.frame = bounds;
    gCPWWindow.rootViewController.view.frame = CGRectMake(0, 0, bounds.size.width, bounds.size.height);
    CGFloat width = MIN(bounds.size.width - 48.0, 620.0);
    gCPWLabel.frame = CGRectMake((bounds.size.width - width) / 2.0,
                                 MAX(18.0, bounds.size.height * 0.06),
                                 width,
                                 84.0);

    CGFloat highest = UIWindowLevelAlert;
    for (UIWindow *w in scene.windows) {
        if (w && w != gCPWWindow) highest = MAX(highest, w.windowLevel);
    }
    gCPWWindow.windowLevel = MAX(UIWindowLevelAlert + 250.0, highest + 120.0);
    gCPWWindow.hidden = NO;
    gCPWWindow.alpha = 1.0;
}

static NSString *CPWDescription(NSInteger code) {
    if (code == 0) return @"Trời quang";
    if (code <= 3) return @"Có mây";
    if (code == 45 || code == 48) return @"Sương mù";
    if ((code >= 51 && code <= 57) || (code >= 61 && code <= 67) || (code >= 80 && code <= 82)) return @"Có mưa";
    if (code >= 71 && code <= 77) return @"Có tuyết";
    if (code >= 95) return @"Có dông";
    return @"Thời tiết thay đổi";
}

static void CPWShowText(NSString *text, NSTimeInterval duration) {
    dispatch_async(dispatch_get_main_queue(), ^{
        CPWEnsureWindow();
        if (!gCPWWindow || !gCPWLabel) {
            NSLog(@"[CPWIPC] no CarPlay window for text=%@", text);
            return;
        }
        gCPWLabel.text = text;
        gCPWLabel.hidden = NO;
        gCPWLabel.alpha = 1.0;
        gCPWLabel.layer.zPosition = CGFLOAT_MAX;
        [gCPWLabel.superview bringSubviewToFront:gCPWLabel];
        NSLog(@"[CPWIPC] show %@", text);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if ([gCPWLabel.text isEqualToString:text]) gCPWLabel.hidden = YES;
        });
    });
}

static void CPWReadWeather(int token) {
    uint64_t state = 0;
    uint32_t status = notify_get_state(token, &state);
    NSLog(@"[CPWIPC] weather event token=%d getState=%u state=%llu", token, status, state);
    if (status != NOTIFY_STATUS_OK) return;

    NSInteger tempPacked = (NSInteger)(state & 0xFFFFULL);
    NSInteger code = (NSInteger)((state >> 16) & 0xFFULL);
    NSInteger windPacked = (NSInteger)((state >> 24) & 0xFFFFULL);
    double tempC = ((double)tempPacked - 1000.0) / 10.0;
    double wind = ((double)windPacked) / 10.0;
    NSString *condition = CPWDescription(code);
    NSString *text = [NSString stringWithFormat:@"THỜI TIẾT ĐIỂM ĐẾN\n%.0f°C • %@ • gió %.0f km/h",
                      tempC, condition, wind];
    CPWShowText(text, 12.0);
}

static void CPWStartReceivers(void) {
    if (!CPWIsCarPlayApp()) return;

    if (!gCPWToken) {
        int token = 0;
        uint32_t status = notify_register_dispatch(kCPWWeatherNotify, &token, dispatch_get_main_queue(), ^(int incomingToken) {
            gCPWToken = incomingToken;
            CPWReadWeather(incomingToken);
        });
        if (status == NOTIFY_STATUS_OK) {
            gCPWToken = token;
            NSLog(@"[CPWIPC] weather receiver ready token=%d", token);
        } else {
            NSLog(@"[CPWIPC] weather receiver failed status=%u", status);
        }
    }

    if (!gCPWTestToken) {
        int token = 0;
        uint32_t status = notify_register_dispatch(kCPWTestNotify, &token, dispatch_get_main_queue(), ^(int incomingToken) {
            gCPWTestToken = incomingToken;
            NSLog(@"[CPWIPC] GOOGLE MAPS TEST EVENT RECEIVED token=%d", incomingToken);
            CPWShowText(@"GOOGLE MAPS IPC OK", 7.0);
        });
        if (status == NOTIFY_STATUS_OK) {
            gCPWTestToken = token;
            NSLog(@"[CPWIPC] test receiver ready token=%d", token);
        } else {
            NSLog(@"[CPWIPC] test receiver failed status=%u", status);
        }
    }
}

%ctor {
    @autoreleasepool {
        if (!CPWIsCarPlayApp()) return;
        NSLog(@"[CPWIPC] 16.7 receiver loaded");
        CPWStartReceivers();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            CPWShowText(@"WEATHER IPC READY", 6.0);
        });

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UISceneDidActivateNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                            CPWEnsureWindow();
                        });
                    }];
    }
}
