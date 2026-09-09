#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>
#import <math.h>

#pragma mark - Globals

static UIWindow *gPhoneWindow = nil;
static UIView *gCarPlayBubble = nil;
static __weak UIView *gCarPlayHost = nil;
static __weak UIWindow *gCarPlayRoot = nil;
static NSInteger gCurrentSpeed = 0;
static int gSpeedNotifyToken = 0;
static BOOL gAddingOwnView = NO;
static BOOL gPhoneCreateScheduled = NO;
static BOOL gScannerStarted = NO;
static __weak UIView *gLastLoggedHost = nil;
static __weak UIWindow *gLastLoggedRoot = nil;

static const NSInteger kPhoneBubbleTag = 990099;
static const NSInteger kCarPlayBubbleTag = 990199;
static const NSInteger kLabelTag = 990100;

#pragma mark - Logging

static void VMLLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"[VMLV11.4] %@", msg);

    NSString *line = [NSString stringWithFormat:@"%@\n", msg];
    FILE *f = fopen("/var/mobile/VMLHostSniffer.txt", "a");
    if (f) {
        fprintf(f, "%s", line.UTF8String);
        fclose(f);
    }
}

static BOOL VMLIsSpringBoard(void) {
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"";
    return [bundle isEqualToString:@"com.apple.springboard"];
}

static BOOL VMLContainsCI(NSString *value, NSString *needle) {
    if (!value || !needle) return NO;
    return [value rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

#pragma mark - Speed

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
    bubble.layer.borderWidth = MAX(4.0, size * 0.10);
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
    label.minimumScaleFactor = 0.45;
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
    if (bubble.superview) [bubble.superview bringSubviewToFront:bubble];
}

static void VMLUpdateAllBubbles(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gPhoneWindow) {
            VMLUpdateBubble([gPhoneWindow viewWithTag:kPhoneBubbleTag]);
        }
        VMLUpdateBubble(gCarPlayBubble);
    });
}

#pragma mark - IPC

static void VMLReadSpeed(void) {
    if (gSpeedNotifyToken == 0) return;

    uint64_t state = 0;
    uint32_t status = notify_get_state(gSpeedNotifyToken, &state);
    if (status != NOTIFY_STATUS_OK) {
        VMLLog(@"notify_get_state failed=%u", status);
        return;
    }

    NSInteger speed = (NSInteger)state;
    if (speed < 0 || speed > 200) return;

    gCurrentSpeed = speed;
    VMLLog(@"*** SPEED RECEIVED = %ld ***", (long)gCurrentSpeed);
    VMLUpdateAllBubbles();
}

static void VMLStartSpeedReceiver(void) {
    if (!VMLIsSpringBoard() || gSpeedNotifyToken != 0) return;

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
    VMLLog(@"SPEED RECEIVER ACTIVE token=%d", token);
    VMLReadSpeed();
}

#pragma mark - Phone bubble (known-good style + retries)

static BOOL VMLSceneLooksPhone(UIWindowScene *scene) {
    if (!scene) return NO;
    NSString *role = scene.session.role ?: @"";
    if (VMLContainsCI(role, @"carplay")) return NO;
    if (scene.screen != UIScreen.mainScreen) return NO;
    return YES;
}

static UIWindowScene *VMLFindPhoneScene(void) {
    UIApplication *app = UIApplication.sharedApplication;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        if (VMLSceneLooksPhone(ws)) return ws;
    }
    return nil;
}

static void VMLCreatePhoneBubbleNow(void) {
    if (!VMLIsSpringBoard()) return;
    if (gPhoneWindow) return;

    UIWindowScene *scene = VMLFindPhoneScene();
    if (!scene) {
        VMLLog(@"PHONE SCENE NOT FOUND - retrying");
        return;
    }

    CGFloat size = 64.0;
    gAddingOwnView = YES;

    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    window.frame = CGRectMake(18, 110, size, size);
    window.backgroundColor = UIColor.clearColor;
    window.windowLevel = UIWindowLevelAlert + 1000;

    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.clearColor;
    vc.view.userInteractionEnabled = NO;
    window.rootViewController = vc;

    UIView *bubble = VMLMakeBubble(kPhoneBubbleTag, size);
    bubble.frame = vc.view.bounds;
    bubble.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [vc.view addSubview:bubble];

    window.hidden = NO;
    gPhoneWindow = window;
    gAddingOwnView = NO;

    VMLLog(@"*** PHONE BUBBLE CREATED text=%@ sceneRole=%@ ***",
           VMLSpeedText(), scene.session.role ?: @"nil");
}

static void VMLSchedulePhoneCreation(void) {
    if (gPhoneCreateScheduled || gPhoneWindow) return;
    gPhoneCreateScheduled = YES;

    __block NSInteger attempts = 0;
    __block void (^retryBlock)(void) = nil;
    retryBlock = ^{
        attempts++;
        VMLCreatePhoneBubbleNow();

        if (gPhoneWindow || attempts >= 15) {
            gPhoneCreateScheduled = NO;
            if (!gPhoneWindow) VMLLog(@"PHONE BUBBLE FAILED after %ld attempts", (long)attempts);
            retryBlock = nil;
            return;
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), retryBlock);
    };

    dispatch_async(dispatch_get_main_queue(), retryBlock);
}



#pragma mark - Render path mapper

static BOOL VMLInterestingRenderClass(NSString *className) {
    if (!className) return NO;
    NSArray<NSString *> *tokens = @[
        @"Scene", @"Presentation", @"Host", @"Application",
        @"Root", @"VisualEffect", @"CarPlay", @"Dashboard",
        @"Display", @"Portal", @"Remote", @"Snapshot", @"Container"
    ];
    for (NSString *token in tokens) {
        if (VMLContainsCI(className, token)) return YES;
    }
    return NO;
}

static void VMLLogLayerInfo(UIView *view, NSString *prefix) {
    if (!view) return;
    CALayer *layer = view.layer;
    VMLLog(@"[map] %@ layer=%@ frame=%@ bounds=%@ hidden=%d opacity=%.3f z=%.3f masks=%d superlayer=%@",
           prefix,
           NSStringFromClass(layer.class),
           NSStringFromCGRect(layer.frame),
           NSStringFromCGRect(layer.bounds),
           layer.hidden,
           layer.opacity,
           layer.zPosition,
           layer.masksToBounds,
           layer.superlayer ? NSStringFromClass(layer.superlayer.class) : @"nil");
}

static void VMLLogViewNode(UIView *view, NSInteger depth, NSString *kind) {
    if (!view) return;
    UIWindow *window = view.window;
    VMLLog(@"[map] %@ depth=%ld class=%@ frame=%@ bounds=%@ hidden=%d alpha=%.3f clips=%d ui=%d super=%@ window=%@ subviews=%lu",
           kind,
           (long)depth,
           NSStringFromClass(view.class),
           NSStringFromCGRect(view.frame),
           NSStringFromCGRect(view.bounds),
           view.hidden,
           view.alpha,
           view.clipsToBounds,
           view.userInteractionEnabled,
           view.superview ? NSStringFromClass(view.superview.class) : @"nil",
           window ? NSStringFromClass(window.class) : @"nil",
           (unsigned long)view.subviews.count);
}

static void VMLDumpRenderTreeRecursive(UIView *view, NSInteger depth, NSUInteger *count) {
    if (!view || !count) return;
    if (depth > 14 || *count >= 220) return;
    (*count)++;

    NSString *className = NSStringFromClass(view.class);
    BOOL interesting = VMLInterestingRenderClass(className);
    if (depth <= 6 || interesting) {
        VMLLogViewNode(view, depth, interesting ? @"TREE*" : @"TREE");
        if (interesting) VMLLogLayerInfo(view, [NSString stringWithFormat:@"TREE*:%@", className]);
    }

    NSArray<UIView *> *children = [view.subviews copy];
    for (UIView *child in children) {
        VMLDumpRenderTreeRecursive(child, depth + 1, count);
        if (*count >= 220) break;
    }
}

static void VMLDumpHostSiblings(UIView *host) {
    UIView *parent = host.superview;
    if (!parent) {
        VMLLog(@"[map] HOST SIBLINGS parent=nil");
        return;
    }

    NSArray<UIView *> *siblings = [parent.subviews copy];
    VMLLog(@"[map] ===== HOST SIBLINGS parent=%@ count=%lu =====",
           NSStringFromClass(parent.class), (unsigned long)siblings.count);
    NSInteger index = 0;
    for (UIView *sibling in siblings) {
        VMLLog(@"[map] sibling[%ld] %@%@ frame=%@ bounds=%@ hidden=%d alpha=%.3f subviews=%lu",
               (long)index,
               sibling == host ? @"<HOST> " : @"",
               NSStringFromClass(sibling.class),
               NSStringFromCGRect(sibling.frame),
               NSStringFromCGRect(sibling.bounds),
               sibling.hidden,
               sibling.alpha,
               (unsigned long)sibling.subviews.count);
        VMLLogLayerInfo(sibling, [NSString stringWithFormat:@"sibling[%ld]", (long)index]);
        index++;
    }
    VMLLog(@"[map] ===== END HOST SIBLINGS =====");
}

static void VMLDumpSuperviewChainDetailed(UIView *host) {
    VMLLog(@"[map] ===== HOST -> ROOT SUPER CHAIN =====");
    UIView *v = host;
    NSInteger depth = 0;
    while (v && depth < 16) {
        VMLLogViewNode(v, depth, @"SUPER");
        VMLLogLayerInfo(v, [NSString stringWithFormat:@"SUPER[%ld]", (long)depth]);
        VMLLogResponderChain(v, [NSString stringWithFormat:@"super[%ld]", (long)depth]);
        v = v.superview;
        depth++;
    }
    VMLLog(@"[map] ===== END SUPER CHAIN =====");
}

static void VMLDumpFullRenderPath(UIView *host, UIWindow *root, NSString *reason) {
    if (!host || !root) return;

    VMLLog(@"[map] ################################################");
    VMLLog(@"[map] *** FULL CARPLAY RENDER PATH DUMP reason=%@ ***", reason);
    VMLLog(@"[map] root=%@ frame=%@ bounds=%@ hidden=%d alpha=%.3f level=%.1f role=%@",
           NSStringFromClass(root.class),
           NSStringFromCGRect(root.frame),
           NSStringFromCGRect(root.bounds),
           root.hidden,
           root.alpha,
           root.windowLevel,
           root.windowScene.session.role ?: @"nil");
    VMLLogLayerInfo(root, @"ROOT");

    VMLDumpHostSiblings(host);
    VMLDumpSuperviewChainDetailed(host);

    NSUInteger count = 0;
    VMLLog(@"[map] ===== ROOT VIEW TREE BEGIN =====");
    VMLDumpRenderTreeRecursive(root, 0, &count);
    VMLLog(@"[map] ===== ROOT VIEW TREE END nodes=%lu =====", (unsigned long)count);
    VMLLog(@"[map] *** FULL CARPLAY RENDER PATH DUMP COMPLETE ***");
    VMLLog(@"[map] ################################################");
}

#pragma mark - CarPlay candidate / host

static BOOL VMLLandscapeLike(CGSize size) {
    if (size.width < 320.0 || size.height < 120.0) return NO;
    return size.width > size.height * 1.35;
}

static BOOL VMLWindowLooksCarPlay(UIWindow *window) {
    if (!window || window == gPhoneWindow) return NO;

    NSString *className = NSStringFromClass(window.class);
    UIWindowScene *scene = window.windowScene;
    NSString *role = scene.session.role ?: @"";
    UIScreen *screen = window.screen;

    if (VMLContainsCI(role, @"carplay")) return YES;
    if ([className isEqualToString:@"UIRootSceneWindow"] && screen && screen != UIScreen.mainScreen) return YES;
    if ([className isEqualToString:@"UIRootSceneWindow"] && VMLLandscapeLike(window.bounds.size)) return YES;

    return NO;
}

static UIView *VMLFindVisualHostRecursive(UIView *view) {
    if (!view) return nil;

    NSString *className = NSStringFromClass(view.class);
    if ([className isEqualToString:@"_UIVisualEffectContentView"]) {
        CGSize s = view.bounds.size;
        if (s.width >= 300.0 && s.height >= 120.0) return view;
    }

    for (UIView *child in [view.subviews copy]) {
        UIView *found = VMLFindVisualHostRecursive(child);
        if (found) return found;
    }
    return nil;
}

static NSString *VMLCarPlayPathLabel(UIWindow *window) {
    if (!window) return @"UNKNOWN";
    NSString *role = window.windowScene.session.role ?: @"";
    NSString *className = NSStringFromClass(window.class);

    if (VMLContainsCI(role, @"carplay")) return @"NATIVE_ROLE";
    if ([className isEqualToString:@"UIRootSceneWindow"] && window.screen != UIScreen.mainScreen) return @"EXTERNAL_ROOT";
    if ([className isEqualToString:@"UIRootSceneWindow"] && VMLLandscapeLike(window.bounds.size)) return @"LANDSCAPE_ROOT";
    return @"OTHER";
}

static void VMLLogResponderChain(UIResponder *start, NSString *prefix) {
    UIResponder *r = start;
    NSInteger depth = 0;
    while (r && depth < 12) {
        VMLLog(@"[path] %@ responder[%ld]=%@", prefix, (long)depth, NSStringFromClass(r.class));
        r = r.nextResponder;
        depth++;
    }
}

static void VMLLogHostDiagnostics(UIView *host, UIWindow *root, NSString *reason) {
    if (!host || !root) return;
    if (gLastLoggedHost == host && gLastLoggedRoot == root) return;

    gLastLoggedHost = host;
    gLastLoggedRoot = root;

    VMLLog(@"[path] ===== HOST DIAGNOSTIC =====");
    VMLLog(@"[path] label=%@ reason=%@", VMLCarPlayPathLabel(root), reason);
    VMLLog(@"[path] root=%@ frame=%@ bounds=%@ hidden=%d level=%.1f role=%@ screenMain=%d",
           NSStringFromClass(root.class), NSStringFromCGRect(root.frame), NSStringFromCGRect(root.bounds),
           root.hidden, root.windowLevel, root.windowScene.session.role ?: @"nil", root.screen == UIScreen.mainScreen);
    VMLLog(@"[path] host=%@ frame=%@ bounds=%@ hidden=%d alpha=%.3f super=%@",
           NSStringFromClass(host.class), NSStringFromCGRect(host.frame), NSStringFromCGRect(host.bounds),
           host.hidden, host.alpha, host.superview ? NSStringFromClass(host.superview.class) : @"nil");

    UIView *v = host;
    NSInteger depth = 0;
    while (v && depth < 10) {
        VMLLog(@"[path] super[%ld]=%@ frame=%@ hidden=%d alpha=%.3f",
               (long)depth, NSStringFromClass(v.class), NSStringFromCGRect(v.frame), v.hidden, v.alpha);
        v = v.superview;
        depth++;
    }

    VMLLogResponderChain(host, @"host");
    VMLLogResponderChain(root, @"root");
    VMLLog(@"[path] ===== END DIAGNOSTIC =====");

    VMLDumpFullRenderPath(host, root, reason);
}

static void VMLAttachCarPlayBubble(UIView *host, UIWindow *root, NSString *reason) {
    if (!host || !root) return;

    UIView *existing = [host viewWithTag:kCarPlayBubbleTag];
    if (existing) {
        gCarPlayHost = host;
        gCarPlayBubble = existing;
        VMLUpdateBubble(existing);
        return;
    }

    if (gCarPlayBubble && gCarPlayBubble.superview && gCarPlayBubble.superview != host) {
        [gCarPlayBubble removeFromSuperview];
        gCarPlayBubble = nil;
    }

    gAddingOwnView = YES;

    CGFloat hostH = MAX(1.0, host.bounds.size.height);
    CGFloat size = MAX(42.0, MIN(58.0, hostH * 0.19));
    CGFloat x = MAX(8.0, MIN(host.bounds.size.width - size - 8.0, host.bounds.size.width * 0.105));
    CGFloat y = MAX(8.0, MIN(host.bounds.size.height - size - 8.0, host.bounds.size.height * 0.50));

    UIView *bubble = VMLMakeBubble(kCarPlayBubbleTag, size);
    bubble.frame = CGRectMake(x, y, size, size);
    [host addSubview:bubble];
    [host bringSubviewToFront:bubble];

    gCarPlayHost = host;
    gCarPlayBubble = bubble;
    gAddingOwnView = NO;

    VMLLog(@"*** CARPLAY BUBBLE ADDED reason=%@ root=%@ rootFrame=%@ host=%@ hostFrame=%@ text=%@ ***",
           reason,
           NSStringFromClass(root.class),
           NSStringFromCGRect(root.frame),
           NSStringFromClass(host.class),
           NSStringFromCGRect(host.frame),
           VMLSpeedText());
}

static void VMLProcessCarPlayWindow(UIWindow *window, NSString *reason) {
    if (!VMLWindowLooksCarPlay(window)) return;

    gCarPlayRoot = window;
    VMLLog(@"[root] candidate path=%@ reason=%@ class=%@ frame=%@ bounds=%@ screen=%@ native=%@ role=%@ hidden=%d",
           VMLCarPlayPathLabel(window), reason,
           NSStringFromClass(window.class),
           NSStringFromCGRect(window.frame),
           NSStringFromCGRect(window.bounds),
           NSStringFromCGRect(window.screen.bounds),
           NSStringFromCGRect(window.screen.nativeBounds),
           window.windowScene.session.role ?: @"nil",
           window.hidden);

    UIView *host = VMLFindVisualHostRecursive(window);
    if (host) {
        VMLLogHostDiagnostics(host, window, reason);
        VMLAttachCarPlayBubble(host, window, reason);
    } else {
        VMLLog(@"[root] candidate but no visual host reason=%@ subviews=%lu",
               reason, (unsigned long)window.subviews.count);
    }
}

#pragma mark - Active scan

static void VMLScanCarPlayScenes(void) {
    if (!VMLIsSpringBoard()) return;

    NSUInteger candidates = 0;
    UIApplication *app = UIApplication.sharedApplication;

    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *window in ws.windows) {
            if (!VMLWindowLooksCarPlay(window)) continue;
            candidates++;
            VMLProcessCarPlayWindow(window, @"scanner");
        }
    }

    if (candidates == 0) {
        NSMutableArray *screens = [NSMutableArray array];
        for (UIScreen *screen in UIScreen.screens) {
            [screens addObject:[NSString stringWithFormat:@"bounds=%@ native=%@ scale=%.2f",
                                NSStringFromCGRect(screen.bounds),
                                NSStringFromCGRect(screen.nativeBounds),
                                screen.scale]];
        }
        VMLLog(@"[scanner] no candidate windows screens=%lu %@",
               (unsigned long)UIScreen.screens.count, screens);
    }
}

static void VMLScannerTick(void) {
    if (!VMLIsSpringBoard()) {
        gScannerStarted = NO;
        return;
    }

    VMLScanCarPlayScenes();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        VMLScannerTick();
    });
}

static void VMLStartScanner(void) {
    if (gScannerStarted) return;
    gScannerStarted = YES;
    VMLLog(@"[scanner] V11.4 scanner started");
    dispatch_async(dispatch_get_main_queue(), ^{ VMLScannerTick(); });
}

#pragma mark - Lifecycle fallback

%hook UIView

- (void)didMoveToWindow {
    %orig;

    if (!VMLIsSpringBoard() || gAddingOwnView) return;
    UIWindow *window = self.window;
    if (!window || !VMLWindowLooksCarPlay(window)) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        VMLProcessCarPlayWindow(window, [NSString stringWithFormat:@"didMove:%@", NSStringFromClass(self.class)]);
    });
}

%end

#pragma mark - Start

%ctor {
    @autoreleasepool {
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"";
        NSString *process = NSProcessInfo.processInfo.processName ?: @"";

        VMLLog(@"========================================");
        VMLLog(@"VML SPEED BUBBLE V11.4 RENDER PATH MAPPER");
        VMLLog(@"bundle=%@ process=%@", bundle, process);
        VMLLog(@"========================================");

        if (!VMLIsSpringBoard()) return;

        VMLLog(@"*** SPRINGBOARD INJECTION CONFIRMED ***");
        VMLStartSpeedReceiver();
        VMLSchedulePhoneCreation();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            VMLStartScanner();
        });

        VMLLog(@"V11.4 ACTIVE");
    }
}
