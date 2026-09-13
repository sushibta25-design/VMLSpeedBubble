#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <notify.h>

static NSString * const kTHWBundle = @"com.apple.CarPlayTemplateUIHost";
static NSString * const kTHWPreviewClass = @"CPSPagingTripPreviewsCardView";
static NSString * const kTHWETAClass = @"CPSNavigationETAView";
static const char *kTHWWeatherNotify = "com.sushibta.vmlspeedbubble.weather";
static NSString * const kTHWLogPath = @"/var/mobile/VMLTemplateWeather.txt";

static NSString *gTHWName = nil;
static NSString *gTHWAddress = nil;
static NSString *gTHWLastSentQuery = nil;
static NSDate *gTHWLastSentAt = nil;
static int gTHWNotifyToken = 0;
static BOOL gTHWFetching = NO;

static BOOL THWIsHost(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:kTHWBundle];
}

static void THWLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ | %@\n", [NSDate date], msg ?: @""];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:kTHWLogPath]) {
        [data writeToFile:kTHWLogPath atomically:YES];
        return;
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kTHWLogPath];
    if (!fh) return;
    @try { [fh seekToEndOfFile]; [fh writeData:data]; [fh closeFile]; }
    @catch (__unused NSException *e) {}
}

static NSArray<UIWindow *> *THWWindows(void) {
    NSMutableArray<UIWindow *> *out = [NSMutableArray array];
    for (UIScene *raw in UIApplication.sharedApplication.connectedScenes) {
        if (![raw isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)raw).windows) {
            if (w && ![out containsObject:w]) [out addObject:w];
        }
    }
    return out;
}

static UIView *THWFindClass(UIView *root, NSString *className) {
    if (!root) return nil;
    if ([NSStringFromClass(root.class) isEqualToString:className]) return root;
    for (UIView *sub in root.subviews) {
        UIView *found = THWFindClass(sub, className);
        if (found) return found;
    }
    return nil;
}

static UIView *THWVisibleClass(NSString *className) {
    for (UIWindow *w in THWWindows()) {
        if (w.hidden || w.alpha <= 0.01 || !w.rootViewController.view) continue;
        UIView *found = THWFindClass(w.rootViewController.view, className);
        if (found && !found.hidden && found.alpha > 0.01) return found;
    }
    return nil;
}

static void THWCollectText(UIView *view, NSMutableArray<NSString *> *out) {
    if (!view || view.hidden || view.alpha <= 0.01) return;
    NSString *text = nil;
    if ([view isKindOfClass:UILabel.class]) text = ((UILabel *)view).text;
    else if ([view isKindOfClass:UIButton.class]) text = ((UIButton *)view).currentTitle;
    if (!text.length) text = view.accessibilityLabel;
    if (text.length) {
        NSString *clean = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (clean.length && ![out containsObject:clean]) [out addObject:clean];
    }
    for (UIView *sub in view.subviews) THWCollectText(sub, out);
}

static NSString *THWAddressFromText(NSString *text) {
    if (!text.length) return nil;
    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    for (NSString *raw in [lines reverseObjectEnumerator]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (line.length >= 12 && ([line containsString:@","] || [line localizedCaseInsensitiveContainsString:@"Việt Nam"])) return line;
    }
    if (text.length >= 20 && [text containsString:@","]) return text;
    return nil;
}

static BOOL THWGenericText(NSString *s) {
    NSString *l = s.lowercaseString;
    NSArray<NSString *> *blocked = @[@"bắt đầu", @"hủy", @"lộ trình khác", @"tuyến đường", @"phút", @"km", @"đến", @"qua "];
    for (NSString *b in blocked) if ([l containsString:b]) return YES;
    return NO;
}

static void THWCaptureDestination(void) {
    UIView *preview = THWVisibleClass(kTHWPreviewClass);
    if (!preview) return;
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    THWCollectText(preview, texts);

    NSString *name = nil;
    NSString *address = nil;
    for (NSString *s in texts) {
        NSString *candidateAddress = THWAddressFromText(s);
        if (!address.length && candidateAddress.length) address = candidateAddress;
        if (!name.length && s.length >= 2 && s.length <= 100 && !THWGenericText(s) && !candidateAddress.length) name = s;
    }

    BOOL changed = NO;
    if (name.length && ![name isEqualToString:gTHWName]) { gTHWName = [name copy]; changed = YES; }
    if (address.length && ![address isEqualToString:gTHWAddress]) { gTHWAddress = [address copy]; changed = YES; }
    if (changed) THWLog(@"cached name=%@ address=%@ texts=%@", gTHWName ?: @"<nil>", gTHWAddress ?: @"<nil>", texts);
}

static BOOL THWNavigationActive(void) {
    return THWVisibleClass(kTHWETAClass) != nil;
}

static void THWPostWeather(double tempC, NSInteger code, double windKmh) {
    if (!gTHWNotifyToken) {
        int token = 0;
        uint32_t status = notify_register_check(kTHWWeatherNotify, &token);
        if (status != NOTIFY_STATUS_OK) { THWLog(@"notify_register_check failed=%u", status); return; }
        gTHWNotifyToken = token;
    }
    NSInteger temp10 = (NSInteger)llround(tempC * 10.0);
    NSInteger wind10 = (NSInteger)llround(MAX(0.0, windKmh) * 10.0);
    uint64_t tempPacked = (uint64_t)MAX(0, MIN(65535, temp10 + 1000));
    uint64_t codePacked = (uint64_t)MAX(0, MIN(255, code));
    uint64_t windPacked = (uint64_t)MAX(0, MIN(65535, wind10));
    uint64_t state = tempPacked | (codePacked << 16) | (windPacked << 24);
    uint32_t setStatus = notify_set_state(gTHWNotifyToken, state);
    uint32_t postStatus = notify_post(kTHWWeatherNotify);
    THWLog(@"posted weather temp=%.1f code=%ld wind=%.1f set=%u post=%u", tempC, (long)code, windKmh, setStatus, postStatus);
}

static void THWFetchIfReady(void) {
    THWCaptureDestination();
    if (!THWNavigationActive() || gTHWFetching) return;
    NSString *query = gTHWAddress.length ? gTHWAddress : gTHWName;
    if (!query.length) return;
    if ([query isEqualToString:gTHWLastSentQuery] && gTHWLastSentAt && [[NSDate date] timeIntervalSinceDate:gTHWLastSentAt] < 300.0) return;

    gTHWFetching = YES;
    THWLog(@"navigation active; geocode query=%@ name=%@", query, gTHWName ?: @"<nil>");
    CLGeocoder *geocoder = [CLGeocoder new];
    [geocoder geocodeAddressString:query completionHandler:^(NSArray<CLPlacemark *> *placemarks, NSError *error) {
        CLLocation *location = placemarks.firstObject.location;
        if (error || !location) {
            THWLog(@"geocode failed error=%@ count=%lu", error.localizedDescription ?: @"none", (unsigned long)placemarks.count);
            gTHWFetching = NO;
            return;
        }
        THWLog(@"geocode ok lat=%.6f lon=%.6f", location.coordinate.latitude, location.coordinate.longitude);
        NSString *urlString = [NSString stringWithFormat:@"https://api.open-meteo.com/v1/forecast?latitude=%.6f&longitude=%.6f&current=temperature_2m,weather_code,wind_speed_10m&timezone=auto", location.coordinate.latitude, location.coordinate.longitude];
        NSURL *url = [NSURL URLWithString:urlString];
        if (!url) { gTHWFetching = NO; return; }
        [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *netError) {
            NSInteger statusCode = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
            THWLog(@"open-meteo status=%ld bytes=%lu error=%@", (long)statusCode, (unsigned long)data.length, netError.localizedDescription ?: @"none");
            if (netError || !data) { gTHWFetching = NO; return; }
            NSError *jsonError = nil;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            NSDictionary *current = [json isKindOfClass:NSDictionary.class] ? json[@"current"] : nil;
            NSNumber *temp = current[@"temperature_2m"];
            NSNumber *code = current[@"weather_code"];
            NSNumber *wind = current[@"wind_speed_10m"];
            if (!temp || !code) {
                THWLog(@"parse failed current=%@ error=%@", current, jsonError.localizedDescription ?: @"none");
                gTHWFetching = NO;
                return;
            }
            gTHWLastSentQuery = [query copy];
            gTHWLastSentAt = [NSDate date];
            THWPostWeather(temp.doubleValue, code.integerValue, wind ? wind.doubleValue : 0.0);
            gTHWFetching = NO;
        }] resume];
    }];
}

static void THWSchedule(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ THWFetchIfReady(); });
}

%hook UIView
- (void)didMoveToWindow {
    %orig;
    if (!THWIsHost() || !self.window) return;
    NSString *name = NSStringFromClass(self.class);
    if ([name isEqualToString:kTHWPreviewClass]) THWCaptureDestination();
    if ([name isEqualToString:kTHWPreviewClass] || [name isEqualToString:kTHWETAClass]) THWSchedule();
}
%end

%hook UILabel
- (void)setText:(NSString *)text {
    %orig;
    if (!THWIsHost() || !self.window) return;
    UIView *v = self;
    while (v) {
        if ([NSStringFromClass(v.class) isEqualToString:kTHWPreviewClass]) {
            THWCaptureDestination();
            THWSchedule();
            break;
        }
        v = v.superview;
    }
}
%end

%ctor {
    @autoreleasepool {
        if (!THWIsHost()) return;
        THWLog(@"16.13 template weather sender loaded");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            THWCaptureDestination();
            THWFetchIfReady();
            [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(__unused NSTimer *timer) { THWFetchIfReady(); }];
        });
    }
}
