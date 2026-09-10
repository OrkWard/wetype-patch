#import <Foundation/Foundation.h>

// Main-thread only. Uses the SAME native getter as AppDelegate's toggle.
BOOL WTStateInitialize(NSString **error);
BOOL WTReadMode(id *controller, BOOL *ascii, NSString **error);
BOOL WTReadModeForController(id controller, BOOL *ascii, NSString **error);
BOOL WTIsCurrentController(id controller);
NSString *WTBundleForController(id controller);
