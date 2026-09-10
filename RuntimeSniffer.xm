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
static BOOL gLastPhoneSceneForeground = NO;
static BOOL gHavePhoneSceneState = NO;

static BOOL VMLLooksLikePhoneWindowScene(UIWindowScene *ws) {
    if (!ws) return NO;

    CGSize size = ws.screen.bounds.size;

    CGFloat w = MIN(size.width, size.height);
    CGFloat h = MAX(size.width, size.height);

    // iPhone display: narrow + tall. This intentionally excludes
    // the 426/640 x 240 CarPlay screen.
    return (w <= 500.0 && h >= 600.0);
}

static BOOL VMLPhoneSceneIsForeground(void) {
    UIApplication *app = UIApplication.sharedApplication;

    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class])
            continue;

        UIWindowScene *ws = (UIWindowScene *)scene;

        if (!VMLLooksLikePhoneWindowScene(ws))
            continue;

        BOOL active =
            (ws.activationState == UISceneActivationStateForegroundActive);

        if (active)
            return YES;
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
            VMLLog(@"phoneforeground register failed=%u", status);
            return;
        }

        gPhoneForegroundToken = token;
    }

    notify_set_state(
        gPhoneForegroundToken,
        foreground ? 1 : 0
    );

    notify_post(
        "com.sushibta.vmlspeedbubble.phoneforeground"
    );

    if (!gHavePhoneSceneState ||
        gLastPhoneSceneForeground != foreground) {

        VMLLog(
            @"*** VML PHONE SCENE FOREGROUND = %d ***",
            foreground
        );
    }

    gLastPhoneSceneForeground = foreground;
    gHavePhoneSceneState = YES;
}

static void VMLInstallPhoneForegroundObservers(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        VMLPublishPhoneForeground(
            VMLPhoneSceneIsForeground()
        );

        [NSTimer scheduledTimerWithTimeInterval:0.20
                                        repeats:YES
                                          block:^(__unused NSTimer *timer) {
            VMLPublishPhoneForeground(
                VMLPhoneSceneIsForeground()
            );
        }];
    });
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

static NSInteger VMLSpeedFromObject(id obj) {
    if (!obj)
        return -1;

    if ([obj respondsToSelector:@selector(integerValue)]) {
        return [obj integerValue];
    }

    return -1;
}

static NSInteger VMLCurrentSpeedLimitFromArguments(id arguments) {
    if (!arguments)
        return -1;

    // Direct updateSpeedLimit payload.
    NSInteger direct =
        VMLSpeedFromObject(arguments);

    if (direct > 0 && direct <= 200)
        return direct;

    if ([arguments isKindOfClass:NSDictionary.class]) {
        NSDictionary *dict =
            (NSDictionary *)arguments;

        // Only current-limit keys. Deliberately ignore nextSpeedLimit.
        NSArray<NSString *> *keys =
            @[
                @"speedLimit",
                @"currentSpeedLimit",
                @"current_speed_limit"
            ];

        for (NSString *key in keys) {
            id value =
                dict[key];

            NSInteger speed =
                VMLSpeedFromObject(value);

            if (speed > 0 && speed <= 200)
                return speed;
        }

        // Some Flutter payloads wrap the road data one level deeper.
        NSArray<NSString *> *containers =
            @[
                @"data",
                @"arguments",
                @"payload",
                @"road",
                @"currentRoad"
            ];

        for (NSString *key in containers) {
            id nested =
                dict[key];

            NSInteger speed =
                VMLCurrentSpeedLimitFromArguments(nested);

            if (speed > 0 && speed <= 200)
                return speed;
        }
    }

    if ([arguments isKindOfClass:NSArray.class]) {
        for (id item in (NSArray *)arguments) {
            NSInteger speed =
                VMLCurrentSpeedLimitFromArguments(item);

            if (speed > 0 && speed <= 200)
                return speed;
        }
    }

    return -1;
}

static void VMLPublishValidSpeed(NSInteger speed) {
    // V12.3: 0 means "no fresh value". Never overwrite the last valid
    // notify state with 0, so CarPlay can read the latest known limit instantly.
    if (speed <= 0 || speed > 200) {
        VMLLog(@"KEEP LAST VALID - ignore publish speed=%ld", (long)speed);
        return;
    }

    if (gPublishToken == 0) {
        int token = 0;

        uint32_t status =
            notify_register_check(
                "com.sushibta.vmlspeedbubble.speed",
                &token
            );

        if (status != NOTIFY_STATUS_OK) {
            VMLLog(
                @"notify_register_check failed=%u",
                status
            );
            return;
        }

        gPublishToken = token;
    }

    uint32_t stateStatus =
        notify_set_state(
            gPublishToken,
            (uint64_t)speed
        );

    uint32_t postStatus =
        notify_post(
            "com.sushibta.vmlspeedbubble.speed"
        );

    VMLLog(
        @"*** PUBLISHED VALID SPEED=%ld stateStatus=%u postStatus=%u ***",
        (long)speed,
        stateStatus,
        postStatus
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
        speed =
            VMLCurrentSpeedLimitFromArguments(arguments);
    } else if ([arguments isKindOfClass:NSDictionary.class] ||
               [arguments isKindOfClass:NSArray.class]) {
        speed =
            VMLCurrentSpeedLimitFromArguments(arguments);
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
    VMLLog(@"VML RUNTIME BRIDGE V13.7");
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
