#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <AVFoundation/AVFoundation.h>
#include <stdio.h>
#include <stdarg.h>

static NSString * const kGMBundle = @"com.google.Maps";
static NSString * const kGMDestinationClass = @"AZDDestinationPreviewContentView";
static NSString * const kGMNavHeaderClass = @"GMSNavHeaderView";
static NSString * const kGMNavFooterClass = @"GMSNavFooterRouteSummaryView";
#define kGMDebugLogPath ([NSHomeDirectory() stringByAppendingPathComponent:@"Documents/GoogleMapsWeatherDebug.txt"])

static NSString *gGMCachedDestination = nil;
static NSString *gGMLastWeatherDestination = nil;
static NSDate *gGMLastWeatherAt = nil;
static AVSpeechSynthesizer *gGMSpeech = nil;
static NSString *gGMLastState = nil;

static BOOL GMIsGoogleMaps(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:kGMBundle];
}

static void GMLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ | %@\n", [NSDate date], message ?: @""];
    NSLog(@"[GMWEATHER] %@", message);
    @synchronized (kGMDebugLogPath) {
        FILE *f = fopen(kGMDebugLogPath.UTF8String, "a");
        if (f) { fprintf(f, "%s", line.UTF8String); fclose(f); }
    }
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
        for (UIWindow *window in legacy) if (window && ![windows containsObject:window]) [windows addObject:window];
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

static UIView *GMFindVisibleClass(NSString *className) {
    for (UIWindow *window in GMAllWindows()) {
        if (window.hidden || window.alpha <= 0.01) continue;
        UIView *v = GMFindViewByClassName(window, className);
        if (v) return v;
    }
    return nil;
}

static BOOL GMNavigationActive(void) {
    return GMFindVisibleClass(kGMNavHeaderClass) != nil || GMFindVisibleClass(kGMNavFooterClass) != nil;
}

static void GMCollectText(UIView *view, NSMutableArray<NSString *> *out) {
    if (!view || view.hidden || view.alpha <= 0.01) return;
    NSArray *values = @[
        ([view isKindOfClass:UILabel.class] ? (((UILabel *)view).text ?: @"") : @""),
        ([view isKindOfClass:UITextField.class] ? (((UITextField *)view).text ?: @"") : @""),
        ([view isKindOfClass:UITextView.class] ? (((UITextView *)view).text ?: @"") : @""),
        ([view isKindOfClass:UIButton.class] ? (((UIButton *)view).currentTitle ?: @"") : @""),
        view.accessibilityLabel ?: @"",
        view.accessibilityValue ?: @""
    ];
    for (NSString *text in values) {
        NSString *clean = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (clean.length > 1 && clean.length < 220 && ![out containsObject:clean]) [out addObject:clean];
    }
    for (UIView *sub in view.subviews) GMCollectText(sub, out);
}

static NSString *GMChooseDestination(NSArray<NSString *> *texts) {
    for (NSString *candidate in texts) {
        NSString *lower = candidate.lowercaseString;
        if ([lower containsString:@"km"] || [lower containsString:@"min"] || [lower containsString:@"phút"] || [lower containsString:@"giờ"] || [lower containsString:@"bắt đầu"] || [lower containsString:@"start"]) continue;
        return candidate;
    }
    return nil;
}

static void GMCaptureDestinationFromPreview(UIView *preview, NSString *reason) {
    if (!preview) return;
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    GMCollectText(preview, texts);
    GMLog(@"PREVIEW reason=%@ class=%@ texts=%@", reason ?: @"unknown", NSStringFromClass(preview.class), texts);
    NSString *chosen = GMChooseDestination(texts);
    if (chosen.length && ![chosen isEqualToString:gGMCachedDestination]) {
        gGMCachedDestination = [chosen copy];
        GMLog(@"DESTINATION_CACHED value=\"%@\"", gGMCachedDestination);
    }
}

static void GMScanAndCacheDestination(NSString *reason) {
    UIView *preview = GMFindVisibleClass(kGMDestinationClass);
    if (preview) GMCaptureDestinationFromPreview(preview, reason);
}

static UIWindow *GMTopWindow(void) {
    UIWindow *best = nil;
    for (UIWindow *window in GMAllWindows()) {
        if (window.hidden || window.alpha <= 0.01) continue;
        if (!best || window.windowLevel >= best.windowLevel) best = window;
    }
    return best;
}

static void GMShowBannerForDuration(NSString *text, NSTimeInterval duration) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = GMTopWindow();
        if (!window || !text.length) { GMLog(@"BANNER_FAILED window=%@ textLength=%lu", window, (unsigned long)text.length); return; }
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.numberOfLines = 0;
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = UIColor.whiteColor;
        label.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
        label.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        label.layer.cornerRadius = 14;
        label.layer.masksToBounds = YES;
        label.text = text;
        CGFloat width = MIN(window.bounds.size.width - 32.0, 420.0);
        CGSize fit = [label sizeThatFits:CGSizeMake(width - 28.0, CGFLOAT_MAX)];
        CGFloat height = MAX(58.0, fit.height + 28.0);
        label.frame = CGRectMake((window.bounds.size.width - width) / 2.0, window.safeAreaInsets.top + 12.0, width, height);
        label.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
        [window addSubview:label];
        GMLog(@"BANNER_SHOW text=\"%@\" duration=%.0f", text, duration);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [label removeFromSuperview]; });
    });
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

static void GMSpeakVietnamese(NSString *text) {
    if (!text.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gGMSpeech) gGMSpeech = [AVSpeechSynthesizer new];
        AVSpeechUtterance *utterance = [AVSpeechUtterance speechUtteranceWithString:text];
        utterance.voice = [AVSpeechSynthesisVoice voiceWithLanguage:@"vi-VN"];
        utterance.rate = 0.50;
        GMLog(@"TTS value=\"%@\" voice=%@", text, utterance.voice.language ?: @"nil");
        [gGMSpeech speakUtterance:utterance];
    });
}

static void GMFetchWeatherForDestination(NSString *destination) {
    BOOL nav = GMNavigationActive();
    GMLog(@"WEATHER_BEGIN nav=%d destination=\"%@\"", nav, destination ?: @"");
    if (!destination.length || !nav) return;
    if ([destination isEqualToString:gGMLastWeatherDestination] && gGMLastWeatherAt && [[NSDate date] timeIntervalSinceDate:gGMLastWeatherAt] < 300.0) {
        GMLog(@"WEATHER_SKIP duplicateWithin300s");
        return;
    }
    gGMLastWeatherDestination = [destination copy];
    gGMLastWeatherAt = [NSDate date];
    CLGeocoder *geocoder = [CLGeocoder new];
    GMLog(@"GEOCODE_START query=\"%@\"", destination);
    [geocoder geocodeAddressString:destination completionHandler:^(NSArray<CLPlacemark *> *placemarks, NSError *error) {
        CLLocation *location = placemarks.firstObject.location;
        GMLog(@"GEOCODE_RESULT count=%lu lat=%f lon=%f error=%@", (unsigned long)placemarks.count, location.coordinate.latitude, location.coordinate.longitude, error.localizedDescription ?: @"none");
        if (error || !location) return;
        NSString *urlString = [NSString stringWithFormat:@"https://api.open-meteo.com/v1/forecast?latitude=%.6f&longitude=%.6f&current=temperature_2m,weather_code,wind_speed_10m&timezone=auto", location.coordinate.latitude, location.coordinate.longitude];
        GMLog(@"OPEN_METEO_REQUEST url=%@", urlString);
        [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:urlString] completionHandler:^(NSData *data, NSURLResponse *response, NSError *netError) {
            NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
            GMLog(@"OPEN_METEO_RESPONSE status=%ld bytes=%lu error=%@", (long)status, (unsigned long)data.length, netError.localizedDescription ?: @"none");
            if (netError || !data) return;
            NSError *jsonError = nil;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            NSDictionary *current = [json isKindOfClass:NSDictionary.class] ? json[@"current"] : nil;
            GMLog(@"OPEN_METEO_CURRENT current=%@ jsonError=%@", current, jsonError.localizedDescription ?: @"none");
            NSNumber *temp = current[@"temperature_2m"];
            NSNumber *code = current[@"weather_code"];
            NSNumber *wind = current[@"wind_speed_10m"];
            if (!temp || !code) return;
            NSString *condition = GMWeatherDescription(code.integerValue);
            NSString *banner = wind ? [NSString stringWithFormat:@"%@\n%.0f°C, %@, gió %.0f km/h", destination, temp.doubleValue, condition, wind.doubleValue] : [NSString stringWithFormat:@"%@\n%.0f°C, %@", destination, temp.doubleValue, condition];
            NSString *speech = [NSString stringWithFormat:@"Điểm đến %@, %.0f độ, %@.", destination, temp.doubleValue, condition];
            GMShowBannerForDuration(banner, 12.0);
            GMSpeakVietnamese(speech);
        }] resume];
    }];
}

static void GMCheckState(NSString *reason) {
    if (!GMIsGoogleMaps()) return;
    UIView *header = GMFindVisibleClass(kGMNavHeaderClass);
    UIView *footer = GMFindVisibleClass(kGMNavFooterClass);
    UIView *preview = GMFindVisibleClass(kGMDestinationClass);
    if (preview) GMCaptureDestinationFromPreview(preview, reason);
    NSString *state = [NSString stringWithFormat:@"header=%d footer=%d preview=%d nav=%d cached=%@", header != nil, footer != nil, preview != nil, (header || footer) != nil, gGMCachedDestination ?: @"<nil>"];
    if (![state isEqualToString:gGMLastState]) {
        gGMLastState = [state copy];
        GMLog(@"STATE reason=%@ %@", reason ?: @"unknown", state);
    }
    if ((header || footer) && gGMCachedDestination.length) GMFetchWeatherForDestination(gGMCachedDestination);
}

static void GMScheduleCheck(NSString *reason, NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ GMCheckState(reason); });
}

%hook UIView
- (void)didMoveToWindow {
    %orig;
    if (!GMIsGoogleMaps() || !self.window) return;
    NSString *name = NSStringFromClass(self.class);
    if ([name isEqualToString:kGMDestinationClass]) {
        GMLog(@"CLASS_SEEN %@", name);
        GMCaptureDestinationFromPreview(self, @"didMoveToWindow");
        GMScheduleCheck(@"destination-didMove", 0.4);
    } else if ([name isEqualToString:kGMNavHeaderClass] || [name isEqualToString:kGMNavFooterClass]) {
        GMLog(@"CLASS_SEEN %@", name);
        GMScheduleCheck(@"nav-didMove", 0.5);
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
            GMLog(@"PREVIEW_LABEL text=\"%@\"", text ?: @"");
            GMCaptureDestinationFromPreview(v, @"label-setText");
            break;
        }
        v = v.superview;
    }
}
%end

%ctor {
    @autoreleasepool {
        if (!GMIsGoogleMaps()) return;
        GMLog(@"========================================");
        GMLog(@"16.4-phone-weather-debug1 LOADED bundle=%@ process=%@", NSBundle.mainBundle.bundleIdentifier ?: @"", NSProcessInfo.processInfo.processName ?: @"");
        GMLog(@"logPath=%@", kGMDebugLogPath);
        GMLog(@"========================================");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            GMShowBannerForDuration(@"Weather debug loaded", 4.0);
            GMScanAndCacheDestination(@"startup");
            GMCheckState(@"startup");
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(__unused NSTimer *timer) { GMCheckState(@"timer"); }];
        });
    }
}
