#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

static NSString *CPLogPath(void) {
    return @"/var/mobile/CarPlayLog.txt";
}

static void CPWrite(NSString *format, ...) {
    va_list args;
    va_start(args, format);

    NSString *line =
        [[NSString alloc] initWithFormat:format arguments:args];

    va_end(args);

    NSString *full =
        [NSString stringWithFormat:@"%@\n", line];

    NSData *data =
        [full dataUsingEncoding:NSUTF8StringEncoding];

    NSString *path = CPLogPath();

    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
        return;
    }

    NSFileHandle *handle =
        [NSFileHandle fileHandleForWritingAtPath:path];

    if (handle) {
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle closeFile];
    }
}

static void CPLogState(NSString *reason) {
    dispatch_async(dispatch_get_main_queue(), ^{

        NSString *bundle =
            NSBundle.mainBundle.bundleIdentifier ?: @"(nil)";

        NSString *process =
            NSProcessInfo.processInfo.processName ?: @"(nil)";

        UIApplication *app =
            UIApplication.sharedApplication;

        CPWrite(@"");
        CPWrite(@"========================================");
        CPWrite(@"REASON: %@", reason);
        CPWrite(@"PROCESS: %@", process);
        CPWrite(@"BUNDLE: %@", bundle);
        CPWrite(@"========================================");

        CPWrite(@"UIScreen count: %lu",
                (unsigned long)UIScreen.screens.count);

        NSInteger screenIndex = 0;

        for (UIScreen *screen in UIScreen.screens) {

            CPWrite(@"SCREEN[%ld]", (long)screenIndex);
            CPWrite(@"  bounds=%@",
                    NSStringFromCGRect(screen.bounds));
            CPWrite(@"  scale=%.2f",
                    screen.scale);
            CPWrite(@"  nativeBounds=%@",
                    NSStringFromCGRect(screen.nativeBounds));

            screenIndex++;
        }

        CPWrite(@"Connected scene count: %lu",
                (unsigned long)app.connectedScenes.count);

        NSInteger sceneIndex = 0;

        for (UIScene *scene in app.connectedScenes) {

            CPWrite(@"");
            CPWrite(@"SCENE[%ld]", (long)sceneIndex);

            CPWrite(@"  class=%@",
                    NSStringFromClass(scene.class));

            CPWrite(@"  state=%ld",
                    (long)scene.activationState);

            CPWrite(@"  role=%@",
                    scene.session.role);

            CPWrite(@"  persistentIdentifier=%@",
                    scene.session.persistentIdentifier);

            if ([scene isKindOfClass:[UIWindowScene class]]) {

                UIWindowScene *ws =
                    (UIWindowScene *)scene;

                CPWrite(@"  screen=%@", ws.screen);

                CPWrite(@"  screenBounds=%@",
                        NSStringFromCGRect(ws.screen.bounds));

                CPWrite(@"  windows=%lu",
                        (unsigned long)ws.windows.count);

                NSInteger windowIndex = 0;

                for (UIWindow *window in ws.windows) {

                    CPWrite(@"    WINDOW[%ld]",
                            (long)windowIndex);

                    CPWrite(@"      class=%@",
                            NSStringFromClass(window.class));

                    CPWrite(@"      frame=%@",
                            NSStringFromCGRect(window.frame));

                    CPWrite(@"      level=%.2f",
                            window.windowLevel);

                    CPWrite(@"      hidden=%d",
                            window.hidden);

                    CPWrite(@"      keyWindow=%d",
                            window.isKeyWindow);

                    CPWrite(@"      rootVC=%@",
                            window.rootViewController ?
                            NSStringFromClass(
                                window.rootViewController.class
                            ) :
                            @"(nil)");

                    windowIndex++;
                }
            }

            sceneIndex++;
        }

        CPWrite(@"");
        CPWrite(@"========== END ==========");
        CPWrite(@"");
    });
}

%hook UIApplication

- (void)_sendWillEnterForegroundCallbacksForScene:(id)scene {
    %orig;

    CPLogState(@"willEnterForeground");
}

%end

%ctor {
    @autoreleasepool {

        NSString *bundle =
            NSBundle.mainBundle.bundleIdentifier ?: @"(nil)";

        NSString *process =
            NSProcessInfo.processInfo.processName ?: @"(nil)";

        CPWrite(@"");
        CPWrite(@"******** LOGGER INJECTED ********");
        CPWrite(@"PROCESS: %@", process);
        CPWrite(@"BUNDLE: %@", bundle);
        CPWrite(@"*********************************");

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          5 * NSEC_PER_SEC),
            dispatch_get_main_queue(),
            ^{
                CPLogState(@"startup");
            }
        );

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UISceneWillConnectNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {

            CPWrite(@"EVENT: UISceneWillConnect");
            CPLogState(@"sceneConnect");
        }];

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIScreenDidConnectNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {

            CPWrite(@"EVENT: UIScreenDidConnect");
            CPLogState(@"screenConnect");
        }];
    }
}
