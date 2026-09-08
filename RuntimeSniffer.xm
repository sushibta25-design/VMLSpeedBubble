#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

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
            NSLog(@"[VMLRUNTIME] WRITE ERROR: %@", error);
        }
    } else {
        [fh seekToEndOfFile];

        [fh writeData:
            [line dataUsingEncoding:NSUTF8StringEncoding]];

        [fh closeFile];
    }

    NSLog(@"[VMLRUNTIME] %@", msg);
}

static NSString *VMLSafeDescription(id obj) {
    if (!obj)
        return @"(nil)";

    @try {
        NSString *s = [obj description];

        if (s.length > 1500) {
            s =
                [[s substringToIndex:1500]
                 stringByAppendingString:@"..."];
        }

        return s ?: @"(null description)";
    }
    @catch (NSException *e) {
        return
            [NSString stringWithFormat:
                @"<description exception %@>", e];
    }
}

#pragma mark - Hook storage

static NSMutableSet *gVMLHooked = nil;

static const void *VMLKeyForMethod(Class cls, SEL sel) {
    NSString *key =
        [NSString stringWithFormat:@"%@|%@",
         NSStringFromClass(cls),
         NSStringFromSelector(sel)];

    return (__bridge_retained const void *)key;
}

static IMP VMLOriginalIMP(Class cls, SEL sel) {
    if (!cls || !sel)
        return NULL;

    NSString *key =
        [NSString stringWithFormat:@"%@|%@",
         NSStringFromClass(cls),
         NSStringFromSelector(sel)];

    NSValue *value =
        objc_getAssociatedObject(
            cls,
            (__bridge const void *)key
        );

    if (!value)
        return NULL;

    return (IMP)[value pointerValue];
}

static void VMLStoreOriginalIMP(
    Class cls,
    SEL sel,
    IMP imp
) {
    if (!cls || !sel || !imp)
        return;

    NSString *key =
        [NSString stringWithFormat:@"%@|%@",
         NSStringFromClass(cls),
         NSStringFromSelector(sel)];

    objc_setAssociatedObject(
        cls,
        (__bridge const void *)key,
        [NSValue valueWithPointer:(const void *)imp],
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );
}

#pragma mark - Selector filter

static BOOL VMLInterestingSelector(NSString *name) {
    if (!name.length)
        return NO;

    NSString *s = name.lowercaseString;

    return
        [s containsString:@"speedlimit"] ||
        [s containsString:@"speed_limit"] ||
        [s containsString:@"speedandlimit"] ||
        [s containsString:@"speedandlimitview"] ||
        [s containsString:@"updatespeed"] ||
        [s containsString:@"sendspeed"];
}

#pragma mark - Replacement methods

static IMP VMLFindOriginal(id self, SEL cmd) {
    if (!self || !cmd)
        return NULL;

    Class cls = [self class];

    IMP imp =
        VMLOriginalIMP(cls, cmd);

    if (!imp) {
        Class meta =
            object_getClass(cls);

        imp =
            VMLOriginalIMP(meta, cmd);
    }

    return imp;
}

static void VMLVoidNoArg(
    id self,
    SEL _cmd
) {
    VMLRLog(
        @"CALL class=%@ selector=%@",
        NSStringFromClass([self class]),
        NSStringFromSelector(_cmd)
    );

    IMP imp =
        VMLFindOriginal(self, _cmd);

    if (imp) {
        ((void (*)(id, SEL))imp)(
            self,
            _cmd
        );
    }
}

static void VMLVoidOneObject(
    id self,
    SEL _cmd,
    id arg
) {
    VMLRLog(
        @"CALL class=%@ selector=%@ arg=%@ argClass=%@",
        NSStringFromClass([self class]),
        NSStringFromSelector(_cmd),
        VMLSafeDescription(arg),
        arg ? NSStringFromClass([arg class]) : @"nil"
    );

    IMP imp =
        VMLFindOriginal(self, _cmd);

    if (imp) {
        ((void (*)(id, SEL, id))imp)(
            self,
            _cmd,
            arg
        );
    }
}

static id VMLObjectNoArg(
    id self,
    SEL _cmd
) {
    IMP imp =
        VMLFindOriginal(self, _cmd);

    id result = nil;

    if (imp) {
        result =
            ((id (*)(id, SEL))imp)(
                self,
                _cmd
            );
    }

    VMLRLog(
        @"RETURN class=%@ selector=%@ value=%@ valueClass=%@",
        NSStringFromClass([self class]),
        NSStringFromSelector(_cmd),
        VMLSafeDescription(result),
        result ? NSStringFromClass([result class]) : @"nil"
    );

    return result;
}

static id VMLObjectOneObject(
    id self,
    SEL _cmd,
    id arg
) {
    VMLRLog(
        @"CALL class=%@ selector=%@ arg=%@ argClass=%@",
        NSStringFromClass([self class]),
        NSStringFromSelector(_cmd),
        VMLSafeDescription(arg),
        arg ? NSStringFromClass([arg class]) : @"nil"
    );

    IMP imp =
        VMLFindOriginal(self, _cmd);

    id result = nil;

    if (imp) {
        result =
            ((id (*)(id, SEL, id))imp)(
                self,
                _cmd,
                arg
            );
    }

    VMLRLog(
        @"RETURN class=%@ selector=%@ value=%@ valueClass=%@",
        NSStringFromClass([self class]),
        NSStringFromSelector(_cmd),
        VMLSafeDescription(result),
        result ? NSStringFromClass([result class]) : @"nil"
    );

    return result;
}

#pragma mark - Runtime scan

static void VMLScanClass(Class cls) {
    if (!cls)
        return;

    NSString *className =
        NSStringFromClass(cls);

    if (!className.length)
        return;

    unsigned int count = 0;

    Method *methods =
        class_copyMethodList(
            cls,
            &count
        );

    if (!methods)
        return;

    for (unsigned int i = 0; i < count; i++) {
        Method method = methods[i];

        SEL sel =
            method_getName(method);

        if (!sel)
            continue;

        NSString *selName =
            NSStringFromSelector(sel);

        if (!VMLInterestingSelector(selName))
            continue;

        NSString *unique =
            [NSString stringWithFormat:@"%@|%@",
             className,
             selName];

        if ([gVMLHooked containsObject:unique])
            continue;

        const char *types =
            method_getTypeEncoding(method);

        if (!types)
            continue;

        unsigned int argc =
            method_getNumberOfArguments(method);

        char returnType[128] = {0};

        method_getReturnType(
            method,
            returnType,
            sizeof(returnType)
        );

        VMLRLog(
            @"FOUND class=%@ selector=%@ argc=%u types=%s",
            className,
            selName,
            argc,
            types
        );

        IMP replacement = NULL;

        /*
         * Objective-C argument count includes:
         *
         * self
         * _cmd
         *
         * Therefore:
         *
         * argc == 2 : no explicit arguments
         * argc == 3 : one explicit argument
         */

        if (argc == 2) {
            if (returnType[0] == 'v') {
                replacement =
                    (IMP)VMLVoidNoArg;
            }
            else if (returnType[0] == '@') {
                replacement =
                    (IMP)VMLObjectNoArg;
            }
        }

        else if (argc == 3) {
            char argType[128] = {0};

            method_getArgumentType(
                method,
                2,
                argType,
                sizeof(argType)
            );

            /*
             * For this diagnostic build we only replace
             * methods taking an Objective-C object.
             *
             * int / BOOL / double / struct etc are logged
             * as FOUND but intentionally skipped.
             */

            if (argType[0] == '@') {
                if (returnType[0] == 'v') {
                    replacement =
                        (IMP)VMLVoidOneObject;
                }
                else if (returnType[0] == '@') {
                    replacement =
                        (IMP)VMLObjectOneObject;
                }
            }
        }

        if (!replacement) {
            VMLRLog(
                @"SKIP unsafe signature class=%@ selector=%@ types=%s",
                className,
                selName,
                types
            );

            continue;
        }

        IMP original =
            method_getImplementation(method);

        if (!original) {
            VMLRLog(
                @"SKIP no IMP class=%@ selector=%@",
                className,
                selName
            );

            continue;
        }

        VMLStoreOriginalIMP(
            cls,
            sel,
            original
        );

        method_setImplementation(
            method,
            replacement
        );

        [gVMLHooked addObject:unique];

        VMLRLog(
            @"HOOKED class=%@ selector=%@",
            className,
            selName
        );
    }

    free(methods);
}

static void VMLScanRuntime(void) {
    int count =
        objc_getClassList(NULL, 0);

    if (count <= 0) {
        VMLRLog(@"objc_getClassList returned %d", count);
        return;
    }

    Class *classes =
        (__unsafe_unretained Class *)
        malloc(sizeof(Class) * count);

    if (!classes) {
        VMLRLog(@"malloc failed");
        return;
    }

    count =
        objc_getClassList(
            classes,
            count
        );

    VMLRLog(
        @"Scanning %d Objective-C classes",
        count
    );

    for (int i = 0; i < count; i++) {
        Class cls =
            classes[i];

        VMLScanClass(cls);

        /*
         * Also scan class methods.
         */

        Class meta =
            object_getClass(cls);

        if (meta)
            VMLScanClass(meta);
    }

    free(classes);

    VMLRLog(
        @"Scan finished. Hooked=%lu",
        (unsigned long)gVMLHooked.count
    );
}

#pragma mark - Startup

static void VMLStartRuntimeSniffer(void) {
    NSString *bundle =
        NSBundle.mainBundle.bundleIdentifier ?: @"";

    NSString *process =
        NSProcessInfo.processInfo.processName ?: @"";

    if (![bundle isEqualToString:@"vn.vietmap.live"])
        return;

    gVMLHooked =
        [NSMutableSet new];

    VMLRLog(@"========================================");
    VMLRLog(@"VML RUNTIME SNIFFER START");
    VMLRLog(@"bundle=%@", bundle);
    VMLRLog(@"process=%@", process);
    VMLRLog(@"home=%@", NSHomeDirectory());
    VMLRLog(@"log=%@", VMLRuntimeLogPath());
    VMLRLog(@"========================================");

    /*
     * Flutter/native frameworks can appear later,
     * so scan several times.
     */

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            2 * NSEC_PER_SEC
        ),
        dispatch_get_main_queue(),
        ^{
            VMLRLog(@"SCAN +2 sec");
            VMLScanRuntime();
        }
    );

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            6 * NSEC_PER_SEC
        ),
        dispatch_get_main_queue(),
        ^{
            VMLRLog(@"SCAN +6 sec");
            VMLScanRuntime();
        }
    );

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            12 * NSEC_PER_SEC
        ),
        dispatch_get_main_queue(),
        ^{
            VMLRLog(@"SCAN +12 sec");
            VMLScanRuntime();
        }
    );
}

%ctor {
    @autoreleasepool {
        VMLStartRuntimeSniffer();
    }
}
