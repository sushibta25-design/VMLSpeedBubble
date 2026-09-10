#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <notify.h>



static IMP gOrigMethodCallInit = NULL;
static void VMLLog(NSString *format, ...);

static int gPublishToken = 0;

static int gCarPlayVisibleToken = 0;
static BOOL gLastCarPlayVisible = NO;
static BOOL gHaveCarPlayVisibleState = NO;

static BOOL VMLLooksLikeExternalCarPlayScreen(UIScreen *screen) {
    if (!screen) return NO;

    CGSize s = screen.bounds.size;
    CGFloat w = MAX(s.width, s.height);
    CGFloat h = MIN(s.width, s.height);

    // Proven CarPlay layouts on this setup are ~640x240 and ~426.67x240.
    return (h >= 180.0 && h <= 300.0 && w >= 400.0);
}

static void VMLPublishCarPlayVisible(BOOL visible) {
    if (gCarPlayVisibleToken == 0) {
        int token = 0;
        uint32_t status =
            notify_register_check(
                "com.sushibta.vmlspeedbubble.vmlcarplayvisible",
                &token
            );

        if (status != NOTIFY_STATUS_OK) {
            VMLLog(@"carplay-visible notify_register_check failed=%u", status);
            return;
        }

        gCarPlayVisibleToken = token;
    }

    notify_set_state(
        gCarPlayVisibleToken,
        visible ? 1 : 0
    );

    notify_post(
        "com.sushibta.vmlspeedbubble.vmlcarplayvisible"
    );

    if (!gHaveCarPlayVisibleState || gLastCarPlayVisible != visible) {
        VMLLog(
            @"*** VML CARPLAY VISIBLE = %d ***",
            visible
        );
    }

    gLastCarPlayVisible = visible;
    gHaveCarPlayVisibleState = YES;
}

static BOOL VMLHasVisibleCarPlayScene(void) {
    UIApplication *app = UIApplication.sharedApplication;

    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class])
            continue;

        UIWindowScene *ws = (UIWindowScene *)scene;

        if (!VMLLooksLikeExternalCarPlayScreen(ws.screen))
            continue;

        if (ws.activationState == UISceneActivationStateUnattached)
            continue;

        BOOL hasVisibleWindow = NO;

        for (UIWindow *window in ws.windows) {
            if (!window.hidden && window.alpha > 0.01) {
                hasVisibleWindow = YES;
                break;
            }
        }

        if (hasVisibleWindow)
            return YES;
    }

    return NO;
}

static void VMLStartCarPlayVisibilityWatcher(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        VMLPublishCarPlayVisible(VMLHasVisibleCarPlayScene());

        [NSTimer scheduledTimerWithTimeInterval:0.35
                                        repeats:YES
                                          block:^(__unused NSTimer *timer) {
            VMLPublishCarPlayVisible(VMLHasVisibleCarPlayScene());
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

    if ([methodName isEqualToString:@"updateSpeedLimit"]) {
        NSInteger speed =
            VMLSpeedFromObject(arguments);

        VMLLog(
            @"updateSpeedLimit arguments=%@ parsed=%ld",
            arguments,
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

static void VMLStart(void) {
    NSString *bundle =
        NSBundle.mainBundle.bundleIdentifier ?: @"";

    NSString *process =
        NSProcessInfo.processInfo.processName ?: @"";

    if (![bundle isEqualToString:@"vn.vietmap.live"]) {
        return;
    }

    VMLStartCarPlayVisibilityWatcher();

    VMLLog(@"========================================");
    VMLLog(@"VML RUNTIME BRIDGE V12.7");
    VMLLog(@"bundle=%@", bundle);
    VMLLog(@"process=%@", process);
    VMLLog(@"home=%@", NSHomeDirectory());
    VMLLog(@"========================================");

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            1 * NSEC_PER_SEC
        ),
        dispatch_get_main_queue(),
        ^{
            VMLLog(@"INSTALL +1");
            VMLInstallHook();
        }
    );

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            4 * NSEC_PER_SEC
        ),
        dispatch_get_main_queue(),
        ^{
            VMLLog(@"INSTALL +4");
            VMLInstallHook();
        }
    );

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            8 * NSEC_PER_SEC
        ),
        dispatch_get_main_queue(),
        ^{
            VMLLog(@"INSTALL +8");
            VMLInstallHook();
        }
    );
}

%ctor {
    @autoreleasepool {
        VMLStart();
    }
}
