#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#pragma mark - Log

static NSString *VMLRuntimeLogPath(void) {
    NSString *documents =
        [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];

    return [documents stringByAppendingPathComponent:@"VMLRuntime.txt"];
}

static void VMLRLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);

    NSString *msg =
        [[NSString alloc] initWithFormat:format arguments:args];

    va_end(args);

    NSString *line =
        [NSString stringWithFormat:@"%@\n", msg];

    NSString *path = VMLRuntimeLogPath();

    NSFileHandle *fh =
        [NSFileHandle fileHandleForWritingAtPath:path];

    if (!fh) {
        NSError *error = nil;

        [line writeToFile:path
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:&error];

        if (error) {
            NSLog(@"[VMLRUNTIME] WRITE ERROR %@", error);
        }
    } else {
        [fh seekToEndOfFile];

        [fh writeData:
            [line dataUsingEncoding:NSUTF8StringEncoding]];

        [fh closeFile];
    }

    NSLog(@"[VMLRUNTIME] %@", msg);
}

#pragma mark - Helpers

static BOOL VMLPlausibleSpeed(unsigned long long value) {
    return value >= 1 && value <= 200;
}

static void VMLLogSpeed(
    NSString *className,
    NSString *selectorName,
    unsigned long long value
) {
    if (VMLPlausibleSpeed(value)) {
        VMLRLog(
            @"*** SPEED CANDIDATE *** class=%@ selector=%@ value=%llu",
            className,
            selectorName,
            value
        );
    } else {
        VMLRLog(
            @"VALUE class=%@ selector=%@ value=%llu",
            className,
            selectorName,
            value
        );
    }
}

#pragma mark - MNLocation

static IMP orig_MNLocation_speedLimit = NULL;
static IMP orig_MNLocation_setSpeedLimit = NULL;

static unsigned long long
hook_MNLocation_speedLimit(id self, SEL _cmd) {

    unsigned long long value = 0;

    if (orig_MNLocation_speedLimit) {
        value =
            ((unsigned long long (*)(id, SEL))
             orig_MNLocation_speedLimit)(
                self,
                _cmd
            );
    }

    VMLLogSpeed(
        NSStringFromClass([self class]),
        @"speedLimit",
        value
    );

    return value;
}

static void
hook_MNLocation_setSpeedLimit(
    id self,
    SEL _cmd,
    unsigned long long value
) {
    VMLLogSpeed(
        NSStringFromClass([self class]),
        @"setSpeedLimit:",
        value
    );

    if (orig_MNLocation_setSpeedLimit) {
        ((void (*)(id, SEL, unsigned long long))
         orig_MNLocation_setSpeedLimit)(
            self,
            _cmd,
            value
        );
    }
}

#pragma mark - GEOMapFeatureRoad

static IMP orig_GEOMapFeatureRoad_speedLimit = NULL;

static unsigned long long
hook_GEOMapFeatureRoad_speedLimit(id self, SEL _cmd) {

    unsigned long long value = 0;

    if (orig_GEOMapFeatureRoad_speedLimit) {
        value =
            ((unsigned long long (*)(id, SEL))
             orig_GEOMapFeatureRoad_speedLimit)(
                self,
                _cmd
            );
    }

    VMLLogSpeed(
        NSStringFromClass([self class]),
        @"speedLimit",
        value
    );

    return value;
}

#pragma mark - GEOMapAccessRoad

static IMP orig_GEOMapAccessRoad_speedLimit = NULL;

static unsigned long long
hook_GEOMapAccessRoad_speedLimit(id self, SEL _cmd) {

    unsigned long long value = 0;

    if (orig_GEOMapAccessRoad_speedLimit) {
        value =
            ((unsigned long long (*)(id, SEL))
             orig_GEOMapAccessRoad_speedLimit)(
                self,
                _cmd
            );
    }

    VMLLogSpeed(
        NSStringFromClass([self class]),
        @"speedLimit",
        value
    );

    return value;
}

#pragma mark - GEOMultiSectionFeature

static IMP orig_GEOMulti_speedLimit = NULL;
static IMP orig_GEOMulti_displaySpeedLimit = NULL;
static IMP orig_GEOMulti_reverseSpeedLimit = NULL;

static unsigned char
hook_GEOMulti_speedLimit(id self, SEL _cmd) {

    unsigned char value = 0;

    if (orig_GEOMulti_speedLimit) {
        value =
            ((unsigned char (*)(id, SEL))
             orig_GEOMulti_speedLimit)(
                self,
                _cmd
            );
    }

    VMLLogSpeed(
        NSStringFromClass([self class]),
        @"speedLimit",
        (unsigned long long)value
    );

    return value;
}

static unsigned char
hook_GEOMulti_displaySpeedLimit(id self, SEL _cmd) {

    unsigned char value = 0;

    if (orig_GEOMulti_displaySpeedLimit) {
        value =
            ((unsigned char (*)(id, SEL))
             orig_GEOMulti_displaySpeedLimit)(
                self,
                _cmd
            );
    }

    VMLLogSpeed(
        NSStringFromClass([self class]),
        @"displaySpeedLimit",
        (unsigned long long)value
    );

    return value;
}

static unsigned char
hook_GEOMulti_reverseSpeedLimit(id self, SEL _cmd) {

    unsigned char value = 0;

    if (orig_GEOMulti_reverseSpeedLimit) {
        value =
            ((unsigned char (*)(id, SEL))
             orig_GEOMulti_reverseSpeedLimit)(
                self,
                _cmd
            );
    }

    VMLLogSpeed(
        NSStringFromClass([self class]),
        @"reverseDirectionDisplaySpeedLimit",
        (unsigned long long)value
    );

    return value;
}

#pragma mark - Hook installer

static BOOL VMLHookMethod(
    NSString *className,
    NSString *selectorName,
    IMP replacement,
    IMP *originalStorage
) {
    Class cls =
        objc_getClass([className UTF8String]);

    if (!cls) {
        VMLRLog(
            @"WAIT class not loaded: %@",
            className
        );

        return NO;
    }

    SEL sel =
        NSSelectorFromString(selectorName);

    Method method =
        class_getInstanceMethod(cls, sel);

    if (!method) {
        VMLRLog(
            @"MISSING %@ %@",
            className,
            selectorName
        );

        return NO;
    }

    IMP current =
        method_getImplementation(method);

    if (!current) {
        VMLRLog(
            @"NO IMP %@ %@",
            className,
            selectorName
        );

        return NO;
    }

    /*
     * If already pointing to our replacement,
     * don't install twice.
     */
    if (current == replacement) {
        return YES;
    }

    *originalStorage = current;

    method_setImplementation(
        method,
        replacement
    );

    VMLRLog(
        @"HOOK INSTALLED class=%@ selector=%@ types=%s",
        className,
        selectorName,
        method_getTypeEncoding(method)
    );

    return YES;
}

static void VMLInstallHooks(void) {

    VMLRLog(@"---------- INSTALL PASS ----------");

    if (!orig_MNLocation_speedLimit) {
        VMLHookMethod(
            @"MNLocation",
            @"speedLimit",
            (IMP)hook_MNLocation_speedLimit,
            &orig_MNLocation_speedLimit
        );
    }

    if (!orig_MNLocation_setSpeedLimit) {
        VMLHookMethod(
            @"MNLocation",
            @"setSpeedLimit:",
            (IMP)hook_MNLocation_setSpeedLimit,
            &orig_MNLocation_setSpeedLimit
        );
    }

    if (!orig_GEOMapFeatureRoad_speedLimit) {
        VMLHookMethod(
            @"GEOMapFeatureRoad",
            @"speedLimit",
            (IMP)hook_GEOMapFeatureRoad_speedLimit,
            &orig_GEOMapFeatureRoad_speedLimit
        );
    }

    if (!orig_GEOMapAccessRoad_speedLimit) {
        VMLHookMethod(
            @"GEOMapAccessRoad",
            @"speedLimit",
            (IMP)hook_GEOMapAccessRoad_speedLimit,
            &orig_GEOMapAccessRoad_speedLimit
        );
    }

    if (!orig_GEOMulti_speedLimit) {
        VMLHookMethod(
            @"GEOMultiSectionFeature",
            @"speedLimit",
            (IMP)hook_GEOMulti_speedLimit,
            &orig_GEOMulti_speedLimit
        );
    }

    if (!orig_GEOMulti_displaySpeedLimit) {
        VMLHookMethod(
            @"GEOMultiSectionFeature",
            @"displaySpeedLimit",
            (IMP)hook_GEOMulti_displaySpeedLimit,
            &orig_GEOMulti_displaySpeedLimit
        );
    }

    if (!orig_GEOMulti_reverseSpeedLimit) {
        VMLHookMethod(
            @"GEOMultiSectionFeature",
            @"reverseDirectionDisplaySpeedLimit",
            (IMP)hook_GEOMulti_reverseSpeedLimit,
            &orig_GEOMulti_reverseSpeedLimit
        );
    }

    VMLRLog(@"---------- INSTALL DONE ----------");
}

#pragma mark - Start

static void VMLStart(void) {

    NSString *bundle =
        NSBundle.mainBundle.bundleIdentifier ?: @"";

    NSString *process =
        NSProcessInfo.processInfo.processName ?: @"";

    if (![bundle isEqualToString:@"vn.vietmap.live"])
        return;

    VMLRLog(@"======================================");
    VMLRLog(@"VML RUNTIME SNIFFER V2");
    VMLRLog(@"bundle=%@", bundle);
    VMLRLog(@"process=%@", process);
    VMLRLog(@"home=%@", NSHomeDirectory());
    VMLRLog(@"log=%@", VMLRuntimeLogPath());
    VMLRLog(@"======================================");

    /*
     * Try several times because frameworks may load
     * after tweak constructor runs.
     */

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            1 * NSEC_PER_SEC
        ),
        dispatch_get_main_queue(),
        ^{
            VMLRLog(@"INSTALL +1 sec");
            VMLInstallHooks();
        }
    );

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            4 * NSEC_PER_SEC
        ),
        dispatch_get_main_queue(),
        ^{
            VMLRLog(@"INSTALL +4 sec");
            VMLInstallHooks();
        }
    );

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            8 * NSEC_PER_SEC
        ),
        dispatch_get_main_queue(),
        ^{
            VMLRLog(@"INSTALL +8 sec");
            VMLInstallHooks();
        }
    );

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            15 * NSEC_PER_SEC
        ),
        dispatch_get_main_queue(),
        ^{
            VMLRLog(@"INSTALL +15 sec");
            VMLInstallHooks();
        }
    );
}

%ctor {
    @autoreleasepool {
        VMLStart();
    }
}
