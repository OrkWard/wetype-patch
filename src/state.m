#import <AppKit/AppKit.h>
#import <InputMethodKit/InputMethodKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <dlfcn.h>
#import <stdbool.h>
#import <string.h>
#import "state.h"
#import "state-profile.h" // Generated from an explicitly reviewed version profile.

typedef void *(*WTWeakLoad)(void *);
typedef bool (*WTGetter)(void *context __attribute__((swift_context))) __attribute__((swiftcall));
typedef void *(*WTSessionGetter)(void *context __attribute__((swift_context))) __attribute__((swiftcall));
typedef uintptr_t (*WTSessionIDGetter)(void *context __attribute__((swift_context))) __attribute__((swiftcall));
typedef void (*WTModeTips)(uintptr_t sessionID, uint8_t type, bool ascii) __attribute__((swiftcall));
typedef void (*WTSwiftRelease)(void *object);
static WTWeakLoad weakLoad;
static WTGetter getter;
static WTSessionGetter sessionGetter;
static WTSessionIDGetter sessionIDGetter;
static WTModeTips modeTips;
static WTSwiftRelease swiftRelease;
static uintptr_t controllerSlot, controllerInitToken;
static BOOL ready;

static BOOL fail(NSString **error, NSString *message) {
    if (error) *error = message;
    return NO;
}

BOOL WTStateInitialize(NSString **error) {
    if (![NSThread isMainThread]) return fail(error, @"State reader requires main thread");
    if (ready) return YES;
    if (![[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] isEqual:@WT_HOST_VERSION] ||
        ![[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] isEqual:@WT_HOST_BUILD])
        return fail(error, @"Unreviewed host version");
    const struct mach_header_64 *header = (const void *)_dyld_get_image_header(0);
    if (!header || header->magic != MH_MAGIC_64 || header->filetype != MH_EXECUTE)
        return fail(error, @"Unexpected main image");
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    const struct section_64 *text = getsectbynamefromheader_64(header, "__TEXT", "__text");
    if (!text || text->size == 0 || text->size > UINT32_MAX)
        return fail(error, @"Invalid host code section");
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256((const void *)(text->addr + slide), (CC_LONG)text->size, digest);
    if (memcmp(digest, WT_TEXT_SHA256, sizeof(digest)) != 0)
        return fail(error, @"Host code fingerprint mismatch; private ABI disabled");
    weakLoad = (WTWeakLoad)dlsym(RTLD_DEFAULT, "swift_unknownObjectWeakLoadStrong");
    swiftRelease = (WTSwiftRelease)dlsym(RTLD_DEFAULT, "swift_release");
    if (!weakLoad || !swiftRelease) return fail(error, @"Swift reference runtime unavailable");
    getter = (WTGetter)(WT_GETTER_ADDRESS + slide);
    sessionGetter = (WTSessionGetter)(WT_SESSION_GETTER_ADDRESS + slide);
    sessionIDGetter = (WTSessionIDGetter)(WT_SESSION_ID_GETTER_ADDRESS + slide);
    modeTips = (WTModeTips)(WT_MODE_TIPS_ADDRESS + slide);
    controllerSlot = WT_CONTROLLER_SLOT + slide;
    controllerInitToken = WT_CONTROLLER_INIT_TOKEN + slide;
    ready = YES;
    return YES;
}

static id currentController(void) {
    if (!ready || ![NSThread isMainThread]) return nil;
    intptr_t token = 0;
    memcpy(&token, (const void *)controllerInitToken, sizeof(token));
    // Do not operate on uninitialized Swift weak storage or force initialization.
    if (token != -1) return nil;
    // Swift runtime returns a +1 reference; transfer it to ARC, never dereference
    // the weak-storage bits as though they were an object pointer.
    id controller = (__bridge_transfer id)weakLoad((void *)controllerSlot);
    Class expected = NSClassFromString(@"WeType.InputController");
    if (!expected || ![controller isKindOfClass:expected]) return nil;
    return controller;
}

BOOL WTIsCurrentController(id controller) {
    return controller && currentController() == controller;
}

NSString *WTBundleForController(id controller) {
    return [[(IMKInputController *)controller client] bundleIdentifier];
}

BOOL WTReadModeForController(id controller, BOOL *ascii, NSString **error) {
    if (!WTIsCurrentController(controller)) return fail(error, @"No stable current input controller");
    // Clang's swift_context attribute supplies self in x20 / r13. No manual
    // register assembly, no Swift String ABI, and no raw state writes.
    *ascii = getter((__bridge void *)controller);
    if (!WTIsCurrentController(controller)) return fail(error, @"Input controller changed during read");
    return YES;
}

void WTShowModeTips(id controller, BOOL ascii) {
    BOOL current = NO;
    if (!ready || !WTReadModeForController(controller, &current, NULL) || current != ascii) return;
    // Reviewed arm64 Swift ABI, protected by the same version/text fingerprint.
    // The native getter returns +1; InputSession is a Swift object, not an ARC id.
    void *session = sessionGetter((__bridge void *)controller);
    if (!session) return;
    uintptr_t sessionID;
    @try {
        sessionID = sessionIDGetter(session);
    } @finally {
        swiftRelease(session);
    }
    if (!WTReadModeForController(controller, &current, NULL) || current != ascii) return;
    // Tag 0 is Chinese/English, as used by native switchInputMode. This specialized
    // entry has no metatype argument. Native code handles cursor lookup/animation;
    // a missing cursor rect simply skips the tip. No delayed retries or key hooks.
    modeTips(sessionID, 0, ascii != NO);
}

BOOL WTReadMode(id *controller, BOOL *ascii, NSString **error) {
    if (!ready) return fail(error, @"State reader unavailable for this host");
    id value = currentController();
    if (!value) return fail(error, @"No current WeType input session");
    if (!WTReadModeForController(value, ascii, error)) return NO;
    *controller = value;
    return YES;
}
