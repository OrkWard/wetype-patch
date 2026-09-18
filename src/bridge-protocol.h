#import <Foundation/Foundation.h>

// Same-login-session transport, NOT authenticated against other local processes.
// Stable names: intentionally distinct from the earlier temporary lab bridge.
static NSString * const WTRequestName = @"local.orkward.wetype.bridge.request.v1";
static NSString * const WTReplyName = @"local.orkward.wetype.bridge.reply.v1";
static NSString * const WTBundleID = @"com.tencent.inputmethod.wetype";
static NSString * const WTBridgeVersion = @"1.3.1";
