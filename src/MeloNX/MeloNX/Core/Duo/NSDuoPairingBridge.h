#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NS_SWIFT_UI_ACTOR
@interface NSDuoPairingBridge : NSObject
+ (void)startWithProgress:(void (^)(NSString *stage))progress
                     pin:(void (^)(NSString *pin))pin
          completion:(void (^)(NSData * _Nullable data, NSError * _Nullable error))completion
    NS_SWIFT_NAME(start(progress:pin:completion:)) NS_SWIFT_DISABLE_ASYNC;
+ (void)cancel;
@end

NS_ASSUME_NONNULL_END
