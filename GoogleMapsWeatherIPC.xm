#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <notify.h>

static NSString * const kGMWBundle = @"com.google.Maps";
static NSString * const kGMWDestinationClass = @"AZDDestinationPreviewContentView";
static NSString * const kGMWNavHeaderClass = @"GMSNavHeaderView";
static NSString * const kGMWNavFooterClass = @"GMSNavFooterRouteSummaryView";
static const char *kGMWWeatherNotify = "com.sushibta.vmlspeedbubble.weather";

static NSString *gGMWDestination = nil;
static NSString *gGMWLastSentDestination = nil;
static NSDate *gGMWLastSentAt = nil;
static int gGMWNotifyToken = 0;

static BOOL GMWIsGoogleMaps(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:kGMWBundle];
}

static NSArray<UIWindow *> *GMWWindows(void) {
    NSMutableArray *out = [NSMutableArray array];
    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w && ![out containsObject:w]) [out addObject:w];
            }
        }
    }
    @try {
        for (UIWindow *w in [app valueForKey:@"windows"]) {
            if (w && ![out containsObject:w]) [out addObject:w];
        }
    } @catch (__unused NSException *e) {}
    return out;
}

static UIView *GMWFind(UIView *root, NSString *className) {
    if (!root) return nil;
    if ([NSStringFromClass(root.class) isEqualToString:className]) return root;
    for (UIView *sub in root.subviews) {
        UIView *f = GMWFind(sub, className);
        if (f) return f;
    }
    return nil;
}

static UIView *GMWVisibleClass(NSString *className) {
    for (UIWindow *w in GMWWindows()) {
        if (w.hidden || w.alpha <= 0.01) continue;
        UIView *f = GMWFind(w, className);
        if (f) return f;
    }
    return nil;
}

static BOOL GMWNavigationActive(void) {
    return GMWVisibleClass(kGMWNavHeaderClass) != nil || GMWVisibleClass(kGMWNavFooterClass) != nil;
}

static void GMWCollectText(UIView *view, NSMutableArray<NSString *> *texts) {
    if (!view || view.hidden || view.alpha <= 0.01) return;
    NSArray *values = @[
        ([view isKindOfClass:UILabel.class] ? (((UILabel *)view).text ?: @"") : @""),
        ([view isKindOfClass:UITextField.class] ? (((UITextField *)view).text ?: @"") : @""),
        ([view isKindOfClass:UITextView.class] ? (((UITextView *)view).text ?: @"") : @""),
        ([view isKindOfClass:UIButton.class] ? (((UIButton *)view).currentTitle ?: @"") : @""),
        view.accessibilityLabel ?: @"",
        view.accessibilityValue ?: @""
    ];
    for (NSString *value in values) {
        NSString *s = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (s.length > 1 && s.length < 180 && ![texts containsObject:s]) [texts addObject:s];
    }
    for (UIView *sub in view.subviews) GMWCollectText(sub, texts);
}

static NSString *GMWChooseDestination(NSArray<NSString *> *texts) {
    for (NSString *s in texts) {
        NSString *l = s.lowercaseString;
        if ([l containsString:@"km"] || [l containsString:@"min"] || [l containsString:@"phút"] || [l containsString:@"giờ"] || [l containsString:@"bắt đầu"] || [l containsString:@"start"]) continue;
        return s;
    }
    return nil;
}

static void GMWCaptureDestination(void) {
    UIView *preview = GMWVisibleClass(kGMWDestinationClass);
    if (!preview) return;
    NSMutableArray *texts = [NSMutableArray array];
    GMWCollectText(preview, texts);
    NSString *chosen = GMWChooseDestination(texts);
    if (chosen.length) gGMWDestination = [chosen copy];
}

static void GMWPostWeather(double tempC, NSInteger code, double windKmh) {
    if (!gGMWNotifyToken) {
        int token = 0;
        if (notify_register_check(kGMWWeatherNotify, &token) != NOTIFY_STATUS_OK) return;
        gGMWNotifyToken = token;
    }
    NSInteger temp10 = (NSInteger)llround(tempC * 10.0);
    NSInteger wind10 = (NSInteger)llround(MAX(0.0, windKmh) * 10.0);
    uint64_t tempPacked = (uint64_t)MAX(0, MIN(65535, temp10 + 1000));
    uint64_t codePacked = (uint64_t)MAX(0, MIN(255, code));
    uint64_t windPacked = (uint64_t)MAX(0, MIN(65535, wind10));
    uint64_t state = tempPacked | (codePacked << 16) | (windPacked << 24);
    notify_set_state(gGMWNotifyToken, state);
    notify_post(kGMWWeatherNotify);
    NSLog(@"[GMWIPC] posted state=%llu temp=%.1f code=%ld wind=%.1f", state, tempC, (long)code, windKmh);
}

static void GMWFetchWeatherIfReady(void) {
    GMWCaptureDestination();
    if (!GMWNavigationActive() || !gGMWDestination.length) return;
    if ([gGMWDestination isEqualToString:gGMWLastSentDestination] && gGMWLastSentAt && [[NSDate date] timeIntervalSinceDate:gGMWLastSentAt] < 300.0) return;
    gGMWLastSentDestination = [gGMWDestination copy];
    gGMWLastSentAt = [NSDate date];

    CLGeocoder *geocoder = [CLGeocoder new];
    [geocoder geocodeAddressString:gGMWDestination completionHandler:^(NSArray<CLPlacemark *> *placemarks, NSError *error) {
        CLLocation *location = placemarks.firstObject.location;
        if (error || !location) return;
        NSString *urlString = [NSString stringWithFormat:@"https://api.open-meteo.com/v1/forecast?latitude=%.6f&longitude=%.6f&current=temperature_2m,weather_code,wind_speed_10m&timezone=auto", location.coordinate.latitude, location.coordinate.longitude];
        NSURL *url = [NSURL URLWithString:urlString];
        if (!url) return;
        [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *netError) {
            if (netError || !data) return;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSDictionary *current = [json isKindOfClass:NSDictionary.class] ? json[@"current"] : nil;
            NSNumber *temp = current[@"temperature_2m"];
            NSNumber *code = current[@"weather_code"];
            NSNumber *wind = current[@"wind_speed_10m"];
            if (!temp || !code) return;
            GMWPostWeather(temp.doubleValue, code.integerValue, wind ? wind.doubleValue : 0.0);
        }] resume];
    }];
}

static void GMWSchedule(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ GMWFetchWeatherIfReady(); });
}

%hook UIView
- (void)didMoveToWindow {
    %orig;
    if (!GMWIsGoogleMaps() || !self.window) return;
    NSString *name = NSStringFromClass(self.class);
    if ([name isEqualToString:kGMWDestinationClass]) GMWCaptureDestination();
    if ([name isEqualToString:kGMWDestinationClass] || [name isEqualToString:kGMWNavHeaderClass] || [name isEqualToString:kGMWNavFooterClass]) GMWSchedule();
}
%end

%hook UILabel
- (void)setText:(NSString *)text {
    %orig;
    if (!GMWIsGoogleMaps() || !self.window) return;
    UIView *v = self;
    while (v) {
        if ([NSStringFromClass(v.class) isEqualToString:kGMWDestinationClass]) {
            GMWCaptureDestination();
            GMWSchedule();
            break;
        }
        v = v.superview;
    }
}
%end

%ctor {
    @autoreleasepool {
        if (!GMWIsGoogleMaps()) return;
        NSLog(@"[GMWIPC] 16.6 sender loaded");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(__unused NSTimer *timer) { GMWFetchWeatherIfReady(); }];
        });
    }
}
