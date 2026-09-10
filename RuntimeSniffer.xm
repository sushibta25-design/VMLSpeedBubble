#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <notify.h>
#import <mach-o/dyld.h>



static IMP gOrigMethodCallInit = NULL;
static void VMLLog(NSString *format, ...);

static int gPublishToken = 0;

static int gCarPlaySceneToken = 0;
static BOOL gLastCarPlaySceneActive = NO;
static BOOL gHaveCarPlaySceneState = NO;

static BOOL VMLIsTemplateCarPlayScene(UIScene *scene) {
    if (!scene) return NO;

    NSString *className = NSStringFromClass(scene.class);
    NSString *role = scene.session.role ?: @"";

    if ([className containsString:@"CPTemplateApplicationScene"])
        return YES;

    if ([role localizedCaseInsensitiveContainsString:@"CarTemplateApplication"])
        return YES;

    if ([role localizedCaseInsensitiveContainsString:@"CarPlay"])
        return YES;

    return NO;
}

static BOOL VMLCarPlayTemplateSceneIsForeground(void) {
    UIApplication *app = UIApplication.sharedApplication;

    for (UIScene *scene in app.connectedScenes) {
        if (!VMLIsTemplateCarPlayScene(scene))
            continue;

        UISceneActivationState state = scene.activationState;

        if (state == UISceneActivationStateForegroundActive)
            return YES;
    }

    return NO;
}

static void VMLPublishCarPlaySceneState(BOOL active) {
    if (gCarPlaySceneToken == 0) {
        int token = 0;

        uint32_t status =
            notify_register_check(
                "com.sushibta.vmlspeedbubble.vmlcarplaysceneactive",
                &token
            );

        if (status != NOTIFY_STATUS_OK) {
            VMLLog(@"cpscene notify_register_check failed=%u", status);
            return;
        }

        gCarPlaySceneToken = token;
    }

    notify_set_state(
        gCarPlaySceneToken,
        active ? 1 : 0
    );

    notify_post(
        "com.sushibta.vmlspeedbubble.vmlcarplaysceneactive"
    );

    if (!gHaveCarPlaySceneState ||
        gLastCarPlaySceneActive != active) {

        VMLLog(
            @"*** VML CPTEMPLATE SCENE ACTIVE = %d ***",
            active
        );
    }

    gLastCarPlaySceneActive = active;
    gHaveCarPlaySceneState = YES;
}

static void VMLStartCarPlayTemplateSceneWatcher(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        VMLPublishCarPlaySceneState(
            VMLCarPlayTemplateSceneIsForeground()
        );

        [NSTimer scheduledTimerWithTimeInterval:0.25
                                        repeats:YES
                                          block:^(__unused NSTimer *timer) {
            VMLPublishCarPlaySceneState(
                VMLCarPlayTemplateSceneIsForeground()
            );
        }];
    });
}

static int gPhoneForegroundToken = 0;
static BOOL gLastPhoneForeground = NO;
static BOOL gHavePhoneForegroundState = NO;

static BOOL VMLHasActiveMainScreenWindow(void) {
    UIApplication *app =
        UIApplication.sharedApplication;

    UIScreen *mainScreen =
        UIScreen.mainScreen;

    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class])
            continue;

        UIWindowScene *ws =
            (UIWindowScene *)scene;

        if (ws.screen != mainScreen)
            continue;

        if (ws.activationState !=
            UISceneActivationStateForegroundActive) {

            continue;
        }

        for (UIWindow *window in ws.windows) {
            if (!window.hidden &&
                window.alpha > 0.01 &&
                window.bounds.size.width > 1.0 &&
                window.bounds.size.height > 1.0) {

                return YES;
            }
        }
    }

    return NO;
}

static void VMLPublishPhoneForeground(BOOL foreground) {
    if (gPhoneForegroundToken == 0) {
        int token = 0;

        uint32_t status =
            notify_register_check(
                "com.sushibta.vmlspeedbubble.phoneforeground",
                &token
            );

        if (status != NOTIFY_STATUS_OK) {
            VMLLog(
                @"phoneforeground register failed=%u",
                status
            );
            return;
        }

        gPhoneForegroundToken =
            token;
    }

    notify_set_state(
        gPhoneForegroundToken,
        foreground ? 1 : 0
    );

    notify_post(
        "com.sushibta.vmlspeedbubble.phoneforeground"
    );

    if (!gHavePhoneForegroundState ||
        gLastPhoneForeground != foreground) {

        VMLLog(
            @"*** VML PHONE MAIN-SCREEN ACTIVE = %d ***",
            foreground
        );
    }

    gLastPhoneForeground =
        foreground;

    gHavePhoneForegroundState =
        YES;
}

static void VMLRefreshPhoneForegroundEvent(void) {
    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            VMLPublishPhoneForeground(
                VMLHasActiveMainScreenWindow()
            );
        }
    );
}

static void VMLInstallPhoneForegroundObservers(void) {
    NSNotificationCenter *nc =
        NSNotificationCenter.defaultCenter;

    NSArray<NSNotificationName> *names =
        @[
            UIApplicationDidBecomeActiveNotification,
            UIApplicationWillResignActiveNotification,
            UIApplicationDidEnterBackgroundNotification,
            UISceneDidActivateNotification,
            UISceneWillDeactivateNotification,
            UISceneDidEnterBackgroundNotification
        ];

    for (NSNotificationName name in names) {
        [nc addObserverForName:name
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *note) {
            VMLRefreshPhoneForegroundEvent();
        }];
    }

    VMLRefreshPhoneForegroundEvent();
}


static NSString *VMLLogPath(void) {
    NSString *documents =
        [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];

    return [documents stringByAppendingPathComponent:@"VMLRuntime.txt"];
}

static void VMLLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);

    NSString *msg =
        [[NSString alloc] initWithFormat:format arguments:args];

    va_end(args);

    NSString *line =
        [NSString stringWithFormat:@"%@\n", msg];

    NSString *path = VMLLogPath();

    NSFileHandle *fh =
        [NSFileHandle fileHandleForWritingAtPath:path];

    if (!fh) {
        NSError *error = nil;

        [line writeToFile:path
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:&error];

        if (error) {
            NSLog(@"[VMLV12.3] WRITE ERROR %@", error);
        }
    } else {
        [fh seekToEndOfFile];

        NSData *data =
            [line dataUsingEncoding:NSUTF8StringEncoding];

        [fh writeData:data];
        [fh closeFile];
    }

    NSLog(@"[VMLV12.3] %@", msg);
}


static void VMLTrace(NSString *format, ...) {
    va_list args;
    va_start(args, format);

    NSString *msg =
        [[NSString alloc] initWithFormat:format arguments:args];

    va_end(args);

    NSString *line =
        [NSString stringWithFormat:@"%@\n", msg];

    FILE *f =
        fopen("/var/mobile/VMLSpeedTrace.txt", "a");

    if (f) {
        fprintf(f, "%s", line.UTF8String);
        fclose(f);
    }
}





static NSInteger VMLSpeedFromObject(id obj) {
    if (!obj)
        return -1;

    if ([obj respondsToSelector:@selector(integerValue)]) {
        return [obj integerValue];
    }

    return -1;
}


static void VMLPublishValidSpeed(NSInteger speed) {
    if (speed <= 0 || speed > 200)
        return;

    if (gPublishToken == 0) {
        int token = 0;

        uint32_t status =
            notify_register_check(
                "com.sushibta.vmlspeedbubble.speed",
                &token
            );

        if (status != NOTIFY_STATUS_OK) {
            VMLTrace(
                @"TRACE PUBLISH register failed=%u",
                status
            );
            return;
        }

        gPublishToken =
            token;
    }

    notify_set_state(
        gPublishToken,
        (uint64_t)speed
    );

    notify_post(
        "com.sushibta.vmlspeedbubble.speed"
    );

    VMLTrace(
        @"TRACE PUBLISH STATE speed=%ld token=%d",
        (long)speed,
        gPublishToken
    );
}

static id VMLHookMethodCallInit(
    id self,
    SEL _cmd,
    NSString *methodName,
    id arguments
) {
    id result = nil;

    if (gOrigMethodCallInit) {
        result =
            ((id (*)(id, SEL, NSString *, id))
             gOrigMethodCallInit)(
                self,
                _cmd,
                methodName,
                arguments
            );
    }

    NSInteger speed = -1;

    if ([methodName isEqualToString:@"updateSpeedLimit"]) {
        VMLTrace(
            @"TRACE FLUTTER method=updateSpeedLimit argsClass=%@ args=%@",
            NSStringFromClass([arguments class]),
            arguments ?: @"nil"
        );
    } else if ([arguments isKindOfClass:NSDictionary.class]) {
        NSDictionary *traceDict =
            (NSDictionary *)arguments;

        if (traceDict[@"speedLimit"] ||
            traceDict[@"currentSpeedLimit"]) {

            VMLTrace(
                @"TRACE PAYLOAD method=%@ speedLimit=%@ currentSpeedLimit=%@",
                methodName ?: @"nil",
                traceDict[@"speedLimit"] ?: @"nil",
                traceDict[@"currentSpeedLimit"] ?: @"nil"
            );
        }
    }

// Source A: proven direct Flutter event.
    if ([methodName isEqualToString:@"updateSpeedLimit"]) {
        speed =
            VMLSpeedFromObject(arguments);
    }

    // Source B: proven VietMap road payload:
    // { roadName=..., speed=..., speedLimit=50/60, ... }
    // IMPORTANT: only exact TOP-LEVEL current-limit keys are accepted.
    // No recursive scanning and no arbitrary numbers.
    if ((speed <= 0 || speed > 200) &&
        [arguments isKindOfClass:NSDictionary.class]) {

        NSDictionary *dict =
            (NSDictionary *)arguments;

        id value =
            dict[@"speedLimit"];

        if (!value) {
            value =
                dict[@"currentSpeedLimit"];
        }

        NSInteger candidate =
            VMLSpeedFromObject(value);

        if (candidate > 0 &&
            candidate <= 200) {

            speed =
                candidate;
        }
    }

    if (speed > 0 && speed <= 200) {
        VMLLog(
            @"CURRENT SPEED LIMIT method=%@ speed=%ld",
            methodName ?: @"nil",
            (long)speed
        );

        VMLPublishValidSpeed(speed);
    }

    return result;
}

static void VMLInstallHook(void) {
    Class cls =
        objc_getClass("FlutterMethodCall");

    if (!cls) {
        VMLLog(@"FlutterMethodCall not loaded yet");
        return;
    }

    SEL sel =
        NSSelectorFromString(
            @"initWithMethodName:arguments:"
        );

    Method method =
        class_getInstanceMethod(cls, sel);

    if (!method) {
        VMLLog(@"FlutterMethodCall method missing");
        return;
    }

    IMP current =
        method_getImplementation(method);

    if (current == (IMP)VMLHookMethodCallInit) {
        VMLLog(@"FlutterMethodCall already hooked");
        return;
    }

    gOrigMethodCallInit = current;

    method_setImplementation(
        method,
        (IMP)VMLHookMethodCallInit
    );

    VMLLog(
        @"HOOKED FlutterMethodCall initWithMethodName:arguments:"
    );
}


static void VMLDyldImageAdded(
    const struct mach_header *mh,
    intptr_t slide
) {
    (void)mh;
    (void)slide;

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            VMLInstallHook();
        }
    );
}

static void VMLStart(void) {
    NSString *bundle =
        NSBundle.mainBundle.bundleIdentifier ?: @"";

    NSString *process =
        NSProcessInfo.processInfo.processName ?: @"";

    if (![bundle isEqualToString:@"vn.vietmap.live"]) {
        return;
    }

    VMLInstallPhoneForegroundObservers();
    VMLStartCarPlayTemplateSceneWatcher();




    VMLLog(@"========================================");
    VMLLog(@"VML RUNTIME BRIDGE V14.5");
    VMLLog(@"bundle=%@", bundle);
    VMLLog(@"process=%@", process);
    VMLLog(@"home=%@", NSHomeDirectory());
    VMLLog(@"========================================");

    // Install immediately so we do not miss the first speed-limit event.
    VMLInstallHook();

    _dyld_register_func_for_add_image(
        VMLDyldImageAdded
    );

    NSArray<NSNumber *> *delays =
        @[@0.10, @0.30, @0.75, @1.50, @3.00];

    for (NSNumber *delay in delays) {
        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                (int64_t)(
                    delay.doubleValue *
                    NSEC_PER_SEC
                )
            ),
            dispatch_get_main_queue(),
            ^{
                VMLInstallHook();
            }
        );
    }
}

%ctor {
    @autoreleasepool {
        VMLStart();
    }
}
