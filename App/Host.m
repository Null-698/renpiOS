#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "Host.h"
#include <stdint.h>

extern int launcher_main(int argc, char **argv);
extern void renios_library(void);
extern int SDL_PushEvent(void *event);
#if RENIOS_SDL3
extern int SDL_RunApp(int, char **, int (*)(int, char **), void *);
#else
extern int SDL_UIKitRunApp(int, char **, int (*)(int, char **));
#endif

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

static void writeKeyboardProbe(void) {
    UIView *viewport = probedViewport;
    if (!viewport.window) { return; }

    CGRect current = [viewport convertRect:viewport.bounds toView:nil];
    NSDictionary *result = @{
        @"keyboardVisible": @YES,
        @"viewportStable": @(CGRectEqualToRect(viewportAtInput, current) &&
                             current.size.width > 0 && current.size.height > 0),
        @"before": NSStringFromCGRect(viewportAtInput),
        @"after": NSStringFromCGRect(current)
    };
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory
                                                        inDomains:NSUserDomainMask].firstObject;
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    [data writeToURL:[caches URLByAppendingPathComponent:@"renios-keyboard.json"]
             options:NSDataWritingAtomic error:nil];
}

int renios_play(const char *project, const char *saves, int keyboardProbe) {
    Class controller = NSClassFromString(@"SDL_uikitviewcontroller");
    keyboardMethod = controller ? class_getInstanceMethod(controller, sel_registerName("updateKeyboard")) : NULL;
    if (!keyboardMethod) { return -2; }

    probeEnabled = keyboardProbe != 0;
    originalKeyboardUpdate = method_setImplementation(keyboardMethod, (IMP)keepGameViewportInPlace);
    id observer = nil;
    if (probeEnabled) {
        observer = [NSNotificationCenter.defaultCenter addObserverForName:UIKeyboardDidShowNotification
                        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            // Let UIKit deliver the rest of its layout callbacks first.
            dispatch_async(dispatch_get_main_queue(), ^{ writeKeyboardProbe(); });
        }];
        setenv("RENIOS_KEYBOARD_PROBE", "1", 1);
    }

    setenv("RENPY_PLATFORM", "ios-arm64", 1);
    setenv("RENPY_DISABLE_FULLSCREEN", "1", 1);
    char *argv[] = {
        (char *)NSBundle.mainBundle.executablePath.fileSystemRepresentation,
        (char *)project, "--savedir", (char *)saves, NULL
    };
    int status = launcher_main(4, argv);

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
    SDL_PushEvent(&event);
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
