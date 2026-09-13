#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <notify.h>

static NSString * const kGMWBundle = @"com.google.Maps";
static NSString * const kGMWDestinationClass = @"AZDDestinationPreviewContentView";
static NSString * const kGMWNavHeaderClass = @"GMSNavHeaderView";
static NSString * const kGMWNavFooterClass = @"GMSNavFooterRouteSummaryView";
static const char *kGMWWeatherNotify = "com.sushibta.vmlspeedbubble.weather";
static const char *kGMWTestNotify = "com.sushibta.vmlspeedbubble.weather.test";

static NSString *gGMWDestination = nil;
static NSString *gGMWLastSentDestination = nil;
static NSDate *gGMWLastSentAt = nil;
static int gGMWNotifyToken = 0;

static BOOL GMWIsGoogleMaps(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:kGMWBundle];
}

static NSArray<UIWindow *> *GMWWindows(void) {
    NSMutableArray<UIWindow *> *out = [NSMutableArray array];
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
        NSArray *legacy = [app valueForKey:@"windows"];
        for (UIWindow *w in legacy) if (w && ![out containsObject:w]) [out addObject:w];
    } @catch (__unused NSException *e) {}
    return out;
}

static UIView *GMWFind(UIView *root, NSString *className) {
    if (!root) return nil;
    if ([NSStringFromClass(root.class) isEqualToString:className]) return root;
    for (UIView *sub in root.subviews) {
        UIView *found = GMWFind(sub, className);
        if (found) return found;
    }
    return nil;
}

static UIView *GMWVisibleClass(NSString *className) {
    for (UIWindow *w in GMWWindows()) {
        if (w.hidden || w.alpha <= 0.01) continue;
        UIView *found = GMWFind(w, className);
        if (found) return found;
    }
    return nil;
}

static BOOL GMWNavigationActive(void) {
    return GMWVisibleClass(kGMWNavHeaderClass) != nil || GMWVisibleClass(kGMWNavFooterClass) != nil;
}

static void GMWCollectText(UIView *view, NSMutableArray<NSString *> *texts) {
    if (!view || view.hidden || view.alpha <= 0.01) return;
    NSArray<NSString *> *values = @[
        ([view isKindOfClass:UILabel.class] ? (((UILabel *)view).text ?: @"") : @""),
        ([view isKindOfClass:UITextField.class] ? (((UITextField *)view).text ?: @"") : @""),
        ([view isKindOfClass:UITextView.class] ? (((UITextView *)view).text ?: @"") : @""),
        ([view isKindOfClass:UIButton.class] ? (((UIButton *)view).currentTitle ?: @"") : @""),
        view.accessibilityLabel ?: @"",
        view.accessibilityValue ?: @""
    ];
    for (NSString *value in values) {
        NSString *clean = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (clean.length > 1 && clean.length < 180 && ![texts containsObject:clean]) [texts addObject:clean];
    }
    for (UIView *sub in view.subviews) GMWCollectText(sub, texts);
}

static NSString *GMWChooseDestination(NSArray<NSString *> *texts) {
    for (NSString *candidate in texts) {
        NSString *lower = candidate.lowercaseString;
        if ([lower containsString:@"km"] || [lower containsString:@"min"] || [lower containsString:@"phút"] || [lower containsString:@"giờ"] || [lower containsString:@"bắt đầu"] || [lower containsString:@"start"]) continue;
        return candidate;
    }
    return nil;
}

static void GMWCaptureDestination(void) {
    UIView *preview = GMWVisibleClass(kGMWDestinationClass);
    if (!preview) return;
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    GMWCollectText(preview, texts);
    NSString *chosen = GMWChooseDestination(texts);
    if (chosen.length && ![chosen isEqualToString:gGMWDestination]) {
        gGMWDestination = [chosen copy];
        NSLog(@"[GMWIPC] destination cached=%@ texts=%@", gGMWDestination, texts);
    }
}

static void GMWPostSenderTest(void) {
    notify_post(kGMWTestNotify);
    NSLog(@"[GMWIPC] sender test posted");
}

static void GMWPostWeather(double tempC, NSInteger code, double windKmh) {
    if (!gGMWNotifyToken) {
        int token = 0;
        uint32_t status = notify_register_check(kGMWWeatherNotify, &token);
        if (status != NOTIFY_STATUS_OK) {
            NSLog(@"[GMWIPC] notify_register_check failed=%u", status);
            return;
        }
        gGMWNotifyToken = token;
    }
    NSInteger temp10 = (NSInteger)llround(tempC * 10.0);
    NSInteger wind10 = (NSInteger)llround(MAX(0.0, windKmh) * 10.0);
    uint64_t tempPacked = (uint64_t)MAX(0, MIN(65535, temp10 + 1000));
    uint64_t codePacked = (uint64_t)MAX(0, MIN(255, code));
    uint64_t windPacked = (uint64_t)MAX(0, MIN(65535, wind10));
    uint64_t state = tempPacked | (codePacked << 16) | (windPacked << 24);
    uint32_t setStatus = notify_set_state(gGMWNotifyToken, state);
    uint32_t postStatus = notify_post(kGMWWeatherNotify);
    NSLog(@"[GMWIPC] weather posted state=%llu temp=%.1f code=%ld wind=%.1f set=%u post=%u", state, tempC, (long)code, windKmh, setStatus, postStatus);
}

static void GMWFetchWeatherIfReady(void) {
    GMWCaptureDestination();
    BOOL nav = GMWNavigationActive();
    NSLog(@"[GMWIPC] tick nav=%d destination=%@", nav, gGMWDestination ?: @"<nil>");
    if (!nav || !gGMWDestination.length) return;
    if ([gGMWDestination isEqualToString:gGMWLastSentDestination] && gGMWLastSentAt && [[NSDate date] timeIntervalSinceDate:gGMWLastSentAt] < 300.0) return;

    gGMWLastSentDestination = [gGMWDestination copy];
    gGMWLastSentAt = [NSDate date];
    NSString *query = [gGMWDestination copy];
    NSLog(@"[GMWIPC] geocode start=%@", query);

    CLGeocoder *geocoder = [CLGeocoder new];
    [geocoder geocodeAddressString:query completionHandler:^(NSArray<CLPlacemark *> *placemarks, NSError *error) {
        CLLocation *location = placemarks.firstObject.location;
        NSLog(@"[GMWIPC] geocode count=%lu error=%@ location=%@", (unsigned long)placemarks.count, error.localizedDescription ?: @"none", location);
        if (error || !location) return;

        NSString *urlString = [NSString stringWithFormat:@"https://api.open-meteo.com/v1/forecast?latitude=%.6f&longitude=%.6f&current=temperature_2m,weather_code,wind_speed_10m&timezone=auto", location.coordinate.latitude, location.coordinate.longitude];
        NSURL *url = [NSURL URLWithString:urlString];
        if (!url) return;
        NSLog(@"[GMWIPC] open-meteo request=%@", urlString);

        [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *netError) {
            NSInteger statusCode = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
            NSLog(@"[GMWIPC] open-meteo status=%ld bytes=%lu error=%@", (long)statusCode, (unsigned long)data.length, netError.localizedDescription ?: @"none");
            if (netError || !data) return;

            NSError *jsonError = nil;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            NSDictionary *current = [json isKindOfClass:NSDictionary.class] ? json[@"current"] : nil;
            NSNumber *temp = current[@"temperature_2m"];
            NSNumber *code = current[@"weather_code"];
            NSNumber *wind = current[@"wind_speed_10m"];
            NSLog(@"[GMWIPC] parsed current=%@ jsonError=%@", current, jsonError.localizedDescription ?: @"none");
            if (!temp || !code) return;
            GMWPostWeather(temp.doubleValue, code.integerValue, wind ? wind.doubleValue : 0.0);
        }] resume];
    }];
}

static void GMWSchedule(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        GMWFetchWeatherIfReady();
    });
}

%hook UIView
- (void)didMoveToWindow {
    %orig;
    if (!GMWIsGoogleMaps() || !self.window) return;
    NSString *name = NSStringFromClass(self.class);
    if ([name isEqualToString:kGMWDestinationClass]) {
        NSLog(@"[GMWIPC] class seen=%@", name);
        GMWCaptureDestination();
    }
    if ([name isEqualToString:kGMWDestinationClass] || [name isEqualToString:kGMWNavHeaderClass] || [name isEqualToString:kGMWNavFooterClass]) {
        NSLog(@"[GMWIPC] trigger class=%@", name);
        GMWSchedule();
    }
}
%end

%hook UILabel
- (void)setText:(NSString *)text {
    %orig;
    if (!GMWIsGoogleMaps() || !self.window) return;
    UIView *v = self;
    while (v) {
        if ([NSStringFromClass(v.class) isEqualToString:kGMWDestinationClass]) {
            NSLog(@"[GMWIPC] preview label=%@", text ?: @"");
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
        NSLog(@"[GMWIPC] 16.7 sender loaded bundle=%@", NSBundle.mainBundle.bundleIdentifier ?: @"");

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            GMWPostSenderTest();
        });

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            GMWCaptureDestination();
            GMWFetchWeatherIfReady();
            [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(__unused NSTimer *timer) {
                GMWFetchWeatherIfReady();
            }];
        });
    }
}
