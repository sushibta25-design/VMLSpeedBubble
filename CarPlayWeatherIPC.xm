#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <notify.h>

static const char *kCPWWeatherNotify = "com.sushibta.vmlspeedbubble.weather";
static int gCPWToken = 0;
static UIWindow *gCPWWindow = nil;
static UILabel *gCPWLabel = nil;
static AVSpeechSynthesizer *gCPWSpeech = nil;

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
        label.textAlignment = NSTextAlignmentLeft;
        label.textColor = UIColor.whiteColor;
        label.backgroundColor = [UIColor colorWithWhite:0.055 alpha:0.94];
        label.layer.cornerRadius = 14.0;
        label.layer.masksToBounds = YES;
        label.layer.borderWidth = 0.5;
        label.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.16].CGColor;
        label.hidden = YES;
        label.userInteractionEnabled = NO;
        [vc.view addSubview:label];
        gCPWLabel = label;
    }

    gCPWWindow.frame = bounds;
    gCPWWindow.rootViewController.view.frame = CGRectMake(0, 0, bounds.size.width, bounds.size.height);
    CGFloat width = MIN(bounds.size.width - 36.0, 580.0);
    CGFloat height = 72.0;
    gCPWLabel.frame = CGRectMake((bounds.size.width - width) / 2.0,
                                 MAX(12.0, bounds.size.height * 0.045),
                                 width,
                                 height);

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

static NSAttributedString *CPWBannerText(double tempC, NSString *condition, double wind) {
    NSString *line1 = [NSString stringWithFormat:@"   %.0f°C   %@", tempC, condition];
    NSString *line2 = [NSString stringWithFormat:@"   Điểm đến  •  Gió %.0f km/h", wind];
    NSString *all = [NSString stringWithFormat:@"%@\n%@", line1, line2];

    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.lineSpacing = 1.0;
    style.alignment = NSTextAlignmentLeft;

    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:all attributes:@{
        NSForegroundColorAttributeName: UIColor.whiteColor,
        NSFontAttributeName: [UIFont systemFontOfSize:17.0 weight:UIFontWeightRegular],
        NSParagraphStyleAttributeName: style
    }];

    NSRange tempRange = [line1 rangeOfString:[NSString stringWithFormat:@"%.0f°C", tempC]];
    if (tempRange.location != NSNotFound) {
        [attr addAttribute:NSFontAttributeName value:[UIFont systemFontOfSize:25.0 weight:UIFontWeightSemibold] range:tempRange];
    }
    NSRange conditionRange = [line1 rangeOfString:condition];
    if (conditionRange.location != NSNotFound) {
        [attr addAttribute:NSFontAttributeName value:[UIFont systemFontOfSize:19.0 weight:UIFontWeightSemibold] range:conditionRange];
    }
    NSRange secondLine = NSMakeRange(line1.length + 1, line2.length);
    [attr addAttribute:NSForegroundColorAttributeName value:[UIColor colorWithWhite:0.86 alpha:1.0] range:secondLine];
    [attr addAttribute:NSFontAttributeName value:[UIFont systemFontOfSize:16.0 weight:UIFontWeightRegular] range:secondLine];
    return attr;
}

static void CPWSpeak(double tempC, NSString *condition, double wind) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gCPWSpeech) gCPWSpeech = [AVSpeechSynthesizer new];
        [gCPWSpeech stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
        NSString *speech = [NSString stringWithFormat:@"Thời tiết tại điểm đến. %.0f độ, %@, gió %.0f ki lô mét một giờ.", tempC, condition.lowercaseString, wind];
        AVSpeechUtterance *utterance = [AVSpeechUtterance speechUtteranceWithString:speech];
        utterance.voice = [AVSpeechSynthesisVoice voiceWithLanguage:@"vi-VN"];
        utterance.rate = 0.48;
        utterance.pitchMultiplier = 0.98;
        utterance.volume = 0.92;
        utterance.preUtteranceDelay = 0.15;
        [gCPWSpeech speakUtterance:utterance];
    });
}

static void CPWShowWeather(double tempC, NSString *condition, double wind, NSTimeInterval duration) {
    dispatch_async(dispatch_get_main_queue(), ^{
        CPWEnsureWindow();
        if (!gCPWWindow || !gCPWLabel) return;
        gCPWLabel.attributedText = CPWBannerText(tempC, condition, wind);
        gCPWLabel.hidden = NO;
        gCPWLabel.alpha = 0.0;
        gCPWLabel.transform = CGAffineTransformMakeTranslation(0, -8.0);
        gCPWLabel.layer.zPosition = CGFLOAT_MAX;
        [gCPWLabel.superview bringSubviewToFront:gCPWLabel];

        [UIView animateWithDuration:0.22 animations:^{
            gCPWLabel.alpha = 1.0;
            gCPWLabel.transform = CGAffineTransformIdentity;
        }];

        CPWSpeak(tempC, condition, wind);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.22 animations:^{
                gCPWLabel.alpha = 0.0;
                gCPWLabel.transform = CGAffineTransformMakeTranslation(0, -6.0);
            } completion:^(__unused BOOL finished) {
                gCPWLabel.hidden = YES;
                gCPWLabel.transform = CGAffineTransformIdentity;
            }];
        });
    });
}

static void CPWReadWeather(int token) {
    uint64_t state = 0;
    uint32_t status = notify_get_state(token, &state);
    if (status != NOTIFY_STATUS_OK) return;

    NSInteger tempPacked = (NSInteger)(state & 0xFFFFULL);
    NSInteger code = (NSInteger)((state >> 16) & 0xFFULL);
    NSInteger windPacked = (NSInteger)((state >> 24) & 0xFFFFULL);
    double tempC = ((double)tempPacked - 1000.0) / 10.0;
    double wind = ((double)windPacked) / 10.0;
    NSString *condition = CPWDescription(code);
    CPWShowWeather(tempC, condition, wind, 8.0);
}

static void CPWStartReceiver(void) {
    if (!CPWIsCarPlayApp() || gCPWToken) return;
    int token = 0;
    uint32_t status = notify_register_dispatch(kCPWWeatherNotify, &token, dispatch_get_main_queue(), ^(int incomingToken) {
        gCPWToken = incomingToken;
        CPWReadWeather(incomingToken);
    });
    if (status == NOTIFY_STATUS_OK) gCPWToken = token;
}

%ctor {
    @autoreleasepool {
        if (!CPWIsCarPlayApp()) return;
        CPWStartReceiver();
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
