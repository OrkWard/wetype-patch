#import <Foundation/Foundation.h>

// Main-thread only. Uses the SAME per-client getter as AppDelegate's toggle.
BOOL WTStateInitialize(NSString **error);
BOOL WTReadMode(id *controller, BOOL *ascii, NSString **error);
BOOL WTReadModeForController(id controller, BOOL *ascii, NSString **error);
BOOL WTIsCurrentController(id controller);
