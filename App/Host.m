#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "Host.h"
#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

extern int launcher_main(int argc, char **argv);
extern void renios_library(void);
extern int SDL_PushEvent(void *event);
#if RENIOS_SDL3
extern int SDL_RunApp(int, char **, int (*)(int, char **), void *);
#else
extern int SDL_UIKitRunApp(int, char **, int (*)(int, char **));
#endif

typedef int (*EngineMain)(int, char **);
typedef int (*EnginePushEvent)(void *);
typedef void (*LegacyEventPump)(int);

static EnginePushEvent activePushEvent;
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
static Method keyboardMethod;
static IMP originalKeyboardUpdate;
static CGRect viewportAtInput;
static __weak UIView *probedViewport;

static void keepGameViewportInPlace(UIViewController *controller, SEL selector) {
    // SDL's UIKit implementation uses this callback solely to reposition
    // the render view around text input. Keep its original coordinate space.
    if (probeEnabled && !probedViewport && controller.view.window) {
        probedViewport = controller.view;
        viewportAtInput = [controller.view convertRect:controller.view.bounds toView:nil];
    }
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

int renios_play(const char *project, const char *saves, const char *engine, const char *orientation, int keyboardProbe) {
    NSString *version = @(engine);
    NSBundle *bundle = NSBundle.mainBundle;
    NSDictionary *namespaces = [bundle objectForInfoDictionaryKey:@"ReniosLegacyNamespaces"];
    NSString *prefix = namespaces[version];
    NSString *executable = bundle.executablePath;
    EngineMain entry = launcher_main;
    EnginePushEvent push = SDL_PushEvent;
    LegacyEventPump legacyEventPump = NULL;
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
        void (*mainReady)(void) = dlsym(handle, "SDL_SetMainReady");
        if (!entry || !push || !legacyEventPump || !mainReady) {
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
    keyboardMethod = controller ? class_getInstanceMethod(controller, sel_registerName("updateKeyboard")) : NULL;
    if (!keyboardMethod) {
        NSLog(@"Ren’Py %@ has no SDL keyboard hook for %@", version, controllerName);
        if (legacyEventPump) { legacyEventPump(0); }
        if (windowInitializer) { method_setImplementation(windowInitializer, previousWindowInitializer); }
        legacyScene = nil;
        return -2;
    }
    activePushEvent = push;

    probeEnabled = keyboardProbe != 0;
    originalKeyboardUpdate = method_setImplementation(keyboardMethod, (IMP)keepGameViewportInPlace);
    id observer = nil;
    NSTimer *quitProbe = nil;
    if (probeEnabled) {
        observer = [NSNotificationCenter.defaultCenter addObserverForName:UIKeyboardDidShowNotification
                        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            // Let UIKit deliver the rest of its layout callbacks first.
            dispatch_async(dispatch_get_main_queue(), ^{ writeKeyboardProbe(); });
        }];
        setenv("RENIOS_KEYBOARD_PROBE", "1", 1);
        unsetenv("RENIOS_QUIT_CONFIRMED");
        unsetenv("RENIOS_PROBE_ENGINE");
        NSURL *request = probeFile(@"renios-quit.request");
        quitProbe = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
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
    if (orientation[0]) { setenv(hint, orientation, 1); }
    if (prefix) { NSLog(@"Starting Ren’Py %@", version); }
    int status = entry(4, argv);
    if (prefix) { NSLog(@"Ren’Py %@ returned %d", version, status); }
    activePushEvent = NULL;
    if (legacyEventPump) { legacyEventPump(0); }
    if (windowInitializer) { method_setImplementation(windowInitializer, previousWindowInitializer); }
    legacyScene = nil;
    if (orientation[0]) { unsetenv(hint); }

    [quitProbe invalidate];
    if (probeEnabled) {
        const char *confirmed = getenv("RENIOS_QUIT_CONFIRMED");
        BOOL confirmationRan = confirmed && strcmp(confirmed, "1") == 0;
        const char *reported = getenv("RENIOS_PROBE_ENGINE");
        writeProbe(@{@"confirmed": confirmationRan ? @YES : @NO, @"exitStatus": @(status),
                     @"engine": reported ? @(reported) : @""}, @"renios-quit.json");
        unsetenv("RENIOS_QUIT_CONFIRMED");
        unsetenv("RENIOS_PROBE_ENGINE");
        unsetenv("RENIOS_KEYBOARD_PROBE");
    }
    if (observer) { [NSNotificationCenter.defaultCenter removeObserver:observer]; }
    method_setImplementation(keyboardMethod, originalKeyboardUpdate);
    probedViewport = nil;
    probeEnabled = NO;
    return status;
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
