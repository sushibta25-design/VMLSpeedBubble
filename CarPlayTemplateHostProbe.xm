#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

static NSString * const kTHPLogPath = @"/var/mobile/VMLTemplateHostProbe.txt";
static NSString *gTHPLastFingerprint = nil;

static BOOL THPIsTemplateHost(void) {
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"";
    NSString *process = NSProcessInfo.processInfo.processName ?: @"";
    return [bundle isEqualToString:@"com.apple.CarPlayTemplateUIHost"] ||
           [process localizedCaseInsensitiveContainsString:@"CarPlayTemplateUIHost"];
}

static void THPLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ | %@\n", [NSDate date], message ?: @""];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:kTHPLogPath]) {
        [data writeToFile:kTHPLogPath atomically:YES];
        return;
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kTHPLogPath];
    if (!fh) return;
    @try { [fh seekToEndOfFile]; [fh writeData:data]; [fh closeFile]; }
    @catch (__unused NSException *e) {}
}

static NSArray<UIWindow *> *THPWindows(void) {
    NSMutableArray<UIWindow *> *out = [NSMutableArray array];
    for (UIScene *raw in UIApplication.sharedApplication.connectedScenes) {
        if (![raw isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *scene = (UIWindowScene *)raw;
        for (UIWindow *w in scene.windows) if (w && ![out containsObject:w]) [out addObject:w];
    }
    return out;
}

static NSString *THPTextForView(UIView *view) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if ([view isKindOfClass:UILabel.class] && ((UILabel *)view).text.length) [parts addObject:((UILabel *)view).text];
    if ([view isKindOfClass:UIButton.class] && ((UIButton *)view).currentTitle.length) [parts addObject:((UIButton *)view).currentTitle];
    if ([view isKindOfClass:UITextField.class] && ((UITextField *)view).text.length) [parts addObject:((UITextField *)view).text];
    if ([view isKindOfClass:UITextView.class] && ((UITextView *)view).text.length) [parts addObject:((UITextView *)view).text];
    if (view.accessibilityLabel.length) [parts addObject:[NSString stringWithFormat:@"axLabel=%@", view.accessibilityLabel]];
    if (view.accessibilityValue.length) [parts addObject:[NSString stringWithFormat:@"axValue=%@", view.accessibilityValue]];
    if (view.accessibilityIdentifier.length) [parts addObject:[NSString stringWithFormat:@"axID=%@", view.accessibilityIdentifier]];
    return [parts componentsJoinedByString:@" | "];
}

static void THPDumpView(UIView *view, NSUInteger depth, NSMutableArray<NSString *> *lines) {
    if (!view || depth > 18) return;
    NSString *text = THPTextForView(view);
    BOOL interesting = text.length || depth <= 5;
    if (interesting) {
        NSString *indent = [@"                                        " substringToIndex:MIN(depth * 2, 40UL)];
        [lines addObject:[NSString stringWithFormat:@"%@%@ frame=%@ hidden=%d alpha=%.2f %@",
                          indent, NSStringFromClass(view.class), NSStringFromCGRect(view.frame), view.hidden, view.alpha, text]];
    }
    for (UIView *sub in view.subviews) THPDumpView(sub, depth + 1, lines);
}

static void THPDump(NSString *reason) {
    if (!THPIsTemplateHost()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"<nil>";
        NSString *process = NSProcessInfo.processInfo.processName ?: @"<nil>";
        [lines addObject:[NSString stringWithFormat:@"bundle=%@ process=%@ reason=%@ scenes=%lu", bundle, process, reason ?: @"?", (unsigned long)UIApplication.sharedApplication.connectedScenes.count]];
        NSInteger wi = 0;
        for (UIWindow *w in THPWindows()) {
            [lines addObject:[NSString stringWithFormat:@"WINDOW[%ld] class=%@ frame=%@ level=%.1f hidden=%d key=%d root=%@",
                              (long)wi++, NSStringFromClass(w.class), NSStringFromCGRect(w.frame), w.windowLevel, w.hidden, w.isKeyWindow,
                              w.rootViewController ? NSStringFromClass(w.rootViewController.class) : @"nil"]];
            if (w.rootViewController.view) THPDumpView(w.rootViewController.view, 0, lines);
        }
        NSString *fingerprint = [lines componentsJoinedByString:@"\n"];
        if ([fingerprint isEqualToString:gTHPLastFingerprint]) return;
        gTHPLastFingerprint = [fingerprint copy];
        THPLog(@"================ %@ ================", reason ?: @"dump");
        for (NSString *line in lines) THPLog(@"%@", line);
    });
}

static void THPShowProbe(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = nil;
        for (UIWindow *w in THPWindows()) if (!w.hidden && w.alpha > 0.01 && w.rootViewController) { window = w; if (w.isKeyWindow) break; }
        if (!window) return;
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(20, 18, MAX(100, window.bounds.size.width - 40), 52)];
        label.text = @"TEMPLATE HOST OK";
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = UIColor.whiteColor;
        label.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.95];
        label.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
        label.layer.cornerRadius = 12;
        label.layer.masksToBounds = YES;
        label.userInteractionEnabled = NO;
        label.tag = 916512;
        [[window viewWithTag:916512] removeFromSuperview];
        [window addSubview:label];
        [window bringSubviewToFront:label];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [label removeFromSuperview]; });
    });
}

%hook UIView
- (void)didMoveToWindow {
    %orig;
    if (!THPIsTemplateHost() || !self.window) return;
    NSString *name = NSStringFromClass(self.class);
    if ([name localizedCaseInsensitiveContainsString:@"template"] ||
        [name localizedCaseInsensitiveContainsString:@"map"] ||
        self.accessibilityLabel.length || self.accessibilityValue.length) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ THPDump(@"view-change"); });
    }
}
%end

%ctor {
    @autoreleasepool {
        if (!THPIsTemplateHost()) return;
        THPLog(@"16.12 template host probe loaded bundle=%@ process=%@", NSBundle.mainBundle.bundleIdentifier ?: @"", NSProcessInfo.processInfo.processName ?: @"");
        [[NSNotificationCenter defaultCenter] addObserverForName:UISceneDidActivateNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *note) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ THPShowProbe(); THPDump(@"scene-active"); });
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            THPShowProbe();
            THPDump(@"startup");
            [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(__unused NSTimer *timer) { THPDump(@"timer"); }];
        });
    }
}
