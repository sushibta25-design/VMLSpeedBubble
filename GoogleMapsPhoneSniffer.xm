#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <AVFoundation/AVFoundation.h>

static NSString * const kGMBundle = @"com.google.Maps";
static NSString * const kGMDestinationClass = @"AZDDestinationPreviewContentView";
static NSString * const kGMNavHeaderClass = @"GMSNavHeaderView";
static NSString * const kGMNavFooterClass = @"GMSNavFooterRouteSummaryView";

static NSString *gGMLastDestination = nil;
static NSDate *gGMLastWeatherAt = nil;
static AVSpeechSynthesizer *gGMSpeech = nil;

static BOOL GMIsGoogleMaps(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:kGMBundle];
}

static NSArray<UIWindow *> *GMAllWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window && ![windows containsObject:window]) [windows addObject:window];
            }
        }
    }
    @try {
        NSArray *legacy = [app valueForKey:@"windows"];
        for (UIWindow *window in legacy) {
            if (window && ![windows containsObject:window]) [windows addObject:window];
        }
    } @catch (__unused NSException *e) {}
    return windows;
}

static UIView *GMFindViewByClassName(UIView *root, NSString *className) {
    if (!root) return nil;
    if ([NSStringFromClass(root.class) isEqualToString:className]) return root;
    for (UIView *sub in root.subviews) {
        UIView *found = GMFindViewByClassName(sub, className);
        if (found) return found;
    }
    return nil;
}

static BOOL GMNavigationActive(void) {
    for (UIWindow *window in GMAllWindows()) {
        if (window.hidden || window.alpha <= 0.01) continue;
        if (GMFindViewByClassName(window, kGMNavHeaderClass) || GMFindViewByClassName(window, kGMNavFooterClass)) return YES;
    }
    return NO;
}

static void GMCollectText(UIView *view, NSMutableArray<NSString *> *out) {
    if (!view || view.hidden || view.alpha <= 0.01) return;
    NSString *text = nil;
    if ([view isKindOfClass:UILabel.class]) text = ((UILabel *)view).text;
    else if ([view isKindOfClass:UITextField.class]) text = ((UITextField *)view).text;
    else if ([view isKindOfClass:UITextView.class]) text = ((UITextView *)view).text;
    else if ([view isKindOfClass:UIButton.class]) text = ((UIButton *)view).currentTitle;
    if (!text.length) text = view.accessibilityLabel;
    if (text.length) {
        NSString *clean = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (clean.length > 1 && clean.length < 180 && ![out containsObject:clean]) [out addObject:clean];
    }
    for (UIView *sub in view.subviews) GMCollectText(sub, out);
}

static NSString *GMDestinationText(void) {
    for (UIWindow *window in GMAllWindows()) {
        if (window.hidden || window.alpha <= 0.01) continue;
        UIView *preview = GMFindViewByClassName(window, kGMDestinationClass);
        if (!preview) continue;
        NSMutableArray<NSString *> *texts = [NSMutableArray array];
        GMCollectText(preview, texts);
        for (NSString *candidate in texts) {
            NSString *lower = candidate.lowercaseString;
            if ([lower containsString:@"km"] || [lower containsString:@"min"] || [lower containsString:@"phút"] || [lower containsString:@"giờ"]) continue;
            return candidate;
        }
    }
    return nil;
}

static NSString *GMWeatherDescription(NSInteger code) {
    if (code == 0) return @"trời quang";
    if (code <= 3) return @"có mây";
    if (code == 45 || code == 48) return @"có sương mù";
    if ((code >= 51 && code <= 57) || (code >= 61 && code <= 67) || (code >= 80 && code <= 82)) return @"có mưa";
    if (code >= 71 && code <= 77) return @"có tuyết";
    if (code >= 95) return @"có dông";
    return @"thời tiết thay đổi";
}

static UIWindow *GMTopWindow(void) {
    UIWindow *best = nil;
    for (UIWindow *window in GMAllWindows()) {
        if (window.hidden || window.alpha <= 0.01) continue;
        if (!best || window.windowLevel >= best.windowLevel) best = window;
    }
    return best;
}

static void GMShowBanner(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = GMTopWindow();
        if (!window || !text.length) return;
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.numberOfLines = 0;
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = UIColor.whiteColor;
        label.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
        label.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        label.layer.cornerRadius = 14;
        label.layer.masksToBounds = YES;
        label.text = text;
        CGFloat width = MIN(window.bounds.size.width - 32.0, 420.0);
        CGSize fit = [label sizeThatFits:CGSizeMake(width - 28.0, CGFLOAT_MAX)];
        CGFloat height = MAX(58.0, fit.height + 28.0);
        CGFloat top = window.safeAreaInsets.top + 12.0;
        label.frame = CGRectMake((window.bounds.size.width - width) / 2.0, top, width, height);
        label.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
        [window addSubview:label];
        label.alpha = 0.0;
        [UIView animateWithDuration:0.2 animations:^{ label.alpha = 1.0; }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.25 animations:^{ label.alpha = 0.0; } completion:^(__unused BOOL finished){ [label removeFromSuperview]; }];
        });
    });
}

static void GMSpeakVietnamese(NSString *text) {
    if (!text.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gGMSpeech) gGMSpeech = [AVSpeechSynthesizer new];
        [gGMSpeech stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
        AVSpeechUtterance *utterance = [AVSpeechUtterance speechUtteranceWithString:text];
        utterance.voice = [AVSpeechSynthesisVoice voiceWithLanguage:@"vi-VN"];
        utterance.rate = 0.50;
        [gGMSpeech speakUtterance:utterance];
    });
}

static void GMFetchWeatherForDestination(NSString *destination) {
    if (!destination.length || !GMNavigationActive()) return;
    if ([destination isEqualToString:gGMLastDestination] && gGMLastWeatherAt && [[NSDate date] timeIntervalSinceDate:gGMLastWeatherAt] < 300.0) return;
    gGMLastDestination = [destination copy];
    gGMLastWeatherAt = [NSDate date];

    CLGeocoder *geocoder = [CLGeocoder new];
    [geocoder geocodeAddressString:destination completionHandler:^(NSArray<CLPlacemark *> *placemarks, NSError *error) {
        CLLocation *location = placemarks.firstObject.location;
        if (error || !location || !GMNavigationActive()) return;
        double lat = location.coordinate.latitude;
        double lon = location.coordinate.longitude;
        NSString *urlString = [NSString stringWithFormat:@"https://api.open-meteo.com/v1/forecast?latitude=%.6f&longitude=%.6f&current=temperature_2m,weather_code,wind_speed_10m&timezone=auto", lat, lon];
        NSURL *url = [NSURL URLWithString:urlString];
        if (!url) return;
        [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *netError) {
            if (netError || !data || !GMNavigationActive()) return;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSDictionary *current = [json isKindOfClass:NSDictionary.class] ? json[@"current"] : nil;
            if (![current isKindOfClass:NSDictionary.class]) return;
            NSNumber *temp = current[@"temperature_2m"];
            NSNumber *code = current[@"weather_code"];
            NSNumber *wind = current[@"wind_speed_10m"];
            if (!temp || !code) return;
            NSString *condition = GMWeatherDescription(code.integerValue);
            NSString *banner = wind ? [NSString stringWithFormat:@"%@\n%.0f°C, %@, gió %.0f km/h", destination, temp.doubleValue, condition, wind.doubleValue] : [NSString stringWithFormat:@"%@\n%.0f°C, %@", destination, temp.doubleValue, condition];
            NSString *speech = [NSString stringWithFormat:@"Điểm đến %@, %.0f độ, %@.", destination, temp.doubleValue, condition];
            GMShowBanner(banner);
            GMSpeakVietnamese(speech);
        }] resume];
    }];
}

static void GMCheckDestinationAndWeather(void) {
    if (!GMIsGoogleMaps() || !GMNavigationActive()) return;
    NSString *destination = GMDestinationText();
    if (destination.length) GMFetchWeatherForDestination(destination);
}

%hook UIView

- (void)didMoveToWindow {
    %orig;
    if (!GMIsGoogleMaps() || !self.window) return;
    NSString *name = NSStringFromClass(self.class);
    if ([name isEqualToString:kGMDestinationClass] || [name isEqualToString:kGMNavHeaderClass] || [name isEqualToString:kGMNavFooterClass]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 700 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ GMCheckDestinationAndWeather(); });
    }
}

%end

%hook UILabel

- (void)setText:(NSString *)text {
    %orig;
    if (!GMIsGoogleMaps() || !self.window) return;
    UIView *v = self;
    while (v) {
        if ([NSStringFromClass(v.class) isEqualToString:kGMDestinationClass]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ GMCheckDestinationAndWeather(); });
            break;
        }
        v = v.superview;
    }
}

%end

%ctor {
    @autoreleasepool {
        if (!GMIsGoogleMaps()) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ GMCheckDestinationAndWeather(); });
    }
}
