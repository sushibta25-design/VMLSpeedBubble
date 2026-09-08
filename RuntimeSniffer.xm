#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#pragma mark - LOG

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
            NSLog(@"[VMLV3] WRITE ERROR %@", error);
        }
    } else {
        [fh seekToEndOfFile];

        [fh writeData:
            [line dataUsingEncoding:NSUTF8StringEncoding]];

        [fh closeFile];
    }

    NSLog(@"[VMLV3] %@", msg);
}

static NSString *VMLDescribe(id obj) {
    if (!obj)
        return @"(nil)";

    @try {
        NSString *s = [obj description];

        if (!s)
            return @"(null description)";

        if (s.length > 3000) {
            s =
                [[s substringToIndex:3000]
                 stringByAppendingString:@"..."];
        }

        return s;
    }
    @catch (NSException *e) {
        return
            [NSString stringWithFormat:
                @"<description exception %@>", e];
    }
}

#pragma mark - FILTER

static BOOL VMLInterestingText(NSString *text) {
    if (!text.length)
        return NO;

    NSString *s = text.lowercaseString;

    return
        [s containsString:@"speedlimit"] ||
        [s containsString:@"speed_limit"] ||
        [s containsString:@"speed limit"] ||
        [s containsString:@"currentspeed"] ||
        [s containsString:@"nextspeed"] ||
        [s containsString:@"lanespeed"] ||
        [s containsString:@"speedandlimit"] ||
        [s containsString:@"updatespeed"] ||
        [s containsString:@"sendspeed"] ||
        [s containsString:@"road.speed"] ||
        [s containsString:@"carplay"];
}

#pragma mark - FLUTTER METHOD CHANNEL

static IMP orig_FlutterInvoke2 = NULL;
static IMP orig_FlutterInvoke3 = NULL;

static void hook_FlutterInvoke2(
    id self,
    SEL _cmd,
    NSString *method,
    id arguments
) {
    NSString *argText =
        VMLDescribe(arguments);

    if (VMLInterestingText(method) ||
        VMLInterestingText(argText)) {

        VMLLog(@"================================");
        VMLLog(@"FLUTTER OUT");
        VMLLog(@"class=%@", NSStringFromClass([self class]));
        VMLLog(@"method=%@", method);
        VMLLog(@"arguments=%@", argText);
        VMLLog(@"================================");
    }

    if (orig_FlutterInvoke2) {
        ((void (*)(id, SEL, NSString *, id))
         orig_FlutterInvoke2)(
            self,
            _cmd,
            method,
            arguments
        );
    }
}

static void hook_FlutterInvoke3(
    id self,
    SEL _cmd,
    NSString *method,
    id arguments,
    id result
) {
    NSString *argText =
        VMLDescribe(arguments);

    if (VMLInterestingText(method) ||
        VMLInterestingText(argText)) {

        VMLLog(@"================================");
        VMLLog(@"FLUTTER OUT + RESULT");
        VMLLog(@"class=%@", NSStringFromClass([self class]));
        VMLLog(@"method=%@", method);
        VMLLog(@"arguments=%@", argText);
        VMLLog(@"================================");
    }

    if (orig_FlutterInvoke3) {
        ((void (*)(id, SEL, NSString *, id, id))
         orig_FlutterInvoke3)(
            self,
            _cmd,
            method,
            arguments,
            result
        );
    }
}

#pragma mark - METHOD CALL OBJECT

static IMP orig_MethodCallInit = NULL;

static id hook_MethodCallInit(
    id self,
    SEL _cmd,
    NSString *method,
    id arguments
) {
    id result = nil;

    if (orig_MethodCallInit) {
        result =
            ((id (*)(id, SEL, NSString *, id))
             orig_MethodCallInit)(
                self,
                _cmd,
                method,
                arguments
            );
    }

    NSString *argText =
        VMLDescribe(arguments);

    if (VMLInterestingText(method) ||
        VMLInterestingText(argText)) {

        VMLLog(@"================================");
        VMLLog(@"FLUTTER METHOD CALL");
        VMLLog(@"method=%@", method);
        VMLLog(@"arguments=%@", argText);
        VMLLog(@"================================");
    }

    return result;
}

#pragma mark - TARGET SELECTOR SCANNER

static NSMutableSet *gHookedKeys = nil;

static BOOL VMLInterestingSelectorName(NSString *name) {
    if (!name.length)
        return NO;

    NSString *s = name.lowercaseString;

    return
        [s containsString:@"currentspeedlimit"] ||
        [s containsString:@"nextspeedlimit"] ||
        [s containsString:@"lanespeedlimits"] ||
        [s containsString:@"updatespeedlimit"] ||
        [s containsString:@"sendspeedlimit"] ||
        [s containsString:@"speedandlimit"];
}

static void hookVoidNoArg(id self, SEL _cmd);

static NSMutableDictionary *gOriginals = nil;

static NSString *VMLMethodKey(
    Class cls,
    SEL sel
) {
    NSString *prefix =
        class_isMetaClass(cls) ? @"+" : @"-";

    return
        [NSString stringWithFormat:@"%@%@|%@",
         prefix,
         NSStringFromClass(cls),
         NSStringFromSelector(sel)];
}

static void VMLStoreOriginal(
    Class cls,
    SEL sel,
    IMP imp
) {
    if (!gOriginals)
        gOriginals = [NSMutableDictionary new];

    NSString *key =
        VMLMethodKey(cls, sel);

    gOriginals[key] =
        [NSValue valueWithPointer:(const void *)imp];
}

static IMP VMLGetOriginalForObject(
    id self,
    SEL sel
) {
    if (!self || !sel)
        return NULL;

    Class realClass =
        object_getClass(self);

    NSString *key =
        VMLMethodKey(realClass, sel);

    NSValue *value =
        gOriginals[key];

    if (!value) {
        Class instanceClass =
            [self class];

        key =
            VMLMethodKey(instanceClass, sel);

        value =
            gOriginals[key];
    }

    return
        value ? (IMP)[value pointerValue] : NULL;
}

static void hookVoidNoArg(
    id self,
    SEL _cmd
) {
    VMLLog(
        @"TARGET CALL class=%@ selector=%@",
        NSStringFromClass([self class]),
        NSStringFromSelector(_cmd)
    );

    IMP orig =
        VMLGetOriginalForObject(self, _cmd);

    if (orig) {
        ((void (*)(id, SEL))orig)(
            self,
            _cmd
        );
    }
}

static void hookVoidObject(
    id self,
    SEL _cmd,
    id arg
) {
    VMLLog(
        @"TARGET CALL class=%@ selector=%@ arg=%@",
        NSStringFromClass([self class]),
        NSStringFromSelector(_cmd),
        VMLDescribe(arg)
    );

    IMP orig =
        VMLGetOriginalForObject(self, _cmd);

    if (orig) {
        ((void (*)(id, SEL, id))orig)(
            self,
            _cmd,
            arg
        );
    }
}

static id hookObjectNoArg(
    id self,
    SEL _cmd
) {
    IMP orig =
        VMLGetOriginalForObject(self, _cmd);

    id value = nil;

    if (orig) {
        value =
            ((id (*)(id, SEL))orig)(
                self,
                _cmd
            );
    }

    VMLLog(
        @"TARGET RETURN class=%@ selector=%@ value=%@",
        NSStringFromClass([self class]),
        NSStringFromSelector(_cmd),
        VMLDescribe(value)
    );

    return value;
}

static unsigned long long hookUInt64NoArg(
    id self,
    SEL _cmd
) {
    IMP orig =
        VMLGetOriginalForObject(self, _cmd);

    unsigned long long value = 0;

    if (orig) {
        value =
            ((unsigned long long (*)(id, SEL))orig)(
                self,
                _cmd
            );
    }

    VMLLog(
        @"*** TARGET NUMBER *** class=%@ selector=%@ value=%llu",
        NSStringFromClass([self class]),
        NSStringFromSelector(_cmd),
        value
    );

    return value;
}

static void hookVoidUInt64(
    id self,
    SEL _cmd,
    unsigned long long value
) {
    VMLLog(
        @"*** TARGET NUMBER *** class=%@ selector=%@ value=%llu",
        NSStringFromClass([self class]),
        NSStringFromSelector(_cmd),
        value
    );

    IMP orig =
        VMLGetOriginalForObject(self, _cmd);

    if (orig) {
        ((void (*)(id, SEL, unsigned long long))orig)(
            self,
            _cmd,
            value
        );
    }
}

static void VMLScanTargetClass(Class cls) {
    if (!cls)
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
        Method m = methods[i];

        SEL sel =
            method_getName(m);

        NSString *selName =
            NSStringFromSelector(sel);

        if (!VMLInterestingSelectorName(selName))
            continue;

        NSString *key =
            VMLMethodKey(cls, sel);

        if ([gHookedKeys containsObject:key])
            continue;

        const char *types =
            method_getTypeEncoding(m);

        unsigned int argc =
            method_getNumberOfArguments(m);

        char ret[64] = {0};

        method_getReturnType(
            m,
            ret,
            sizeof(ret)
        );

        VMLLog(
            @"TARGET FOUND class=%@ selector=%@ argc=%u types=%s",
            NSStringFromClass(cls),
            selName,
            argc,
            types
        );

        IMP replacement = NULL;

        if (argc == 2) {
            if (ret[0] == 'v') {
                replacement =
                    (IMP)hookVoidNoArg;
            }
            else if (ret[0] == '@') {
                replacement =
                    (IMP)hookObjectNoArg;
            }
            else if (
                ret[0] == 'Q' ||
                ret[0] == 'q' ||
                ret[0] == 'I' ||
                ret[0] == 'i' ||
                ret[0] == 'C'
            ) {
                replacement =
                    (IMP)hookUInt64NoArg;
            }
        }

        else if (argc == 3) {
            char arg[64] = {0};

            method_getArgumentType(
                m,
                2,
                arg,
                sizeof(arg)
            );

            if (ret[0] == 'v' &&
                arg[0] == '@') {

                replacement =
                    (IMP)hookVoidObject;
            }

            else if (
                ret[0] == 'v' &&
                (
                    arg[0] == 'Q' ||
                    arg[0] == 'q' ||
                    arg[0] == 'I' ||
                    arg[0] == 'i' ||
                    arg[0] == 'C'
                )
            ) {
                replacement =
                    (IMP)hookVoidUInt64;
            }
        }

        if (!replacement) {
            VMLLog(
                @"TARGET SKIP unsupported signature class=%@ selector=%@ types=%s",
                NSStringFromClass(cls),
                selName,
                types
            );

            continue;
        }

        IMP orig =
            method_getImplementation(m);

        if (!orig)
            continue;

        VMLStoreOriginal(
            cls,
            sel,
            orig
        );

        method_setImplementation(
            m,
            replacement
        );

        [gHookedKeys addObject:key];

        VMLLog(
            @"TARGET HOOKED class=%@ selector=%@",
            NSStringFromClass(cls),
            selName
        );
    }

    free(methods);
}

static void VMLScanTargets(void) {
    int count =
        objc_getClassList(NULL, 0);

    if (count <= 0)
        return;

    Class *classes =
        (__unsafe_unretained Class *)
        malloc(sizeof(Class) * count);

    if (!classes)
        return;

    count =
        objc_getClassList(
            classes,
            count
        );

    VMLLog(@"TARGET SCAN classes=%d", count);

    for (int i = 0; i < count; i++) {
        Class cls = classes[i];

        VMLScanTargetClass(cls);

        Class meta =
            object_getClass(cls);

        if (meta)
            VMLScanTargetClass(meta);
    }

    free(classes);
}

#pragma mark - GENERIC INSTALLER

static BOOL VMLHookInstanceMethod(
    NSString *className,
    NSString *selectorName,
    IMP replacement,
    IMP *storage
) {
    Class cls =
        objc_getClass([className UTF8String]);

    if (!cls) {
        VMLLog(
            @"WAIT class=%@",
            className
        );

        return NO;
    }

    SEL sel =
        NSSelectorFromString(selectorName);

    Method method =
        class_getInstanceMethod(cls, sel);

    if (!method) {
        VMLLog(
            @"MISSING %@ %@",
            className,
            selectorName
        );

        return NO;
    }

    IMP current =
        method_getImplementation(method);

    if (current == replacement)
        return YES;

    *storage = current;

    method_setImplementation(
        method,
        replacement
    );

    VMLLog(
        @"HOOKED %@ %@ types=%s",
        className,
        selectorName,
        method_getTypeEncoding(method)
    );

    return YES;
}

#pragma mark - INSTALL FLUTTER HOOKS

static void VMLInstallFlutterHooks(void) {
    VMLLog(@"---------- FLUTTER INSTALL ----------");

    if (!orig_FlutterInvoke2) {
        VMLHookInstanceMethod(
            @"FlutterMethodChannel",
            @"invokeMethod:arguments:",
            (IMP)hook_FlutterInvoke2,
            &orig_FlutterInvoke2
        );
    }

    if (!orig_FlutterInvoke3) {
        VMLHookInstanceMethod(
            @"FlutterMethodChannel",
            @"invokeMethod:arguments:result:",
            (IMP)hook_FlutterInvoke3,
            &orig_FlutterInvoke3
        );
    }

    if (!orig_MethodCallInit) {
        VMLHookInstanceMethod(
            @"FlutterMethodCall",
            @"initWithMethodName:arguments:",
            (IMP)hook_MethodCallInit,
            &orig_MethodCallInit
        );
    }

    VMLScanTargets();

    VMLLog(@"---------- INSTALL END ----------");
}

#pragma mark - START

static void VMLStartV3(void) {
    NSString *bundle =
        NSBundle.mainBundle.bundleIdentifier ?: @"";

    NSString *process =
        NSProcessInfo.processInfo.processName ?: @"";

    if (![bundle isEqualToString:@"vn.vietmap.live"])
        return;

    gHookedKeys =
        [NSMutableSet new];

    gOriginals =
        [NSMutableDictionary new];

    VMLLog(@"========================================");
    VMLLog(@"VML RUNTIME SNIFFER V3");
    VMLLog(@"bundle=%@", bundle);
    VMLLog(@"process=%@", process);
    VMLLog(@"home=%@", NSHomeDirectory());
    VMLLog(@"log=%@", VMLLogPath());
    VMLLog(@"========================================");

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            1 * NSEC_PER_SEC
        ),
        dispatch_get_main_queue(),
        ^{
            VMLLog(@"INSTALL +1 sec");
            VMLInstallFlutterHooks();
        }
    );

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            4 * NSEC_PER_SEC
        ),
        dispatch_get_main_queue(),
        ^{
            VMLLog(@"INSTALL +4 sec");
            VMLInstallFlutterHooks();
        }
    );

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            8 * NSEC_PER_SEC
        ),
        dispatch_get_main_queue(),
        ^{
            VMLLog(@"INSTALL +8 sec");
            VMLInstallFlutterHooks();
        }
    );

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            15 * NSEC_PER_SEC
        ),
        dispatch_get_main_queue(),
        ^{
            VMLLog(@"INSTALL +15 sec");
            VMLInstallFlutterHooks();
        }
    );
}

%ctor {
    @autoreleasepool {
        VMLStartV3();
    }
}
