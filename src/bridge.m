#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <InputMethodKit/InputMethodKit.h>
#import <objc/message.h>
#include <math.h>
#include <unistd.h>
#import "bridge-protocol.h"
#import "state.h"

static NSString * const WTAutoDefaultsSuite = @"local.orkward.wetype.patch";
static NSString * const WTAppModesKey = @"appModes";
static NSString * const WTFixedAppModesKey = @"fixedAppModes";
static NSString * const WTAutoEnabledKey = @"automaticModeManagement";

@interface WTLabBridge : NSObject
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *replies;
@property(nonatomic, strong) NSMutableArray<NSString *> *order;
@property(nonatomic, strong) NSUserDefaults *autoDefaults;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *appModes;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *fixedAppModes;
@property(nonatomic, copy) NSString *frontBundle;
@property(nonatomic) BOOL automaticModeManagement;
@property(nonatomic) BOOL stopped;
- (void)receive:(NSNotification *)notification;
- (void)processRequest:(NSDictionary *)request;
- (void)emitReply:(NSDictionary *)reply;
- (void)startAutomaticModeManagement;
- (void)activateController:(id)controller;
- (void)restoreCurrentMode;
- (void)rememberASCII:(BOOL)ascii forBundle:(NSString *)bundle;
- (NSDictionary *)automaticStatus;
- (void)recordExplicitASCII:(BOOL)ascii controller:(id)controller;
- (void)showModeTipsForController:(id)controller ascii:(BOOL)ascii inputSource:(NSString *)inputSource;
@end

static WTLabBridge *bridge;

// A private selector retaining its name across releases is not sufficient:
// reject an incompatible ABI rather than calling it through objc_msgSend.
static BOOL actionAvailable(id delegate) {
    SEL selector = NSSelectorFromString(@"changeInputMode");
    if (![delegate respondsToSelector:selector]) return NO;
    NSMethodSignature *signature = [delegate methodSignatureForSelector:selector];
    return signature && signature.numberOfArguments == 2 &&
        strcmp(signature.methodReturnType, @encode(void)) == 0;
}

#ifdef WT_BRIDGE_TESTING
extern NSDictionary *WTTestSourceInfo(void);
static NSDictionary *sourceInfo(void) { return WTTestSourceInfo(); }
#else
static NSDictionary *sourceInfo(void) {
    TISInputSourceRef source = TISCopyCurrentKeyboardInputSource();
    NSString *bundle = source ? (__bridge NSString *)TISGetInputSourceProperty(source, kTISPropertyBundleID) : nil;
    NSString *identifier = source ? (__bridge NSString *)TISGetInputSourceProperty(source, kTISPropertyInputSourceID) : nil;
    NSDictionary *info = @{ @"activeWeType": @([bundle isEqualToString:WTBundleID]),
        @"inputSource": identifier ?: @"", @"pid": @(getpid()), @"protocol": @1,
        @"bridgeVersion": WTBridgeVersion,
        @"hostVersion": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"",
        @"hostBuild": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"" };
    if (source) CFRelease(source);
    return info;
}
#endif

@implementation WTLabBridge
- (instancetype)init {
    if ((self = [super init])) {
        _replies = [NSMutableDictionary dictionary];
        _order = [NSMutableArray array];
    }
    return self;
}
- (void)rememberASCII:(BOOL)ascii forBundle:(NSString *)bundle {
    if (!bundle.length) return;
    NSString *mode = ascii ? @"english" : @"chinese";
    if ([self.appModes[bundle] isEqualToString:mode]) return;
    self.appModes[bundle] = mode;
    [self.autoDefaults setObject:[self.appModes copy] forKey:WTAppModesKey];
}
- (void)activateController:(id)controller {
    if (self.stopped || ![NSThread isMainThread] || !WTIsCurrentController(controller)) return;
    NSString *bundle = WTBundleForController(controller);
    if (!bundle.length || [bundle isEqualToString:self.frontBundle]) return;
    BOOL ascii = NO;
    if (!WTReadModeForController(controller, &ascii, NULL)) return;
    // All clients read the same native mode. It is still the outgoing app's
    // value here; changing currentInputController no longer selects another mode.
    if (self.automaticModeManagement) [self rememberASCII:ascii forBundle:self.frontBundle];
    self.frontBundle = bundle;
    [self restoreCurrentMode];
}
- (void)restoreCurrentMode {
    if (!self.automaticModeManagement || self.stopped || !self.frontBundle.length) return;
    NSDictionary *source = sourceInfo();
    if (![source[@"activeWeType"] boolValue]) return;
    id controller = nil;
    BOOL ascii = NO;
    NSString *error = nil;
    if (!WTReadMode(&controller, &ascii, &error) ||
        ![WTBundleForController(controller) isEqualToString:self.frontBundle]) return;
    NSString *mode = self.fixedAppModes[self.frontBundle] ?: self.appModes[self.frontBundle];
    BOOL desired = ![mode isEqualToString:@"chinese"];
    if (ascii == desired) return;
    id delegate = NSApp.delegate;
    if (!actionAvailable(delegate) || !WTIsCurrentController(controller) ||
        ![sourceInfo()[@"inputSource"] isEqual:source[@"inputSource"]]) return;
    ((void (*)(id, SEL))objc_msgSend)(delegate, NSSelectorFromString(@"changeInputMode"));
    BOOL after = NO;
    if (!WTReadModeForController(controller, &after, &error) || after != desired ||
        ![sourceInfo()[@"inputSource"] isEqual:source[@"inputSource"]]) {
        NSLog(@"[WeTypeBridge] mode result unknown for %@: %@", self.frontBundle,
            error ?: @"target state not verified");
    } else {
        [self showModeTipsForController:controller ascii:after inputSource:source[@"inputSource"]];
    }
    // The application has already been recorded above. Never retry this activation.
}
- (NSDictionary *)automaticStatus {
    return @{ @"automaticModeManagement": @(self.automaticModeManagement),
        @"defaultMode": @"english", @"frontmostBundle": self.frontBundle ?: @"",
        @"appModes": [self.appModes copy] ?: @{},
        @"fixedAppModes": [self.fixedAppModes copy] ?: @{} };
}
- (void)recordExplicitASCII:(BOOL)ascii controller:(id)controller {
    if (!self.automaticModeManagement || !controller) return;
    [self rememberASCII:ascii forBundle:WTBundleForController(controller)];
}
- (void)showModeTipsForController:(id)controller ascii:(BOOL)ascii inputSource:(NSString *)inputSource {
    // Cosmetic failure must never turn a successful toggle into an unknown result.
    @try {
        NSDictionary *source = sourceInfo();
        if (self.stopped || ![source[@"activeWeType"] boolValue] ||
            ![source[@"inputSource"] isEqual:inputSource] || !WTIsCurrentController(controller)) return;
        WTShowModeTips(controller, ascii);
    } @catch (NSException *exception) {
        NSLog(@"[WeTypeBridge] mode tip skipped: %@", exception.name);
    }
}
- (void)startAutomaticModeManagement {
    self.autoDefaults = [[NSUserDefaults alloc] initWithSuiteName:WTAutoDefaultsSuite];
    self.appModes = [NSMutableDictionary dictionary];
    NSDictionary *storedModes = [self.autoDefaults dictionaryForKey:WTAppModesKey];
    [storedModes enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        (void)stop;
        if ([key isKindOfClass:[NSString class]] && [key length] > 0 &&
            ([value isEqual:@"chinese"] || [value isEqual:@"english"])) self.appModes[key] = value;
    }];
    self.fixedAppModes = [NSMutableDictionary dictionary];
    NSDictionary *fixedModes = [self.autoDefaults dictionaryForKey:WTFixedAppModesKey];
    [fixedModes enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        (void)stop;
        if ([key isKindOfClass:[NSString class]] && [key length] > 0 &&
            ([value isEqual:@"chinese"] || [value isEqual:@"english"])) self.fixedAppModes[key] = value;
    }];
    id enabled = [self.autoDefaults objectForKey:WTAutoEnabledKey];
    self.automaticModeManagement = enabled ? [enabled boolValue] : YES;
}
- (void)emitReply:(NSDictionary *)reply {
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:WTReplyName object:nil
        userInfo:reply deliverImmediately:YES];
}
- (void)receive:(NSNotification *)notification {
    if (![notification.userInfo isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *request = [notification.userInfo copy];
    // Never mutate input-method state off the main thread.
    dispatch_async(dispatch_get_main_queue(), ^{ [self processRequest:request]; });
}
- (void)processRequest:(NSDictionary *)request {
    NSAssert([NSThread isMainThread], @"main thread required");
    if (self.stopped) return;
    NSString *identifier = request[@"requestID"];
    NSString *operation = request[@"operation"];
    NSNumber *deadline = request[@"deadline"];
    if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0 || identifier.length > 128 ||
        ![operation isKindOfClass:[NSString class]] || ![deadline isKindOfClass:[NSNumber class]]) return;
    NSDistributedNotificationCenter *center = [NSDistributedNotificationCenter defaultCenter];
    NSDictionary *cached = self.replies[identifier];
    if (cached) {
        [self emitReply:cached];
        return;
    }
    NSMutableDictionary *reply = [sourceInfo() mutableCopy];
    reply[@"requestID"] = identifier;
    reply[@"operation"] = operation;
    reply[@"ok"] = @NO;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    double expiry = deadline.doubleValue;
    if (!isfinite(expiry) || expiry < now || expiry > now + 15) {
        reply[@"error"] = @"Expired or invalid request deadline";
    } else if ([@[@"auto-status", @"apps", @"auto-on", @"auto-off"] containsObject:operation]) {
        if ([operation isEqualToString:@"auto-on"] || [operation isEqualToString:@"auto-off"]) {
            self.automaticModeManagement = [operation isEqualToString:@"auto-on"];
            [self.autoDefaults setBool:self.automaticModeManagement forKey:WTAutoEnabledKey];
            if (self.automaticModeManagement) [self restoreCurrentMode];
        }
        [reply addEntriesFromDictionary:[self automaticStatus]];
        reply[@"ok"] = @YES;
    } else if ([@[@"app-set", @"app-forget"] containsObject:operation]) {
        NSString *bundle = request[@"bundleID"];
        NSString *mode = request[@"mode"];
        if (![bundle isKindOfClass:[NSString class]] || bundle.length == 0 || bundle.length > 255) {
            reply[@"error"] = @"Invalid bundle ID";
        } else if ([operation isEqualToString:@"app-set"] &&
            !([mode isEqualToString:@"chinese"] || [mode isEqualToString:@"english"])) {
            reply[@"error"] = @"Mode must be chinese or english";
        } else {
            if ([operation isEqualToString:@"app-forget"]) {
                [self.fixedAppModes removeObjectForKey:bundle];
            } else {
                self.fixedAppModes[bundle] = mode;
            }
            [self.autoDefaults setObject:[self.fixedAppModes copy] forKey:WTFixedAppModesKey];
            if ([bundle isEqualToString:self.frontBundle])
                [self restoreCurrentMode];
            [reply addEntriesFromDictionary:[self automaticStatus]];
            reply[@"configuredBundle"] = bundle;
            reply[@"ok"] = @YES;
        }
    } else if ([@[@"status", @"toggle", @"chinese", @"english"] containsObject:operation]) {
        @try {
            id controller = nil;
            BOOL before = NO;
            NSString *stateError = nil;
            BOOL active = [reply[@"activeWeType"] boolValue];
            BOOL known = active && WTReadMode(&controller, &before, &stateError);
            reply[@"mode"] = known ? (before ? @"english" : @"chinese") : @"unknown";
            reply[@"stateKnown"] = @(known);
            if (!active) stateError = @"WeType is not the selected input source";
            if (stateError) reply[@"stateError"] = stateError;
            if ([operation isEqualToString:@"status"]) {
                // ok = IPC healthy; stateKnown separately describes mode validity.
                [reply addEntriesFromDictionary:[self automaticStatus]];
                reply[@"ok"] = @YES;
            } else if (!known) {
                reply[@"error"] = stateError ?: @"Cannot establish current mode";
            } else {
                BOOL desired = [operation isEqualToString:@"toggle"] ? !before : [operation isEqualToString:@"english"];
                reply[@"before"] = before ? @"english" : @"chinese";
                id delegate = NSApp.delegate;
                SEL selector = NSSelectorFromString(@"changeInputMode");
                if (!actionAvailable(delegate) || !WTIsCurrentController(controller) ||
                    ![sourceInfo()[@"inputSource"] isEqual:reply[@"inputSource"]]) {
                    reply[@"error"] = @"Input target/action changed before operation";
                } else if (before == desired) {
                    // An explicit set also finishes preedit without toggling the mode.
                    [(IMKInputController *)controller commitComposition:[(IMKInputController *)controller client]];
                    reply[@"ok"] = @YES;
                    reply[@"changed"] = @NO;
                    reply[@"actionInvoked"] = @NO;
                    [self recordExplicitASCII:desired controller:controller];
                } else {
                    // Read/compare/action/verify are serialized on the main queue.
                    // A set request already in its desired mode NEVER calls toggle.
                    [(IMKInputController *)controller commitComposition:[(IMKInputController *)controller client]];
                    reply[@"actionInvoked"] = @YES;
                    ((void (*)(id, SEL))objc_msgSend)(delegate, selector);
                    BOOL after = NO;
                    BOOL verified = WTReadModeForController(controller, &after, &stateError) &&
                        [sourceInfo()[@"inputSource"] isEqual:reply[@"inputSource"]];
                    reply[@"stateKnown"] = @(verified);
                    reply[@"mode"] = verified ? (after ? @"english" : @"chinese") : @"unknown";
                    if (verified && after == desired) {
                        reply[@"ok"] = @YES;
                        reply[@"changed"] = after != before ? @YES : @NO;
                        [self recordExplicitASCII:after controller:controller];
                        [self showModeTipsForController:controller ascii:after inputSource:reply[@"inputSource"]];
                    } else {
                        reply[@"error"] = stateError ?: @"Action returned but target state was not verified";
                    }
                }
            }
        } @catch (NSException *exception) {
            reply[@"error"] = exception.name;
            reply[@"stateKnown"] = @NO;
            reply[@"mode"] = @"unknown";
        }
    } else if ([operation isEqualToString:@"stop"]) {
        reply[@"ok"] = @YES;
    } else {
        reply[@"error"] = @"Unknown operation";
    }
    // Prevent duplicate delivery from toggling twice. No client retries.
    self.replies[identifier] = [reply copy];
    [self.order addObject:identifier];
    if (self.order.count > 128) {
        [self.replies removeObjectForKey:self.order.firstObject];
        [self.order removeObjectAtIndex:0];
    }
    [self emitReply:reply];
    if ([operation isEqualToString:@"stop"] && [reply[@"ok"] boolValue]) {
        self.stopped = YES;
        [center removeObserver:self];
    }
}
@end

__attribute__((visibility("default")))
int WTBridgeStart(void) {
    if (![NSThread isMainThread]) return 1;
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:WTBundleID]) return 2;
    if (!NSApp || !NSApp.delegate) return 3;
    if (!actionAvailable(NSApp.delegate)) return 4;
    if (bridge) return 0;
    NSString *stateError = nil;
    if (!WTStateInitialize(&stateError)) {
        NSLog(@"[WeTypeBridge] %@", stateError);
        return 5;
    }
    bridge = [WTLabBridge new];
    [bridge startAutomaticModeManagement];
    [[NSDistributedNotificationCenter defaultCenter] addObserver:bridge selector:@selector(receive:)
        name:WTRequestName object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    return 0;
}

// Called synchronously by the patched mode-decision block in activateServer.
__attribute__((visibility("default")))
void WTBridgeActivate(id controller) {
    if (![NSThread isMainThread]) return;
    if (!bridge && WTBridgeStart() != 0) return;
    [bridge activateController:controller];
}

#ifndef WT_BRIDGE_TESTING
static void tryAutomaticStart(unsigned attempt) {
    // The main queue only gets this work once dyld has finished initialization.
    // Do not create NSApplication or replace the host's delegate ourselves.
    int result = (NSApp && NSApp.isRunning) ? WTBridgeStart() : 3;
    if (result == 0) {
        NSLog(@"[WeTypeBridge] %@ ready (pid %d)", WTBridgeVersion, getpid());
        return;
    }
    if (result != 3 || attempt >= 240) {
        NSLog(@"[WeTypeBridge] startup refused/timed out (code %d); input method left unchanged", result);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
        dispatch_get_main_queue(), ^{ tryAutomaticStart(attempt + 1); });
}

__attribute__((constructor))
static void WTBridgeInitialize(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ tryAutomaticStart(0); });
}
#endif
