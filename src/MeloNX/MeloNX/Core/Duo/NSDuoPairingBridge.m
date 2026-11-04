#import "NSDuoPairingBridge.h"
#import <dlfcn.h>

@protocol NSDuoPairingRuntimeAPI <NSObject>
+ (void)startWithProgress:(void (^)(NSString *))progress pin:(void (^)(NSString *))pin
               completion:(void (^)(NSData *, NSError *))completion;
+ (void)cancel;
@end

@implementation NSDuoPairingBridge
+ (Class<NSDuoPairingRuntimeAPI>)runtime {
    // No link dependency on StikJIT in the host. Loading its pairing adapter
    // never starts its debugger; the JIT helper remains a separate process.
    static void *framework;
    if (!framework) {
        NSURL *url = [NSBundle.mainBundle.privateFrameworksURL URLByAppendingPathComponent:@"StikJIT.framework/StikJIT"];
        if (url) { framework = dlopen(url.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL); }
    }
    Class runtime = framework ? NSClassFromString(@"NSDuoPairingRuntime") : Nil;
    if (![runtime respondsToSelector:@selector(startWithProgress:pin:completion:)] ||
        ![runtime respondsToSelector:@selector(cancel)]) { return Nil; }
    return runtime;
}

+ (void)startWithProgress:(void (^)(NSString *))progress pin:(void (^)(NSString *))pin
               completion:(void (^)(NSData *, NSError *))completion {
    NSAssert(NSThread.isMainThread, @"Pairing state belongs to the main queue");
    Class<NSDuoPairingRuntimeAPI> runtime = [self runtime];
    if (!runtime) {
        completion(nil, [NSError errorWithDomain:@"NSDuoOnDevicePairing" code:2 userInfo:@{
            NSLocalizedDescriptionKey: @"安装包缺少本机配对组件，请使用新版构建脚本重新编译安装 NS Duo。"
        }]);
        return;
    }
    [runtime startWithProgress:progress pin:pin completion:completion];
}

+ (void)cancel {
    NSAssert(NSThread.isMainThread, @"Pairing state belongs to the main queue");
    [[self runtime] cancel];
}
@end
