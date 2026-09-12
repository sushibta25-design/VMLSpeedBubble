#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>
#import <objc/message.h>
#import <math.h>

// V15.9: synchronized overlays on every CarPlay Dashboard scene.
// CarPlay can keep multiple equal-size DBDashboard scenes alive at once.
// A UIWindow with a higher level still cannot cover _UISceneLayerHostContainerView
// surfaces reliably. Keep the original pass-through bubble for the Dock/touches,
// and mirror it inside the DuoDash window that owns two hosted scene surfaces.

@interface VMLPassthroughWindow : UIWindow
@property(nonatomic, weak) UIView *interactiveBubble;
@end

@implementation VMLPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *bubble = self.interactiveBubble;
    if (!bubble || bubble.hidden || bubble.alpha <= 0.01) return nil;
    CGPoint p = [bubble convertPoint:point fromView:self];
    if (!CGRectContainsPoint(bubble.bounds, p)) return nil;
    return [bubble hitTest:p withEvent:event] ?: bubble;
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return [self hitTest:point withEvent:event] != nil;
}
@end

#pragma mark - Globals

static NSInteger gCurrentSpeed = 0;
static int gSpeedNotifyToken = 0;
static int gEncodedReceiverStarted = 0;
static NSMutableArray<NSNumber *> *gEncodedSpeedTokens = nil;
static int gSpringBoardReplayRequestToken = 0;
static BOOL gSpringBoardRebroadcastRunning = NO;
static BOOL gCarPlayReplayRequesterRunning = NO;
static NSInteger gCarPlayReplayRequestCount = 0;
static BOOL gCarPlayHasEncodedSpeed = NO;

static int gVMLCarPlaySceneToken = 0;
static BOOL gVMLCarPlaySceneActive = NO;

static UIWindow *gCarPlayOverlayWindow = nil;
static UIView *gCarPlayBubble = nil;
static UIView *gDuoDashMirrorBubble = nil;
static __weak UIWindow *gDuoDashHostWindow = nil;
static __weak UIWindowScene *gLastSelectedCarPlayScene = nil;
static NSUInteger gLastDuoDashHostCount = 0;
static NSMutableDictionary<NSString *, VMLPassthroughWindow *> *gSatelliteOverlayWindows = nil;
static NSMutableDictionary<NSString *, UIView *> *gSatelliteOverlayBubbles = nil;
static CGPoint gCarPlayBubbleCenterRatio = {0, 0};
static BOOL gCarPlayBubblePositionLoaded = NO;
static BOOL gOverlayLoopRunning = NO;
static BOOL gCarPlayDragging = NO;

static int gOverspeedOnToken = 0;
static int gOverspeedOffToken = 0;
static BOOL gOverspeedActive = NO;
static BOOL gOverspeedFlashOn = NO;
static BOOL gOverspeedFlashLoopRunning = NO;
static UIView *gOverspeedFlashView = nil;
static UIView *gOverspeedBannerContainer = nil;
static UIView *gOverspeedBannerPanel = nil;
static UIImageView *gOverspeedFuelIcon = nil;
static UILabel *gOverspeedTitleLabel = nil;
static UILabel *gOverspeedSubtitleLabel = nil;
static NSMutableArray<UIView *> *gOverspeedWarningMarks = nil;

static const NSInteger kCarPlayBubbleTag = 990199;
static const NSInteger kLabelTag = 990100;

#pragma mark - Logging / process

static NSString *VMLBundle(void) { return NSBundle.mainBundle.bundleIdentifier ?: @""; }
static NSString *VMLProcess(void) { return NSProcessInfo.processInfo.processName ?: @""; }
static BOOL VMLIsSpringBoard(void) { return [VMLBundle() isEqualToString:@"com.apple.springboard"]; }
static BOOL VMLIsCarPlayApp(void) { return [VMLBundle() isEqualToString:@"com.apple.CarPlayApp"]; }

static void VMLAppend(NSString *path, NSString *prefix, NSString *format, va_list args) {
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    if (prefix) NSLog(@"%@ %@", prefix, message);
    FILE *f = fopen(path.UTF8String, "a");
    if (f) { fprintf(f, "%s\n", message.UTF8String); fclose(f); }
}
static void VMLLog(NSString *format, ...) {
    va_list args; va_start(args, format);
    VMLAppend(@"/var/mobile/VMLHostSniffer.txt", @"[VMLV15.9]", format, args);
    va_end(args);
}
static void VMLTrace(NSString *format, ...) {
    va_list args; va_start(args, format);
    VMLAppend(@"/var/mobile/VMLSpeedTrace.txt", nil, format, args);
    va_end(args);
}

#pragma mark - Bubble

static NSString *VMLSpeedText(void) {
    return (gCurrentSpeed > 0 && gCurrentSpeed <= 200)
        ? [NSString stringWithFormat:@"%ld", (long)gCurrentSpeed] : @"--";
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

static void VMLUpdateOneBubble(UIView *bubble) {
    if (!bubble) return;
    UILabel *label = (UILabel *)[bubble viewWithTag:kLabelTag];
    if (label) label.text = VMLSpeedText();
    bubble.hidden = gVMLCarPlaySceneActive;
    bubble.alpha = 1.0;
    bubble.layer.hidden = NO;
    bubble.layer.opacity = 1.0;
    bubble.layer.zPosition = CGFLOAT_MAX;
    [bubble.superview bringSubviewToFront:bubble];
}

static void VMLUpdateAllBubbles(void) {
    VMLUpdateOneBubble(gCarPlayBubble);
    VMLUpdateOneBubble(gDuoDashMirrorBubble);
    for (UIView *bubble in gSatelliteOverlayBubbles.allValues)
        VMLUpdateOneBubble(bubble);
}

#pragma mark - Speed IPC

static void VMLBroadcastEncodedSpeed(NSInteger speed) {
    if (speed <= 0 || speed > 200) return;
    NSString *name = [NSString stringWithFormat:@"com.sushibta.vmlspeedbubble.speed.%ld", (long)speed];
    notify_post(name.UTF8String);
    VMLTrace(@"TRACE SB ENCODED RELAY speed=%ld", (long)speed);
}

static void VMLReadSpeed(void) {
    if (!VMLIsSpringBoard() || gSpeedNotifyToken == 0) return;
    uint64_t state = 0;
    if (notify_get_state(gSpeedNotifyToken, &state) != NOTIFY_STATUS_OK) return;
    NSInteger speed = (NSInteger)state;
    if (speed <= 0 || speed > 200) return;
    gCurrentSpeed = speed;
    VMLTrace(@"TRACE SB CACHE speed=%ld", (long)speed);
    VMLBroadcastEncodedSpeed(speed);
}

static void VMLStartSpeedReceiver(void) {
    if (!VMLIsSpringBoard() || gSpeedNotifyToken != 0) return;
    int token = 0;
    uint32_t status = notify_register_dispatch(
        "com.sushibta.vmlspeedbubble.speed", &token, dispatch_get_main_queue(),
        ^(int incomingToken) { gSpeedNotifyToken = incomingToken; VMLReadSpeed(); });
    if (status != NOTIFY_STATUS_OK) { VMLLog(@"notify_register_dispatch failed=%u", status); return; }
    gSpeedNotifyToken = token;
    VMLReadSpeed();
}

static void VMLApplyCarPlayEncodedSpeed(NSInteger speed) {
    if (!VMLIsCarPlayApp() || speed <= 0 || speed > 200) return;
    gCurrentSpeed = speed;
    gCarPlayHasEncodedSpeed = YES;
    VMLUpdateAllBubbles();
    VMLTrace(@"CP TRACE ENCODED ACCEPT speed=%ld", (long)speed);
}

static void VMLStartEncodedSpeedReceiver(void) {
    if ((!VMLIsCarPlayApp() && !VMLIsSpringBoard()) || gEncodedReceiverStarted) return;
    gEncodedReceiverStarted = 1;
    gEncodedSpeedTokens = [NSMutableArray arrayWithCapacity:200];
    for (NSInteger speed = 1; speed <= 200; speed++) {
        NSString *name = [NSString stringWithFormat:@"com.sushibta.vmlspeedbubble.speed.%ld", (long)speed];
        int token = 0; NSInteger capturedSpeed = speed;
        uint32_t status = notify_register_dispatch(name.UTF8String, &token, dispatch_get_main_queue(),
            ^(__unused int incomingToken) {
                if (VMLIsSpringBoard()) {
                    gCurrentSpeed = capturedSpeed;
                    VMLTrace(@"TRACE SB ENCODED CACHE speed=%ld", (long)capturedSpeed);
                } else {
                    VMLApplyCarPlayEncodedSpeed(capturedSpeed);
                }
            });
        if (status == NOTIFY_STATUS_OK) [gEncodedSpeedTokens addObject:@(token)];
    }
    VMLTrace(@"TRACE ENCODED RECEIVER READY bundle=%@ count=%lu", VMLBundle(),
             (unsigned long)gEncodedSpeedTokens.count);
}

static void VMLSpringBoardReplyWithCachedSpeed(void) {
    if (!VMLIsSpringBoard()) return;
    if (gCurrentSpeed > 0 && gCurrentSpeed <= 200) {
        VMLBroadcastEncodedSpeed(gCurrentSpeed);
        VMLTrace(@"TRACE SB REPLAY ANSWER cached=%ld", (long)gCurrentSpeed);
        return;
    }
    if (!gSpeedNotifyToken) return;
    uint64_t state = 0;
    uint32_t status = notify_get_state(gSpeedNotifyToken, &state);
    if (state) VMLTrace(@"TRACE SB REPLAY FALLBACK token=%d status=%u state=%llu",
                        gSpeedNotifyToken, status, state);
    NSInteger speed = (NSInteger)state;
    if (status != NOTIFY_STATUS_OK || speed <= 0 || speed > 200) return;
    gCurrentSpeed = speed;
    VMLBroadcastEncodedSpeed(speed);
    VMLTrace(@"TRACE SB REPLAY ANSWER fallback=%ld", (long)speed);
}

static void VMLStartSpringBoardReplayResponder(void) {
    if (!VMLIsSpringBoard() || gSpringBoardReplayRequestToken) return;
    int token = 0;
    uint32_t status = notify_register_dispatch(
        "com.sushibta.vmlspeedbubble.speed.request", &token, dispatch_get_main_queue(),
        ^(__unused int incomingToken) { VMLSpringBoardReplyWithCachedSpeed(); });
    if (status == NOTIFY_STATUS_OK) {
        gSpringBoardReplayRequestToken = token;
        VMLTrace(@"TRACE SB REPLAY RESPONDER READY token=%d", token);
    }
}

static void VMLSpringBoardRebroadcastTick(void) {
    if (!VMLIsSpringBoard()) { gSpringBoardRebroadcastRunning = NO; return; }
    if (gCurrentSpeed > 0 && gCurrentSpeed <= 200) VMLBroadcastEncodedSpeed(gCurrentSpeed);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        VMLSpringBoardRebroadcastTick();
    });
}
static void VMLStartSpringBoardRebroadcast(void) {
    if (!VMLIsSpringBoard() || gSpringBoardRebroadcastRunning) return;
    gSpringBoardRebroadcastRunning = YES;
    VMLSpringBoardRebroadcastTick();
}

static void VMLCarPlayReplayRequestTick(void) {
    if (!VMLIsCarPlayApp()) { gCarPlayReplayRequesterRunning = NO; return; }
    if (!gCarPlayHasEncodedSpeed) {
        notify_post("com.sushibta.vmlspeedbubble.speed.request");
        gCarPlayReplayRequestCount++;
        if (gCarPlayReplayRequestCount == 1 || gCarPlayReplayRequestCount % 5 == 0)
            VMLTrace(@"CP TRACE REPLAY REQUEST count=%ld", (long)gCarPlayReplayRequestCount);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        VMLCarPlayReplayRequestTick();
    });
}
static void VMLStartCarPlayReplayRequester(void) {
    if (!VMLIsCarPlayApp() || gCarPlayReplayRequesterRunning) return;
    gCarPlayReplayRequesterRunning = YES;
    VMLCarPlayReplayRequestTick();
}

#pragma mark - Overspeed warning

static UIColor *VMLOverspeedYellowColor(void) {
    return [UIColor colorWithRed:1 green:0.86 blue:0 alpha:1];
}
static UIColor *VMLOverspeedBlueColor(void) {
    return [UIColor colorWithRed:0 green:0.66 blue:1 alpha:1];
}

static void VMLApplyOverspeedBannerColor(UIColor *color) {
    if (!color) return;
    gOverspeedBannerPanel.layer.borderColor = color.CGColor;
    gOverspeedBannerPanel.layer.shadowColor = color.CGColor;
    gOverspeedFuelIcon.tintColor = color;
    gOverspeedTitleLabel.textColor = color;
    gOverspeedSubtitleLabel.textColor = color;
    for (UIView *mark in gOverspeedWarningMarks) {
        mark.backgroundColor = color;
        mark.layer.shadowColor = color.CGColor;
    }
}

static void VMLLayoutOverspeedBanner(void) {
    UIView *container = gOverspeedBannerContainer;
    UIView *panel = gOverspeedBannerPanel;
    UIView *canvas = container.superview;
    if (!container || !panel || !canvas) return;
    CGFloat W = MAX(CGRectGetWidth(canvas.bounds), 1), H = MAX(CGRectGetHeight(canvas.bounds), 1);
    CGFloat panelW = MAX(W * 0.58, MIN(W * 0.82, H * 3.55));
    CGFloat panelH = MAX(H * 0.30, MIN(H * 0.48, panelW * 0.30));
    CGFloat side = MIN(W * 0.065, panelH * 0.50);
    CGFloat containerW = MIN(W * 0.94, panelW + side * 2);
    container.bounds = CGRectMake(0, 0, containerW, panelH);
    container.center = CGPointMake(CGRectGetMidX(canvas.bounds), CGRectGetMidY(canvas.bounds));
    CGFloat panelX = (containerW - panelW) / 2;
    panel.frame = CGRectMake(panelX, 0, panelW, panelH);
    panel.layer.cornerRadius = MAX(10, panelH * 0.14);
    panel.layer.borderWidth = MAX(3, panelH * 0.035);
    panel.layer.shadowOpacity = 0.70;
    panel.layer.shadowRadius = MAX(4, panelH * 0.08);
    panel.layer.shadowOffset = CGSizeZero;

    CGFloat iconSide = panelH * 0.58, left = panelH * 0.18;
    gOverspeedFuelIcon.frame = CGRectMake(left, (panelH-iconSide)/2, iconSide, iconSide);
    CGFloat textX = left + iconSide + panelH * 0.13;
    CGFloat textW = MAX(10, panelW - textX - panelH * 0.16);
    CGFloat titleH = panelH * 0.43, subtitleH = panelH * 0.35;
    CGFloat textY = (panelH - titleH - subtitleH) / 2;
    gOverspeedTitleLabel.frame = CGRectMake(textX, textY, textW, titleH);
    gOverspeedTitleLabel.font = [UIFont systemFontOfSize:MAX(14, panelH*0.30) weight:UIFontWeightHeavy];
    gOverspeedSubtitleLabel.frame = CGRectMake(textX, textY+titleH, textW, subtitleH);
    gOverspeedSubtitleLabel.font = [UIFont systemFontOfSize:MAX(12, panelH*0.245) weight:UIFontWeightBold];

    if (gOverspeedWarningMarks.count == 4) {
        CGFloat markW = MAX(7, panelH*0.17), markH = MAX(4, panelH*0.055);
        CGFloat gap = MAX(4, panelH*0.065), offset = panelH*0.17, cy = panelH/2;
        CGFloat lx = panelX-gap-markW/2, rx = panelX+panelW+gap+markW/2;
        CGPoint points[4] = {{lx,cy-offset},{lx,cy+offset},{rx,cy-offset},{rx,cy+offset}};
        for (NSUInteger i=0; i<4; i++) {
            UIView *mark = gOverspeedWarningMarks[i];
            mark.bounds = CGRectMake(0,0,markW,markH); mark.center = points[i];
            mark.layer.cornerRadius = markH/2; mark.layer.shadowOpacity = 0.75;
            mark.layer.shadowRadius = MAX(2,panelH*0.04); mark.layer.shadowOffset = CGSizeZero;
            mark.transform = CGAffineTransformMakeRotation((i==0 || i==3) ? -0.42 : 0.42);
        }
    }
}

static void VMLAttachOverspeedBannerIfNeeded(void) {
    if (!VMLIsCarPlayApp() || !gCarPlayOverlayWindow.rootViewController) return;
    UIView *canvas = gCarPlayOverlayWindow.rootViewController.view;
    if (!canvas) return;
    if (!gOverspeedBannerContainer) {
        UIView *container = [UIView new]; container.backgroundColor = UIColor.clearColor;
        container.userInteractionEnabled = NO; container.hidden = YES; container.alpha = 0;
        UIView *panel = [UIView new]; panel.backgroundColor = UIColor.blackColor;
        panel.userInteractionEnabled = NO; panel.clipsToBounds = NO; [container addSubview:panel];
        UIImageView *icon = [UIImageView new];
        if (@available(iOS 13.0,*)) icon.image = [UIImage systemImageNamed:@"fuelpump.fill"];
        icon.contentMode = UIViewContentModeScaleAspectFit; [panel addSubview:icon];
        UILabel *title = [UILabel new]; title.text = @"XĂNG ĐANG TĂNG"; title.textAlignment = NSTextAlignmentCenter;
        title.adjustsFontSizeToFitWidth = YES; title.minimumScaleFactor = 0.68; [panel addSubview:title];
        UILabel *subtitle = [UILabel new]; subtitle.text = @"GIẢM TỐC ĐỘ ĐÊ!";
        subtitle.textAlignment = NSTextAlignmentCenter; subtitle.adjustsFontSizeToFitWidth = YES;
        subtitle.minimumScaleFactor = 0.68; [panel addSubview:subtitle];
        NSMutableArray *marks = [NSMutableArray arrayWithCapacity:4];
        for (NSUInteger i=0;i<4;i++) { UIView *mark=[UIView new]; mark.userInteractionEnabled=NO;
            [container addSubview:mark]; [marks addObject:mark]; }
        [canvas addSubview:container];
        gOverspeedBannerContainer=container; gOverspeedBannerPanel=panel; gOverspeedFuelIcon=icon;
        gOverspeedTitleLabel=title; gOverspeedSubtitleLabel=subtitle; gOverspeedWarningMarks=marks;
        VMLApplyOverspeedBannerColor(VMLOverspeedYellowColor());
    } else if (gOverspeedBannerContainer.superview != canvas) {
        [gOverspeedBannerContainer removeFromSuperview]; [canvas addSubview:gOverspeedBannerContainer];
    }
    VMLLayoutOverspeedBanner();
}

static void VMLAttachOverspeedViewIfNeeded(void) {
    if (!VMLIsCarPlayApp() || !gCarPlayOverlayWindow.rootViewController) return;
    UIView *canvas = gCarPlayOverlayWindow.rootViewController.view;
    if (!gOverspeedFlashView) {
        UIView *flash = [[UIView alloc] initWithFrame:canvas.bounds];
        flash.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        flash.backgroundColor = [UIColor colorWithRed:1 green:0.02 blue:0 alpha:1];
        flash.userInteractionEnabled=NO; flash.hidden=YES; flash.alpha=0;
        [canvas insertSubview:flash atIndex:0]; gOverspeedFlashView=flash;
    } else if (gOverspeedFlashView.superview != canvas) {
        [gOverspeedFlashView removeFromSuperview]; gOverspeedFlashView.frame=canvas.bounds;
        [canvas insertSubview:gOverspeedFlashView atIndex:0];
    }
    VMLAttachOverspeedBannerIfNeeded();
}

static void VMLShowOverspeedBannerForPhase(BOOL yellow) {
    VMLAttachOverspeedBannerIfNeeded();
    if (!gOverspeedBannerContainer) return;
    VMLApplyOverspeedBannerColor(yellow ? VMLOverspeedYellowColor() : VMLOverspeedBlueColor());
    VMLLayoutOverspeedBanner();
    gOverspeedBannerContainer.hidden=NO; gOverspeedBannerContainer.alpha=1;
    gOverspeedBannerContainer.layer.zPosition=CGFLOAT_MAX-2;
    [gOverspeedBannerContainer.superview bringSubviewToFront:gOverspeedBannerContainer];
    [gOverspeedBannerContainer.superview bringSubviewToFront:gCarPlayBubble];
}
static void VMLHideOverspeedBannerImmediately(void) {
    gOverspeedBannerContainer.alpha=0; gOverspeedBannerContainer.hidden=YES;
}

static void VMLOverspeedFlashTick(void) {
    if (!VMLIsCarPlayApp()) { gOverspeedFlashLoopRunning=NO; return; }
    VMLAttachOverspeedViewIfNeeded();
    if (gOverspeedActive) {
        gOverspeedFlashOn=!gOverspeedFlashOn;
        gOverspeedFlashView.hidden=NO;
        [UIView performWithoutAnimation:^{ gOverspeedFlashView.alpha=gOverspeedFlashOn?0.82:0.30; }];
        VMLShowOverspeedBannerForPhase(gOverspeedFlashOn);
    } else {
        gOverspeedFlashOn=NO; gOverspeedFlashView.alpha=0; gOverspeedFlashView.hidden=YES;
        VMLHideOverspeedBannerImmediately();
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,500*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        VMLOverspeedFlashTick();
    });
}
static void VMLStartOverspeedFlashLoop(void) {
    if (!VMLIsCarPlayApp() || gOverspeedFlashLoopRunning) return;
    gOverspeedFlashLoopRunning=YES; VMLOverspeedFlashTick();
}
static void VMLSetOverspeedActive(BOOL active) {
    if (!VMLIsCarPlayApp()) return;
    gOverspeedActive=active; VMLAttachOverspeedViewIfNeeded();
    if (!active) {
        gOverspeedFlashOn=NO; gOverspeedFlashView.alpha=0; gOverspeedFlashView.hidden=YES;
        VMLHideOverspeedBannerImmediately();
    } else {
        gOverspeedFlashOn=YES; gOverspeedFlashView.hidden=NO; gOverspeedFlashView.alpha=0.82;
        VMLShowOverspeedBannerForPhase(YES);
    }
    VMLTrace(@"SOS CARPLAY ACTIVE=%d",active);
}
static void VMLStartOverspeedReceiver(void) {
    if (!VMLIsCarPlayApp()) return;
    if (!gOverspeedOnToken) {
        int token=0; if (notify_register_dispatch("com.sushibta.vmlspeedbubble.overspeed.on",&token,
            dispatch_get_main_queue(),^(__unused int t){VMLSetOverspeedActive(YES);})==NOTIFY_STATUS_OK)
            gOverspeedOnToken=token;
    }
    if (!gOverspeedOffToken) {
        int token=0; if (notify_register_dispatch("com.sushibta.vmlspeedbubble.overspeed.off",&token,
            dispatch_get_main_queue(),^(__unused int t){VMLSetOverspeedActive(NO);})==NOTIFY_STATUS_OK)
            gOverspeedOffToken=token;
    }
    VMLStartOverspeedFlashLoop();
}

#pragma mark - VietMap CarPlay state

static void VMLReadCarPlaySceneState(void) {
    if (!gVMLCarPlaySceneToken) return;
    uint64_t state=0;
    if (notify_get_state(gVMLCarPlaySceneToken,&state)!=NOTIFY_STATUS_OK) return;
    BOOL active=state!=0;
    if (active!=gVMLCarPlaySceneActive) {
        gVMLCarPlaySceneActive=active;
        VMLLog(@"*** VML CPTEMPLATE ACTIVE ON CARPLAY = %d ***",active);
    }
    gCarPlayOverlayWindow.hidden=active;
    gDuoDashMirrorBubble.hidden=active;
    for (UIWindow *window in gSatelliteOverlayWindows.allValues)
        window.hidden=active;
}
static void VMLStartCarPlaySceneReceiver(void) {
    if (gVMLCarPlaySceneToken) return;
    int token=0;
    uint32_t status=notify_register_dispatch("com.sushibta.vmlspeedbubble.vmlcarplaysceneactive",&token,
        dispatch_get_main_queue(),^(int incoming){gVMLCarPlaySceneToken=incoming;VMLReadCarPlaySceneState();});
    if (status!=NOTIFY_STATUS_OK) {VMLLog(@"cpscene receiver failed=%u",status);return;}
    gVMLCarPlaySceneToken=token; VMLReadCarPlaySceneState();
    VMLLog(@"CPTEMPLATE SCENE RECEIVER ACTIVE token=%d",token);
}

#pragma mark - CarPlay scene / DuoDash host

static BOOL VMLSceneLooksCarPlay(UIWindowScene *scene) {
    if (!scene) return NO;
    NSString *role=scene.session.role?:@"";
    if ([role localizedCaseInsensitiveContainsString:@"CarPlay"]) return YES;
    CGSize size=scene.screen.bounds.size;
    return size.width>size.height && size.width>=300 && size.height<=500;
}

static UIWindowScene *VMLFindCarPlayScene(void) {
    NSSet<UIScene *> *connected=UIApplication.sharedApplication.connectedScenes;
    UIWindowScene *current=gCarPlayOverlayWindow.windowScene;
    if (current && [connected containsObject:current] && VMLSceneLooksCarPlay(current))
        return current;

    UIWindowScene *best=nil;
    CGFloat bestScore=-CGFLOAT_MAX;
    NSString *bestPersistentID=nil;

    for (UIScene *scene in connected) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws=(UIWindowScene *)scene;
        if (!VMLSceneLooksCarPlay(ws)) continue;

        CGSize size=ws.screen.bounds.size;
        CGFloat area=size.width*size.height;
        NSString *persistentID=ws.session.persistentIdentifier?:@"";
        BOOL isDashboard=([persistentID containsString:@"DBDashboard-Car"] ||
                          [persistentID containsString:@"DBDashboard"]);
        CGFloat highestLevel=-CGFLOAT_MAX;
        for (UIWindow *window in ws.windows) {
            if (window && !window.hidden && window.alpha>0.01)
                highestLevel=MAX(highestLevel,window.windowLevel);
        }
        if (highestLevel==-CGFLOAT_MAX) highestLevel=-10000.0;

        // Several CarPlay scenes report exactly 426.67 x 240. Area alone made
        // V15.7 alternate between them. DuoDash creates its split window only
        // in the DBDashboard-Car scene, so that identity must dominate.
        CGFloat score=(isDashboard?1000000000.0:0.0)+
                      (highestLevel>=UIWindowLevelAlert?100000000.0:0.0)+
                      area+highestLevel;

        // Make equal-score selection deterministic. The other equal-size scenes
        // receive satellite overlays below, so the primary must never oscillate.
        BOOL winsTie=(fabs(score-bestScore)<0.5 &&
                      (!bestPersistentID || [persistentID compare:bestPersistentID]==NSOrderedAscending));
        if (!best || score>bestScore || winsTie) {
            best=ws;
            bestScore=score;
            bestPersistentID=persistentID;
        }
    }

    if (best && best!=gLastSelectedCarPlayScene) {
        CGFloat highest=-CGFLOAT_MAX;
        for (UIWindow *window in best.windows)
            if (window && !window.hidden && window.alpha>0.01)
                highest=MAX(highest,window.windowLevel);
        VMLLog(@"[scene] SELECTED pid=%@ role=%@ size=%@ windows=%lu highestLevel=%.1f",
               best.session.persistentIdentifier?:@"",
               best.session.role?:@"",
               NSStringFromCGSize(best.screen.bounds.size),
               (unsigned long)best.windows.count,
               highest);
        gLastSelectedCarPlayScene=best;
    }

    return best;
}

static NSUInteger VMLHostedSceneLayerCount(UIView *view, NSUInteger depth) {
    if (!view || depth>16) return 0;
    NSString *name=NSStringFromClass(view.class);
    NSUInteger count=([name containsString:@"_UISceneLayerHostContainerView"] ||
                      [name containsString:@"UISceneLayerHostContainerView"]) ? 1 : 0;
    for (UIView *child in view.subviews) count+=VMLHostedSceneLayerCount(child,depth+1);
    return count;
}

static UIWindow *VMLFindDuoDashHostWindow(UIWindowScene *scene, NSUInteger *hostCountOut) {
    UIWindow *best=nil;
    NSUInteger bestCount=0;
    CGFloat bestGeometryScore=-CGFLOAT_MAX;
    CGRect sceneBounds=scene.coordinateSpace.bounds;

    for (UIWindow *window in scene.windows) {
        if (!window || window==gCarPlayOverlayWindow || window.hidden || window.alpha<=0.01 ||
            !window.rootViewController.view) continue;

        NSUInteger count=VMLHostedSceneLayerCount(window.rootViewController.view,0);
        if (count<2) continue;

        CGRect frame=window.frame;
        BOOL insetFromDock=(CGRectGetMinX(frame)>1.0 &&
                            CGRectGetWidth(frame)<CGRectGetWidth(sceneBounds)-1.0);
        BOOL alertLevel=(window.windowLevel>=UIWindowLevelAlert);

        // The normal Dashboard window can also contain two or more hosted surfaces,
        // but it is full-screen at level -1. DuoDash's real split window is the
        // elevated, Dock-inset window (currently x ~= 45, Alert + 70).
        // Rank window level first, then the split geometry. Hosted-surface count is
        // only a qualification/tie-breaker and must never make the level -1
        // Dashboard beat the real DuoDash window.
        CGFloat geometryScore=(alertLevel?1000000.0:0.0)+
                              (insetFromDock?100000.0:0.0)+
                              window.windowLevel;

        if (!best || geometryScore>bestGeometryScore ||
            (fabs(geometryScore-bestGeometryScore)<0.5 && count>bestCount)) {
            best=window;
            bestCount=count;
            bestGeometryScore=geometryScore;
        }
    }

    if (hostCountOut) *hostCountOut=bestCount;
    return best;
}

static void VMLRemoveDuoDashMirror(NSString *reason) {
    if (gDuoDashMirrorBubble) {
        [gDuoDashMirrorBubble removeFromSuperview];
        gDuoDashMirrorBubble=nil;
        VMLLog(@"[mirror] removed reason=%@",reason?:@"unknown");
    }
    gDuoDashHostWindow=nil; gLastDuoDashHostCount=0;
}

static void VMLRefreshDuoDashMirror(UIWindowScene *scene, CGRect sceneBubbleFrame, CGFloat size) {
    NSUInteger hostCount=0;
    UIWindow *host=VMLFindDuoDashHostWindow(scene,&hostCount);
    UIView *canvas=host.rootViewController.view;
    if (!host || !canvas) { VMLRemoveDuoDashMirror(@"no two-surface host"); return; }

    if (host!=gDuoDashHostWindow || !gDuoDashMirrorBubble || gDuoDashMirrorBubble.superview!=canvas) {
        [gDuoDashMirrorBubble removeFromSuperview];
        UIView *mirror=VMLMakeBubble(kCarPlayBubbleTag+1,size);
        mirror.userInteractionEnabled=NO;
        [canvas addSubview:mirror];
        gDuoDashMirrorBubble=mirror; gDuoDashHostWindow=host; gLastDuoDashHostCount=hostCount;
        VMLLog(@"[mirror] ATTACHED host=%@ level=%.1f frame=%@ hostedSurfaces=%lu",
               NSStringFromClass(host.class),host.windowLevel,NSStringFromCGRect(host.frame),(unsigned long)hostCount);
    }

    CGRect localFrame=[canvas convertRect:sceneBubbleFrame fromCoordinateSpace:scene.coordinateSpace];
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    gDuoDashMirrorBubble.frame=localFrame;
    gDuoDashMirrorBubble.layer.cornerRadius=size/2.0;
    [CATransaction commit];
    VMLUpdateOneBubble(gDuoDashMirrorBubble);
}

#pragma mark - Overlay / dragging

static NSString *VMLCarPlayPosKeyX(void){return @"VMLSpeedBubble.CarPlayPosX";}
static NSString *VMLCarPlayPosKeyY(void){return @"VMLSpeedBubble.CarPlayPosY";}
static void VMLLoadCarPlayBubblePosition(void) {
    if (gCarPlayBubblePositionLoaded) return;
    NSUserDefaults *d=NSUserDefaults.standardUserDefaults;
    CGFloat x=[d doubleForKey:VMLCarPlayPosKeyX()],y=[d doubleForKey:VMLCarPlayPosKeyY()];
    gCarPlayBubbleCenterRatio=(x>0&&x<1&&y>0&&y<1)?CGPointMake(x,y):CGPointMake(0.08,0.60);
    gCarPlayBubblePositionLoaded=YES;
}
static void VMLSaveCarPlayBubblePosition(void) {
    if (!gCarPlayBubblePositionLoaded) return;
    NSUserDefaults *d=NSUserDefaults.standardUserDefaults;
    [d setDouble:gCarPlayBubbleCenterRatio.x forKey:VMLCarPlayPosKeyX()];
    [d setDouble:gCarPlayBubbleCenterRatio.y forKey:VMLCarPlayPosKeyY()]; [d synchronize];
}
static CGRect VMLCarPlayBubbleFrameForScene(CGRect bounds,CGFloat size) {
    VMLLoadCarPlayBubblePosition(); CGFloat W=MAX(bounds.size.width,1),H=MAX(bounds.size.height,1),half=size/2;
    CGFloat x=MAX(half+4,MIN(W-half-4,gCarPlayBubbleCenterRatio.x*W));
    CGFloat y=MAX(half+4,MIN(H-half-4,gCarPlayBubbleCenterRatio.y*H));
    return CGRectMake(x-half,y-half,size,size);
}

static void VMLLayoutSynchronizedOverlayBubbles(void) {
    if (gCarPlayOverlayWindow.rootViewController.view && gCarPlayBubble) {
        UIView *canvas=gCarPlayOverlayWindow.rootViewController.view;
        CGFloat size=gCarPlayBubble.bounds.size.width;
        gCarPlayBubble.frame=VMLCarPlayBubbleFrameForScene(canvas.bounds,size);
    }
    for (NSString *key in gSatelliteOverlayWindows) {
        VMLPassthroughWindow *window=gSatelliteOverlayWindows[key];
        UIView *bubble=gSatelliteOverlayBubbles[key];
        UIView *canvas=window.rootViewController.view;
        if (!window || !bubble || !canvas) continue;
        CGFloat size=bubble.bounds.size.width;
        bubble.frame=VMLCarPlayBubbleFrameForScene(canvas.bounds,size);
        VMLUpdateOneBubble(bubble);
    }
}

static void VMLHandleCarPlayBubblePan(UIPanGestureRecognizer *pan) {
    UIView *sourceBubble=pan.view;
    UIView *canvas=sourceBubble.superview;
    if (!sourceBubble || !canvas) return;
    UIGestureRecognizerState state=pan.state;
    if(state==UIGestureRecognizerStateBegan){
        gCarPlayDragging=YES;
        sourceBubble.layer.actions=@{@"position":[NSNull null],@"bounds":[NSNull null],@"frame":[NSNull null]};
    }
    if(state==UIGestureRecognizerStateBegan||state==UIGestureRecognizerStateChanged){
        CGPoint finger=[pan locationInView:canvas];
        CGFloat hw=sourceBubble.bounds.size.width/2,hh=sourceBubble.bounds.size.height/2;
        CGFloat W=MAX(canvas.bounds.size.width,1),H=MAX(canvas.bounds.size.height,1);
        finger.x=MAX(hw+4,MIN(W-hw-4,finger.x)); finger.y=MAX(hh+4,MIN(H-hh-4,finger.y));
        gCarPlayBubbleCenterRatio=CGPointMake(finger.x/W,finger.y/H);gCarPlayBubblePositionLoaded=YES;
        [UIView performWithoutAnimation:^{VMLLayoutSynchronizedOverlayBubbles();}];
        UIWindowScene *scene=gCarPlayOverlayWindow.windowScene;
        if(scene && gCarPlayBubble)
            VMLRefreshDuoDashMirror(scene,gCarPlayBubble.frame,gCarPlayBubble.bounds.size.width);
    }
    if(state==UIGestureRecognizerStateEnded||state==UIGestureRecognizerStateCancelled||state==UIGestureRecognizerStateFailed){
        VMLSaveCarPlayBubblePosition();gCarPlayDragging=NO;
        VMLLog(@"*** CARPLAY BUBBLE MOVED x=%.3f y=%.3f ***",gCarPlayBubbleCenterRatio.x,gCarPlayBubbleCenterRatio.y);
    }
}

@interface VMLCarPlayDragTarget:NSObject
- (void)handlePan:(UIPanGestureRecognizer *)pan;
@end
@implementation VMLCarPlayDragTarget
- (void)handlePan:(UIPanGestureRecognizer *)pan{VMLHandleCarPlayBubblePan(pan);}
@end
static VMLCarPlayDragTarget *gCarPlayDragTarget=nil;

static NSString *VMLSceneOverlayKey(UIWindowScene *scene) {
    NSString *persistentID=scene.session.persistentIdentifier;
    return persistentID.length ? persistentID : [NSString stringWithFormat:@"scene-%p",scene];
}

static void VMLRefreshSatelliteOverlays(UIWindowScene *primaryScene) {
    if (!gSatelliteOverlayWindows)
        gSatelliteOverlayWindows=[NSMutableDictionary dictionary];
    if (!gSatelliteOverlayBubbles)
        gSatelliteOverlayBubbles=[NSMutableDictionary dictionary];

    NSMutableSet<NSString *> *liveKeys=[NSMutableSet set];
    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if (![candidate isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *scene=(UIWindowScene *)candidate;
        if (scene==primaryScene || !VMLSceneLooksCarPlay(scene)) continue;

        NSString *persistentID=scene.session.persistentIdentifier?:@"";
        if (![persistentID containsString:@"DBDashboard"]) continue;
        NSString *key=VMLSceneOverlayKey(scene);
        [liveKeys addObject:key];

        VMLPassthroughWindow *window=gSatelliteOverlayWindows[key];
        UIView *bubble=gSatelliteOverlayBubbles[key];
        CGRect bounds=scene.coordinateSpace.bounds;
        if (CGRectIsEmpty(bounds)) bounds=scene.screen.bounds;
        CGFloat size=MAX(84,MIN(112,MAX(bounds.size.height,1)*0.40));

        if (!window || window.windowScene!=scene || !bubble) {
            window.hidden=YES;
            window.rootViewController=nil;
            window=[[VMLPassthroughWindow alloc]initWithWindowScene:scene];
            window.backgroundColor=UIColor.clearColor;
            window.userInteractionEnabled=YES;
            UIViewController *vc=[UIViewController new];
            vc.view.backgroundColor=UIColor.clearColor;
            vc.view.userInteractionEnabled=YES;
            window.rootViewController=vc;
            bubble=VMLMakeBubble(kCarPlayBubbleTag+100+gSatelliteOverlayWindows.count,size);
            bubble.userInteractionEnabled=YES;
            [vc.view addSubview:bubble];
            UIPanGestureRecognizer *pan=[[UIPanGestureRecognizer alloc]
                initWithTarget:gCarPlayDragTarget action:@selector(handlePan:)];
            pan.cancelsTouchesInView=YES;
            pan.delaysTouchesBegan=NO;
            pan.delaysTouchesEnded=NO;
            pan.minimumNumberOfTouches=1;
            pan.maximumNumberOfTouches=1;
            [bubble addGestureRecognizer:pan];
            window.interactiveBubble=bubble;
            gSatelliteOverlayWindows[key]=window;
            gSatelliteOverlayBubbles[key]=bubble;
            VMLLog(@"[multi-scene] CREATED pid=%@ role=%@",persistentID,scene.session.role?:@"");
        }

        CGFloat highest=UIWindowLevelAlert;
        for (UIWindow *other in scene.windows)
            if (other && other!=window) highest=MAX(highest,other.windowLevel);
        window.windowLevel=MAX(UIWindowLevelAlert+100,highest+100);
        window.frame=bounds;
        window.rootViewController.view.frame=CGRectMake(0,0,bounds.size.width,bounds.size.height);
        bubble.frame=VMLCarPlayBubbleFrameForScene(window.rootViewController.view.bounds,size);
        window.hidden=gVMLCarPlaySceneActive;
        window.alpha=1;
        VMLUpdateOneBubble(bubble);
    }

    for (NSString *key in [gSatelliteOverlayWindows.allKeys copy]) {
        if ([liveKeys containsObject:key]) continue;
        VMLPassthroughWindow *window=gSatelliteOverlayWindows[key];
        window.hidden=YES;
        window.rootViewController=nil;
        [gSatelliteOverlayWindows removeObjectForKey:key];
        [gSatelliteOverlayBubbles removeObjectForKey:key];
        VMLLog(@"[multi-scene] REMOVED pid=%@",key);
    }
}

static void VMLDestroyOldOverlayIfNeeded(UIWindowScene *wantedScene) {
    if(!gCarPlayOverlayWindow||gCarPlayOverlayWindow.windowScene==wantedScene)return;
    VMLRemoveDuoDashMirror(@"scene changed");
    gCarPlayOverlayWindow.hidden=YES;gCarPlayOverlayWindow.rootViewController=nil;
    gCarPlayOverlayWindow=nil;gCarPlayBubble=nil;VMLLog(@"[overlay] discarded stale overlay window");
}

static void VMLPromoteOverlayAboveCarPlayWindows(UIWindowScene *scene) {
    if(!scene||!gCarPlayOverlayWindow)return;
    CGFloat highest=UIWindowLevelAlert;
    for(UIWindow *w in scene.windows)if(w&&w!=gCarPlayOverlayWindow)highest=MAX(highest,w.windowLevel);
    CGFloat target=MAX(UIWindowLevelAlert+100,highest+100);
    if(fabs(gCarPlayOverlayWindow.windowLevel-target)>0.5){
        gCarPlayOverlayWindow.windowLevel=target;
        VMLLog(@"[overlay] promoted level=%.1f highestOther=%.1f windows=%lu",target,highest,(unsigned long)scene.windows.count);
    }
    if(!gVMLCarPlaySceneActive){gCarPlayOverlayWindow.hidden=NO;gCarPlayOverlayWindow.alpha=1;}
}

static void VMLCreateOrRefreshSingleOverlay(void) {
    if(!VMLIsCarPlayApp())return;
    VMLReadCarPlaySceneState();
    UIWindowScene *scene=VMLFindCarPlayScene();
    if(!scene){VMLRemoveDuoDashMirror(@"no CarPlay scene");return;}
    VMLDestroyOldOverlayIfNeeded(scene);
    CGRect bounds=scene.coordinateSpace.bounds;if(CGRectIsEmpty(bounds))bounds=scene.screen.bounds;
    CGFloat size=MAX(84,MIN(112,MAX(bounds.size.height,1)*0.40));
    CGRect bubbleFrame=VMLCarPlayBubbleFrameForScene(bounds,size);
    if(!gCarPlayOverlayWindow){
        gCarPlayOverlayWindow=[[VMLPassthroughWindow alloc]initWithWindowScene:scene];
        gCarPlayOverlayWindow.backgroundColor=UIColor.clearColor;gCarPlayOverlayWindow.windowLevel=UIWindowLevelAlert+100;
        gCarPlayOverlayWindow.userInteractionEnabled=YES;
        UIViewController *vc=[UIViewController new];vc.view.backgroundColor=UIColor.clearColor;vc.view.userInteractionEnabled=YES;
        gCarPlayOverlayWindow.rootViewController=vc;
        UIView *bubble=VMLMakeBubble(kCarPlayBubbleTag,size);bubble.frame=bubbleFrame;bubble.userInteractionEnabled=YES;[vc.view addSubview:bubble];
        if(!gCarPlayDragTarget)gCarPlayDragTarget=[VMLCarPlayDragTarget new];
        UIPanGestureRecognizer *pan=[[UIPanGestureRecognizer alloc]initWithTarget:gCarPlayDragTarget action:@selector(handlePan:)];
        pan.cancelsTouchesInView=YES;pan.delaysTouchesBegan=NO;pan.delaysTouchesEnded=NO;
        pan.minimumNumberOfTouches=1;pan.maximumNumberOfTouches=1;[bubble addGestureRecognizer:pan];
        gCarPlayBubble=bubble;((VMLPassthroughWindow *)gCarPlayOverlayWindow).interactiveBubble=bubble;
        VMLLog(@"*** CARPLAY OVERLAY CREATED V15.9 scene=%@ frame=%@ ***",NSStringFromCGRect(bounds),NSStringFromCGRect(bubbleFrame));
    }
    gCarPlayOverlayWindow.frame=bounds;
    gCarPlayOverlayWindow.rootViewController.view.frame=CGRectMake(0,0,bounds.size.width,bounds.size.height);
    if(!gCarPlayDragging){[CATransaction begin];[CATransaction setDisableActions:YES];gCarPlayBubble.frame=bubbleFrame;[CATransaction commit];}
    VMLUpdateOneBubble(gCarPlayBubble);
    gCarPlayOverlayWindow.hidden=gVMLCarPlaySceneActive;
    if(!gVMLCarPlaySceneActive)VMLPromoteOverlayAboveCarPlayWindows(scene);
    VMLRefreshSatelliteOverlays(scene);
    VMLRefreshDuoDashMirror(scene,bubbleFrame,size);
    VMLAttachOverspeedViewIfNeeded();VMLLayoutOverspeedBanner();gCarPlayOverlayWindow.alpha=1;
}

static void VMLOverlayTick(void) {
    if(!VMLIsCarPlayApp()){gOverlayLoopRunning=NO;return;}
    if(!gCarPlayDragging)VMLCreateOrRefreshSingleOverlay();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,500*NSEC_PER_MSEC),dispatch_get_main_queue(),^{VMLOverlayTick();});
}
static void VMLStartOverlayLoop(void) {
    if(!VMLIsCarPlayApp()||gOverlayLoopRunning)return;
    gOverlayLoopRunning=YES;dispatch_async(dispatch_get_main_queue(),^{VMLOverlayTick();});
}

#pragma mark - Start

%ctor {
    @autoreleasepool {
        VMLLog(@"========================================");
        VMLLog(@"VML SPEED BUBBLE V15.9 MULTI-SCENE OVERLAY");
        VMLLog(@"bundle=%@ process=%@",VMLBundle(),VMLProcess());
        VMLLog(@"========================================");
        if(VMLIsSpringBoard()){
            VMLLog(@"*** SPRINGBOARD INJECTION CONFIRMED V15.9 ***");
            VMLStartSpeedReceiver();VMLStartEncodedSpeedReceiver();VMLStartSpringBoardReplayResponder();VMLStartSpringBoardRebroadcast();
            VMLLog(@"V15.9 SPRINGBOARD ACTIVE");return;
        }
        if(VMLIsCarPlayApp()){
            VMLStartOverspeedReceiver();VMLStartEncodedSpeedReceiver();VMLStartCarPlayReplayRequester();
            VMLStartCarPlaySceneReceiver();VMLStartOverlayLoop();
            VMLLog(@"*** CARPLAY.APP INJECTION CONFIRMED V15.9 ***");
            VMLLog(@"V15.9 CARPLAY ACTIVE");return;
        }
    }
}
