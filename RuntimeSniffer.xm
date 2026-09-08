#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString * const VMLRuntimeLogPath = @"/var/mobile/VMLRuntime.txt";

static void VMLRLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"%@\n", msg];

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:VMLRuntimeLogPath];

    if (!fh) {
        [line writeToFile:VMLRuntimeLogPath
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:nil];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }

    NSLog(@"[VMLRUNTIME] %@", msg);
}

static NSString *VMLSafeDescription(id obj) {
    if (!obj) return @"(nil)";

    @try {
        NSString *s = [obj description];
        if (s.length > 1500)
            s = [[s substringToIndex:1500] stringByAppendingString:@"..."];
        return s ?: @"(null description)";
    }
    @catch (NSException *e) {
        return [NSString stringWithFormat:@"<description exception %@>", e];
    }
}

#pragma mark - Dynamic selector sniffer

static NSMutableSet *gVMLHooked;

static BOOL VMLInterestingSelector(NSString *name) {
    if (!name) return NO;

    NSString *s = name.lowercaseString;

    return
        [s containsString:@"speedlimit"] ||
        [s containsString:@"speed_limit"] ||
        [s containsString:@"speedandlimit"] ||
        [s containsString:@"speedandlimitview"] ||
        [s containsString:@"updatespeed"] ||
        [s containsString:@"sendspeed"];
}

static IMP VMLOriginalIMP(Class cls, SEL sel) {
    NSString *key =
        [NSString stringWithFormat:@"%@|%@",
         NSStringFromClass(cls),
         NSStringFromSelector(sel)];

    NSValue *v =
        objc_getAssociatedObject(cls,
            (__bridge const void *)(key));

    return v ? [v pointerValue] : NULL;
}

static void VMLStoreOriginalIMP(Class cls, SEL sel, IMP imp) {
    NSString *key =
        [NSString stringWithFormat:@"%@|%@",
         NSStringFromClass(cls),
         NSStringFromSelector(sel)];

    objc_setAssociatedObject(
        cls,
        (__bridge const void *)(key),
        [NSValue valueWithPointer:imp],
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );
}

/*
 * These wrappers cover the most useful Objective-C signatures:
 *
 *   -(void)foo
 *   -(void)foo:(id)arg
 *   -(id)foo
 *   -(id)foo:(id)arg
 *
 * We only hook methods whose type encoding matches safely.
 */

static void VMLVoidNoArg(id self, SEL _cmd) {
    VMLRLog(@"CALL class=%@ selector=%@",
            NSStringFromClass([self class]),
            NSStringFromSelector(_cmd));

    IMP imp = VMLOriginalIMP(object_getClass(self), _cmd);

    if (!imp)
        imp = VMLOriginalIMP([self class], _cmd);

    if (imp)
        ((void (*)(id, SEL))imp)(self, _cmd);
}

static void VMLVoidOneObject(id self, SEL _cmd, id arg) {
    VMLRLog(@"CALL class=%@ selector=%@ arg=%@ argClass=%@",
            NSStringFromClass([self class]),
            NSStringFromSelector(_cmd),
            VMLSafeDescription(arg),
            arg ? NSStringFromClass([arg class]) : @"nil");

    IMP imp = VMLOriginalIMP(object_getClass(self), _cmd);

    if (!imp)
        imp = VMLOriginalIMP([self class], _cmd);

    if (imp)
        ((void (*)(id, SEL, id))imp)(self, _cmd, arg);
}

static id VMLObjectNoArg(id self, SEL _cmd) {
    IMP imp = VMLOriginalIMP(object_getClass(self), _cmd);

    if (!imp)
        imp = VMLOriginalIMP([self class], _cmd);

    id result = nil;

    if (imp)
        result = ((id (*)(id, SEL))imp)(self, _cmd);

    VMLRLog(@"RETURN class=%@ selector=%@ value=%@ valueClass=%@",
            NSStringFromClass([self class]),
            NSStringFromSelector(_cmd),
            VMLSafeDescription(result),
            result ? NSStringFromClass([result class]) : @"nil");

    return result;
}

static id VMLObjectOneObject(id self, SEL _cmd, id arg) {
    VMLRLog(@"CALL class=%@ selector=%@ arg=%@ argClass=%@",
            NSStringFromClass([self class]),
            NSStringFromSelector(_cmd),
            VMLSafeDescription(arg),
            arg ? NSStringFromClass([arg class]) : @"nil");

    IMP imp = VMLOriginalIMP(object_getClass(self), _cmd);

    if (!imp)
        imp = VMLOriginalIMP([self class], _cmd);

    id result = nil;

    if (imp)
        result = ((id (*)(id, SEL, id))imp)(self, _cmd, arg);

    VMLRLog(@"RETURN class=%@ selector=%@ value=%@ valueClass=%@",
            NSStringFromClass([self class]),
            NSStringFromSelector(_cmd),
            VMLSafeDescription(result),
            result ? NSStringFromClass([result class]) : @"nil");

    return result;
}

static void VMLScanClass(Class cls) {
    if (!cls) return;

    NSString *className = NSStringFromClass(cls);
    if (!className.length) return;

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);

    for (unsigned int i = 0; i < count; i++) {

        Method m = methods[i];
        SEL sel = method_getName(m);

        NSString *selName = NSStringFromSelector(sel);

        if (!VMLInterestingSelector(selName))
            continue;

        NSString *unique =
            [NSString stringWithFormat:@"%@|%@",
             className, selName];

        if ([gVMLHooked containsObject:unique])
            continue;

        const char *types = method_getTypeEncoding(m);

        if (!types)
            continue;

        unsigned int argc =
            method_getNumberOfArguments(m);

        char returnType[128] = {0};
        method_getReturnType(m,
                            returnType,
                            sizeof(returnType));

        VMLRLog(@"FOUND class=%@ selector=%@ argc=%u types=%s",
                className,
                selName,
                argc,
                types);

        IMP replacement = NULL;

        /*
         * argc includes self + _cmd
         */

        if (argc == 2) {

            if (returnType[0] == 'v')
                replacement = (IMP)VMLVoidNoArg;

            else if (returnType[0] == '@')
                replacement = (IMP)VMLObjectNoArg;

        } else if (argc == 3) {

            char argType[128] = {0};

            method_getArgumentType(
                m,
                2,
                argType,
                sizeof(argType)
            );

            /*
             * Only hook object arguments.
             * Avoid corrupting int/double/struct signatures.
             */
            if (argType[0] == '@') {

                if (returnType[0] == 'v')
                    replacement =
                        (IMP)VMLVoidOneObject;

                else if (returnType[0] == '@')
                    replacement =
                        (IMP)VMLObjectOneObject;
            }
        }

        if (!replacement) {
            VMLRLog(@"SKIP unsafe signature class=%@ selector=%@ types=%s",
                    className,
                    selName,
                    types);
            continue;
        }

        IMP original =
            method_getImplementation(m);

        VMLStoreOriginalIMP(cls,
                            sel,
                            original);

        method_setImplementation(
            m,
            replacement
        );

        [gVMLHooked addObject:unique];

        VMLRLog(@"HOOKED class=%@ selector=%@",
                className,
                selName);
    }

    if (methods)
        free(methods);
}

static void VMLScanRuntime(void) {

    int count =
        objc_getClassList(NULL, 0);

    if (count <= 0)
        return;

    Class *classes =
        (__unsafe_unretained Class *)
        malloc(sizeof(Class) * count);

    count =
        objc_getClassList(classes,
                          count);

    VMLRLog(@"Scanning %d Objective-C classes",
            count);

    for (int i = 0; i < count; i++) {

        Class cls = classes[i];

        VMLScanClass(cls);

        /*
         * Also inspect class methods.
         */
        Class meta =
            object_getClass(cls);

        if (meta)
            VMLScanClass(meta);
    }

    free(classes);
}

static void VMLStartRuntimeSniffer(void) {

    NSString *bundle =
        NSBundle.mainBundle.bundleIdentifier ?: @"";

    NSString *process =
        NSProcessInfo.processInfo.processName ?: @"";

    if (![bundle isEqualToString:@"vn.vietmap.live"])
        return;

    gVMLHooked =
        [NSMutableSet new];

    VMLRLog(@"================================");
    VMLRLog(@"VML RUNTIME SNIFFER START");
    VMLRLog(@"bundle=%@", bundle);
    VMLRLog(@"process=%@", process);
    VMLRLog(@"================================");

    /*
     * Flutter/native frameworks may load after tweak ctor.
     * Scan several times.
     */

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      2 * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{
            VMLRLog(@"SCAN +2 sec");
            VMLScanRuntime();
        });

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      6 * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{
            VMLRLog(@"SCAN +6 sec");
            VMLScanRuntime();
        });

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      12 * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{
            VMLRLog(@"SCAN +12 sec");
            VMLScanRuntime();
        });
}

%ctor {
    @autoreleasepool {
        VMLStartRuntimeSniffer();
    }
}
