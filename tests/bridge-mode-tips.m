// Standalone bridge tests: no host process, preferences, IPC, or real animations.
#define WT_BRIDGE_TESTING 1
#import "../src/bridge.m"
#include <assert.h>

@interface WTTestController : NSObject
@property(nonatomic, copy) NSString *bundleIdentifier;
- (id)client;
- (void)commitComposition:(id)client;
@end
@implementation WTTestController
- (id)client { return self; }
- (void)commitComposition:(id)client { (void)client; }
@end

static WTTestController *current;
static BOOL asciiMode, modeKnown, active, actionWorks, invalidateController, changeSource, throwTip;
static unsigned actions, tips;
static BOOL lastTipASCII;
static NSString *sourceID;

@interface WTTestDelegate : NSObject
- (void)changeInputMode;
@end
@implementation WTTestDelegate
- (void)changeInputMode {
    actions++;
    if (actionWorks) asciiMode = !asciiMode;
    if (invalidateController) current = nil;
    if (changeSource) sourceID = @"other-source";
}
@end

// NSApp is only used to fetch the delegate. Do not initialize a GUI application.
@interface WTTestApplication : NSObject
@property(nonatomic, strong) id delegate;
@end
@implementation WTTestApplication
@end

@interface WTTestBridge : WTLabBridge
@property(nonatomic, strong) NSDictionary *lastReply;
@end
@implementation WTTestBridge
- (void)emitReply:(NSDictionary *)reply { self.lastReply = reply; }
@end

NSDictionary *WTTestSourceInfo(void) {
    return @{ @"activeWeType": @(active), @"inputSource": sourceID };
}
BOOL WTStateInitialize(NSString **error) { (void)error; return YES; }
BOOL WTIsCurrentController(id controller) { return controller && controller == current; }
NSString *WTBundleForController(id controller) { return [controller bundleIdentifier]; }
BOOL WTReadModeForController(id controller, BOOL *ascii, NSString **error) {
    (void)error;
    if (!modeKnown || !WTIsCurrentController(controller)) return NO;
    *ascii = asciiMode;
    return YES;
}
BOOL WTReadMode(id *controller, BOOL *ascii, NSString **error) {
    *controller = current;
    return WTReadModeForController(current, ascii, error);
}
void WTShowModeTips(id controller, BOOL ascii) {
    assert(WTIsCurrentController(controller));
    assert(ascii == asciiMode);
    if (throwTip) [NSException raise:@"TestTipFailure" format:@"cosmetic failure"];
    tips++;
    lastTipASCII = ascii;
}

static WTTestBridge *setup(void) {
    current = [WTTestController new];
    current.bundleIdentifier = @"test.target";
    asciiMode = modeKnown = active = actionWorks = YES;
    invalidateController = changeSource = throwTip = NO;
    sourceID = @"test.wetype";
    actions = tips = 0;
    WTTestBridge *value = [WTTestBridge new];
    value.appModes = [NSMutableDictionary dictionary];
    value.fixedAppModes = [NSMutableDictionary dictionary];
    value.automaticModeManagement = YES;
    value.frontBundle = current.bundleIdentifier;
    return value;
}

static NSDictionary *request(NSString *operation) {
    return @{ @"requestID": NSUUID.UUID.UUIDString, @"operation": operation,
              @"deadline": @([NSDate date].timeIntervalSince1970 + 5) };
}

int main(void) {
    @autoreleasepool {
        WTTestApplication *app = [WTTestApplication new];
        app.delegate = [WTTestDelegate new];
        NSApp = (NSApplication *)app;

        WTTestBridge *value = setup();
        NSDictionary *toggle = request(@"toggle");
        [value processRequest:toggle];
        assert(actions == 1 && tips == 1 && !lastTipASCII);
        assert([value.lastReply[@"ok"] boolValue]);
        [value processRequest:toggle]; // Cached request must not replay animation.
        assert(actions == 1 && tips == 1);
        [value processRequest:request(@"english")];
        assert(actions == 2 && tips == 2 && lastTipASCII);
        [value processRequest:request(@"english")];
        assert(actions == 2 && tips == 2); // Idempotent set.
        [value processRequest:request(@"status")];
        assert(actions == 2 && tips == 2);

        value = setup();
        value.frontBundle = @"test.outgoing";
        value.appModes[current.bundleIdentifier] = @"chinese";
        [value activateController:current];
        assert(actions == 1 && tips == 1 && !lastTipASCII);
        [value activateController:current];
        assert(actions == 1 && tips == 1);
        WTTestController *replacement = [WTTestController new];
        replacement.bundleIdentifier = current.bundleIdentifier;
        current = replacement;
        [value activateController:current];
        assert(actions == 1 && tips == 1); // Same app, new controller.

        value = setup();
        value.frontBundle = @"test.outgoing";
        [value activateController:current]; // Already English (default).
        assert(actions == 0 && tips == 0);
        value.automaticModeManagement = NO;
        value.appModes[current.bundleIdentifier] = @"chinese";
        [value restoreCurrentMode];
        assert(actions == 0 && tips == 0);
        [value processRequest:request(@"toggle")]; // auto-off does not disable manual tips.
        assert(actions == 1 && tips == 1);

        for (unsigned scenario = 0; scenario < 4; scenario++) {
            value = setup();
            if (scenario == 0) modeKnown = NO;
            if (scenario == 1) actionWorks = NO;
            if (scenario == 2) invalidateController = YES;
            if (scenario == 3) changeSource = YES;
            [value processRequest:request(@"chinese")];
            assert(tips == 0 && ![value.lastReply[@"ok"] boolValue]);

            value = setup();
            value.fixedAppModes[current.bundleIdentifier] = @"chinese";
            if (scenario == 0) modeKnown = NO;
            if (scenario == 1) actionWorks = NO;
            if (scenario == 2) invalidateController = YES;
            if (scenario == 3) changeSource = YES;
            [value restoreCurrentMode];
            assert(tips == 0);
        }

        value = setup();
        active = NO;
        [value processRequest:request(@"toggle")];
        assert(actions == 0 && tips == 0);
        value.fixedAppModes[current.bundleIdentifier] = @"chinese";
        [value restoreCurrentMode];
        assert(actions == 0 && tips == 0);

        value = setup();
        NSMutableDictionary *configure = [request(@"app-set") mutableCopy];
        configure[@"bundleID"] = current.bundleIdentifier;
        configure[@"mode"] = @"chinese";
        [value processRequest:configure];
        assert(actions == 1 && tips == 1 && !lastTipASCII);

        value = setup();
        throwTip = YES;
        [value processRequest:request(@"toggle")];
        assert(actions == 1 && tips == 0 && !asciiMode);
        assert([value.lastReply[@"ok"] boolValue]);
        assert([value.lastReply[@"stateKnown"] boolValue]);
        assert([value.appModes[current.bundleIdentifier] isEqual:@"chinese"]);

        value = setup();
        value.stopped = YES;
        [value processRequest:request(@"toggle")];
        value.fixedAppModes[current.bundleIdentifier] = @"chinese";
        [value restoreCurrentMode];
        assert(actions == 0 && tips == 0);

        NSApp = nil;
        puts("bridge mode-tip tests passed");
    }
    return 0;
}
