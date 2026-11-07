# 普通 Switch 核心异步提交与等待日志

本次开启 MoltenVK 异步提交，其余已有配置赋值保持原样。未调整分辨率、抗锯齿、滤镜、着色器绘制策略、VSync、交换链图像数或帧队列深度。原来的锁、fence、超时和资源释放顺序均保留。

## 初始化记录

在游戏库左上角「… → 诊断日志」导出该次游戏的日志。在 `current.log` 或 `previous.log` 中搜索 `moltenvk_config`。

- `async_submit=True`：设置后从 MoltenVK 读回的同步提交开关已关闭。
- `previous_sync`：本次设置之前的状态；同一 App 进程第二次启动游戏时可能已经是 `False`。
- `prefill`：当前 Metal 命令预填充方式，仅记录，不在本次修改。
- `max_active_command_buffers`、`semaphore_style`、`fast_math`、`argument_buffers`：设置后读回的相关配置。
- `set_result=Incomplete`：本项目只传入旧配置结构前缀，而库还支持追加字段时可正常出现；代码同时检查已复制大小，确保所访问字段都存在。

配置结构的大小参数按照原生接口改为可读写引用；初始化前后均读取配置，无法安全取得配置或设置失败时沿既有异常处理链报告，不伪报启用成功。

## 等待记录

搜索 `graphics_timing`。原有诊断线程约每 5 秒汇总一次有变化或仍在执行中的计时，正常结束时补写最后一份。渲染线程只读取时钟和更新原子计数，不逐次格式化或写文件；未开启诊断会话时作用域为空操作。

| kind | 测量范围 |
| --- | --- |
| `RendererFrameWait` | GPU 指令线程等待后端消费上一帧呈现命令 |
| `AcquireImage` | `vkAcquireNextImageKHR` 调用，包含等交换链图像可用的时间 |
| `QueueSubmitWithLock` | 获取提交锁、提交 API 调用及释放锁 |
| `QueueSubmitCall` | 锁内 `vkQueueSubmit` 调用 |
| `QueuePresentWithLock` | 获取呈现锁、呈现 API 调用及释放锁 |
| `QueuePresentCall` | 锁内 `vkQueuePresentKHR` 调用 |
| `GpuFenceWait` | Vulkan fence 的阻塞轮询等待 |
| `GpuSyncWait` | 后端同步对象等待，包含需要的 flush 协调与对象锁 |
| `GuestFrameFence` | 消费游戏帧之前等待该帧的 guest fence |

各条记录是该次游戏的**累计 CPU 耗时**：`calls` 为已完成次数，`total_ms` 为累计时长，`avg_ms` 和 `max_ms` 为平均/最长时长，`over_1ms`、`over_16ms` 为达到对应时长的次数，`active` 为仍未返回的调用数。

计数器无锁采样，正在结束的调用可能跨相邻样本显示。统计包含加载、暂停切换和退出阶段，以日志的时间与 phase/paused 变化一起判断；当前 phase 不代表所有历史累计数据都发生在该阶段。

`WithLock` 包含对应的 `Call`，两者累计时长之差可用于粗略观察锁开销。不同线程以及嵌套指标会重叠，不能把所有 `total_ms` 相加当作整段运行时间。提交或呈现 API 返回也不代表 GPU 已执行完成，更不代表该帧已显示到屏幕。

## 真机观察

本次改动位于 C# 核心，测试包需包含重新生成的核心；启动手机上原有的旧包不会带入这些改动。

使用同一游戏、存档和场景，分别观察静止、移动、战斗以及区域切换；兼顾短暂停顿、操作响应和持续运行后的发热。发现黑屏、花屏或异常退出时，保留该次诊断记录并导出。

本次只做静态语义、源文件引用及差异检查，没有编译 App、执行主机回归或运行真机，尚无性能改善或画面一致性的实测结论。已补充计数并发、异常路径收尾、结束汇总和旧会话隔离的回归用例，但本次仅静态检查这些用例。

接口依据：[MoltenVK 1.4.0 配置说明](https://github.com/KhronosGroup/MoltenVK/blob/v1.4.0/Docs/MoltenVK_Configuration_Parameters.md#mvk_config_synchronous_queue_submits)、[配置读取和结构大小约定](https://github.com/KhronosGroup/MoltenVK/blob/v1.4.0/MoltenVK/MoltenVK/API/mvk_private_api.h)。
