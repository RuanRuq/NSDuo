# 运行期回归检查 / Runtime regression checks

在工程依赖准备完成后，从工程根目录执行：

```sh
python3 tools/nsduo/tests/run-runtime-checks.py
```

检查在 Mac 本机运行，使用 Xcode 的 Swift 和工程内 `.toolchain/dotnet`，不需要模拟器、手机、游戏文件、密钥或签名。生成文件及缓存放在工程内 `work/runtime-checks`。

覆盖内容：

- 回调替换、注销、过期标识、执行中对象的存活，以及释放时重新进入注册表。
- 普通游戏页面忽略重复统计值；需要显示性能数据的页面仍收到更新；旧会话数据不能进入新会话。
- 超过一个复制块的文件校验值与内容一致；文件长度变化和取消会中止导入。
- 未变化的目录不重写清单；根目录时间未变时仍发现深层更新和 DLC；忽略目录外的符号链接；原文件移除后保留 App 副本。
- 震动的启用、持续时间替换、暂停、恢复、零强度及销毁。
- 无输入时的轮询频率、暂停时不更新输入，以及按键、恢复和退出的唤醒。
- 移除游戏必须连续按住 5 秒；提前松手、移出按钮、切后台或界面中断会归零，完成后只能执行一次。边框顺时针显示进度，轻微震动逐渐增强。计时、取消与震动强度范围使用可控时间戳验证，实际触摸和手感仍需真机测试。

测试直接编译生产 Swift 实现，从 UIKit Store 提取 Foundation 数据类型，从 `WindowBase.cs` 提取实际输入循环。原生游戏包解析、NSZ 解压、游戏核心与震动硬件使用边界替身；这些检查不能证明具体游戏帧率、真实手感或真机兼容性。

The command runs host-only regression checks using production Swift implementations and the actual C# input-loop methods. Build outputs and caches stay inside the project. Native package inspection, NSZ decoding, emulation and haptic hardware are test boundaries. These checks do not benchmark device FPS or validate physical haptic output.

Game removal requires a continuous five-second hold, with clockwise border progress and a gentle increasing haptic effect. Release, leaving the button, backgrounding or an interrupted UI cancels and resets the hold. Completion authorizes deletion once. Host tests check timing, cancellation and intensity bounds; physical touch and haptic output require device testing. Removing a game preserves its original source files and emulator saves; deleting the entire app through iOS deletes its local data, including saves, unless backed up separately.

## 第二轮优化检查 / Additional optimization checks

原有 `run-runtime-checks.py` 还覆盖：多指抬起后的稳定编号和触点上限、暂停后拒绝过期体感样本、连续触摸只发布一次菜单显示状态、自动隐藏期限延长，以及更新包清理时保留共享文件和保存失败时保留旧副本。

核心依赖已在本工程准备并构建过后，可再运行：

```sh
python3 tools/nsduo/tests/run-core-checks.py
```

该命令复用工程内的 .NET SDK、ZstdSharp 和已有 Common/Shader/Input 依赖，直接编译当前 GAL 渲染队列、原生触摸与手柄、NSZ 解压器的生产代码为主机测试程序。输出放在 `work/core-runtime-checks`，不生成 iOS App。

- 在真实渲染命令中注入异常，检查 GPU 工作线程和同步调用、帧、队列背压、纹理/缓冲区/同步对象等待均能退出；正常退出会先处理完队列，再销毁后端。
- 从 WindowBase 提取实际异常处理方法，检查尚未启动与仍在运行的 GPU 工作线程完成信号。
- 并发修改和读取触点，检查稳定编号、快照和销毁清理；一次变化的体感样本只触发一次输入通知，相同样本不重复通知。
- 检查无监听者时着色器进度不分配内存，有监听者时仍发送完成事件。
- 使用合成普通压缩和分块压缩 NSZ，核对边写边计算的完整 NSP SHA-256、原有 NCA 校验、无 ticket 容器规则、取消清理、禁止覆盖目标，以及 C ABI 校验值返回。无需任何游戏、固件或密钥。

These additional host checks cover stable touch IDs, motion session rejection, coalesced menu updates, commit-safe file reclamation, actual threaded-renderer failure paths, native input concurrency, progress allocation and solid/block NSZ decoding with streaming SHA-256. The renderer backend and device hardware are test boundaries. These are correctness checks, not device FPS benchmarks or proof that every game is compatible.

## 加载卡顿检查 / Loading-stutter checks

```sh
python3 tools/nsduo/tests/run-pipeline-checks.py
```

使用工程内 .NET SDK 和合成缓存数据，输出留在 `work/pipeline-checks`，不编译 iOS App。

- 驱动管线缓存跨会话复用，校验设备、驱动、系统及缓存 UUID；损坏、截断、超限缓存不会交给驱动；保存失败保留上一份有效缓存。
- 提取 `VulkanRenderer` 的实际缓存读写方法，验证驱动拒绝缓存时改建空缓存、真正的设备错误仍会抛出、不完整快照不能覆盖有效缓存。
- 提取 `PipelineState` 的实际编译临界区，验证同时未命中的请求只编译一次，不同状态分别编译，暂时失败可以重试，以及 Metal 混合状态修正不改变缓存键。
- 阻塞一个程序的驱动编译调用，确认另一个程序的计算与图形管线仍能完成创建；同一程序继续去重。驱动缓存保留 Vulkan 内部同步，缓存导出只在停止编译后进行。

原生 Vulkan 调用使用替身。此检查验证缓存与并发行为，不证明真机帧率或卡顿已经消失。新增驱动缓存只在正常结束游戏时保存，下次启动自动读取；它补充原有中间着色器缓存，不预编译从未遇到过的全部游戏内容，也不改变分辨率或跳过绘制。编译耗时超过 100 ms 时会限频记录 `Slow pipeline creation`，结束时记录累计编译和等待时间。

These host checks exercise persistent driver-cache validation and the production cache/compilation methods with fake Vulkan calls. They cover corrupt data, identity changes, rejected caches, incomplete snapshots, concurrent misses and retryable failures. Driver caches are saved on orderly game shutdown and restored on the next launch; unseen content can still require first-use compilation. No resolution or draw-skipping setting is changed. Device performance still requires measurement.

The contention regression holds one program inside a fake driver call and requires another program's graphics/compute creation to finish before releasing it. Production creation gates are scoped to each shader program, retaining duplicate-request protection. The shared driver cache keeps Vulkan's internal synchronization; snapshot export happens after compiler workers finish. The test verifies progress and correctness, not a device FPS improvement. Different states of the same program may still wait, as can driver-internal work and first-use compilation.

## 本地诊断检查 / Local diagnostic checks

### iOS CPU 信号接口静态检查

```sh
python3 tools/nsduo/tests/check-signal-abi.py
```

读取实际 C# 的 Darwin `sigaction` 字段与 `SA_SIGINFO` 常量，对照本机 iPhoneOS SDK 做 Clang 静态断言，并核对生成信号回调与托管配置的偏移、读取宽度。只使用 `-fsyntax-only`，不编译 App/核心或运行测试程序。输出留在 `work/signal-abi-checks`；可用 `NSDUO_DEVELOPER_DIR` 选择已有 Xcode。

2026-11-03 修正了 iOS 错用 Linux 信号结构和常量、两个内存信号共用旧回调、32 位参数标志被按 64 位读取的问题。`SIGSEGV` / `SIGBUS` 现在分别保存和转发旧回调，安装前先发布回调配置；静态检查不能替代真实 JIT、内存保护和游戏兼容性验证。

2026-11-03 后续真机报告确认《超级马力欧银河》1.3.1 仍在未受检的原生页表索引处崩溃。原始 `.ips` 的寄存器可精确复现越界地址：`0x7389e78000 + (0x1f9000fe200ff1 >> 12) * 8 = 0x103b8a669000`。该 title `010099C022B96000` 在 iOS ARM64 的 64 位进程中，将运行时 `HostMappedUnsafe` 改为 `HostMapped`，保留 LightningJit；另外修正 HostTracked 受检路径，使索引与 PTE 相对地址均使用裁剪到 guest 地址空间位宽后的值。兼容策略不写回配置文件，诊断记录配置值和实际模式。`CpuMemoryCompatibilityChecks.cs` 包含平台/title/大小写/显式配置边界用例；当前仅静态语义验证，未执行回归或验证实际游戏恢复。

```sh
python3 tools/nsduo/tests/run-diagnostics-checks.py
```

直接编译生产日志实现，使用可控时间戳和合成事件验证：首帧等待、长帧、暂停恢复、有限队列、双文件轮转、问题记录保留、非正常结束标记、路径与敏感字段过滤，以及写入失败不会阻止游戏启动。依赖工程内 .NET SDK 和已构建的 Common 组件，生成内容留在 `work/diagnostics-checks`。

还覆盖原生宿主没有 .NET 入口程序集时的版本号读取，以及日志元数据或初始化失败后仍可继续运行、下一次记录能够恢复。此回归用真实 `ReleaseInformation` 实现与空入口程序集复现 iOS 启动条件。

同时编译实际 Swift 日志文件操作，验证清除范围、符号链接处理、游戏/存档保留、重复清除、清除后可再次写入，以及异常路径。日志页面的“清除日志”需要确认，只删除本机诊断记录和临时导出文件，之后继续自动记录。已保存到“文件”或其他位置的日志副本不受影响。

异常收集新增用例覆盖：采样消息拥塞时异常仍独立同步落盘、异常类型与堆栈保留、非 GPU Error、问题标记立即写入、异常突发大小上限、App 报告去重、JSON 脱敏和导出白名单。上述主机回归需要编译并执行测试程序，日常只做静态验证时不运行。

运行记录自动存于手机 `Documents/Diagnostics`。每次运行采样正文最多约 4 MiB，另外两个异常文件各最多 128 KiB；正常结束后保留最近 5 次普通记录和 10 次问题记录。游戏内左上角仅保留暂停和返回游戏库按钮；游戏库菜单的“诊断日志”可选择记录，再分享或存储为文本。没有自动上传；需要长期保留的记录应主动导出。

日志包含核心初始化阶段、GPU 编译与等待信息、呈现帧间隔、核心统计、托管内存、温度状态、低电量模式、前后台及内存警告。核心捕获的启动/渲染异常和各模块 Error 写入 `exceptions.log`；全局未处理的终止异常写入 `fatal.log`，包含时间、阶段、线程和经脱敏的堆栈。异常文件独立同步刷盘，不等待采样队列；最多保留约 16 Ki 个字符的异常详情，突发写满时保留最先记录的错误，终止异常另存。全局 AppDomain/TaskScheduler 处理器只注册一次，不改变异常处理策略。

App 初始化时还注册 Objective-C 未捕获异常回调，并通过 MetricKit 接收系统原生崩溃报告；不接管 JIT 和内存保护使用的信号处理器。这两类报告显示为独立的“App 未捕获异常”或“App 系统崩溃报告”，和游戏记录一样可选择导出。系统报告附带经脱敏的 `system-crash.json`（最多 2 MiB；超限保留摘要并注明），包含系统提供的异常类型、信号、终止原因和调用栈。系统报告可能在重启 App 后延迟交付；列表时间是报告统计区间的结束时间，并非精确崩溃时刻，不据此强行归到某一局游戏。已接收报告的摘要 ID 保存在 UserDefaults，避免重复交付或清日志后重新导入历史报告。

无新画面也可能是游戏正常加载；未正常结束也可能是强制退出或系统终止，不能单凭这些标记判定根因。原生收集属于尽力记录，系统强杀、内存耗尽、栈溢出等情况不保证执行回调或交付堆栈；不会伪造具体原因。进程突然终止时，最后约一秒或尚未处理的采样队列内容仍可能丢失，必要时继续使用 iOS `.ips`/Jetsam 报告。

The diagnostic checks compile the production recorder with synthetic events and controlled timestamps. They verify frame stalls, pause/resume, queue and file limits, retention, interrupted-session markers, redaction and I/O failure. Device sessions are stored locally under `Documents/Diagnostics`; the library's diagnostic menu exports an allowlisted text report. The in-game controls at the top left provide pause and return-to-library actions. There is no automatic upload. Sampling logs retain roughly 4 MiB per session, plus two bounded synchronous exception files, with five ordinary and ten problem sessions after clean shutdown. Objective-C uncaught exceptions and MetricKit crash reports become separate exportable records. MetricKit delivery may be delayed, and its reporting period does not identify one game session. No-frame and interrupted-session markers are clues, not proof of a crash or its cause. Abrupt termination may lose buffered sampling events; system kills may not provide an in-app stack and iOS crash reports may still be needed.

The Swift file checks also exercise scoped clearing, symlinks, preserved game/save fixtures, repeated clearing, subsequent recording and error handling. The diagnostic page confirms before deleting its local records and temporary exports. Recording continues during future play; copies saved elsewhere remain untouched.

Native-host regressions use the production `ReleaseInformation` implementation with no managed entry assembly. They also check that metadata/setup failures remain isolated from game startup and that later diagnostic sessions can record successfully.

## 2026-10-30 性能优化回归

以下命令只运行主机逻辑检查，不构建 iOS App，不启动模拟器；SDK、输出与缓存沿用工程内目录。

```sh
python3 tools/nsduo/tests/run-gpu-memory-checks.py
python3 tools/nsduo/tests/run-audio-checks.py
python3 tools/nsduo/tests/run-jit-sharing-checks.py
python3 tools/nsduo/tests/run-library-performance-checks.py
python3 tools/nsduo/tests/run-console-motion-checks.py
```

- GPU：短缓存首次引用、重复引用与到期释放；内存压力采样、多缓存分摊、分批淘汰及保护当前呈现纹理；默认 shader 构造路径受并发调度器约束。
- 音频：生产 PCM/描述记录交错、跨缓冲完成计数、完整音量整数 PCM 快路径、浮点及其它增益保留 SDL 行为、生命周期与锁顺序。
- JIT：仅合并同实例同代际的在途编译；不同地址/模式仍能推进；编译异常可重试、失效拒绝旧结果、重入与关闭可退出。原生 Map 仍为测试边界。
- 游戏库：串行 worker、启动抢占自动扫描但等待不可取消提交完成、采用最新目录记录、封面取消交接及硬内存预算。原有 runtime 检查补充目录复用、忽略文件指纹变化及目录更换游戏。
- 日志与体感：控制台轮转、输出描述符恢复、多次会话、重复低等级日志合并、退出排空在途错误日志、按游戏保存体感偏好。

这些检查验证逻辑与资源生命周期；FPS、峰值内存、发热、真实音频和触控体感仍需真机对比。日志分段目标为 2 MiB，按秒检查，瞬时大量输出可能超过目标；纹理回收每帧限制次数和启动新回收的时间窗口，单次驱动 flush 仍可能较慢。
