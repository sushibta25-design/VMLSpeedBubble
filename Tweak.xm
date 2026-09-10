#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>
#import <objc/message.h>

#pragma mark - Globals

static NSInteger gCurrentSpeed = 0;
static int gSpeedNotifyToken = 0;

static UIWindow *gPhoneWindow = nil;
static __weak UIView *gNativeCarPlayHost = nil;
static UIView *gNativeCarPlayBubble = nil;
static __weak UIViewController *gLastNativeController = nil;
static BOOL gNativeWatchdogRunning = NO;

static const NSInteger kPhoneBubbleTag = 990099;
static const NSInteger kCarPlayBubbleTag = 990199;
static const NSInteger kLabelTag = 990100;

#pragma mark - Logging

static void VMLLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"[VMLV12] %@", msg);

    NSString *line = [NSString stringWithFormat:@"%@\n", msg];
    FILE *f = fopen("/var/mobile/VMLHostSniffer.txt", "a");
    if (f) {
        fprintf(f, "%s", line.UTF8String);
        fclose(f);
    }
}

#pragma mark - Process helpers

static NSString *VMLBundle(void) {
    return NSBundle.mainBundle.bundleIdentifier ?: @"";
}

static NSString *VMLProcess(void) {
    return NSProcessInfo.processInfo.processName ?: @"";
}

static BOOL VMLIsSpringBoard(void) {
    return [VMLBundle() isEqualToString:@"com.apple.springboard"];
}

static BOOL VMLIsCarPlayApp(void) {
    return [VMLBundle() isEqualToString:@"com.apple.CarPlayApp"];
}

#pragma mark - Bubble

static NSString *VMLSpeedText(void) {
    if (gCurrentSpeed > 0 && gCurrentSpeed <= 200) {
        return [NSString stringWithFormat:@"%ld", (long)gCurrentSpeed];
    }
    return @"--";
}

static UIView *VMLMakeBubble(NSInteger tag, CGFloat size) {
    UIView *bubble = [[UIView alloc] initWithFrame:CGRectMake(0, 0, size, size)];
    bubble.tag = tag;
    bubble.backgroundColor = UIColor.whiteColor;
    bubble.layer.cornerRadius = size / 2.0;
    bubble.layer.borderWidth = 5.0;
    bubble.layer.borderColor = UIColor.systemRedColor.CGColor;
    bubble.clipsToBounds = YES;
    bubble.userInteractionEnabled = NO;

    UILabel *label = [[UILabel alloc] initWithFrame:bubble.bounds];
    label.tag = kLabelTag;
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    label.text = VMLSpeedText();
    label.textColor = UIColor.blackColor;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont systemFontOfSize:size * 0.40 weight:UIFontWeightBold];
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.5;

    [bubble addSubview:label];
    return bubble;
}

static void VMLUpdateBubble(UIView *bubble) {
    if (!bubble) return;
    UILabel *label = (UILabel *)[bubble viewWithTag:kLabelTag];
    if (label) label.text = VMLSpeedText();
    bubble.hidden = NO;
    bubble.alpha = 1.0;
    bubble.layer.zPosition = CGFLOAT_MAX;
    if (bubble.superview) {
        [bubble.superview bringSubviewToFront:bubble];
    }
}

static void VMLUpdateAllBubbles(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gPhoneWindow) {
            UIView *b = [gPhoneWindow viewWithTag:kPhoneBubbleTag];
            if (b) VMLUpdateBubble(b);
        }
        if (gNativeCarPlayBubble) {
            VMLUpdateBubble(gNativeCarPlayBubble);
        }
    });
}


#pragma mark - Persistent last valid speed

static NSString *VMLLastSpeedPath(void) {
    return @"/var/mobile/VMLLastSpeed.txt";
}

static NSInteger VMLReadCachedLastValidSpeed(void) {
    NSError *error = nil;
    NSString *s = [NSString stringWithContentsOfFile:VMLLastSpeedPath()
                                            encoding:NSUTF8StringEncoding
                                               error:&error];
    if (error || !s.length) return -1;

    NSInteger value = s.integerValue;
    if (value <= 0 || value > 200) return -1;
    return value;
}

static void VMLRestoreCachedSpeedImmediately(void) {
    NSInteger cached = VMLReadCachedLastValidSpeed();
    if (cached <= 0 || cached > 200) {
        VMLLog(@"[cache] no valid cached speed");
        return;
    }

    gCurrentSpeed = cached;
    VMLLog(@"*** IMMEDIATE CACHED SPEED RESTORED = %ld ***", (long)cached);
    VMLUpdateAllBubbles();
}

#pragma mark - Speed IPC

static void VMLReadSpeed(void) {
    if (gSpeedNotifyToken == 0) return;

    uint64_t state = 0;
    uint32_t status = notify_get_state(gSpeedNotifyToken, &state);
    if (status != NOTIFY_STATUS_OK) return;

    NSInteger speed = (NSInteger)state;
    if (speed < 0 || speed > 200) return;

    if (speed == 0) {
        if (gCurrentSpeed > 0 && gCurrentSpeed <= 200) {
            VMLLog(@"[speed] received 0 -> KEEP LAST VALID %ld", (long)gCurrentSpeed);
            VMLUpdateAllBubbles();
            return;
        }

        NSInteger cached = VMLReadCachedLastValidSpeed();
        if (cached > 0 && cached <= 200) {
            gCurrentSpeed = cached;
            VMLLog(@"[speed] received 0 -> RESTORE CACHE %ld", (long)cached);
            VMLUpdateAllBubbles();
            return;
        }

        VMLLog(@"[speed] received 0 and no cache -> --");
        return;
    }

    gCurrentSpeed = speed;
    VMLLog(@"*** SPEED RECEIVED = %ld ***", (long)gCurrentSpeed);
    VMLUpdateAllBubbles();
}

static void VMLStartSpeedReceiver(void) {
    if (gSpeedNotifyToken != 0) return;

    int token = 0;
    uint32_t status = notify_register_dispatch(
        "com.sushibta.vmlspeedbubble.speed",
        &token,
        dispatch_get_main_queue(),
        ^(int incomingToken) {
            gSpeedNotifyToken = incomingToken;
            VMLReadSpeed();
        }
    );

    if (status != NOTIFY_STATUS_OK) {
        VMLLog(@"notify_register_dispatch failed=%u", status);
        return;
    }

    gSpeedNotifyToken = token;
    VMLLog(@"SPEED RECEIVER ACTIVE token=%d bundle=%@", token, VMLBundle());

    VMLRestoreCachedSpeedImmediately();
    VMLReadSpeed();
}

#pragma mark - Phone bubble

static UIWindowScene *VMLPhoneScene(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        CGSize s = ws.screen.bounds.size;
        if (s.width <= 430.0 && s.height >= 600.0) return ws;
    }
    return nil;
}

static void VMLCreatePhoneBubble(void) {
    if (!VMLIsSpringBoard() || gPhoneWindow) return;

    UIWindowScene *scene = VMLPhoneScene();
    if (!scene) {
        VMLLog(@"PHONE SCENE NOT FOUND");
        return;
    }

    CGFloat size = 64.0;
    gPhoneWindow = [[UIWindow alloc] initWithWindowScene:scene];
    gPhoneWindow.frame = CGRectMake(18, 110, size, size);
    gPhoneWindow.backgroundColor = UIColor.clearColor;
    gPhoneWindow.windowLevel = UIWindowLevelAlert + 1000;

    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.clearColor;
    gPhoneWindow.rootViewController = vc;

    UIView *bubble = VMLMakeBubble(kPhoneBubbleTag, size);
    [vc.view addSubview:bubble];

    gPhoneWindow.hidden = NO;
    VMLLog(@"*** PHONE BUBBLE CREATED text=%@ ***", VMLSpeedText());
}

#pragma mark - Native CarPlay host discovery

static BOOL VMLClassLooksNativeCarPlayController(NSString *name) {
    if (!name.length) return NO;

    NSArray<NSString *> *exact = @[
        @"CARAppDockViewController",
        @"DBDashboardRootViewController"
    ];

    for (NSString *s in exact) {
        if ([name isEqualToString:s]) return YES;
    }

    NSArray<NSString *> *tokens = @[
        @"CarPlay",
        @"Dashboard",
        @"AppDock",
        @"DockViewController"
    ];

    for (NSString *token in tokens) {
        if ([name containsString:token]) return YES;
    }

    return NO;
}

static UIView *VMLCallViewSelector(id obj, NSString *selectorName) {
    if (!obj || !selectorName.length) return nil;

    SEL sel = NSSelectorFromString(selectorName);
    if (![obj respondsToSelector:sel]) return nil;

    id result = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
    if ([result isKindOfClass:UIView.class]) {
        VMLLog(@"[native] selector %@ -> %@ frame=%@",
               selectorName,
               NSStringFromClass([result class]),
               NSStringFromCGRect([(UIView *)result frame]));
        return (UIView *)result;
    }

    return nil;
}

static UIView *VMLPreferredNativeHost(UIViewController *vc) {
    if (!vc) return nil;

    NSArray<NSString *> *selectors = @[
        @"dockModeHostViewCreatingIfNeeded",
        @"splitHostView",
        @"host"
    ];

    for (NSString *selName in selectors) {
        UIView *v = VMLCallViewSelector(vc, selName);
        if (v && v.window) return v;
    }

    UIView *view = vc.view;
    if (view && view.window) return view;

    return nil;
}

static void VMLAttachNativeCarPlayBubble(UIView *host, NSString *reason) {
    if (!VMLIsCarPlayApp() || !host || !host.window) return;

    if (gNativeCarPlayBubble && gNativeCarPlayBubble.superview == host) {
        VMLUpdateBubble(gNativeCarPlayBubble);
        return;
    }

    if (gNativeCarPlayBubble && gNativeCarPlayBubble.superview) {
        [gNativeCarPlayBubble removeFromSuperview];
        gNativeCarPlayBubble = nil;
    }

    CGFloat W = MAX(host.bounds.size.width, 1.0);
    CGFloat H = MAX(host.bounds.size.height, 1.0);
    CGFloat size = MAX(42.0, MIN(56.0, H * 0.20));

    UIView *bubble = VMLMakeBubble(kCarPlayBubbleTag, size);

    CGFloat x = MAX(8.0, MIN(W - size - 8.0, W * 0.08));
    CGFloat y = MAX(8.0, MIN(H - size - 8.0, H * 0.50));
    bubble.frame = CGRectMake(x, y, size, size);
    bubble.layer.zPosition = CGFLOAT_MAX;

    [host addSubview:bubble];
    [host bringSubviewToFront:bubble];

    gNativeCarPlayHost = host;
    gNativeCarPlayBubble = bubble;

    VMLLog(@"*** NATIVE CARPLAY BUBBLE ADDED V12.1 reason=%@ host=%@ frame=%@ window=%@ windowFrame=%@ text=%@ ***",
           reason,
           NSStringFromClass(host.class),
           NSStringFromCGRect(host.frame),
           NSStringFromClass(host.window.class),
           NSStringFromCGRect(host.window.frame),
           VMLSpeedText());
}

static void VMLHandleNativeCarPlayController(UIViewController *vc, NSString *reason) {
    if (!VMLIsCarPlayApp() || !vc) return;

    NSString *name = NSStringFromClass(vc.class);
    if (!VMLClassLooksNativeCarPlayController(name)) return;

    gLastNativeController = vc;

    VMLLog(@"[native] controller=%@ reason=%@ view=%@ frame=%@ window=%@",
           name,
           reason,
           NSStringFromClass(vc.view.class),
           NSStringFromCGRect(vc.view.frame),
           vc.view.window ? NSStringFromClass(vc.view.window.class) : @"nil");

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC),
        dispatch_get_main_queue(),
        ^{
            UIView *host = VMLPreferredNativeHost(vc);
            if (host) {
                VMLAttachNativeCarPlayBubble(
                    host,
                    [NSString stringWithFormat:@"%@:%@", reason, name]
                );
            } else {
                VMLLog(@"[native] NO HOST for controller=%@", name);
            }
        }
    );
}


#pragma mark - Native CarPlay persistent watchdog

static void VMLNativeWatchdogTick(void) {
    if (!VMLIsCarPlayApp()) {
        gNativeWatchdogRunning = NO;
        return;
    }

    BOOL bubbleAlive =
        gNativeCarPlayBubble &&
        gNativeCarPlayBubble.superview &&
        gNativeCarPlayBubble.window &&
        !gNativeCarPlayBubble.hidden;

    if (!bubbleAlive) {
        UIViewController *vc = gLastNativeController;

        if (vc) {
            UIView *host = VMLPreferredNativeHost(vc);
            if (host && host.window) {
                VMLLog(@"[watchdog] bubble missing -> reattach host=%@ frame=%@",
                       NSStringFromClass(host.class),
                       NSStringFromCGRect(host.frame));

                VMLAttachNativeCarPlayBubble(host, @"watchdog-reattach");
            } else {
                VMLLog(@"[watchdog] bubble missing, last controller has no live host");
            }
        } else {
            VMLLog(@"[watchdog] bubble missing, no native controller captured yet");
        }
    } else {
        VMLUpdateBubble(gNativeCarPlayBubble);
    }

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
        dispatch_get_main_queue(),
        ^{
            VMLNativeWatchdogTick();
        }
    );
}

static void VMLStartNativeWatchdog(void) {
    if (!VMLIsCarPlayApp() || gNativeWatchdogRunning) return;

    gNativeWatchdogRunning = YES;
    VMLLog(@"[watchdog] V12.1 native watchdog started");

    dispatch_async(dispatch_get_main_queue(), ^{
        VMLNativeWatchdogTick();
    });
}

#pragma mark - Hooks

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    VMLHandleNativeCarPlayController(self, @"viewDidAppear");
}

- (void)viewDidLayoutSubviews {
    %orig;
    VMLHandleNativeCarPlayController(self, @"viewDidLayoutSubviews");
}

%end

%hook UIView

- (void)didMoveToWindow {
    %orig;

    if (!VMLIsCarPlayApp() || !self.window) return;

    NSString *name = NSStringFromClass(self.class);

    if ([name containsString:@"Dock"] ||
        [name containsString:@"Dashboard"] ||
        [name containsString:@"CarPlay"] ||
        [name containsString:@"Host"]) {

        VMLLog(@"[native-view] class=%@ frame=%@ bounds=%@ window=%@",
               name,
               NSStringFromCGRect(self.frame),
               NSStringFromCGRect(self.bounds),
               NSStringFromClass(self.window.class));
    }
}

%end

#pragma mark - Startup

%ctor {
    @autoreleasepool {
        VMLLog(@"========================================");
        VMLLog(@"VML SPEED BUBBLE V12.1 INSTANT + PERSISTENT");
        VMLLog(@"bundle=%@ process=%@", VMLBundle(), VMLProcess());
        VMLLog(@"========================================");

        if (VMLIsSpringBoard()) {
            VMLLog(@"*** SPRINGBOARD INJECTION CONFIRMED V12.1 ***");
            VMLStartSpeedReceiver();

            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                dispatch_get_main_queue(),
                ^{
                    VMLCreatePhoneBubble();
                }
            );

            VMLLog(@"V12.1 SPRINGBOARD ACTIVE");
            return;
        }

        if (VMLIsCarPlayApp()) {
            VMLLog(@"*** CARPLAY.APP INJECTION CONFIRMED V12.1 ***");
            VMLStartSpeedReceiver();
            VMLStartNativeWatchdog();
            VMLLog(@"V12.1 NATIVE CARPLAY ACTIVE");
            return;
        }
    }
}
