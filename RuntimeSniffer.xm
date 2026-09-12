#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <notify.h>
#import <mach-o/dyld.h>
#import <CoreLocation/CoreLocation.h>
#import <objc/message.h>
#import <objc/runtime.h>



static IMP gOrigMethodCallInit = NULL;
static void VMLLog(NSString *format, ...);

static int gPublishToken = 0;
static void VMLPublishValidSpeed(NSInteger speed);
static int gReplayRequestToken = 0;
static NSInteger gLastValidSpeed = -1;
static NSInteger gCurrentVehicleSpeed = -1;
static NSInteger gCurrentRoadLimit = -1;
static BOOL gLastOverspeedState = NO;
static BOOL gHaveOverspeedState = NO;
static uint64_t gPublisherSequence = 0;

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


static NSString *VMLClassDumpPath(void) {
    NSString *documents =
        [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];

    return [documents stringByAppendingPathComponent:@"VMLClassDump.txt"];
}

static void VMLClassDumpWrite(NSString *line) {
    if (!line) return;

    NSString *path = VMLClassDumpPath();
    NSString *out = [line stringByAppendingString:@"\n"];

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [out writeToFile:path
              atomically:YES
                encoding:NSUTF8StringEncoding
                   error:nil];
    } else {
        [fh seekToEndOfFile];
        NSData *data = [out dataUsingEncoding:NSUTF8StringEncoding];
        [fh writeData:data];
        [fh closeFile];
    }

    NSLog(@"[VMLCLASS] %@", line);
}

static BOOL VMLClassNameLooksInteresting(NSString *name) {
    if (name.length == 0) return NO;

    NSArray<NSString *> *keys = @[
        @"warning", @"alert", @"sign", @"traffic", @"route",
        @"navigation", @"nav", @"speed", @"limit", @"road",
        @"parking", @"stop", @"camera", @"restriction", @"flutter",
        @"vietmap", @"map"
    ];

    NSString *lower = name.lowercaseString;
    for (NSString *key in keys) {
        if ([lower containsString:key]) return YES;
    }
    return NO;
}

static void VMLDumpLoadedImagesAndClasses(void) {
    if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"vn.vietmap.live"])
        return;

    // Start a fresh dump on every app launch.
    [[NSFileManager defaultManager] removeItemAtPath:VMLClassDumpPath() error:nil];

    NSString *bundlePath = NSBundle.mainBundle.bundlePath ?: @"";
    VMLClassDumpWrite(@"============================================================");
    VMLClassDumpWrite([NSString stringWithFormat:@"VML CLASS DUMP bundle=%@ process=%@",
                       NSBundle.mainBundle.bundleIdentifier ?: @"nil",
                       NSProcessInfo.processInfo.processName ?: @"nil"]);
    VMLClassDumpWrite([NSString stringWithFormat:@"bundlePath=%@", bundlePath]);
    VMLClassDumpWrite(@"---------------- LOADED IMAGES ----------------");

    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *raw = _dyld_get_image_name(i);
        if (!raw) continue;
        NSString *image = [NSString stringWithUTF8String:raw];
        if (!image) continue;

        // App executable + embedded Frameworks are the highest-value images.
        if (bundlePath.length > 0 && [image hasPrefix:bundlePath]) {
            VMLClassDumpWrite([NSString stringWithFormat:@"[IMAGE] %@", image]);
        }
    }

    VMLClassDumpWrite(@"---------------- APP CLASSES ----------------");

    int count = objc_getClassList(NULL, 0);
    if (count <= 0) {
        VMLClassDumpWrite(@"objc_getClassList returned no classes");
        return;
    }

    Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) {
        VMLClassDumpWrite(@"calloc failed");
        return;
    }

    count = objc_getClassList(classes, count);
    NSUInteger appClassCount = 0;
    NSUInteger interestingCount = 0;

    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        if (!cls) continue;

        const char *rawName = class_getName(cls);
        const char *rawImage = class_getImageName(cls);
        if (!rawName || !rawImage) continue;

        NSString *name = [NSString stringWithUTF8String:rawName];
        NSString *image = [NSString stringWithUTF8String:rawImage];
        if (!name || !image) continue;

        if (bundlePath.length == 0 || ![image hasPrefix:bundlePath])
            continue;

        appClassCount++;
        BOOL interesting = VMLClassNameLooksInteresting(name);
        if (interesting) interestingCount++;

        VMLClassDumpWrite([NSString stringWithFormat:@"%@%@ | %@",
                           interesting ? @"[HOT] " : @"",
                           name,
                           image]);
    }

    free(classes);

    VMLClassDumpWrite(@"---------------- SUMMARY ----------------");
    VMLClassDumpWrite([NSString stringWithFormat:@"runtimeClasses=%d appClasses=%lu hotClasses=%lu images=%u",
                       count,
                       (unsigned long)appClassCount,
                       (unsigned long)interestingCount,
                       imageCount]);
    VMLClassDumpWrite(@"============================================================");

    VMLLog(@"CLASS DUMP COMPLETE path=%@ appClasses=%lu hotClasses=%lu",
           VMLClassDumpPath(),
           (unsigned long)appClassCount,
           (unsigned long)interestingCount);
}

static void VMLScheduleClassDump(void) {
    // Flutter/plugins may load after launch, so dump once after the app has settled.
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            VMLDumpLoadedImagesAndClasses();
        }
    );
}



// ============================================================
// Focused VietMap method/property/ivar dump (V2)
// ============================================================
static NSString *VMLMethodDumpPath(void) {
    NSString *documents = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    return [documents stringByAppendingPathComponent:@"VMLMethodDump.txt"];
}

static NSString *VMLWarningTracePath(void) {
    NSString *documents = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    return [documents stringByAppendingPathComponent:@"VMLWarningTrace.txt"];
}

static void VMLAppendLineToPath(NSString *path, NSString *line, NSString *consolePrefix) {
    if (!path || !line) return;
    NSString *out = [line stringByAppendingString:@"\n"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        [fh seekToEndOfFile];
        NSData *data = [out dataUsingEncoding:NSUTF8StringEncoding];
        [fh writeData:data];
        [fh closeFile];
    }
    if (consolePrefix.length > 0) {
        NSLog(@"%@ %@", consolePrefix, line);
    }
}

static void VMLMethodDumpWrite(NSString *line) {
    VMLAppendLineToPath(VMLMethodDumpPath(), line, @"[VMLMETHOD]");
}

static void VMLWarningTraceWrite(NSString *line) {
    VMLAppendLineToPath(VMLWarningTracePath(), line, @"[VMLWARN]");
}

static Class VMLFindRuntimeClassNamed(NSString *target) {
    if (target.length == 0) return Nil;

    Class direct = NSClassFromString(target);
    if (direct) return direct;

    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return Nil;

    Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) return Nil;
    count = objc_getClassList(classes, count);

    Class found = Nil;
    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        const char *raw = cls ? class_getName(cls) : NULL;
        if (!raw) continue;
        NSString *name = [NSString stringWithUTF8String:raw];
        if ([name isEqualToString:target]) {
            found = cls;
            break;
        }
    }
    free(classes);
    return found;
}

static void VMLDumpMethodsForClassObject(Class cls, BOOL classMethods) {
    if (!cls) return;

    Class owner = classMethods ? object_getClass(cls) : cls;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(owner, &count);
    VMLMethodDumpWrite([NSString stringWithFormat:@"%@ METHODS count=%u",
                        classMethods ? @"CLASS" : @"INSTANCE", count]);

    for (unsigned int i = 0; i < count; i++) {
        Method m = methods[i];
        SEL sel = method_getName(m);
        const char *types = method_getTypeEncoding(m);
        VMLMethodDumpWrite([NSString stringWithFormat:@"  %@ %@ | types=%s",
                            classMethods ? @"+" : @"-",
                            NSStringFromSelector(sel) ?: @"?",
                            types ?: "?"]]);
    }
    if (methods) free(methods);
}

static void VMLDumpPropertiesForClass(Class cls) {
    unsigned int count = 0;
    objc_property_t *props = class_copyPropertyList(cls, &count);
    VMLMethodDumpWrite([NSString stringWithFormat:@"PROPERTIES count=%u", count]);
    for (unsigned int i = 0; i < count; i++) {
        const char *name = property_getName(props[i]);
        const char *attrs = property_getAttributes(props[i]);
        VMLMethodDumpWrite([NSString stringWithFormat:@"  %@ | attrs=%s",
                            name ? [NSString stringWithUTF8String:name] : @"?",
                            attrs ?: "?"]]);
    }
    if (props) free(props);
}

static void VMLDumpIvarsForClass(Class cls) {
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    VMLMethodDumpWrite([NSString stringWithFormat:@"IVARS count=%u", count]);
    for (unsigned int i = 0; i < count; i++) {
        const char *name = ivar_getName(ivars[i]);
        const char *type = ivar_getTypeEncoding(ivars[i]);
        ptrdiff_t offset = ivar_getOffset(ivars[i]);
        VMLMethodDumpWrite([NSString stringWithFormat:@"  %@ | type=%s offset=%td",
                            name ? [NSString stringWithUTF8String:name] : @"?",
                            type ?: "?", offset]);
    }
    if (ivars) free(ivars);
}

static void VMLDumpProtocolsForClass(Class cls) {
    unsigned int count = 0;
    __unsafe_unretained Protocol **protocols = class_copyProtocolList(cls, &count);
    VMLMethodDumpWrite([NSString stringWithFormat:@"PROTOCOLS count=%u", count]);
    for (unsigned int i = 0; i < count; i++) {
        const char *name = protocol_getName(protocols[i]);
        VMLMethodDumpWrite([NSString stringWithFormat:@"  %@",
                            name ? [NSString stringWithUTF8String:name] : @"?"]]);
    }
    if (protocols) free(protocols);
}

static void VMLDumpOneTargetClass(NSString *target) {
    Class cls = VMLFindRuntimeClassNamed(target);
    VMLMethodDumpWrite(@"------------------------------------------------------------");
    VMLMethodDumpWrite([NSString stringWithFormat:@"TARGET %@", target]);

    if (!cls) {
        VMLMethodDumpWrite(@"STATUS NOT FOUND");
        return;
    }

    const char *imageRaw = class_getImageName(cls);
    Class superCls = class_getSuperclass(cls);
    VMLMethodDumpWrite([NSString stringWithFormat:@"STATUS FOUND runtime=%@",
                        NSStringFromClass(cls)]);
    VMLMethodDumpWrite([NSString stringWithFormat:@"IMAGE %@",
                        imageRaw ? [NSString stringWithUTF8String:imageRaw] : @"?"]]);
    VMLMethodDumpWrite([NSString stringWithFormat:@"SUPER %@",
                        superCls ? NSStringFromClass(superCls) : @"nil"]);

    VMLDumpMethodsForClassObject(cls, NO);
    VMLDumpMethodsForClassObject(cls, YES);
    VMLDumpPropertiesForClass(cls);
    VMLDumpIvarsForClass(cls);
    VMLDumpProtocolsForClass(cls);
}

static void VMLDumpFocusedVietMapClasses(void) {
    if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"vn.vietmap.live"])
        return;

    [[NSFileManager defaultManager] removeItemAtPath:VMLMethodDumpPath() error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:VMLWarningTracePath() error:nil];

    VMLMethodDumpWrite(@"============================================================");
    VMLMethodDumpWrite([NSString stringWithFormat:@"VML METHOD DUMP V2 bundle=%@ process=%@",
                        NSBundle.mainBundle.bundleIdentifier ?: @"nil",
                        NSProcessInfo.processInfo.processName ?: @"nil"]);

    NSArray<NSString *> *targets = @[
        @"Runner.VMLWarningWidget",
        @"Runner.WarningAlertView",
        @"Runner.SpeedLimitView",
        @"Runner.JustSpeedLimitLayout",
        @"vietmap_live_navigation_plugin.MapSymbolsController",
        @"vietmap_live_navigation_plugin.NavigationTooltipController",
        @"vietmap_live_navigation_plugin.MapRoutesController",
        @"vietmap_live_navigation_plugin.TrafficRoute",
        @"vietmap_live_navigation_plugin.MapRoute",
        @"vietmap_live_navigation_plugin.VMLCarMapControllerV3",
        @"vietmap_live_navigation_plugin.CarMapControllerV3",
        @"vietmap_live_navigation_plugin.VIETMAPCarPlayManager2"
    ];

    for (NSString *target in targets) {
        VMLDumpOneTargetClass(target);
    }

    VMLMethodDumpWrite(@"============================================================");
    VMLLog(@"METHOD DUMP V2 COMPLETE path=%@", VMLMethodDumpPath());
}

static void VMLScheduleFocusedMethodDump(void) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            VMLDumpFocusedVietMapClasses();
        }
    );
}

static BOOL VMLStringLooksWarningRelated(NSString *s) {
    if (s.length == 0) return NO;
    NSString *lower = s.lowercaseString;
    NSArray<NSString *> *keys = @[
        @"warning", @"warn", @"sign", @"traffic", @"route", @"tooltip",
        @"parking", @"park", @"stop", @"restriction", @"road", @"speedlimit",
        @"speed_limit", @"limit", @"symbol", @"camera"
    ];
    for (NSString *key in keys) {
        if ([lower containsString:key]) return YES;
    }
    return NO;
}

static BOOL VMLObjectLooksWarningRelated(id obj) {
    if (!obj) return NO;
    if ([obj isKindOfClass:NSString.class]) {
        return VMLStringLooksWarningRelated((NSString *)obj);
    }
    if ([obj isKindOfClass:NSDictionary.class]) {
        NSDictionary *dict = (NSDictionary *)obj;
        for (id key in dict.allKeys) {
            if (VMLStringLooksWarningRelated([key description])) return YES;
            id value = dict[key];
            if ([value isKindOfClass:NSString.class] &&
                VMLStringLooksWarningRelated((NSString *)value)) return YES;
        }
    }
    return NO;
}

static NSString *VMLSafeDescription(id obj) {
    if (!obj) return @"nil";
    NSString *desc = nil;
    @try { desc = [obj description]; } @catch (__unused NSException *e) { desc = @"<description threw>"; }
    if (!desc) desc = @"nil";
    // Keep one event from exploding the log file.
    if (desc.length > 12000) {
        desc = [[desc substringToIndex:12000] stringByAppendingString:@" ...<truncated>"];
    }
    return desc;
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



static void VMLPublishOverspeedState(BOOL overspeed) {
    if (gHaveOverspeedState &&
        gLastOverspeedState == overspeed) {

        return;
    }

    gLastOverspeedState = overspeed;
    gHaveOverspeedState = YES;

    const char *name =
        overspeed
            ? "com.sushibta.vmlspeedbubble.overspeed.on"
            : "com.sushibta.vmlspeedbubble.overspeed.off";

    notify_post(name);

    VMLTrace(
        @"SOS OVERSPEED=%d current=%ld limit=%ld",
        overspeed,
        (long)gCurrentVehicleSpeed,
        (long)gCurrentRoadLimit
    );
}

static void VMLRecomputeOverspeed(void) {
    if (gCurrentVehicleSpeed < 0 ||
        gCurrentRoadLimit <= 0 ||
        gCurrentRoadLimit > 200) {

        VMLPublishOverspeedState(NO);
        return;
    }

    VMLPublishOverspeedState(
        gCurrentVehicleSpeed > gCurrentRoadLimit
    );
}

static void VMLPublishValidSpeed(NSInteger speed) {
    if (speed <= 0 || speed > 200) {
        VMLTrace(
            @"PUB DROP invalid=%ld",
            (long)speed
        );
        return;
    }

    gLastValidSpeed =
        speed;

    gPublisherSequence++;

    uint64_t seq =
        gPublisherSequence;

    VMLTrace(
        @"PUB BEGIN seq=%llu speed=%ld",
        seq,
        (long)speed
    );

    // Keep the fixed-name state path for diagnostics / SpringBoard fallback.
    if (gPublishToken == 0) {
        int token = 0;

        uint32_t status =
            notify_register_check(
                "com.sushibta.vmlspeedbubble.speed",
                &token
            );

        VMLTrace(
            @"PUB REGISTER seq=%llu status=%u token=%d",
            seq,
            status,
            token
        );

        if (status == NOTIFY_STATUS_OK) {
            gPublishToken =
                token;
        }
    }

    if (gPublishToken != 0) {
        notify_set_state(
            gPublishToken,
            (uint64_t)speed
        );

        VMLTrace(
            @"PUB FIXED STATE seq=%llu token=%d speed=%ld",
            seq,
            gPublishToken,
            (long)speed
        );

        notify_post(
            "com.sushibta.vmlspeedbubble.speed"
        );

        VMLTrace(
            @"PUB FIXED POST seq=%llu",
            seq
        );
    } else {
        VMLTrace(
            @"PUB FIXED SKIP seq=%llu token=0",
            seq
        );
    }

    NSString *encodedName =
        [NSString stringWithFormat:
            @"com.sushibta.vmlspeedbubble.speed.%ld",
            (long)speed];

    const char *encodedCString =
        encodedName.UTF8String;

    VMLTrace(
        @"PUB ENCODED BEFORE seq=%llu name=%@ cstr=%p",
        seq,
        encodedName,
        encodedCString
    );

    if (encodedCString) {
        notify_post(
            encodedCString
        );

        // Send the exact same encoded event a second time immediately.
        // This is intentional in the diagnostic build to rule out a missed single post.
        notify_post(
            encodedCString
        );

        VMLTrace(
            @"PUB ENCODED AFTER seq=%llu name=%@",
            seq,
            encodedName
        );
    } else {
        VMLTrace(
            @"PUB ENCODED FAIL seq=%llu utf8=nil name=%@",
            seq,
            encodedName
        );
    }

    VMLTrace(
        @"PUB END seq=%llu speed=%ld",
        seq,
        (long)speed
    );
}


static void VMLStartSpeedReplayResponder(void) {
    if (gReplayRequestToken != 0)
        return;

    int token = 0;

    uint32_t status =
        notify_register_dispatch(
            "com.sushibta.vmlspeedbubble.speed.request",
            &token,
            dispatch_get_main_queue(),
            ^(__unused int incomingToken) {
                if (gLastValidSpeed > 0 &&
                    gLastValidSpeed <= 200) {

                    VMLTrace(
                        @"REPLAY REQUEST last=%ld",
                        (long)gLastValidSpeed
                    );

                    VMLPublishValidSpeed(
                        gLastValidSpeed
                    );
                } else {
                    VMLTrace(
                        @"REPLAY REQUEST last=none"
                    );
                }
            }
        );

    if (status == NOTIFY_STATUS_OK) {
        gReplayRequestToken =
            token;

        VMLTrace(
            @"REPLAY RESPONDER READY token=%d",
            token
        );
    }
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

    // V2: capture Flutter traffic-sign / warning / route traffic without
    // changing VietMap behavior. This is observation-only.
    if (VMLStringLooksWarningRelated(methodName) || VMLObjectLooksWarningRelated(arguments)) {
        VMLWarningTraceWrite([NSString stringWithFormat:
            @"FLUTTER method=%@ argsClass=%@ args=%@",
            methodName ?: @"nil",
            arguments ? NSStringFromClass([arguments class]) : @"nil",
            VMLSafeDescription(arguments)
        ]);
    }

    NSInteger speed = -1;

    if ([methodName isEqualToString:@"updateCurrentSpeed"]) {
        NSInteger current =
            VMLSpeedFromObject(arguments);

        if (current >= 0 && current <= 300) {
            gCurrentVehicleSpeed =
                current;

            VMLRecomputeOverspeed();
        }
    }

    if ([methodName isEqualToString:@"updateSpeedLimit"]) {
        NSInteger limit =
            VMLSpeedFromObject(arguments);

        if (limit > 0 && limit <= 200) {
            gCurrentRoadLimit =
                limit;

            VMLRecomputeOverspeed();
        }
    }

    // VietMap also publishes its own overSpeedLimit boolean.
    // Use it as an immediate confirmation/fallback signal.
    if ([methodName isEqualToString:@"overSpeedLimit"]) {
        NSInteger flag =
            VMLSpeedFromObject(arguments);

        if (flag == 0 || flag == 1) {
            VMLPublishOverspeedState(
                flag == 1
            );
        }
    }


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
        VMLTrace(
            @"HOOK updateSpeedLimit argsClass=%@ args=%@",
            arguments ? NSStringFromClass([arguments class]) : @"nil",
            arguments ?: @"nil"
        );

        speed =
            VMLSpeedFromObject(arguments);

        VMLTrace(
            @"HOOK parsed speed=%ld",
            (long)speed
        );
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



// ============================================================
// VML GPS REPLAY V3
// Scope: only this injected VietMap Live process.
// Config: <VietMap sandbox>/Documents/VMLGPSReplay.txt
// ============================================================

static BOOL gVMLGPSReplayEnabled = NO;
static BOOL gVMLGPSReplayLoop = YES;
static double gVMLGPSReplaySpeedKmh = 30.0;
static double gVMLGPSReplayInterval = 1.0;
static NSMutableArray<NSValue *> *gVMLGPSRoute = nil;
static NSInteger gVMLGPSSegmentIndex = 0;
static double gVMLGPSSegmentOffsetM = 0.0;
static CLLocation *gVMLGPSFakeLocation = nil;
static NSDate *gVMLGPSConfigMTime = nil;
static NSHashTable *gVMLGPSManagers = nil;

static NSString *VMLGPSReplayPath(void) {
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"]
            stringByAppendingPathComponent:@"VMLGPSReplay.txt"];
}

static NSString *VMLGPSReplayLogPath(void) {
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"]
            stringByAppendingPathComponent:@"VMLGPSReplayLog.txt"];
}

static void VMLGPSLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = VMLGPSReplayLogPath();

    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
    } else {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:data];
            [fh closeFile];
        }
    }
    VMLLog(@"GPSREPLAY %@", msg);
}

static double VMLGPSDeg2Rad(double d) { return d * M_PI / 180.0; }
static double VMLGPSRad2Deg(double r) { return r * 180.0 / M_PI; }

static double VMLGPSDistance(CLLocationCoordinate2D a, CLLocationCoordinate2D b) {
    const double R = 6371000.0;
    double p1 = VMLGPSDeg2Rad(a.latitude);
    double p2 = VMLGPSDeg2Rad(b.latitude);
    double dp = VMLGPSDeg2Rad(b.latitude - a.latitude);
    double dl = VMLGPSDeg2Rad(b.longitude - a.longitude);
    double x = sin(dp/2.0)*sin(dp/2.0) + cos(p1)*cos(p2)*sin(dl/2.0)*sin(dl/2.0);
    return R * 2.0 * atan2(sqrt(x), sqrt(1.0-x));
}

static double VMLGPSBearing(CLLocationCoordinate2D a, CLLocationCoordinate2D b) {
    double p1 = VMLGPSDeg2Rad(a.latitude), p2 = VMLGPSDeg2Rad(b.latitude);
    double dl = VMLGPSDeg2Rad(b.longitude - a.longitude);
    double y = sin(dl) * cos(p2);
    double x = cos(p1)*sin(p2) - sin(p1)*cos(p2)*cos(dl);
    double d = fmod(VMLGPSRad2Deg(atan2(y,x)) + 360.0, 360.0);
    return d;
}

static CLLocationCoordinate2D VMLGPSInterpolate(CLLocationCoordinate2D a, CLLocationCoordinate2D b, double t) {
    if (t < 0) t = 0; if (t > 1) t = 1;
    return CLLocationCoordinate2DMake(a.latitude + (b.latitude-a.latitude)*t,
                                      a.longitude + (b.longitude-a.longitude)*t);
}

static void VMLGPSWriteSampleConfigIfNeeded(void) {
    NSString *path = VMLGPSReplayPath();
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return;
    NSString *sample =
    @"# VML GPS Replay V3\n"
    @"# 1) Doi enabled=1\n"
    @"# 2) Them it nhat 2 diem lat,lon o cuoi file\n"
    @"# 3) Co the sua file khi VML dang mo; tweak tu reload\n"
    @"enabled=0\n"
    @"speed_kmh=30\n"
    @"interval=1.0\n"
    @"loop=1\n"
    @"# route: latitude,longitude\n"
    @"# 10.000000,106.000000\n"
    @"# 10.001000,106.001000\n";
    [sample writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void VMLGPSLoadConfig(BOOL force) {
    NSString *path = VMLGPSReplayPath();
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    NSDate *mtime = attrs[NSFileModificationDate];
    if (!force && gVMLGPSConfigMTime && mtime && [mtime isEqualToDate:gVMLGPSConfigMTime]) return;
    gVMLGPSConfigMTime = mtime;

    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!text) return;

    BOOL enabled = NO, loop = YES;
    double speed = 30.0, interval = 1.0;
    NSMutableArray<NSValue *> *route = [NSMutableArray array];

    for (NSString *raw in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (line.length == 0 || [line hasPrefix:@"#"]) continue;
        if ([line hasPrefix:@"enabled="]) { enabled = [[[line componentsSeparatedByString:@"="] lastObject] integerValue] != 0; continue; }
        if ([line hasPrefix:@"speed_kmh="]) { speed = [[[line componentsSeparatedByString:@"="] lastObject] doubleValue]; continue; }
        if ([line hasPrefix:@"interval="]) { interval = [[[line componentsSeparatedByString:@"="] lastObject] doubleValue]; continue; }
        if ([line hasPrefix:@"loop="]) { loop = [[[line componentsSeparatedByString:@"="] lastObject] integerValue] != 0; continue; }
        NSArray<NSString *> *parts = [line componentsSeparatedByString:@","];
        if (parts.count >= 2) {
            double lat = [parts[0] doubleValue], lon = [parts[1] doubleValue];
            if (fabs(lat) <= 90.0 && fabs(lon) <= 180.0 && (lat != 0.0 || lon != 0.0)) {
                CLLocationCoordinate2D c = CLLocationCoordinate2DMake(lat, lon);
                [route addObject:[NSValue valueWithBytes:&c objCType:@encode(CLLocationCoordinate2D)]];
            }
        }
    }

    BOOL routeChanged = (gVMLGPSRoute.count != route.count);
    gVMLGPSReplayEnabled = enabled && route.count >= 2;
    gVMLGPSReplayLoop = loop;
    gVMLGPSReplaySpeedKmh = MAX(1.0, MIN(speed, 200.0));
    gVMLGPSReplayInterval = MAX(0.2, MIN(interval, 5.0));
    gVMLGPSRoute = route;

    if (routeChanged || force) {
        gVMLGPSSegmentIndex = 0;
        gVMLGPSSegmentOffsetM = 0.0;
        gVMLGPSFakeLocation = nil;
    }

    VMLGPSLog(@"CONFIG enabled=%d points=%lu speed=%.1fkmh interval=%.2fs loop=%d",
              gVMLGPSReplayEnabled, (unsigned long)route.count,
              gVMLGPSReplaySpeedKmh, gVMLGPSReplayInterval, gVMLGPSReplayLoop);
}

static CLLocationCoordinate2D VMLGPSCoordAt(NSInteger idx) {
    CLLocationCoordinate2D c = kCLLocationCoordinate2DInvalid;
    if (idx >= 0 && idx < (NSInteger)gVMLGPSRoute.count) {
        [gVMLGPSRoute[idx] getValue:&c];
    }
    return c;
}

static CLLocation *VMLGPSBuildNextLocation(void) {
    if (!gVMLGPSReplayEnabled || gVMLGPSRoute.count < 2) return nil;

    double advance = (gVMLGPSReplaySpeedKmh / 3.6) * gVMLGPSReplayInterval;
    while (advance >= 0.0) {
        if (gVMLGPSSegmentIndex >= (NSInteger)gVMLGPSRoute.count - 1) {
            if (gVMLGPSReplayLoop) {
                gVMLGPSSegmentIndex = 0;
                gVMLGPSSegmentOffsetM = 0.0;
            } else {
                gVMLGPSReplayEnabled = NO;
                VMLGPSLog(@"ROUTE FINISHED");
                return gVMLGPSFakeLocation;
            }
        }

        CLLocationCoordinate2D a = VMLGPSCoordAt(gVMLGPSSegmentIndex);
        CLLocationCoordinate2D b = VMLGPSCoordAt(gVMLGPSSegmentIndex + 1);
        double seg = VMLGPSDistance(a,b);
        if (seg < 0.5) { gVMLGPSSegmentIndex++; gVMLGPSSegmentOffsetM = 0; continue; }

        double remaining = seg - gVMLGPSSegmentOffsetM;
        if (advance > remaining) {
            advance -= remaining;
            gVMLGPSSegmentIndex++;
            gVMLGPSSegmentOffsetM = 0.0;
            continue;
        }

        gVMLGPSSegmentOffsetM += advance;
        double t = gVMLGPSSegmentOffsetM / seg;
        CLLocationCoordinate2D c = VMLGPSInterpolate(a,b,t);
        double course = VMLGPSBearing(a,b);
        CLLocation *loc = [[CLLocation alloc] initWithCoordinate:c
                                                        altitude:10.0
                                              horizontalAccuracy:3.0
                                                verticalAccuracy:5.0
                                                          course:course
                                                           speed:(gVMLGPSReplaySpeedKmh/3.6)
                                                       timestamp:[NSDate date]];
        gVMLGPSFakeLocation = loc;
        return loc;
    }
    return nil;
}

@interface VMLLocationDelegateProxy : NSObject <CLLocationManagerDelegate>
@property (nonatomic, weak) id originalDelegate;
@end

@implementation VMLLocationDelegateProxy
- (BOOL)respondsToSelector:(SEL)aSelector {
    if (aSelector == @selector(locationManager:didUpdateLocations:)) return YES;
    return [super respondsToSelector:aSelector] || [self.originalDelegate respondsToSelector:aSelector];
}
- (id)forwardingTargetForSelector:(SEL)aSelector { return self.originalDelegate; }
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    id d = self.originalDelegate;
    if (![d respondsToSelector:_cmd]) return;
    NSArray *send = locations;
    if (gVMLGPSReplayEnabled && gVMLGPSFakeLocation) send = @[gVMLGPSFakeLocation];
    ((void(*)(id,SEL,id,id))objc_msgSend)(d, _cmd, manager, send);
}
@end

static const void *kVMLGPSProxyKey = &kVMLGPSProxyKey;

static void VMLGPSRegisterManager(CLLocationManager *manager) {
    if (!manager) return;
    if (!gVMLGPSManagers) gVMLGPSManagers = [NSHashTable weakObjectsHashTable];
    @synchronized(gVMLGPSManagers) { [gVMLGPSManagers addObject:manager]; }
}

static void VMLGPSBroadcast(CLLocation *loc) {
    if (!loc || !gVMLGPSReplayEnabled) return;
    NSArray *managers;
    @synchronized(gVMLGPSManagers) { managers = gVMLGPSManagers.allObjects; }
    for (CLLocationManager *m in managers) {
        VMLLocationDelegateProxy *proxy = objc_getAssociatedObject(m, kVMLGPSProxyKey);
        id d = proxy.originalDelegate;
        SEL sel = @selector(locationManager:didUpdateLocations:);
        if (d && [d respondsToSelector:sel]) {
            ((void(*)(id,SEL,id,id))objc_msgSend)(d, sel, m, @[loc]);
        }
    }
    VMLGPSLog(@"FIX lat=%.6f lon=%.6f speed=%.1f course=%.0f seg=%ld",
              loc.coordinate.latitude, loc.coordinate.longitude,
              loc.speed*3.6, loc.course, (long)gVMLGPSSegmentIndex);
}

static void VMLGPSStartReplayTimer(void) {
    VMLGPSWriteSampleConfigIfNeeded();
    VMLGPSLoadConfig(YES);
    __block double acc = 0.0;
    [NSTimer scheduledTimerWithTimeInterval:0.20 repeats:YES block:^(__unused NSTimer *timer) {
        VMLGPSLoadConfig(NO);
        if (!gVMLGPSReplayEnabled) { acc = 0.0; return; }
        acc += 0.20;
        if (acc + 0.001 < gVMLGPSReplayInterval) return;
        acc = 0.0;
        CLLocation *loc = VMLGPSBuildNextLocation();
        if (loc) VMLGPSBroadcast(loc);
    }];
    VMLGPSLog(@"GPS REPLAY TIMER STARTED config=%@", VMLGPSReplayPath());
}

%hook CLLocationManager
- (void)setDelegate:(id<CLLocationManagerDelegate>)delegate {
    if (!delegate || [delegate isKindOfClass:VMLLocationDelegateProxy.class]) {
        %orig(delegate);
        return;
    }
    VMLLocationDelegateProxy *proxy = objc_getAssociatedObject(self, kVMLGPSProxyKey);
    if (!proxy) {
        proxy = [VMLLocationDelegateProxy new];
        objc_setAssociatedObject(self, kVMLGPSProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    proxy.originalDelegate = delegate;
    VMLGPSRegisterManager(self);
    %orig((id<CLLocationManagerDelegate>)proxy);
}
- (void)startUpdatingLocation {
    VMLGPSRegisterManager(self);
    %orig;
}
- (CLLocation *)location {
    if (gVMLGPSReplayEnabled && gVMLGPSFakeLocation) return gVMLGPSFakeLocation;
    return %orig;
}
%end


static void VMLStart(void) {
    NSString *bundleID =
        NSBundle.mainBundle.bundleIdentifier ?: @"";

    if (![bundleID isEqualToString:@"vn.vietmap.live"]) {
        return;
    }


    VMLTrace(
        @"VML RUNTIME START OK bundle=%@ process=%@",
        NSBundle.mainBundle.bundleIdentifier ?: @"nil",
        NSProcessInfo.processInfo.processName ?: @"nil"
    );

    NSString *bundle =
        NSBundle.mainBundle.bundleIdentifier ?: @"";

    NSString *process =
        NSProcessInfo.processInfo.processName ?: @"";

    if (![bundle isEqualToString:@"vn.vietmap.live"]) {
        return;
    }

    VMLInstallPhoneForegroundObservers();
    VMLStartCarPlayTemplateSceneWatcher();
    VMLScheduleClassDump();
    VMLScheduleFocusedMethodDump();
    VMLGPSStartReplayTimer();




    VMLLog(@"========================================");
    VMLLog(@"VML RUNTIME BRIDGE V15.3");
    VMLLog(@"bundle=%@", bundle);
    VMLLog(@"process=%@", process);
    VMLLog(@"home=%@", NSHomeDirectory());
    VMLLog(@"========================================");

    VMLStartSpeedReplayResponder();

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
