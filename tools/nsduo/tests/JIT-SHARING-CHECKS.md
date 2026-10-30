# LightningJit 在途编译合并检查

运行 `python3 tools/nsduo/tests/run-jit-sharing-checks.py`。只编译主机回归，输出在 `work/jit-sharing-checks`，不生成 iOS App，也不执行生成的机器码。可通过 `NSDUO_JIT_SOURCE_ROOT` 指向旧源码根目录，对比旧行为。

检查使用实际 `CompilationCoordinator`、`CompiledFunction` 和执行模式，原样提取当前 `Translator.Compile/CompileCore` 及 `IsNoWxPlatform`；只在操作系统边界切换 iOS/非 iOS，AarchCompiler 是可控编译替身。非 iOS 覆盖：

- 相同地址、相同模式的并发请求只编译一次；不同地址/模式可以推进。
- 没有等待者时不复制 Code，完成后不留生成代码缓存。
- 失败会同时通知当前等待者，后续调用可重试。
- 任意代码失效推进代际；旧代际的 owner/waiter 不复用旧结果，新代际不等待旧编译。
- 同线程重入不等待自身；关闭释放等待者，并拒绝晚到结果。

非 iOS 的生成代码只在同一个 Translator 内共享。iOS/W^X 兼容路径暂不参与在途合并，直接独立执行 `CompileCore`：新增用例阻塞第一个编译请求，确认第二个同地址/模式请求在释放第一个请求前完成，两者分别返回自己的 Code 和 GuestCodeLength，且共享/复制次数为零。

iOS 的 `Map(framePointer, ...)` 仍由每个原调用线程独立执行，没有共享线程本地可执行指针，也没有跨会话缓存。既有线程本地与 pendingMap 的映射失效语义未改；此兼容保护不宣称修复其历史 TODO。非 iOS 编译期间不持协调器锁，避免与 guest memory 的 Unmap 回调形成反向锁顺序。

退出时日志包含 `JIT compile sharing`：进入协调器的实际编译次数、加入在途等待的请求数、失效重试次数、为等待者复制代码的次数，以及同线程重入绕过次数。iOS 独立编译不计入这些计数。它们不能替代实际帧时间/CPU 采样。

2026-10-30 iOS 隔离回归先 RED 后 GREEN：旧路径四组非 iOS 检查通过，新 iOS 用例因等待另一线程而失败；加入兼容保护后五组通过。日志在 `work/game-launch-crash-20261030/jit-ios-isolation-{red,green}.log`。该测试只验证路径隔离，没有执行真实 ARM 机器码或 iOS 原生映射，不能证明此次启动崩溃由编译合并引起。候选包只改变此编译入口，是否解决问题需要同一游戏的真机 A/B 复测。
