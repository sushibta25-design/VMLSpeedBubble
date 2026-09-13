#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

static NSString * const kProbePath = @"/var/mobile/VMLCarPlayHostProbe.txt";
static BOOL gProbeBannerShown = NO;

static BOOL CPProbeIsCarPlayApp(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.CarPlayApp"];
}

static void CPProbeWrite(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ | %@\n", [NSDate date], msg ?: @""];
    NSLog(@"[CPHOSTPROBE] %@", msg);
    FILE *f = fopen(kProbePath.UTF8String, "a");
    if (f) { fprintf(f, "%s", line.UTF8String); fclose(f); }
}

static NSString *CPProbeSafeValue(id obj, NSString *key) {
    @try {
        id v = [obj valueForKey:key];
        if (!v) return @"<nil>";
        return [v description] ?: @"<nil>";
    } @catch (__unused NSException *e) {
        return @"<KVC-error>";
    }
}

static void CPProbeDumpView(UIView *view, NSUInteger depth, NSMutableSet<NSString *> *seen) {
    if (!view || depth > 18) return;
    NSString *cls = NSStringFromClass(view.class) ?: @"";
    BOOL interesting = [cls containsString:@"SceneLayer"] || [cls containsString:@"HostContainer"] || [cls containsString:@"Hosted"] || [cls containsString:@"SceneHost"];
    if (interesting) {
        NSString *desc = view.description ?: @"";
        NSString *key = [NSString stringWithFormat:@"%p-%@", view, cls];
        if (![seen containsObject:key]) {
            [seen addObject:key];
            CPProbeWrite(@"HOST depth=%lu class=%@ frame=%@ hidden=%d alpha=%.2f", (unsigned long)depth, cls, NSStringFromCGRect(view.frame), view.hidden, view.alpha);
            CPProbeWrite(@"  desc=%@", desc);
            CPProbeWrite(@"  accessibilityIdentifier=%@ label=%@ value=%@", view.accessibilityIdentifier ?: @"<nil>", view.accessibilityLabel ?: @"<nil>", view.accessibilityValue ?: @"<nil>");
            NSArray<NSString *> *keys = @[@"scene", @"sceneIdentifier", @"identifier", @"hostIdentifier", @"sourceContext", @"context", @"displayIdentity", @"sceneHandle", @"hostedScene", @"layer"];
            for (NSString *k in keys) CPProbeWrite(@"  KVC %@=%@", k, CPProbeSafeValue(view, k));
            UIView *s = view.superview;
            NSMutableArray<NSString *> *chain = [NSMutableArray array];
            for (NSUInteger i = 0; s && i < 6; i++, s = s.superview) [chain addObject:NSStringFromClass(s.class) ?: @""];
            CPProbeWrite(@"  superChain=%@", chain);
        }
    }
    for (UIView *sub in view.subviews) CPProbeDumpView(sub, depth + 1, seen);
}

static void CPProbeDumpAll(NSString *reason) {
    if (!CPProbeIsCarPlayApp()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        CPProbeWrite(@"================ %@ ================", reason ?: @"scan");
        CPProbeWrite(@"bundle=%@ process=%@ scenes=%lu", NSBundle.mainBundle.bundleIdentifier ?: @"", NSProcessInfo.processInfo.processName ?: @"", (unsigned long)UIApplication.sharedApplication.connectedScenes.count);
        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        NSInteger si = 0;
        for (UIScene *raw in UIApplication.sharedApplication.connectedScenes) {
            if (![raw isKindOfClass:UIWindowScene.class]) continue;
            UIWindowScene *scene = (UIWindowScene *)raw;
            CPProbeWrite(@"SCENE[%ld] role=%@ pid=%@ state=%ld screen=%@ bounds=%@ windows=%lu", (long)si, scene.session.role ?: @"", scene.session.persistentIdentifier ?: @"", (long)scene.activationState, scene.screen, NSStringFromCGRect(scene.screen.bounds), (unsigned long)scene.windows.count);
            NSInteger wi = 0;
            for (UIWindow *w in scene.windows) {
                CPProbeWrite(@" WINDOW[%ld] class=%@ level=%.1f hidden=%d key=%d frame=%@ root=%@", (long)wi, NSStringFromClass(w.class), w.windowLevel, w.hidden, w.isKeyWindow, NSStringFromCGRect(w.frame), w.rootViewController ? NSStringFromClass(w.rootViewController.class) : @"nil");
                if (w.rootViewController.view) CPProbeDumpView(w.rootViewController.view, 0, seen);
                wi++;
            }
            si++;
        }
    });
}

static UIWindow *CPProbeBestWindow(void) {
    UIWindow *best = nil;
    CGFloat bestLevel = -CGFLOAT_MAX;
    for (UIScene *raw in UIApplication.sharedApplication.connectedScenes) {
        if (![raw isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *scene = (UIWindowScene *)raw;
        CGSize s = scene.screen.bounds.size;
        if (!(s.width > s.height && s.width >= 300 && s.height <= 500)) continue;
        for (UIWindow *w in scene.windows) {
            if (!w.hidden && w.alpha > 0.01 && w.rootViewController && w.windowLevel >= bestLevel) { best = w; bestLevel = w.windowLevel; }
        }
    }
    return best;
}

static void CPProbeShowBanner(void) {
    if (gProbeBannerShown) return;
    UIWindow *w = CPProbeBestWindow();
    if (!w) return;
    gProbeBannerShown = YES;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(20, 18, MAX(100, w.bounds.size.width - 40), 60)];
    label.text = @"HOST PROBE ACTIVE";
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = UIColor.whiteColor;
    label.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.96];
    label.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    label.layer.cornerRadius = 14;
    label.layer.masksToBounds = YES;
    label.tag = 916511;
    [w addSubview:label];
    [w bringSubviewToFront:label];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [label removeFromSuperview]; });
}

%ctor {
    @autoreleasepool {
        if (!CPProbeIsCarPlayApp()) return;
        [[NSFileManager defaultManager] removeItemAtPath:kProbePath error:nil];
        CPProbeWrite(@"16.11 host probe loaded");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ CPProbeShowBanner(); CPProbeDumpAll(@"startup+3s"); });
        [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(__unused NSTimer *timer) { CPProbeDumpAll(@"timer"); }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UISceneDidActivateNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *note) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ CPProbeDumpAll(@"sceneDidActivate"); }); }];
    }
}
