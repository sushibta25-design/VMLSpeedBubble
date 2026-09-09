#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>
#import <math.h>

#pragma mark - Globals

static UIWindow *gPhoneWindow = nil;

static __weak UIWindow *gCarPlayRootWindow = nil;
static __weak UIView *gCarPlayHost = nil;

static UIView *gCarPlayBubble = nil;

static NSInteger gCurrentSpeed = 0;
static int gSpeedNotifyToken = 0;

static BOOL gScannerRunning = NO;
static NSInteger gScanCount = 0;

static const NSInteger kBubbleTag = 990099;
static const NSInteger kLabelTag  = 990100;

#pragma mark - Logging

static void VMLLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);

    NSString *msg =
        [[NSString alloc]
            initWithFormat:format
                 arguments:args];

    va_end(args);

    NSLog(@"[VMLV7.1] %@", msg);

    NSString *line =
        [NSString stringWithFormat:@"%@\n", msg];

    FILE *f =
        fopen(
            "/var/mobile/VMLHostSniffer.txt",
            "a"
        );

    if (f) {
        fprintf(
            f,
            "%s",
            line.UTF8String
        );

        fclose(f);
    }
}

#pragma mark - Process

static BOOL VMLIsSpringBoard(void) {
    NSString *bundle =
        NSBundle.mainBundle.bundleIdentifier ?: @"";

    return
        [bundle isEqualToString:
            @"com.apple.springboard"];
}

#pragma mark - Geometry

static BOOL VMLNear(
    CGFloat a,
    CGFloat b,
    CGFloat tolerance
) {
    return fabs(a - b) <= tolerance;
}

static BOOL VMLLooksLikeCarPlaySize(
    CGSize size
) {
    BOOL landscape =
        VMLNear(size.width, 640.0, 40.0) &&
        VMLNear(size.height, 240.0, 40.0);

    BOOL portrait =
        VMLNear(size.width, 240.0, 40.0) &&
        VMLNear(size.height, 640.0, 40.0);

    return landscape || portrait;
}

static BOOL VMLIsCarPlayRoot(
    UIWindow *window
) {
    if (!window)
        return NO;

    NSString *className =
        NSStringFromClass(window.class);

    if (![className
            isEqualToString:
                @"UIRootSceneWindow"]) {

        return NO;
    }

    return
        VMLLooksLikeCarPlaySize(
            window.bounds.size
        );
}

#pragma mark - Speed

static NSString *VMLSpeedText(void) {
    if (gCurrentSpeed > 0 &&
        gCurrentSpeed <= 200) {

        return
            [NSString stringWithFormat:
                @"%ld",
                (long)gCurrentSpeed];
    }

    return @"--";
}

#pragma mark - Bubble

static UIView *VMLMakeBubble(
    CGFloat size
) {
    UIView *bubble =
        [[UIView alloc]
            initWithFrame:
                CGRectMake(
                    0,
                    0,
                    size,
                    size
                )];

    bubble.tag = kBubbleTag;

    bubble.backgroundColor =
        UIColor.whiteColor;

    bubble.layer.cornerRadius =
        size / 2.0;

    bubble.layer.borderWidth =
        5.0;

    bubble.layer.borderColor =
        UIColor.systemRedColor.CGColor;

    bubble.clipsToBounds = YES;

    bubble.userInteractionEnabled = NO;

    UILabel *label =
        [[UILabel alloc]
            initWithFrame:
                bubble.bounds];

    label.tag = kLabelTag;

    label.autoresizingMask =
        UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;

    label.text =
        VMLSpeedText();

    label.textColor =
        UIColor.blackColor;

    label.textAlignment =
        NSTextAlignmentCenter;

    label.font =
        [UIFont systemFontOfSize:
            size * 0.40
                         weight:
            UIFontWeightBold];

    label.adjustsFontSizeToFitWidth =
        YES;

    label.minimumScaleFactor =
        0.5;

    [bubble addSubview:label];

    return bubble;
}

static void VMLUpdateBubble(
    UIView *bubble
) {
    if (!bubble)
        return;

    UILabel *label =
        (UILabel *)
        [bubble viewWithTag:kLabelTag];

    if (label) {
        label.text =
            VMLSpeedText();
    }

    bubble.layer.zPosition =
        CGFLOAT_MAX;

    if (bubble.superview) {
        [bubble.superview
            bringSubviewToFront:
                bubble];
    }
}

static void VMLUpdateAllBubbles(void) {
    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            if (gCarPlayBubble) {
                VMLUpdateBubble(
                    gCarPlayBubble
                );
            }

            if (gPhoneWindow) {
                UIView *phoneBubble =
                    [gPhoneWindow
                        viewWithTag:
                            kBubbleTag];

                if (phoneBubble) {
                    VMLUpdateBubble(
                        phoneBubble
                    );
                }
            }

            VMLLog(
                @"SPEED UPDATE speed=%ld text=%@",
                (long)gCurrentSpeed,
                VMLSpeedText()
            );
        }
    );
}

#pragma mark - IPC

static void VMLReadSpeed(void) {
    if (gSpeedNotifyToken == 0)
        return;

    uint64_t state = 0;

    uint32_t status =
        notify_get_state(
            gSpeedNotifyToken,
            &state
        );

    if (status != NOTIFY_STATUS_OK) {
        VMLLog(
            @"notify_get_state failed=%u",
            status
        );

        return;
    }

    NSInteger speed =
        (NSInteger)state;

    if (speed < 0 ||
        speed > 200) {

        return;
    }

    gCurrentSpeed =
        speed;

    VMLLog(
        @"*** SPEED RECEIVED = %ld ***",
        (long)gCurrentSpeed
    );

    VMLUpdateAllBubbles();
}

static void VMLStartSpeedReceiver(void) {
    if (!VMLIsSpringBoard())
        return;

    if (gSpeedNotifyToken != 0)
        return;

    int token = 0;

    uint32_t status =
        notify_register_dispatch(
            "com.sushibta.vmlspeedbubble.speed",
            &token,
            dispatch_get_main_queue(),
            ^(int incomingToken) {

                gSpeedNotifyToken =
                    incomingToken;

                VMLReadSpeed();
            }
        );

    if (status != NOTIFY_STATUS_OK) {
        VMLLog(
            @"notify_register_dispatch failed=%u",
            status
        );

        return;
    }

    gSpeedNotifyToken =
        token;

    VMLLog(
        @"SPEED RECEIVER ACTIVE token=%d",
        token
    );

    VMLReadSpeed();
}

#pragma mark - Host scoring

static NSInteger VMLHostScore(
    UIView *view
) {
    if (!view)
        return 0;

    UIWindow *window =
        view.window;

    if (!VMLIsCarPlayRoot(window))
        return 0;

    NSString *className =
        NSStringFromClass(
            view.class
        );

    CGSize size =
        view.bounds.size;

    UIView *parent =
        view.superview;

    NSString *parentClass =
        parent
            ? NSStringFromClass(
                parent.class
            )
            : @"";

    NSInteger score = 0;

    /*
     Host từng render bubble 99 thật:
       _UIVisualEffectContentView
       595 x 240
       parent UIVisualEffectView
    */

    if ([className
            isEqualToString:
                @"_UIVisualEffectContentView"]) {

        score += 100;

        if (VMLNear(
                size.width,
                595.0,
                35.0)) {

            score += 100;
        }

        if (VMLNear(
                size.height,
                240.0,
                25.0)) {

            score += 100;
        }

        if ([parentClass
                isEqualToString:
                    @"UIVisualEffectView"]) {

            score += 100;
        }

        if (parent) {
            CGRect pf =
                parent.frame;

            if (VMLNear(
                    pf.origin.x,
                    45.0,
                    20.0)) {

                score += 40;
            }

            if (VMLNear(
                    pf.size.width,
                    595.0,
                    40.0)) {

                score += 40;
            }
        }
    }

    /*
     Private presentation hosts.
     Chỉ dùng để log/ranking.
    */

    if ([className
            containsString:
                @"ScenePresentation"]) {

        score += 80;
    }

    if ([className
            containsString:
                @"PresentationView"]) {

        score += 70;
    }

    if ([className
            containsString:
                @"ApplicationScene"]) {

        score += 60;
    }

    if ([className
            containsString:
                @"SceneView"]) {

        score += 50;
    }

    if (size.width > 500.0 &&
        size.height > 200.0) {

        score += 20;
    }

    return score;
}

static void VMLFindBestHostRecursive(
    UIView *view,
    UIView **bestView,
    NSInteger *bestScore
) {
    if (!view)
        return;

    NSInteger score =
        VMLHostScore(view);

    if (score > *bestScore) {
        *bestScore =
            score;

        *bestView =
            view;
    }

    for (UIView *child
         in view.subviews) {

        VMLFindBestHostRecursive(
            child,
            bestView,
            bestScore
        );
    }
}

#pragma mark - Candidate log

static void VMLLogCandidatesRecursive(
    UIView *view,
    NSInteger depth
) {
    if (!view)
        return;

    if (depth > 12)
        return;

    NSString *className =
        NSStringFromClass(
            view.class
        );

    BOOL interesting =
        [className
            containsString:
                @"VisualEffect"] ||
        [className
            containsString:
                @"Presentation"] ||
        [className
            containsString:
                @"ApplicationScene"] ||
        [className
            containsString:
                @"SceneView"] ||
        [className
            containsString:
                @"RootScene"];

    if (interesting) {
        VMLLog(
            @"CANDIDATE depth=%ld class=%@ frame=%@ bounds=%@ hidden=%d alpha=%.2f super=%@ score=%ld",
            (long)depth,
            className,
            NSStringFromCGRect(
                view.frame
            ),
            NSStringFromCGRect(
                view.bounds
            ),
            view.hidden,
            view.alpha,
            view.superview
                ? NSStringFromClass(
                    view.superview.class
                )
                : @"nil",
            (long)VMLHostScore(view)
        );
    }

    for (UIView *child
         in view.subviews) {

        VMLLogCandidatesRecursive(
            child,
            depth + 1
        );
    }
}

#pragma mark - Attach

static void VMLAttachToHost(
    UIView *host,
    NSInteger score
) {
    if (!host)
        return;

    UIWindow *window =
        host.window;

    if (!VMLIsCarPlayRoot(window))
        return;

    if (gCarPlayBubble &&
        gCarPlayBubble.superview == host) {

        gCarPlayHost = host;

        VMLUpdateBubble(
            gCarPlayBubble
        );

        return;
    }

    if (gCarPlayBubble) {
        [gCarPlayBubble
            removeFromSuperview];

        gCarPlayBubble = nil;
    }

    UIView *existing =
        [host viewWithTag:
            kBubbleTag];

    if (existing) {
        gCarPlayBubble =
            existing;

        gCarPlayHost =
            host;

        VMLUpdateBubble(
            existing
        );

        return;
    }

    CGFloat bubbleSize =
        46.0;

    UIView *bubble =
        VMLMakeBubble(
            bubbleSize
        );

    /*
     Vị trí test đã từng render:
     99 = {{62,122},{46,46}}
    */

    CGFloat x = 62.0;
    CGFloat y = 122.0;

    CGFloat maxX =
        host.bounds.size.width -
        bubbleSize -
        4.0;

    CGFloat maxY =
        host.bounds.size.height -
        bubbleSize -
        4.0;

    if (maxX < 4.0)
        maxX = 4.0;

    if (maxY < 4.0)
        maxY = 4.0;

    x =
        MAX(
            4.0,
            MIN(x, maxX)
        );

    y =
        MAX(
            4.0,
            MIN(y, maxY)
        );

    bubble.frame =
        CGRectMake(
            x,
            y,
            bubbleSize,
            bubbleSize
        );

    bubble.layer.zPosition =
        CGFLOAT_MAX;

    [host addSubview:bubble];

    [host bringSubviewToFront:
        bubble];

    gCarPlayHost =
        host;

    gCarPlayBubble =
        bubble;

    UIView *parent =
        host.superview;

    VMLLog(
        @"*** V7 HOST ATTACHED score=%ld host=%@ hostFrame=%@ hostBounds=%@ parent=%@ parentFrame=%@ window=%@ windowBounds=%@ speed=%ld text=%@ ***",
        (long)score,
        NSStringFromClass(
            host.class
        ),
        NSStringFromCGRect(
            host.frame
        ),
        NSStringFromCGRect(
            host.bounds
        ),
        parent
            ? NSStringFromClass(
                parent.class
            )
            : @"nil",
        parent
            ? NSStringFromCGRect(
                parent.frame
            )
            : @"nil",
        NSStringFromClass(
            window.class
        ),
        NSStringFromCGRect(
            window.bounds
        ),
        (long)gCurrentSpeed,
        VMLSpeedText()
    );
}

#pragma mark - Scanner

static void VMLScanCarPlayRoot(void) {
    UIWindow *root =
        gCarPlayRootWindow;

    if (!VMLIsCarPlayRoot(root))
        return;

    gScanCount++;

    /*
     Bubble đã sống đúng host:
     chỉ update + bring front.
    */

    if (gCarPlayHost &&
        gCarPlayBubble &&
        gCarPlayBubble.superview ==
            gCarPlayHost &&
        gCarPlayHost.window ==
            root) {

        VMLUpdateBubble(
            gCarPlayBubble
        );

        return;
    }

    UIView *bestHost = nil;
    NSInteger bestScore = 0;

    VMLFindBestHostRecursive(
        root,
        &bestHost,
        &bestScore
    );

    /*
     Chỉ attach khi match rất mạnh.
     Tránh chọc bubble vào host ngẫu nhiên.
    */

    if (bestHost &&
        bestScore >= 300) {

        VMLLog(
            @"*** STRONG HOST FOUND scan=%ld class=%@ score=%ld frame=%@ ***",
            (long)gScanCount,
            NSStringFromClass(
                bestHost.class
            ),
            (long)bestScore,
            NSStringFromCGRect(
                bestHost.frame
            )
        );

        VMLAttachToHost(
            bestHost,
            bestScore
        );

        return;
    }

    /*
     Log candidates:
     scan 1, 2, 3, 5, 10
     rồi mỗi 10 scan.
     Không spam mỗi giây.
    */

    BOOL shouldDump =
        gScanCount == 1 ||
        gScanCount == 2 ||
        gScanCount == 3 ||
        gScanCount == 5 ||
        gScanCount == 10 ||
        (gScanCount % 10) == 0;

    if (shouldDump) {
        VMLLog(
            @"SCAN no strong host scan=%ld best=%@ score=%ld rootSubviews=%lu",
            (long)gScanCount,
            bestHost
                ? NSStringFromClass(
                    bestHost.class
                )
                : @"nil",
            (long)bestScore,
            (unsigned long)
                root.subviews.count
        );

        VMLLogCandidatesRecursive(
            root,
            0
        );
    }
}

static void VMLScannerTick(void) {
    if (!VMLIsSpringBoard()) {
        gScannerRunning = NO;
        return;
    }

    if (!gCarPlayRootWindow) {
        gScannerRunning = NO;
        return;
    }

    VMLScanCarPlayRoot();

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            1 * NSEC_PER_SEC
        ),
        dispatch_get_main_queue(),
        ^{
            VMLScannerTick();
        }
    );
}

static void VMLStartScanner(void) {
    if (gScannerRunning)
        return;

    g
