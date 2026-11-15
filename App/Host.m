#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "Host.h"
#include <dlfcn.h>
#include <stdint.h>
#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern int launcher_main(int argc, char **argv);
extern void renios_library(void);
extern int SDL_PushEvent(void *event);
#if RENIOS_SDL3
extern void *SDL_GetKeyboardFocus(void);
extern bool SDL_StartTextInput(void *window);
extern int SDL_RunApp(int, char **, int (*)(int, char **), void *);
#else
extern void SDL_StartTextInput(void);
extern int SDL_UIKitRunApp(int, char **, int (*)(int, char **));
#endif

typedef int (*EngineMain)(int, char **);
typedef int (*EnginePushEvent)(void *);
typedef void (*LegacyEventPump)(int);

static EnginePushEvent activePushEvent;
static void (*activeStartKeyboard)(void);

static void startDefaultKeyboard(void) {
#if RENIOS_SDL3
    void *window = SDL_GetKeyboardFocus();
    if (window) { SDL_StartTextInput(window); }
#else
    SDL_StartTextInput();
#endif
}
static UIWindow *(*legacyWindowInit)(id, SEL, CGRect);
static __weak UIWindowScene *legacyScene;

static UIWindow *attachLegacyWindow(id window, SEL selector, CGRect frame) {
    UIWindow *result = legacyWindowInit(window, selector, frame);
    if (legacyScene) { result.windowScene = legacyScene; }
    return result;
}

static UIWindowScene *currentScene(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] &&
            [scene.session.role isEqualToString:UIWindowSceneSessionRoleApplication]) {
            return (UIWindowScene *)scene;
        }
    }
    return nil;
}

static BOOL probeEnabled;
static IMP originalLayout;
static IMP originalTransition;
static IMP originalShouldBeginEditing;
static __weak UIViewController *gameController;
static CGSize lastViewportSize;
static BOOL keyboardDismissedByPlayer;
static CGRect viewportAtInput;
static __weak UIView *probedViewport;

static void rememberViewport(UIView *viewport) {
    if (!probedViewport && viewport.window) {
        probedViewport = viewport;
        viewportAtInput = [viewport convertRect:viewport.bounds toView:nil];
    }
}

static void fitGameViewport(UIViewController *controller) {
    UIView *view = controller.viewIfLoaded;
    UIWindow *window = view.window;
    UIView *parent = view.superview;
    if (!window || !parent || window.rootViewController != controller || CGRectIsEmpty(window.bounds)) {
        return;
    }

    gameController = controller;
    CGRect frame = [window convertRect:window.bounds toView:parent];
    if (!CGRectEqualToRect(view.frame, frame)) {
        view.frame = frame;
    }
}

static BOOL readDrawableSize(UIView *view, CGSize *size) {
    SEL widthSelector = sel_registerName("backingWidth");
    SEL heightSelector = sel_registerName("backingHeight");
    if (![view respondsToSelector:widthSelector] || ![view respondsToSelector:heightSelector]) {
        return NO;
    }

    int (*readWidth)(id, SEL) = (void *)[view methodForSelector:widthSelector];
    int (*readHeight)(id, SEL) = (void *)[view methodForSelector:heightSelector];
    *size = CGSizeMake(readWidth(view, widthSelector), readHeight(view, heightSelector));
    return YES;
}

static CGSize expectedDrawableSize(UIView *view) {
    // SDL's UIKit OpenGL view truncates points × content scale to pixels.
    return CGSizeMake((int)(view.bounds.size.width * view.contentScaleFactor),
                      (int)(view.bounds.size.height * view.contentScaleFactor));
}

static BOOL drawableSizeMatches(UIView *view, CGSize actual) {
    CGSize expected = expectedDrawableSize(view);
    return expected.width > 0 && expected.height > 0
        && fabs(expected.width - actual.width) <= 1 && fabs(expected.height - actual.height) <= 1;
}

static BOOL repairGameDrawable(UIViewController *controller) {
    UIView *view = controller.viewIfLoaded;
    CGSize actual;
    if (!view.window || !readDrawableSize(view, &actual) || drawableSizeMatches(view, actual)) {
        return NO;
    }

    // SDL's OpenGL view reallocates its color/depth buffers during layout.
    // Run that layout before Ren’Py computes the viewport from the new size.
    [view setNeedsLayout];
    [view layoutIfNeeded];
    return YES;
}

static void layoutGameViewport(UIViewController *controller, SEL selector) {
    UIViewController *previousController = gameController;
    fitGameViewport(controller);
    CGSize size = controller.viewIfLoaded.bounds.size;
    BOOL changedSize = previousController == controller && gameController == controller
        && !CGSizeEqualToSize(lastViewportSize, size);
    if (gameController == controller) { lastViewportSize = size; }
    ((void (*)(id, SEL))originalLayout)(controller, selector);

    CGSize actual;
    UIView *view = controller.viewIfLoaded;
    if (changedSize && readDrawableSize(view, &actual) && !drawableSizeMatches(view, actual)) {
        // Some scene resizes bypass the controller's transition coordinator.
        // Defer the repair until UIKit has finished the current layout pass.
        [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:NO block:^(NSTimer *timer) {
            if (gameController == controller && repairGameDrawable(controller)) {
                [controller viewDidLayoutSubviews];
            }
        }];
    }
}

static void transitionGameViewport(UIViewController *controller, SEL selector, CGSize size,
                                   id<UIViewControllerTransitionCoordinator> coordinator) {
    ((void (*)(id, SEL, CGSize, id))originalTransition)(controller, selector, size, coordinator);
    [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        if (gameController != controller) { return; }
        fitGameViewport(controller);
        repairGameDrawable(controller);
        [controller viewDidLayoutSubviews];
    }];
}

static void updateGameKeyboardLayout(UIViewController *controller, SEL selector) {
    if (probeEnabled) { rememberViewport(controller.view); }
    // SDL normally adds an offset for the keyboard. Keep the render view in
    // the window's current coordinate space, including after a rotation.
    fitGameViewport(controller);
}

static BOOL allowGameKeyboardFocus(UIViewController *controller, SEL selector, UITextField *field) {
    if (keyboardDismissedByPlayer) { return NO; }
    if (originalShouldBeginEditing) {
        return ((BOOL (*)(id, SEL, UITextField *))originalShouldBeginEditing)(controller, selector, field);
    }
    return YES;
}

static UITextField *gameTextField(void) {
    UIViewController *controller = gameController;
    for (UIView *view in controller.viewIfLoaded.subviews) {
        if ([view isKindOfClass:UITextField.class] && ((UITextField *)view).delegate == (id)controller) {
            return (UITextField *)view;
        }
    }
    return nil;
}

static IMP installViewportHook(Class type, SEL selector, IMP replacement) {
    Method method = class_getInstanceMethod(type, selector);
    if (!method) { return NULL; }
    IMP original = method_getImplementation(method);
    if (!class_addMethod(type, selector, replacement, method_getTypeEncoding(method))) {
        method_setImplementation(method, replacement);
    }
    return original;
}

static NSURL *probeFile(NSString *name) {
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory
                                                        inDomains:NSUserDomainMask].firstObject;
    return [caches URLByAppendingPathComponent:name];
}

static void writeProbe(NSDictionary *result, NSString *name) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
    [data writeToURL:probeFile(name) options:NSDataWritingAtomic error:NULL];
}

static void writeKeyboardProbe(void) {
    UIView *viewport = probedViewport;
    if (!viewport.window) { return; }

    CGRect current = [viewport convertRect:viewport.bounds toView:nil];
    BOOL viewportStable = CGRectEqualToRect(viewportAtInput, current) &&
                          current.size.width > 0 && current.size.height > 0;
    NSDictionary *result = @{
        @"keyboardVisible": @YES,
        @"viewportStable": viewportStable ? @YES : @NO,
        @"before": NSStringFromCGRect(viewportAtInput),
        @"after": NSStringFromCGRect(current)
    };
    writeProbe(result, @"renios-keyboard.json");
}

static BOOL viewportFillsWindow(UIView *view) {
    UIWindow *window = view.window;
    if (!window || CGRectIsEmpty(window.bounds)) { return NO; }
    CGRect actual = [view convertRect:view.bounds toView:window];
    return CGRectContainsRect(CGRectInset(window.bounds, -0.5, -0.5), actual)
        && CGRectContainsRect(CGRectInset(actual, -0.5, -0.5), window.bounds);
}

static void probePlaybackControls(void) {
    UITextField *field = gameTextField();
    UIWindow *window = field.window;
    UIWindowScene *scene = window.windowScene;
    if (!field.isFirstResponder || !scene) {
        writeProbe(@{@"keyboardStayedHidden": @NO, @"rotated": @NO}, @"renios-controls.json");
        return;
    }

    renios_toggle_keyboard();
    // Exercise a real focus request while Ren’Py still has a live input prompt.
    [field becomeFirstResponder];
    const BOOL startedInPortrait = window.bounds.size.height > window.bounds.size.width;
    [NSTimer scheduledTimerWithTimeInterval:0.8 repeats:NO block:^(NSTimer *timer) {
        if (!activePushEvent) { return; }
        const BOOL stayedHidden = !gameTextField().isFirstResponder;
        UIInterfaceOrientationMask target = startedInPortrait
            ? UIInterfaceOrientationMaskLandscapeRight : UIInterfaceOrientationMaskPortrait;
        UIWindowSceneGeometryPreferencesIOS *preferences =
            [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:target];
        [scene requestGeometryUpdateWithPreferences:preferences errorHandler:^(NSError *error) {
            NSLog(@"reniOS rotation probe: %@", error.localizedDescription);
        }];

        __block int attempts = 0;
        [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *rotationTimer) {
            if (!activePushEvent) { [rotationTimer invalidate]; return; }
            UIView *view = gameController.viewIfLoaded;
            CGSize size = view.window.bounds.size;
            BOOL rotated = size.width > 0 && size.height > 0
                && (size.height > size.width) != startedInPortrait;
            BOOL fillsWindow = viewportFillsWindow(view);
            CGSize initialDrawable;
            BOOL drawableMatches = readDrawableSize(view, &initialDrawable)
                && drawableSizeMatches(view, initialDrawable);
            if (++attempts < 32 && (!rotated || !fillsWindow || !drawableMatches)) { return; }
            [rotationTimer invalidate];

            BOOL hiddenThroughRotation = stayedHidden && !gameTextField().isFirstResponder;
            renios_toggle_keyboard();
            [NSTimer scheduledTimerWithTimeInterval:0.4 repeats:NO block:^(NSTimer *reopened) {
                UIView *current = gameController.viewIfLoaded;
                CGSize actual = CGSizeZero;
                BOOL measured = readDrawableSize(current, &actual);
                writeProbe(@{
                    @"drawableMatchesViewport": @(drawableMatches && measured && drawableSizeMatches(current, actual)),
                    @"drawableSize": NSStringFromCGSize(actual),
                    @"expectedDrawableSize": NSStringFromCGSize(expectedDrawableSize(current)),
                    @"keyboardStayedHidden": @(hiddenThroughRotation),
                    @"keyboardReopened": @(gameTextField().isFirstResponder),
                    @"rotated": @(rotated),
                    @"viewportFillsWindow": @(fillsWindow && viewportFillsWindow(gameController.viewIfLoaded))
                }, @"renios-controls.json");
            }];
        }];
    }];
}

int renios_play(const char *project, const char *saves, const char *engine, const char *orientation, int keyboardProbe) {
    NSString *version = @(engine);
    NSBundle *bundle = NSBundle.mainBundle;
    NSDictionary *namespaces = [bundle objectForInfoDictionaryKey:@"ReniosLegacyNamespaces"];
    NSString *prefix = namespaces[version];
    NSString *executable = bundle.executablePath;
    EngineMain entry = launcher_main;
    EnginePushEvent push = SDL_PushEvent;
    LegacyEventPump legacyEventPump = NULL;
    void (*startKeyboard)(void) = startDefaultKeyboard;
    Method windowInitializer = NULL;
    IMP previousWindowInitializer = NULL;
    NSString *controllerName = @"SDL_uikitviewcontroller";

    if (prefix) {
        NSLog(@"Loading Ren’Py %@ in %@", version, prefix);
        NSString *name = [@"RenPy" stringByAppendingString:[version stringByReplacingOccurrencesOfString:@"." withString:@"_"]];
        NSString *relative = [NSString stringWithFormat:@"%@.framework/%@", name, name];
        NSString *framework = [bundle.privateFrameworksPath stringByAppendingPathComponent:relative];
        void *handle = dlopen(framework.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL | RTLD_FIRST);
        if (!handle) {
            NSLog(@"Ren’Py %@ could not load: %s", version, dlerror());
            return -3;
        }
        entry = (EngineMain)dlsym(handle, "launcher_main");
        push = (EnginePushEvent)dlsym(handle, "SDL_PushEvent");
        legacyEventPump = (LegacyEventPump)dlsym(handle, "renios_legacy_set_event_pump");
        startKeyboard = dlsym(handle, "renios_legacy_start_keyboard");
        void (*mainReady)(void) = dlsym(handle, "SDL_SetMainReady");
        if (!entry || !push || !legacyEventPump || !mainReady || !startKeyboard) {
            NSLog(@"Ren’Py %@ is missing a runtime entry point", version);
            return -3;
        }

        executable = [bundle.bundlePath stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"base/Engines/%@/main", version]];
        legacyScene = currentScene();
        controllerName = [prefix stringByAppendingString:@"_uikitviewcontroller"];
        Class windowClass = NSClassFromString([prefix stringByAppendingString:@"_uikitwindow"]);
        SEL selector = @selector(initWithFrame:);
        Method initializer = windowClass ? class_getInstanceMethod(windowClass, selector) : NULL;
        if (!initializer || !legacyScene) {
            NSLog(@"Ren’Py %@ could not attach its SDL window to a scene", version);
            return -3;
        }
        IMP implementation = method_getImplementation(initializer);
        if (implementation != (IMP)attachLegacyWindow) {
            legacyWindowInit = (void *)implementation;
            // Own this method on the private SDL subclass. Never edit UIWindow.
            if (!class_addMethod(windowClass, selector, (IMP)attachLegacyWindow, method_getTypeEncoding(initializer))) {
                windowInitializer = initializer;
                previousWindowInitializer = method_setImplementation(initializer, (IMP)attachLegacyWindow);
            }
        }
        mainReady();
        legacyEventPump(1);
    }

    Class controller = NSClassFromString(controllerName);
    SEL updateKeyboardSelector = sel_registerName("updateKeyboard");
    Method keyboardMethod = controller ? class_getInstanceMethod(controller, updateKeyboardSelector) : NULL;
    if (!keyboardMethod) {
        NSLog(@"Ren’Py %@ has no SDL keyboard hook for %@", version, controllerName);
        if (legacyEventPump) { legacyEventPump(0); }
        if (windowInitializer) { method_setImplementation(windowInitializer, previousWindowInitializer); }
        legacyScene = nil;
        return -2;
    }
    activePushEvent = push;
    activeStartKeyboard = startKeyboard;
    keyboardDismissedByPlayer = NO;

    probeEnabled = keyboardProbe != 0;
    IMP originalKeyboardUpdate = installViewportHook(controller, updateKeyboardSelector, (IMP)updateGameKeyboardLayout);
    SEL layoutSelector = @selector(viewDidLayoutSubviews);
    originalLayout = installViewportHook(controller, layoutSelector, (IMP)layoutGameViewport);
    SEL transitionSelector = @selector(viewWillTransitionToSize:withTransitionCoordinator:);
    originalTransition = installViewportHook(controller, transitionSelector, (IMP)transitionGameViewport);
    SEL editingSelector = @selector(textFieldShouldBeginEditing:);
    originalShouldBeginEditing = installViewportHook(controller, editingSelector, (IMP)allowGameKeyboardFocus);
    if (!originalShouldBeginEditing) {
        char types[16];
        snprintf(types, sizeof(types), "%s@:@", @encode(BOOL));
        class_addMethod(controller, editingSelector, (IMP)allowGameKeyboardFocus, types);
    }
    id willShow = nil;
    id didShow = nil;
    __block NSTimer *keyboardProbeTimer = nil;
    NSTimer *quitProbe = nil;
    if (probeEnabled) {
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        willShow = [center addObserverForName:UIKeyboardWillShowNotification
                     object:nil queue:nil usingBlock:^(NSNotification *note) {
            UIWindowScene *scene = currentScene();
            for (UIWindow *window in scene.windows) {
                if ([window.rootViewController isKindOfClass:controller]) {
                    rememberViewport(window.rootViewController.view);
                    break;
                }
            }
            NSTimeInterval animation = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
            [keyboardProbeTimer invalidate];
            // SDL2 pumps UIKit through a nested run loop, so schedule the
            // measurement there after UIKit's keyboard transition.
            keyboardProbeTimer = [NSTimer scheduledTimerWithTimeInterval:MAX(0.1, animation + 0.15)
                                                           repeats:NO block:^(NSTimer *timer) {
                writeKeyboardProbe();
            }];
        }];
        didShow = [center addObserverForName:UIKeyboardDidShowNotification
                    object:nil queue:nil usingBlock:^(NSNotification *note) {
            [keyboardProbeTimer invalidate];
            keyboardProbeTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:NO
                                                                   block:^(NSTimer *timer) {
                writeKeyboardProbe();
            }];
        }];
        setenv("RENIOS_KEYBOARD_PROBE", "1", 1);
        setenv("RENIOS_PROBE_SAVES", saves, 1);
        unsetenv("RENIOS_PROBE_SAVES_MATCH");
        unsetenv("RENIOS_QUIT_CONFIRMED");
        unsetenv("RENIOS_PROBE_ENGINE");
        NSURL *request = probeFile(@"renios-quit.request");
        NSURL *controls = probeFile(@"renios-controls.request");
        quitProbe = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
            if ([NSFileManager.defaultManager fileExistsAtPath:controls.path]) {
                [NSFileManager.defaultManager removeItemAtURL:controls error:NULL];
                probePlaybackControls();
            }
            if (![NSFileManager.defaultManager fileExistsAtPath:request.path]) { return; }

            [timer invalidate];
            [NSFileManager.defaultManager removeItemAtURL:request error:NULL];
            renios_request_quit();
        }];
    }

    setenv("RENPY_PLATFORM", "ios-arm64", 1);
    setenv("RENPY_DISABLE_FULLSCREEN", "1", 1);
    char *argv[] = {
        (char *)executable.fileSystemRepresentation,
        (char *)project, "--savedir", (char *)saves, NULL
    };
    const char *hint = (RENIOS_SDL3 && !prefix) ? "SDL_ORIENTATIONS" : "SDL_IOS_ORIENTATIONS";
    const char *requestedOrientation = orientation[0] ? orientation : NULL;
    if (probeEnabled && !prefix && !requestedOrientation) {
        requestedOrientation = "Portrait LandscapeLeft LandscapeRight";
    }
    if (requestedOrientation) { setenv(hint, requestedOrientation, 1); }
    if (prefix) { NSLog(@"Starting Ren’Py %@", version); }
    int status = entry(4, argv);
    if (prefix) { NSLog(@"Ren’Py %@ returned %d", version, status); }
    activePushEvent = NULL;
    activeStartKeyboard = NULL;
    keyboardDismissedByPlayer = NO;
    gameController = nil;
    lastViewportSize = CGSizeZero;
    if (legacyEventPump) { legacyEventPump(0); }
    if (windowInitializer) { method_setImplementation(windowInitializer, previousWindowInitializer); }
    legacyScene = nil;
    if (requestedOrientation) { unsetenv(hint); }

    [quitProbe invalidate];
    [keyboardProbeTimer invalidate];
    if (probeEnabled) {
        const char *confirmed = getenv("RENIOS_QUIT_CONFIRMED");
        BOOL confirmationRan = confirmed && strcmp(confirmed, "1") == 0;
        const char *reported = getenv("RENIOS_PROBE_ENGINE");
        const char *saveMatch = getenv("RENIOS_PROBE_SAVES_MATCH");
        BOOL savesMatch = saveMatch && strcmp(saveMatch, "1") == 0;
        writeProbe(@{@"confirmed": confirmationRan ? @YES : @NO, @"exitStatus": @(status),
                     @"engine": reported ? @(reported) : @"", @"usesGameSaves": @(savesMatch)}, @"renios-quit.json");
        unsetenv("RENIOS_QUIT_CONFIRMED");
        unsetenv("RENIOS_PROBE_ENGINE");
        unsetenv("RENIOS_KEYBOARD_PROBE");
        unsetenv("RENIOS_PROBE_SAVES");
        unsetenv("RENIOS_PROBE_SAVES_MATCH");
    }
    if (willShow) { [NSNotificationCenter.defaultCenter removeObserver:willShow]; }
    if (didShow) { [NSNotificationCenter.defaultCenter removeObserver:didShow]; }
    method_setImplementation(class_getInstanceMethod(controller, updateKeyboardSelector), originalKeyboardUpdate);
    if (originalLayout) { method_setImplementation(class_getInstanceMethod(controller, layoutSelector), originalLayout); }
    if (originalTransition) { method_setImplementation(class_getInstanceMethod(controller, transitionSelector), originalTransition); }
    if (originalShouldBeginEditing) {
        method_setImplementation(class_getInstanceMethod(controller, editingSelector), originalShouldBeginEditing);
    }
    probedViewport = nil;
    probeEnabled = NO;
    return status;
}

void renios_toggle_keyboard(void) {
    if (!activeStartKeyboard) { return; }
    UITextField *field = gameTextField();
    if (!keyboardDismissedByPlayer && field.isFirstResponder) {
        // Keep the game's input interaction running, but block refocus until
        // the player explicitly opens the keyboard again.
        keyboardDismissedByPlayer = YES;
        [field resignFirstResponder];
        return;
    }

    keyboardDismissedByPlayer = NO;
    activeStartKeyboard();
    [field becomeFirstResponder];
}

void renios_request_quit(void) {
    // The public SDL quit event is 0x100 in SDL 2 and 3. Reserve extra space
    // and align it to cover both versions' event unions.
    union {
        uint32_t type;
        uint64_t storage[32];
    } event = {0};
    event.type = 0x100;
    if (activePushEvent) { activePushEvent(&event); }
}

static int showLibrary(int argc, char **argv) {
    renios_library();
    return 0;
}

int main(int argc, char **argv) {
#if RENIOS_SDL3
    return SDL_RunApp(argc, argv, showLibrary, NULL);
#else
    return SDL_UIKitRunApp(argc, argv, showLibrary);
#endif
}
