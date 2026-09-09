#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <objc/message.h>
#include <math.h>
#include <unistd.h>
#import "bridge-protocol.h"
#import "state.h"

static NSString * const WTAutoDefaultsSuite = @"local.orkward.wetype.patch";
static NSString * const WTAppModesKey = @"appModes";
static NSString * const WTAutoEnabledKey = @"automaticModeManagement";
static const NSTimeInterval WTEnforcementWindow = 2.0;

@interface WTLabBridge : NSObject
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *replies;
@property(nonatomic, strong) NSMutableArray<NSString *> *order;
@property(nonatomic, strong) NSUserDefaults *autoDefaults;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *appModes;
@property(nonatomic, strong) NSTimer *modeTimer;
@property(nonatomic, copy) NSString *frontBundle;
@property(nonatomic, copy) NSString *pendingBundle;
@property(nonatomic) BOOL pendingDesiredASCII;
@property(nonatomic) NSTimeInterval pendingEnforceUntil;
@property(nonatomic, weak) id blockedController;
@property(nonatomic, weak) id lastController;
@property(nonatomic, weak) id unsafeController;
@property(nonatomic) BOOL waitForNewController;
@property(nonatomic) BOOL transitioning;
@property(nonatomic) BOOL automaticModeManagement;
@property(nonatomic) BOOL stopped;
- (void)receive:(NSNotification *)notification;
- (void)processRequest:(NSDictionary *)request;
- (void)emitReply:(NSDictionary *)reply;
- (void)startAutomaticModeManagement;
- (void)stopAutomaticModeManagement;
- (void)workspaceDidActivate:(NSNotification *)notification;
- (void)workspaceDidDeactivate:(NSNotification *)notification;
- (void)checkAutomaticMode:(NSTimer *)timer;
- (void)beginRestoreForBundle:(NSString *)bundle waitForNewController:(BOOL)wait;
- (void)rememberASCII:(BOOL)ascii forBundle:(NSString *)bundle;
- (NSDictionary *)automaticStatus;
- (void)recordExplicitASCII:(BOOL)ascii controller:(id)controller;
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
- (void)beginRestoreForBundle:(NSString *)bundle waitForNewController:(BOOL)wait {
    if (!self.automaticModeManagement || !bundle.length) return;
    self.pendingBundle = bundle;
    self.pendingDesiredASCII = ![self.appModes[bundle] isEqualToString:@"chinese"];
    self.pendingEnforceUntil = 0;
    self.waitForNewController = wait;
    self.unsafeController = nil;
}
- (void)workspaceDidDeactivate:(NSNotification *)notification {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self workspaceDidDeactivate:notification]; });
        return;
    }
    NSRunningApplication *application = notification.userInfo[NSWorkspaceApplicationKey];
    if (self.frontBundle.length && [application.bundleIdentifier isEqualToString:self.frontBundle]) {
        // The timer has already recorded the last stable value. Do not read here:
        // IMK may have moved currentInputController to the next app before this callback.
        self.blockedController = self.lastController;
        self.transitioning = YES;
    }
}
- (void)workspaceDidActivate:(NSNotification *)notification {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self workspaceDidActivate:notification]; });
        return;
    }
    NSRunningApplication *application = notification.userInfo[NSWorkspaceApplicationKey];
    NSString *bundle = application.bundleIdentifier;
    if (!bundle.length) return;
    self.frontBundle = bundle;
    self.transitioning = NO;
    [self beginRestoreForBundle:bundle waitForNewController:self.blockedController != nil];
}
- (void)checkAutomaticMode:(NSTimer *)timer {
    (void)timer;
    if (!self.automaticModeManagement || self.transitioning || self.stopped) return;
    NSString *actualBundle = NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier;
    if (actualBundle.length && ![actualBundle isEqualToString:self.frontBundle]) {
        self.blockedController = self.lastController;
        self.frontBundle = actualBundle;
        [self beginRestoreForBundle:actualBundle waitForNewController:self.blockedController != nil];
    }
    if (!self.frontBundle.length || ![sourceInfo()[@"activeWeType"] boolValue]) return;
    id controller = nil;
    BOOL ascii = NO;
    NSString *stateError = nil;
    if (!WTReadMode(&controller, &ascii, &stateError)) return;
    if (self.pendingBundle) {
        if (![self.pendingBundle isEqualToString:self.frontBundle]) {
            [self beginRestoreForBundle:self.frontBundle waitForNewController:NO];
        }
        if (self.waitForNewController && self.blockedController && controller == self.blockedController) return;
        self.waitForNewController = NO;
        self.blockedController = nil;
        if (self.lastController != controller) self.unsafeController = nil;
        self.lastController = controller;
        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        if (self.pendingEnforceUntil == 0) self.pendingEnforceUntil = now + WTEnforcementWindow;
        if (ascii != self.pendingDesiredASCII && self.unsafeController != controller) {
            id delegate = NSApp.delegate;
            SEL selector = NSSelectorFromString(@"changeInputMode");
            NSDictionary *sourceBefore = sourceInfo();
            NSString *inputSource = sourceBefore[@"inputSource"];
            if (![sourceBefore[@"activeWeType"] boolValue] || !actionAvailable(delegate) ||
                !WTIsCurrentController(controller)) return;
            ((void (*)(id, SEL))objc_msgSend)(delegate, selector);
            BOOL after = NO;
            BOOL verified = WTReadModeForController(controller, &after, &stateError) &&
                [sourceInfo()[@"inputSource"] isEqual:inputSource];
            if (!verified) {
                // The action ran but its outcome is unknown. Never blindly toggle this controller again.
                self.unsafeController = controller;
                NSLog(@"[WeTypeBridge] automatic mode result unknown for %@: %@", self.frontBundle,
                    stateError ?: @"input target changed");
                return;
            }
            ascii = after;
        }
        if (ascii == self.pendingDesiredASCII && now >= self.pendingEnforceUntil) {
            [self rememberASCII:ascii forBundle:self.frontBundle];
            self.pendingBundle = nil;
            self.pendingEnforceUntil = 0;
            self.unsafeController = nil;
        }
        return;
    }
    if (controller != self.lastController) {
        // A new WeType input session can apply the vendor's own default-app rule.
        // Restore our remembered value before accepting any state from that session.
        self.lastController = controller;
        [self beginRestoreForBundle:self.frontBundle waitForNewController:NO];
        return;
    }
    [self rememberASCII:ascii forBundle:self.frontBundle];
}
- (NSDictionary *)automaticStatus {
    return @{ @"automaticModeManagement": @(self.automaticModeManagement),
        @"defaultMode": @"english", @"frontmostBundle": self.frontBundle ?: @"",
        @"pendingBundle": self.pendingBundle ?: @"", @"appModes": [self.appModes copy] ?: @{} };
}
- (void)recordExplicitASCII:(BOOL)ascii controller:(id)controller {
    if (!self.automaticModeManagement || !self.frontBundle.length || !controller) return;
    self.lastController = controller;
    self.blockedController = nil;
    self.unsafeController = nil;
    self.pendingBundle = nil;
    self.pendingEnforceUntil = 0;
    [self rememberASCII:ascii forBundle:self.frontBundle];
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
    id enabled = [self.autoDefaults objectForKey:WTAutoEnabledKey];
    self.automaticModeManagement = enabled ? [enabled boolValue] : YES;
    NSNotificationCenter *workspaceCenter = NSWorkspace.sharedWorkspace.notificationCenter;
    [workspaceCenter addObserver:self selector:@selector(workspaceDidActivate:)
        name:NSWorkspaceDidActivateApplicationNotification object:nil];
    [workspaceCenter addObserver:self selector:@selector(workspaceDidDeactivate:)
        name:NSWorkspaceDidDeactivateApplicationNotification object:nil];
    self.frontBundle = NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier;
    [self beginRestoreForBundle:self.frontBundle waitForNewController:NO];
    self.modeTimer = [NSTimer scheduledTimerWithTimeInterval:0.2 target:self
        selector:@selector(checkAutomaticMode:) userInfo:nil repeats:YES];
}
- (void)stopAutomaticModeManagement {
    [self.modeTimer invalidate];
    self.modeTimer = nil;
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
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
            if (self.automaticModeManagement)
                [self beginRestoreForBundle:self.frontBundle waitForNewController:NO];
            else
                self.pendingBundle = nil;
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
                [self.appModes removeObjectForKey:bundle];
                [self.autoDefaults setObject:[self.appModes copy] forKey:WTAppModesKey];
            } else {
                [self rememberASCII:[mode isEqualToString:@"english"] forBundle:bundle];
            }
            if ([bundle isEqualToString:self.frontBundle])
                [self beginRestoreForBundle:bundle waitForNewController:NO];
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
                    reply[@"ok"] = @YES;
                    reply[@"changed"] = @NO;
                    reply[@"actionInvoked"] = @NO;
                    [self recordExplicitASCII:desired controller:controller];
                } else {
                    // Read/compare/action/verify are serialized on the main queue.
                    // A set request already in its desired mode NEVER calls toggle.
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
        [self stopAutomaticModeManagement];
        [center removeObserver:self];
        bridge = nil;
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
