#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <notify.h>

static IMP gOrigMethodCallInit = NULL;
static int gPublishToken = 0;

static NSString *VMLLastSpeedPath(void) {
    return @"/var/mobile/VMLLastSpeed.txt";
}

static void VMLSaveLastValidSpeed(NSInteger speed) {
    if (speed <= 0 || speed > 200) return;

    NSString *value = [NSString stringWithFormat:@"%ld", (long)speed];
    NSError *error = nil;
    [value writeToFile:VMLLastSpeedPath()
            atomically:YES
              encoding:NSUTF8StringEncoding
                 error:&error];

    if (error) {
        VMLLog(@"CACHE WRITE ERROR %@", error);
    } else {
        VMLLog(@"*** CACHED LAST VALID SPEED=%ld ***", (long)speed);
    }
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
            NSLog(@"[VMLV4] WRITE ERROR %@", error);
        }
    } else {
        [fh seekToEndOfFile];

        NSData *data =
            [line dataUsingEncoding:NSUTF8StringEncoding];

        [fh writeData:data];
        [fh closeFile];
    }

    NSLog(@"[VMLV4] %@", msg);
}

static NSInteger VMLSpeedFromObject(id obj) {
    if (!obj)
        return -1;

    if ([obj respondsToSelector:@selector(integerValue)]) {
        return [obj integerValue];
    }

    return -1;
}

static void VMLPublishSpeed(NSInteger speed) {
    if (speed < 0 || speed > 200) {
        VMLLog(@"IGNORE invalid speed=%ld", (long)speed);
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
        @"*** PUBLISHED SPEED=%ld stateStatus=%u postStatus=%u ***",
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

        if (speed > 0 && speed <= 200) {
            VMLSaveLastValidSpeed(speed);
        }

        VMLPublishSpeed(speed);
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

    VMLLog(@"========================================");
    VMLLog(@"VML RUNTIME BRIDGE V4");
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
