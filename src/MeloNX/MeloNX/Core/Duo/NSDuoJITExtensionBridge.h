#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The host remains responsive while its separate extension services debugger
// breakpoints. Completion is delivered once, on the main queue.
NS_SWIFT_UI_ACTOR
@interface NSDuoJITExtensionBridge : NSObject
@property (class, nonatomic, readonly) BOOL isActive;

+ (void)startRequest:(NSData *)data
             started:(void (^)(void))started
          completion:(void (^)(NSData * _Nullable response, NSError * _Nullable error))completion
    NS_SWIFT_NAME(startRequest(_:started:completion:));

// Intentionally no cancel/kill API: terminating an attached debugger may crash
// the host. The active request is retained until the system reports its end.
@end

NS_ASSUME_NONNULL_END
