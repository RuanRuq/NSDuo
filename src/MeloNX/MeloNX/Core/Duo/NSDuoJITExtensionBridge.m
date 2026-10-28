#import "NSDuoJITExtensionBridge.h"
#import <dlfcn.h>

// Minimal runtime declarations for Apple's private extension selectors.
// This adapter is implemented locally; it contains no third-party app code.
@protocol NSDuoExtensionRuntime <NSObject>
+ (nullable id)extensionWithIdentifier:(NSString *)identifier error:(NSError **)error;
- (void)beginExtensionRequestWithInputItems:(NSArray *)items completion:(void (^)(NSUUID * _Nullable))completion;
- (void)setRequestCompletionBlock:(void (^ _Nullable)(NSUUID * _Nullable, NSArray * _Nullable))block;
- (void)setRequestCancellationBlock:(void (^ _Nullable)(NSUUID * _Nullable, NSError * _Nullable))block;
- (void)setRequestInterruptionBlock:(void (^ _Nullable)(NSUUID * _Nullable))block;
@end

// Keep this key in sync with NSDuoJITMessage.payloadKey.
static NSString * const NSDuoJITPayloadKey = @"com.nsduo.jit.message";
static NSString * const NSDuoJITBridgeErrorDomain = @"com.nsduo.jit.extension";

static NSError *NSDuoJITBridgeError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:NSDuoJITBridgeErrorDomain code:code
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}

@interface NSDuoJITExtensionRequest : NSObject
@property (nonatomic, strong) id<NSDuoExtensionRuntime> extension;
@property (nonatomic, copy) void (^completion)(NSData * _Nullable, NSError * _Nullable);
@property (nonatomic, copy) void (^started)(void);
@property (nonatomic, strong, nullable) NSUUID *identifier;
@property (nonatomic) BOOL finished;
@property (nonatomic) BOOL didStart;
- (BOOL)acceptsIdentifier:(nullable NSUUID *)identifier;
- (void)finishWithData:(nullable NSData *)data error:(nullable NSError *)error;
@end

static NSDuoJITExtensionRequest *NSDuoActiveJITRequest;

@implementation NSDuoJITExtensionRequest
- (BOOL)acceptsIdentifier:(NSUUID *)identifier {
    return !self.finished && NSDuoActiveJITRequest == self &&
        (!self.identifier || !identifier || [self.identifier isEqual:identifier]);
}

- (void)finishWithData:(NSData *)data error:(NSError *)error {
    NSAssert([NSThread isMainThread], @"JIT bridge state belongs to the main queue");
    if (self.finished || NSDuoActiveJITRequest != self) { return; }
    self.finished = YES;
    void (^completion)(NSData *, NSError *) = self.completion;
    self.completion = nil;
    self.started = nil;
    [self.extension setRequestCompletionBlock:nil];
    [self.extension setRequestCancellationBlock:nil];
    [self.extension setRequestInterruptionBlock:nil];
    self.extension = nil;
    NSDuoActiveJITRequest = nil;
    if (completion) { completion(data, error); }
}
@end

@implementation NSDuoJITExtensionBridge
+ (BOOL)isActive {
    NSAssert([NSThread isMainThread], @"Read JIT status on the main queue");
    return NSDuoActiveJITRequest != nil;
}

+ (void)startRequest:(NSData *)data started:(void (^)(void))started
          completion:(void (^)(NSData *, NSError *))completion {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self startRequest:data started:started completion:completion];
        });
        return;
    }
    if (NSDuoActiveJITRequest) {
        completion(nil, NSDuoJITBridgeError(1, @"已有 JIT 辅助操作正在运行，请等待它结束。"));
        return;
    }
    if (data.length == 0 || data.length > 4 * 1024 * 1024) {
        completion(nil, NSDuoJITBridgeError(2, @"JIT 请求为空或超过大小限制。"));
        return;
    }
    NSURL *helperURL = [[NSBundle.mainBundle builtInPlugInsURL] URLByAppendingPathComponent:@"NSDuoJITHelper.appex"];
    NSString *identifier = helperURL ? [NSBundle bundleWithURL:helperURL].bundleIdentifier : nil;
    if (identifier.length == 0) {
        completion(nil, NSDuoJITBridgeError(3, @"安装包缺少 JIT 辅助扩展，请重新安装并保留 App 扩展。"));
        return;
    }
    Class extensionClass = NSClassFromString(@"NSExtension");
    if (!extensionClass) {
        // Keep the framework loaded for the lifetime of its request objects.
        dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_NOW | RTLD_LOCAL);
        extensionClass = NSClassFromString(@"NSExtension");
    }
    if (![extensionClass respondsToSelector:@selector(extensionWithIdentifier:error:)]) {
        completion(nil, NSDuoJITBridgeError(4, @"当前系统不提供内置 JIT 所需的扩展接口，请使用外部调试工具。"));
        return;
    }
    NSError *creationError;
    id<NSDuoExtensionRuntime> extension = [(Class<NSDuoExtensionRuntime>)extensionClass extensionWithIdentifier:identifier error:&creationError];
    if (!extension) {
        completion(nil, creationError ?: NSDuoJITBridgeError(5, @"系统未能创建 JIT 辅助扩展。"));
        return;
    }
    if (![extension respondsToSelector:@selector(beginExtensionRequestWithInputItems:completion:)] ||
        ![extension respondsToSelector:@selector(setRequestCompletionBlock:)] ||
        ![extension respondsToSelector:@selector(setRequestCancellationBlock:)] ||
        ![extension respondsToSelector:@selector(setRequestInterruptionBlock:)]) {
        completion(nil, NSDuoJITBridgeError(6, @"系统的辅助扩展接口不兼容，请使用外部调试工具。"));
        return;
    }

    NSDuoJITExtensionRequest *request = [NSDuoJITExtensionRequest new];
    request.extension = extension;
    request.started = started;
    request.completion = completion;
    NSDuoActiveJITRequest = request;
    __weak NSDuoJITExtensionRequest *weakRequest = request;

    [extension setRequestCompletionBlock:^(NSUUID *requestIdentifier, NSArray *items) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSDuoJITExtensionRequest *active = weakRequest;
            if (![active acceptsIdentifier:requestIdentifier]) { return; }
            NSExtensionItem *item = items.count == 1 && [items.firstObject isKindOfClass:NSExtensionItem.class] ? items.firstObject : nil;
            id payload = item.userInfo[NSDuoJITPayloadKey];
            NSData *response = [payload isKindOfClass:NSData.class] ? payload : nil;
            if (response.length == 0 || response.length > 4 * 1024 * 1024) {
                [active finishWithData:nil error:NSDuoJITBridgeError(7, @"JIT 辅助扩展没有返回有效结果。")];
                return;
            }
            [active finishWithData:response error:nil];
        });
    }];
    [extension setRequestCancellationBlock:^(NSUUID *requestIdentifier, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSDuoJITExtensionRequest *active = weakRequest;
            if (![active acceptsIdentifier:requestIdentifier]) { return; }
            [active finishWithData:nil error:error ?: NSDuoJITBridgeError(8, @"系统取消了 JIT 辅助请求。")];
        });
    }];
    [extension setRequestInterruptionBlock:^(NSUUID *requestIdentifier) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSDuoJITExtensionRequest *active = weakRequest;
            if (![active acceptsIdentifier:requestIdentifier]) { return; }
            [active finishWithData:nil error:NSDuoJITBridgeError(9, @"JIT 辅助进程已中断，请重新发起。")];
        });
    }];
    NSExtensionItem *input = [NSExtensionItem new];
    input.userInfo = @{NSDuoJITPayloadKey: data};
    [extension beginExtensionRequestWithInputItems:@[input] completion:^(NSUUID *requestIdentifier) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSDuoJITExtensionRequest *active = weakRequest;
            if (!active || active.finished) { return; }
            if (!requestIdentifier) {
                [active finishWithData:nil error:NSDuoJITBridgeError(10, @"系统未能启动 JIT 辅助进程，请检查签名和扩展是否保留。")];
                return;
            }
            active.identifier = requestIdentifier;
            if (!active.didStart) {
                active.didStart = YES;
                void (^onStarted)(void) = active.started;
                active.started = nil;
                if (onStarted) { onStarted(); }
            }
        });
    }];
}
@end
