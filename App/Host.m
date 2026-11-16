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

extern int renios_engine_play(const char *, const char *, const char *);
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

typedef int (*EngineMain)(const char *, const char *, const char *);
typedef int (*EnginePushEvent)(void *);
typedef void (*LegacyEventPump)(int);

static EnginePushEvent activePushEvent;
static BOOL activeSDL3;
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

static IMP originalLayout;
static IMP originalTransition;
static IMP originalShouldBeginEditing;
static __weak UIViewController *gameController;
static CGSize lastViewportSize;
static BOOL keyboardDismissedByPlayer;
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

int renios_play(const char *project, const char *saves, const char *engine, const char *orientation) {
    NSString *version = @(engine);
    NSBundle *bundle = NSBundle.mainBundle;
    NSDictionary *namespaces = [bundle objectForInfoDictionaryKey:@"ReniosLegacyNamespaces"];
    NSString *prefix = namespaces[version];
    NSString *base = [bundle pathForResource:@"base" ofType:nil];
    if (!base) { return -3; }
    EngineMain entry = renios_engine_play;
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
        // Keep each framework and its CPython state alive between games.
        static NSMutableDictionary<NSString *, NSValue *> *loadedEngines;
        if (!loadedEngines) { loadedEngines = [NSMutableDictionary new]; }
        void *handle = loadedEngines[version].pointerValue;
        if (!handle) {
            handle = dlopen(framework.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL | RTLD_FIRST);
            if (handle) { loadedEngines[version] = [NSValue valueWithPointer:handle]; }
        }
        if (!handle) {
            NSLog(@"Ren’Py %@ could not load: %s", version, dlerror());
            return -3;
        }
        entry = (EngineMain)dlsym(handle, "renios_engine_play");
        push = (EnginePushEvent)dlsym(handle, "SDL_PushEvent");
        legacyEventPump = (LegacyEventPump)dlsym(handle, "renios_legacy_set_event_pump");
        startKeyboard = dlsym(handle, "renios_legacy_start_keyboard");
        void (*mainReady)(void) = dlsym(handle, "SDL_SetMainReady");
        if (!entry || !push || !legacyEventPump || !mainReady || !startKeyboard) {
            NSLog(@"Ren’Py %@ is missing a runtime entry point", version);
            return -3;
        }

        base = [base stringByAppendingPathComponent:[NSString stringWithFormat:@"Engines/%@/base", version]];
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
        if (implementation == (IMP)attachLegacyWindow) {
            legacyWindowInit = (void *)class_getMethodImplementation(class_getSuperclass(windowClass), selector);
        } else {
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
    activeSDL3 = RENIOS_SDL3 && !prefix;
    activeStartKeyboard = startKeyboard;
    keyboardDismissedByPlayer = NO;

    IMP originalKeyboardUpdate = installViewportHook(controller, updateKeyboardSelector, (IMP)updateGameKeyboardLayout);
    SEL layoutSelector = @selector(viewDidLayoutSubviews);
    originalLayout = installViewportHook(controller, layoutSelector, (IMP)layoutGameViewport);
    SEL transitionSelector = @selector(viewWillTransitionToSize:withTransitionCoordinator:);
    originalTransition = installViewportHook(controller, transitionSelector, (IMP)transitionGameViewport);
    SEL editingSelector = @selector(textFieldShouldBeginEditing:);
    originalShouldBeginEditing = installViewportHook(controller, editingSelector, (IMP)allowGameKeyboardFocus);
    if (originalShouldBeginEditing == (IMP)allowGameKeyboardFocus) { originalShouldBeginEditing = NULL; }
    if (!originalShouldBeginEditing) {
        char types[16];
        snprintf(types, sizeof(types), "%s@:@", @encode(BOOL));
        class_addMethod(controller, editingSelector, (IMP)allowGameKeyboardFocus, types);
    }
    setenv("RENPY_PLATFORM", "ios-arm64", 1);
    setenv("RENPY_DISABLE_FULLSCREEN", "1", 1);
    const char *hint = (RENIOS_SDL3 && !prefix) ? "SDL_ORIENTATIONS" : "SDL_IOS_ORIENTATIONS";
    const char *requestedOrientation = orientation[0] ? orientation : NULL;
    if (requestedOrientation) { setenv(hint, requestedOrientation, 1); }
    NSLog(@"Starting Ren’Py %@ for %s", version, project);
    int status = entry(base.fileSystemRepresentation, project, saves);
    NSLog(@"Ren’Py %@ returned %d", version, status);
    activePushEvent = NULL;
    activeStartKeyboard = NULL;
    keyboardDismissedByPlayer = NO;
    gameController = nil;
    lastViewportSize = CGSizeZero;
    if (legacyEventPump) { legacyEventPump(0); }
    if (windowInitializer) { method_setImplementation(windowInitializer, previousWindowInitializer); }
    legacyScene = nil;
    if (requestedOrientation) { unsetenv(hint); }

    method_setImplementation(class_getInstanceMethod(controller, updateKeyboardSelector), originalKeyboardUpdate);
    if (originalLayout) { method_setImplementation(class_getInstanceMethod(controller, layoutSelector), originalLayout); }
    if (originalTransition) { method_setImplementation(class_getInstanceMethod(controller, transitionSelector), originalTransition); }
    if (originalShouldBeginEditing) {
        method_setImplementation(class_getInstanceMethod(controller, editingSelector), originalShouldBeginEditing);
    }
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

void renios_playback_key(int scancode, int keycode) {
    if (!activePushEvent) { return; }
    // SDL2 and SDL3 keep the same event numbers but use different keyboard layouts.
    union {
        uint64_t storage[32];
        struct {
            uint32_t type, timestamp, windowID;
            uint8_t down, repeat, padding[2];
            int32_t scancode, key;
            uint16_t modifiers;
            uint32_t unused;
        } sdl2;
        struct {
            uint32_t type, reserved;
            uint64_t timestamp;
            uint32_t windowID, keyboardID;
            int32_t scancode;
            uint32_t key;
            uint16_t modifiers, raw;
            bool down, repeat;
        } sdl3;
    } event = {0};
    for (int down = 1; down >= 0; --down) {
        if (activeSDL3) {
            event.sdl3.type = down ? 0x300 : 0x301;
            event.sdl3.scancode = scancode;
            event.sdl3.key = (uint32_t)keycode;
            event.sdl3.down = down != 0;
        } else {
            event.sdl2.type = down ? 0x300 : 0x301;
            event.sdl2.scancode = scancode;
            event.sdl2.key = keycode;
            event.sdl2.down = (uint8_t)down;
        }
        activePushEvent(&event);
    }
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
