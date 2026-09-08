#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

static NSString *VMLLogPath(void) {
    return @"/tmp/VMLCarPlayLog.txt";
}

static void VMLWriteLine(NSString *line) {
    if (!line) return;

    NSString *text =
        [NSString stringWithFormat:@"%@\n", line];

    NSData *data =
        [text dataUsingEncoding:NSUTF8StringEncoding];

    NSString *path = VMLLogPath();

    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
        return;
    }

    NSFileHandle *fh =
        [NSFileHandle fileHandleForWritingAtPath:path];

    if (!fh) return;

    @try {
        [fh seekToEndOfFile];
        [fh writeData:data];
        [fh closeFile];
    } @catch (__unused NSException *e) {
    }
}

static void VMLDumpCarPlayState(NSString *reason) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *bundle =
            NSBundle.mainBundle.bundleIdentifier ?: @"(nil)";

        NSString *process =
            NSProcessInfo.processInfo.processName ?: @"(nil)";

        VMLWriteLine(@"");
        VMLWriteLine(@"==============================");
        VMLWriteLine(
            [NSString stringWithFormat:
                @"REASON: %@", reason ?: @"unknown"]
        );

        VMLWriteLine(
            [NSString stringWithFormat:
                @"PROCESS: %@", process]
        );

        VMLWriteLine(
            [NSString stringWithFormat:
                @"BUNDLE: %@", bundle]
        );

        UIApplication *app =
            UIApplication.sharedApplication;

        NSSet *scenes =
            app.connectedScenes;

        VMLWriteLine(
            [NSString stringWithFormat:
                @"SCENE COUNT: %lu",
                (unsigned long)scenes.count]
        );

        NSInteger sceneIndex = 0;

        for (UIScene *scene in scenes) {
            VMLWriteLine(
                [NSString stringWithFormat:
                    @"SCENE[%ld] class=%@ state=%ld",
                    (long)sceneIndex,
                    NSStringFromClass(scene.class),
                    (long)scene.activationState]
            );

            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws =
                    (UIWindowScene *)scene;

                UIScreen *screen =
                    ws.screen;

                VMLWriteLine(
                    [NSString stringWithFormat:
                        @"  SCREEN=%@ bounds=%@ scale=%.2f",
                        screen,
                        NSStringFromCGRect(screen.bounds),
                        screen.scale]
                );

                NSArray<UIWindow *> *windows =
                    ws.windows;

                VMLWriteLine(
                    [NSString stringWithFormat:
                        @"  WINDOW COUNT=%lu",
                        (unsigned long)windows.count]
                );

                NSInteger windowIndex = 0;

                for (UIWindow *window in windows) {
                    VMLWriteLine(
                        [NSString stringWithFormat:
                            @"  WINDOW[%ld] class=%@ frame=%@ level=%.2f hidden=%d key=%d",
                            (long)windowIndex,
                            NSStringFromClass(window.class),
                            NSStringFromCGRect(window.frame),
                            window.windowLevel,
                            window.hidden,
                            window.isKeyWindow]
                    );

                    UIViewController *root =
                        window.rootViewController;

                    VMLWriteLine(
                        [NSString stringWithFormat:
                            @"    ROOT=%@",
                            root ?
                            NSStringFromClass(root.class) :
                            @"(nil)"]
                    );

                    windowIndex++;
                }
            }

            sceneIndex++;
        }

        NSArray<UIScreen *> *screens =
            UIScreen.screens;

        VMLWriteLine(
            [NSString stringWithFormat:
                @"UIScreen.screens COUNT=%lu",
                (unsigned long)screens.count]
        );

        NSInteger screenIndex = 0;

        for (UIScreen *screen in screens) {
            VMLWriteLine(
                [NSString stringWithFormat:
                    @"UIScreen[%ld]=%@ bounds=%@ scale=%.2f",
                    (long)screenIndex,
                    screen,
                    NSStringFromCGRect(screen.bounds),
                    screen.scale]
            );

            screenIndex++;
        }

        VMLWriteLine(@"==============================");
    });
}

%hook UIApplication

- (void)_sendWillEnterForegroundCallbacksForScene:(id)scene {
    %orig;

    VMLDumpCarPlayState(@"willEnterForeground");
}

%end

%ctor {
    @autoreleasepool {
        NSString *bundle =
            NSBundle.mainBundle.bundleIdentifier ?: @"(nil)";

        NSString *process =
            NSProcessInfo.processInfo.processName ?: @"(nil)";

        VMLWriteLine(@"");
        VMLWriteLine(@"***** TWEAK INJECTED *****");

        VMLWriteLine(
            [NSString stringWithFormat:
                @"PROCESS=%@", process]
        );

        VMLWriteLine(
            [NSString stringWithFormat:
                @"BUNDLE=%@", bundle]
        );

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                3 * NSEC_PER_SEC
            ),
            dispatch_get_main_queue(),
            ^{
                VMLDumpCarPlayState(@"startup+3s");
            }
        );

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                10 * NSEC_PER_SEC
            ),
            dispatch_get_main_queue(),
            ^{
                VMLDumpCarPlayState(@"startup+10s");
            }
        );

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UISceneWillConnectNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
                        VMLWriteLine(
                            [NSString stringWithFormat:
                                @"UISceneWillConnect: %@",
                                note.object]
                        );

                        VMLDumpCarPlayState(@"sceneConnect");
                    }];

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIScreenDidConnectNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
                        VMLWriteLine(
                            [NSString stringWithFormat:
                                @"UIScreenDidConnect: %@",
                                note.object]
                        );

                        VMLDumpCarPlayState(@"screenConnect");
                    }];
    }
}
