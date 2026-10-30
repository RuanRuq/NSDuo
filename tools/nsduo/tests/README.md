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

```sh
python3 tools/nsduo/tests/run-diagnostics-checks.py
```

直接编译生产日志实现，使用可控时间戳和合成事件验证：首帧等待、长帧、暂停恢复、有限队列、双文件轮转、问题记录保留、非正常结束标记、路径与敏感字段过滤，以及写入失败不会阻止游戏启动。依赖工程内 .NET SDK 和已构建的 Common 组件，生成内容留在 `work/diagnostics-checks`。

还覆盖原生宿主没有 .NET 入口程序集时的版本号读取，以及日志元数据或初始化失败后仍可继续运行、下一次记录能够恢复。此回归用真实 `ReleaseInformation` 实现与空入口程序集复现 iOS 启动条件。

同时编译实际 Swift 日志文件操作，验证清除范围、符号链接处理、游戏/存档保留、重复清除、清除后可再次写入，以及异常路径。日志页面的“清除日志”需要确认，只删除本机诊断记录和临时导出文件，之后继续自动记录。已保存到“文件”或其他位置的日志副本不受影响。

运行记录自动存于手机 `Documents/Diagnostics`。每次运行日志正文最多约 4 MiB；正常结束后保留最近 5 次普通记录和 10 次问题记录。游戏右上角旗帜按钮标记刚才的问题；游戏库菜单的“诊断日志”可选择记录，再分享或存储为文本。没有自动上传；需要长期保留的记录应主动导出。

日志包含核心初始化阶段、GPU 编译与等待信息、呈现帧间隔、核心统计、托管内存、温度状态、低电量模式、前后台及内存警告。无新画面也可能是游戏正常加载；未正常结束也可能是强制退出或系统终止，不能单凭这些标记判定根因。日志不是完整 iOS 崩溃报告，也不会记录从未触发的游戏内容。进程突然终止时，最后约一秒或尚未处理的队列内容可能丢失。

The diagnostic checks compile the production recorder with synthetic events and controlled timestamps. They verify frame stalls, pause/resume, queue and file limits, retention, interrupted-session markers, redaction and I/O failure. Device sessions are stored locally under `Documents/Diagnostics`; the flag button marks an issue, and the library's diagnostic menu exports an allowlisted text report. There is no automatic upload. Logs retain roughly 4 MiB per session, with five ordinary and ten problem sessions after clean shutdown. No-frame and interrupted-session markers are clues, not proof of a crash or its cause. Abrupt termination may lose the last buffered events; iOS crash reports may still be needed.

The Swift file checks also exercise scoped clearing, symlinks, preserved game/save fixtures, repeated clearing, subsequent recording and error handling. The diagnostic page confirms before deleting its local records and temporary exports. Recording continues during future play; copies saved elsewhere remain untouched.

Native-host regressions use the production `ReleaseInformation` implementation with no managed entry assembly. They also check that metadata/setup failures remain isolated from game startup and that later diagnostic sessions can record successfully.
