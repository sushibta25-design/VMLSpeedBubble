#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>

static NSString *const kGMPhoneLogPath =
    @"/var/mobile/GoogleMapsPhoneTrace.txt";

static NSString *const kGMPhoneSnapshotPath =
    @"/var/mobile/GoogleMapsPhoneSnapshot.json";

static NSMutableSet<NSString *> *gGMLoggedTextEvents = nil;
static NSUInteger gGMSnapshotGeneration = 0;
static BOOL gGMRuntimeDumpStarted = NO;

static NSString *GMBundleIdentifier(void) {
    return NSBundle.mainBundle.bundleIdentifier ?: @"";
}

static BOOL GMIsGoogleMaps(void) {
    return [GMBundleIdentifier() isEqualToString:@"com.google.Maps"];
}

static void GMLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);

    NSString *message =
        [[NSString alloc] initWithFormat:format arguments:args];

    va_end(args);

    NSString *line =
        [NSString stringWithFormat:@"%@ | %@\n",
            [NSDate date],
            message];

    NSLog(@"[GMPHONE] %@", message);

    @synchronized (kGMPhoneLogPath) {
        FILE *file = fopen(kGMPhoneLogPath.UTF8String, "a");

        if (file) {
            fprintf(file, "%s", line.UTF8String);
            fclose(file);
        }
    }
}

static NSString *GMCleanText(NSString *text) {
    if (![text isKindOfClass:NSString.class])
        return @"";

    NSString *clean =
        [text stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];

    while ([clean containsString:@"\n\n"]) {
        clean =
            [clean stringByReplacingOccurrencesOfString:@"\n\n"
                                             withString:@"\n"];
    }

    if (clean.length > 300) {
        clean =
            [[clean substringToIndex:300]
                stringByAppendingString:@"…"];
    }

    return clean;
}

static BOOL GMTextIsUseful(NSString *text) {
    NSString *clean = GMCleanText(text);

    if (clean.length < 2)
        return NO;

    NSCharacterSet *letters =
        NSCharacterSet.letterCharacterSet;

    return
        ([clean rangeOfCharacterFromSet:letters].location !=
         NSNotFound);
}

static void GMLogTextEvent(
    NSString *kind,
    UIView *view,
    NSString *text
) {
    if (!GMIsGoogleMaps() ||
        !view.window ||
        !GMTextIsUseful(text)) {

        return;
    }

    NSString *clean = GMCleanText(text);

    NSString *key =
        [NSString stringWithFormat:@"%@|%@|%@",
            kind ?: @"TEXT",
            NSStringFromClass(view.class),
            clean];

    @synchronized (gGMLoggedTextEvents) {
        if ([gGMLoggedTextEvents containsObject:key])
            return;

        if (gGMLoggedTextEvents.count >= 800) {
            [gGMLoggedTextEvents removeAllObjects];
        }

        [gGMLoggedTextEvents addObject:key];
    }

    GMLog(
        @"TEXT kind=%@ class=%@ accessibilityID=\"%@\" value=\"%@\"",
        kind ?: @"unknown",
        NSStringFromClass(view.class),
        view.accessibilityIdentifier ?: @"",
        clean
    );
}

static void GMAddSnapshotText(
    NSMutableArray<NSDictionary *> *items,
    NSMutableSet<NSString *> *seen,
    UIView *view,
    NSString *kind,
    NSString *text
) {
    if (items.count >= 250 ||
        !GMTextIsUseful(text)) {

        return;
    }

    NSString *clean = GMCleanText(text);

    NSString *key =
        [NSString stringWithFormat:@"%@|%@",
            kind ?: @"text",
            clean];

    if ([seen containsObject:key])
        return;

    [seen addObject:key];

    CGRect screenFrame = CGRectZero;

    if (view.window) {
        screenFrame =
            [view convertRect:view.bounds
                       toView:view.window];
    }

    [items addObject:@{
        @"kind": kind ?: @"text",
        @"text": clean,
        @"class": NSStringFromClass(view.class) ?: @"",
        @"accessibilityIdentifier":
            view.accessibilityIdentifier ?: @"",
        @"frame": NSStringFromCGRect(screenFrame)
    }];
}

static void GMCollectViewText(
    UIView *view,
    NSMutableArray<NSDictionary *> *items,
    NSMutableSet<NSString *> *seen,
    NSUInteger *visited
) {
    if (!view ||
        !visited ||
        *visited >= 4000 ||
        items.count >= 250) {

        return;
    }

    (*visited)++;

    if (view.hidden ||
        view.alpha <= 0.01) {

        return;
    }

    if ([view isKindOfClass:UILabel.class]) {
        GMAddSnapshotText(
            items,
            seen,
            view,
            @"label",
            ((UILabel *)view).text
        );
    }

    if ([view isKindOfClass:UITextField.class]) {
        GMAddSnapshotText(
            items,
            seen,
            view,
            @"textField",
            ((UITextField *)view).text
        );
    }

    if ([view isKindOfClass:UITextView.class]) {
        GMAddSnapshotText(
            items,
            seen,
            view,
            @"textView",
            ((UITextView *)view).text
        );
    }

    if ([view isKindOfClass:UIButton.class]) {
        GMAddSnapshotText(
            items,
            seen,
            view,
            @"button",
            ((UIButton *)view).currentTitle
        );
    }

    GMAddSnapshotText(
        items,
        seen,
        view,
        @"accessibilityLabel",
        view.accessibilityLabel
    );

    GMAddSnapshotText(
        items,
        seen,
        view,
        @"accessibilityValue",
        view.accessibilityValue
    );

    for (UIView *subview in view.subviews) {
        GMCollectViewText(
            subview,
            items,
            seen,
            visited
        );

        if (*visited >= 4000 ||
            items.count >= 250) {

            break;
        }
    }
}

static NSArray<UIWindow *> *GMAllWindows(void) {
    NSMutableArray<UIWindow *> *windows =
        [NSMutableArray array];

    UIApplication *application =
        UIApplication.sharedApplication;

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in application.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class])
                continue;

            UIWindowScene *windowScene =
                (UIWindowScene *)scene;

            for (UIWindow *window in windowScene.windows) {
                if (window &&
                    ![windows containsObject:window]) {

                    [windows addObject:window];
                }
            }
        }
    }

    NSArray<UIWindow *> *legacyWindows = nil;

    @try {
        legacyWindows =
            [application valueForKey:@"windows"];
    }
    @catch (__unused NSException *exception) {
        legacyWindows = nil;
    }

    for (UIWindow *window in legacyWindows) {
        if (window &&
            ![windows containsObject:window]) {

            [windows addObject:window];
        }
    }

    return windows;
}

static void GMSaveVisibleSnapshot(
    NSString *reason
) {
    if (!GMIsGoogleMaps())
        return;

    NSMutableArray<NSDictionary *> *items =
        [NSMutableArray array];

    NSMutableSet<NSString *> *seen =
        [NSMutableSet set];

    NSUInteger visited = 0;
    NSUInteger visibleWindowCount = 0;

    for (UIWindow *window in GMAllWindows()) {
        if (window.hidden ||
            window.alpha <= 0.01) {

            continue;
        }

        visibleWindowCount++;

        GMCollectViewText(
            window,
            items,
            seen,
            &visited
        );
    }

    NSDictionary *payload = @{
        @"schema": @1,
        @"capturedAt":
            @([[NSDate date] timeIntervalSince1970]),
        @"reason": reason ?: @"unknown",
        @"bundle": GMBundleIdentifier(),
        @"process":
            NSProcessInfo.processInfo.processName ?: @"",
        @"visibleWindows": @(visibleWindowCount),
        @"visitedViews": @(visited),
        @"items": items
    };

    NSError *error = nil;

    NSData *data =
        [NSJSONSerialization
            dataWithJSONObject:payload
                       options:NSJSONWritingPrettyPrinted
                         error:&error];

    BOOL success = NO;

    if (data) {
        success =
            [data writeToFile:kGMPhoneSnapshotPath
                      options:NSDataWritingAtomic
                        error:&error];
    }

    GMLog(
        @"SNAPSHOT %@ reason=\"%@\" windows=%lu views=%lu "
         "textItems=%lu path=%@ error=%@",
        success ? @"OK" : @"FAILED",
        reason ?: @"unknown",
        (unsigned long)visibleWindowCount,
        (unsigned long)visited,
        (unsigned long)items.count,
        kGMPhoneSnapshotPath,
        error.localizedDescription ?: @"none"
    );

    for (NSDictionary *item in items) {
        GMLog(
            @"SNAPSHOT_TEXT kind=%@ class=%@ value=\"%@\"",
            item[@"kind"],
            item[@"class"],
            item[@"text"]
        );
    }
}

static void GMScheduleSnapshot(
    NSString *reason
) {
    gGMSnapshotGeneration++;

    NSUInteger generation =
        gGMSnapshotGeneration;

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            350 * NSEC_PER_MSEC
        ),
        dispatch_get_main_queue(),
        ^{
            if (generation ==
                gGMSnapshotGeneration) {

                GMSaveVisibleSnapshot(reason);
            }
        }
    );
}

static BOOL GMStringContainsKeyword(
    NSString *value
) {
    NSString *lower =
        value.lowercaseString;

    NSArray<NSString *> *keywords = @[
        @"destination",
        @"navigation",
        @"directions",
        @"route",
        @"trip",
        @"journey"
    ];

    for (NSString *keyword in keywords) {
        if ([lower containsString:keyword])
            return YES;
    }

    return NO;
}

static BOOL GMClassBelongsToGoogleMaps(
    Class cls
) {
    const char *imageName =
        class_getImageName(cls);

    if (!imageName)
        return NO;

    NSString *image =
        [NSString stringWithUTF8String:imageName];

    return
        [image containsString:@"GoogleMaps.app"];
}

static NSUInteger GMDumpMethods(
    Class cls,
    NSString *prefix,
    NSUInteger remaining
) {
    if (!cls ||
        remaining == 0) {

        return 0;
    }

    unsigned int methodCount = 0;

    Method *methods =
        class_copyMethodList(
            cls,
            &methodCount
        );

    NSUInteger logged = 0;

    for (unsigned int index = 0;
         index < methodCount &&
         logged < remaining;
         index++) {

        SEL selector =
            method_getName(methods[index]);

        NSString *selectorName =
            NSStringFromSelector(selector);

        if (!GMStringContainsKeyword(selectorName))
            continue;

        const char *types =
            method_getTypeEncoding(methods[index]);

        GMLog(
            @"CANDIDATE %@[%@ %@] types=%s",
            prefix,
            NSStringFromClass(cls),
            selectorName,
            types ?: ""
        );

        logged++;
    }

    free(methods);

    return logged;
}

static void GMDumpRuntimeCandidates(void) {
    @autoreleasepool {
        if (!GMIsGoogleMaps() ||
            gGMRuntimeDumpStarted) {

            return;
        }

        gGMRuntimeDumpStarted = YES;

        unsigned int classCount = 0;

        Class *classes =
            objc_copyClassList(&classCount);

        NSUInteger logged = 0;
        const NSUInteger limit = 1200;

        GMLog(
            @"RUNTIME SCAN START classes=%u limit=%lu",
            classCount,
            (unsigned long)limit
        );

        for (unsigned int index = 0;
             index < classCount &&
             logged < limit;
             index++) {

            Class cls =
                classes[index];

            if (!GMClassBelongsToGoogleMaps(cls))
                continue;

            NSString *className =
                NSStringFromClass(cls);

            if (!GMStringContainsKeyword(className))
                continue;

            logged +=
                GMDumpMethods(
                    cls,
                    @"-",
                    limit - logged
                );

            Class metaClass =
                object_getClass(cls);

            logged +=
                GMDumpMethods(
                    metaClass,
                    @"+",
                    limit - logged
                );
        }

        free(classes);

        GMLog(
            @"RUNTIME SCAN END candidates=%lu",
            (unsigned long)logged
        );
    }
}

%hook UIApplication

- (BOOL)sendAction:(SEL)action
                to:(id)target
              from:(id)sender
          forEvent:(UIEvent *)event {

    BOOL result = %orig;

    if (GMIsGoogleMaps()) {
        NSString *actionName =
            action
                ? NSStringFromSelector(action)
                : @"nil";

        NSString *senderTitle = @"";

        if ([sender isKindOfClass:UIButton.class]) {
            senderTitle =
                ((UIButton *)sender).currentTitle ?: @"";
        }

        GMLog(
            @"ACTION selector=%@ target=%@ sender=%@ "
             "title=\"%@\" result=%d",
            actionName,
            target
                ? NSStringFromClass([target class])
                : @"nil",
            sender
                ? NSStringFromClass([sender class])
                : @"nil",
            senderTitle,
            result
        );

        GMScheduleSnapshot(
            [NSString stringWithFormat:
                @"action:%@",
                actionName]
        );
    }

    return result;
}

%end

%hook UILabel

- (void)setText:(NSString *)text {
    %orig;

    GMLogTextEvent(
        @"UILabel.setText",
        self,
        text
    );
}

- (void)setAttributedText:
    (NSAttributedString *)text {

    %orig;

    GMLogTextEvent(
        @"UILabel.setAttributedText",
        self,
        text.string
    );
}

%end

%hook UITextField

- (void)setText:(NSString *)text {
    %orig;

    GMLogTextEvent(
        @"UITextField.setText",
        self,
        text
    );
}

%end

%hook UITextView

- (void)setText:(NSString *)text {
    %orig;

    GMLogTextEvent(
        @"UITextView.setText",
        self,
        text
    );
}

%end

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    if (!GMIsGoogleMaps())
        return;

    GMLog(
        @"VIEW_APPEARED class=%@ title=\"%@\"",
        NSStringFromClass(self.class),
        self.title ?: @""
    );

    GMScheduleSnapshot(
        [NSString stringWithFormat:
            @"viewDidAppear:%@",
            NSStringFromClass(self.class)]
    );
}

%end

%ctor {
    @autoreleasepool {
        if (!GMIsGoogleMaps())
            return;

        gGMLoggedTextEvents =
            [NSMutableSet set];

        GMLog(@"========================================");
        GMLog(
            @"GOOGLE MAPS PHONE DIAGNOSTIC "
             "V16.1-PHONE-DIAG1"
        );

        GMLog(
            @"bundle=%@ process=%@ version=%@ build=%@",
            GMBundleIdentifier(),
            NSProcessInfo.processInfo.processName ?: @"",
            [NSBundle.mainBundle
                objectForInfoDictionaryKey:
                    @"CFBundleShortVersionString"] ?: @"",
            [NSBundle.mainBundle
                objectForInfoDictionaryKey:
                    @"CFBundleVersion"] ?: @""
        );

        GMLog(@"NO CARPLAY REQUIRED");
        GMLog(@"========================================");

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                3 * NSEC_PER_SEC
            ),
            dispatch_get_main_queue(),
            ^{
                GMSaveVisibleSnapshot(
                    @"startup"
                );
            }
        );

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                6 * NSEC_PER_SEC
            ),
            dispatch_get_global_queue(
                QOS_CLASS_UTILITY,
                0
            ),
            ^{
                GMDumpRuntimeCandidates();
            }
        );
    }
}
