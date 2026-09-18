#import <Foundation/Foundation.h>

// Main-thread only. Uses the SAME native getter as AppDelegate's toggle.
BOOL WTStateInitialize(NSString **error);
BOOL WTReadMode(id *controller, BOOL *ascii, NSString **error);
BOOL WTReadModeForController(id controller, BOOL *ascii, NSString **error);
BOOL WTIsCurrentController(id controller);
NSString *WTBundleForController(id controller);

// Best-effort native Chinese/English flip tip for a verified, still-current mode.
// Main-thread only; does not change mode or intercept input.
void WTShowModeTips(id controller, BOOL ascii);
