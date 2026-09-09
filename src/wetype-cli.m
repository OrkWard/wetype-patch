#import <Foundation/Foundation.h>
#import "bridge-protocol.h"

@interface WTLabReply : NSObject
@property(nonatomic, copy) NSString *requestID;
@property(nonatomic, copy) NSDictionary *reply;
- (void)receive:(NSNotification *)notification;
@end
@implementation WTLabReply
- (void)receive:(NSNotification *)notification {
    NSDictionary *info = notification.userInfo;
    if ([info isKindOfClass:[NSDictionary class]] && [info[@"requestID"] isEqual:self.requestID])
        self.reply = info;
}
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        const char *usage = "usage: wetype-cli status|chinese|english|toggle|stop|auto-status|auto-on|auto-off|apps\n"
            "       wetype-cli app-set BUNDLE_ID chinese|english\n"
            "       wetype-cli app-forget BUNDLE_ID\n";
        if (argc < 2) {
            fputs(usage, stderr);
            return 2;
        }
        NSString *operation = [NSString stringWithUTF8String:argv[1]];
        if ([operation isEqualToString:@"--help"]) {
            fputs(usage, stdout);
            printf("Bridge %s for %s.\nApp modes are remembered automatically; unseen apps default to English.\n"
                "chinese/english are idempotent and affect the current WeType session only.\n"
                "Requires patched WeType to be running. stop disables IPC until host restart.\n",
                WTBridgeVersion.UTF8String, WTBundleID.UTF8String);
            return 0;
        }
        NSArray *simple = @[@"status", @"chinese", @"english", @"toggle", @"stop",
            @"auto-status", @"auto-on", @"auto-off", @"apps"];
        BOOL appSet = [operation isEqualToString:@"app-set"];
        BOOL appForget = [operation isEqualToString:@"app-forget"];
        if (([simple containsObject:operation] && argc != 2) || (appSet && argc != 4) ||
            (appForget && argc != 3) || (![simple containsObject:operation] && !appSet && !appForget)) {
            fputs(usage, stderr);
            return 2;
        }
        WTLabReply *listener = [WTLabReply new];
        listener.requestID = NSUUID.UUID.UUIDString;
        NSDistributedNotificationCenter *center = [NSDistributedNotificationCenter defaultCenter];
        [center addObserver:listener selector:@selector(receive:) name:WTReplyName object:nil
            suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
        NSTimeInterval expiry = [NSDate date].timeIntervalSince1970 + 3.0;
        NSMutableDictionary *request = [@{ @"requestID": listener.requestID, @"operation": operation,
            @"deadline": @(expiry) } mutableCopy];
        if (appSet || appForget) {
            NSString *bundle = [NSString stringWithUTF8String:argv[2]];
            if (!bundle) { fprintf(stderr, "bundle ID is not UTF-8\n"); return 2; }
            request[@"bundleID"] = bundle;
        }
        if (appSet) {
            NSString *mode = [NSString stringWithUTF8String:argv[3]];
            if (!([mode isEqualToString:@"chinese"] || [mode isEqualToString:@"english"])) {
                fprintf(stderr, "mode must be chinese or english\n");
                return 2;
            }
            request[@"mode"] = mode;
        }
        [center postNotificationName:WTRequestName object:nil userInfo:request deliverImmediately:YES];
        NSDate *timeout = [NSDate dateWithTimeIntervalSince1970:expiry + 0.5];
        while (!listener.reply && timeout.timeIntervalSinceNow > 0) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        [center removeObserver:listener];
        if (!listener.reply) {
            fprintf(stderr, "No bridge reply. Outcome is unknown; do not blindly retry toggle.\n");
            return 3;
        }
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:listener.reply
            options:NSJSONWritingPrettyPrinted error:&error];
        if (!data) { fprintf(stderr, "%s\n", error.description.UTF8String); return 1; }
        fwrite(data.bytes, 1, data.length, stdout);
        putchar('\n');
        return [listener.reply[@"ok"] boolValue] ? 0 : 1;
    }
}
