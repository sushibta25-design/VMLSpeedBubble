#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

static void CPLogState(NSString *reason) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
        NSString *process = NSProcessInfo.processInfo.processName;

        NSLog(@"[CPLOG] ===== %@ =====", reason);
        NSLog(@"[CPLOG] process=%@", process);
        NSLog(@"[CPLOG] bundle=%@", bundle);

        UIApplication *app = UIApplication.sharedApplication;

        NSLog(@"[CPLOG] connectedScenes=%@", app.connectedScenes);
        NSLog(@"[CPLOG] windows=%@", app.windows);

        for (UIScene *scene in app.connectedScenes) {
            NSLog(@"[CPLOG] scene class=%@ state=%ld",
                  NSStringFromClass(scene.class),
                  (long)scene.activationState);

            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)scene;

                NSLog(@"[CPLOG] UIWindowScene=%@", ws);
                NSLog(@"[CPLOG] screen=%@", ws.screen);
                NSLog(@"[CPLOG] windows=%@", ws.windows);

                for (UIWindow *window in ws.windows) {
                    NSLog(@"[CPLOG] window=%@ level=%f hidden=%d frame=%@",
                          window,
                          window.windowLevel,
                          window.hidden,
                          NSStringFromCGRect(window.frame));

                    NSLog(@"[CPLOG] rootVC=%@",
                          window.rootViewController);
                }
            }
        }

        NSLog(@"[CPLOG] UIScreen.screens=%@", UIScreen.screens);
        NSLog(@"[CPLOG] =====================");
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
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
        NSString *process = NSProcessInfo.processInfo.processName;

        NSLog(@"[CPLOG] injected process=%@ bundle=%@",
              process,
              bundle);

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
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
                        NSLog(@"[CPLOG] UISceneWillConnect: %@", note.object);
                        CPLogState(@"sceneConnect");
                    }];

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIScreenDidConnectNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
                        NSLog(@"[CPLOG] UIScreenDidConnect: %@", note.object);
                        CPLogState(@"screenConnect");
                    }];
    }
}
