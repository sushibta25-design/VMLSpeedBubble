#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <notify.h>

static IMP gOrigMethodCallInit = NULL;
static int gNotifyToken = 0;

static NSString *VMLLogPath(void) {
    return [[NSHomeDirectory()
        stringByAppendingPathComponent:@"Documents"]
        stringByAppendingPathComponent:@"VMLRuntime.txt"];
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
        [line writeToFile:path
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:nil];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:
            [line dataUsingEncoding:NSUTF8StringEncoding]];
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
    if (speed < 0 || speed > 200)
        return;

    if (gNotifyToken == 0) {
        int token = 0;

        uint32_t status =
            notify_register_check(
                "com.sushibta.vmlspeedbubble.speed",
                &token
            );

        if (status == NOTIFY_STATUS_OK) {
            gNotifyToken = token;
        } else {
            VMLLog(
                @"notify_register_check failed=%u",
                status
            );

            return;
        }
    }

    notify_set_state(
        gNotifyToken,
        (uint64_t)speed
    );

    notify_post(
        "com.sushibta.vmlspeedbubble.speed"
    );

    VMLLog(
        @"*** PUBLISHED SPEED = %ld ***",
        (long)speed
    );
}

static id VMLHookMethodCallInit(
    id self,
    SEL _cmd,
    NSString *method,
    id arguments
) {
    id result = nil;

    if (gOrigMethodCallInit) {
        result =
            ((id (*)(id, SEL, NSString *, id))
             gOrigMethodCallInit)(
                self,
                _cmd,
                method,
                arguments
            );
    }

    if ([method isEqualToString:@"updateSpeedLimit"]) {
        NSInteger speed =
            VMLSpeedFromObject(arguments);

        VMLLog(
            @"updateSpeedLimit arguments=%@ parsed=%ld",
            arguments,
            (long)speed
        );

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

    if (current == (IMP)VMLHookMethodCallInit)
        return;

    gOrigMethodCallInit = current;

    method_setImplementation(
        method,
        (IMP)VMLHookMethodCallInit
    );

    VMLLog(
        @"HOOKED FlutterMethodCall initWithMethodName:arguments:"
