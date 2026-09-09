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
        if (argc != 2) {
            fprintf(stderr, "usage: wetype-cli status|chinese|english|toggle|stop\n");
            return 2;
        }
        NSString *operation = [NSString stringWithUTF8String:argv[1]];
        if ([operation isEqualToString:@"--help"]) {
            printf("usage: wetype-cli status|chinese|english|toggle|stop\nBridge %s for %s.\nchinese/english are idempotent and affect the current WeType session only.\nRequires patched WeType to be running. stop disables IPC until host restart.\n",
                WTBridgeVersion.UTF8String, WTBundleID.UTF8String);
            return 0;
        }
        if (![@[@"status", @"chinese", @"english", @"toggle", @"stop"] containsObject:operation]) {
            fprintf(stderr, "unknown operation\n");
            return 2;
        }
        WTLabReply *listener = [WTLabReply new];
        listener.requestID = NSUUID.UUID.UUIDString;
        NSDistributedNotificationCenter *center = [NSDistributedNotificationCenter defaultCenter];
        [center addObserver:listener selector:@selector(receive:) name:WTReplyName object:nil
            suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
        NSTimeInterval expiry = [NSDate date].timeIntervalSince1970 + 3.0;
        NSDictionary *request = @{ @"requestID": listener.requestID, @"operation": operation, @"deadline": @(expiry) };
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
