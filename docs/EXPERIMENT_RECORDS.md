# 实验与验证记录索引

整理日期：2026-11-13。这里只保留从原待办中移出的观察、诊断和证据来源，不保存已完成任务清单。当前未完成工作统一在 [TODO.md](../TODO.md)；开发过程与旧清单可从 Git 历史追溯。

所有结论限定在记录时的源码、设备、配置与采样范围。软件测试、原生启动和离屏预览不等于鼠标验收或实机签收；历史绿色 CI 不代表之后任意 HEAD 已验证。

## 设备实验记录

| 日期/范围 | 证据与限制 | 详细记录 |
| --- | --- | --- |
| 2026-11-11 观察页面 | 用户确认观察 UI 的实体输入响应；复核的前缀只有 56 条 A 层触摸/松手输入，不能扩展为全量控件、其他层或输出验收 | [会话记录](HARDWARE_SESSION_2026-11-11.md) |
| 2026-11-12 输入与反馈采样 | 控件 1 的两层 TX、编码器绝对值/加速、按键 LED、灯环显示/样式和层选择的分批观察；保留原始采样范围与非隔离运行的限制 | [会话记录](HARDWARE_SESSION_2026-11-12.md) |
| 2026-11-12 灯环外观校准 | 操作员描述与当时 UI 数值配对，不是相机测量或 LED 读回。E1/E2 与 E9–E13/E15 的样本、相邻双灯与中心常亮可追溯；E14、反向迟滞、精确阈值、B 层与样式编号仍未知 | [灯环校准](RING_CALIBRATION_2026-11-12.md) |
| 2026-11-12/13 电机与 App 门禁 | 单推子操作及有限的 F2–F9/A、F1/B 样本；用户对 HW-6 的签收仅覆盖记录所列范围，不包含后续软件改动或剩余补测 | [会话记录](HARDWARE_SESSION_2026-11-12.md)、[签收范围](HARDWARE_BRINGUP.md#hw-6--one-motor-touch-and-feedback-stage-3) |
| 启动位置读回调查 | 本地已上电设备的 client attach 与闲置抓取无位置回报，随后控制样本证明监听路径能收到输入；上电、USB 重连及请求触发的全量读回仍未验证 | [调查记录](STARTUP_READBACK_INVESTIGATION.md) |
| 远程转发实验 | 临时虚拟设备的双向转发与真实设备的端点可见/被动接入范围分别记录；虚拟设备成功不代表真实设备经转发的双向或直接 USB 验收 | [远程硬件记录](REMOTE_HARDWARE.md) |

### 本台设备的关键观察

- 输入 TX 通道 1；Global RX 通道 2 来自独立逐通道点灯观察，不从 TX 推断。设备档案不自动改写，固件版本仍未读出。
- 已采样按键的 LED 速度为 0 灭、2 亮、3 闪；速度 1 不亮。手册 0/1/2 与实测 0/2/3 仍是两种不同配置，不把少数按键样本当作全量覆盖。
- 已采样的主机灯环显示值只亮单颗，不因样式改变而成为连续段；样式命令会重画并丢弃主机显示位置。本地转动的完整样式曲线仍需补测。
- 已记录的电机移动未回报位置；F1 被按住时的指令无效，松手后固件没有自行补发。它不证明所有推子、数值、固件与保持方式都有同样表现。
- 物理层键与主机 Program Change 都观察到九个推子回零再回原位，且无设备 TX；两层共用最终物理位置。“没有电机 CC”不能证明“没有运动”。按住时切层的行为与 USB 上电运动来源仍未知。
- 早期面板把 B 层位置输入留在 A 层软件值后面，造成显示/事实来源混淆；这不是“位置不可读”的证据。缺少公开查询也不能证明设备不支持全量读回。

原始录制位于忽略的 `captures/private/`，本次整理未修改或入库。具体文件、指纹、操作员描述与未建立的结论以对应会话页为准。未在实机复核的后续软件行为仍保持该标注。

## 建置与原生实验诊断

下表是旧清单中仍有排错价值的记录；不是当前任务或当前 CI 拓扑说明。

| 现象 | 记录中的原因/处理 | 证据与边界 |
| --- | --- | --- |
| SwiftPM 原生包本地化崩溃 | 生成的 `zh-Hans.lproj` 目录被小写化，旧查找代码强制解包；`eea7a22` 加入小写兼容与英文回退 | 原 N1 记录；当前资源验证流程见 [构建工作流](FREECM.md) |
| Swift 6.1.2 Network 回调编译失败 | `9302a27`、`1a99f43` 为 MainActor Task 显式再捕获 self/具名引用，没有关闭 Swift 6 并发检查 | 旧编译器兼容实验，不把本机编译器与托管 Xcode 视为同一版本 |
| 托管截图进程超时 | 旧窗口 `.task` 入口依赖窗口出现；独立 AppKit 入口移除了这项启动依赖。不能据此断言私有窗口管理机制 | 失败 [43005877417](https://github.com/NorthBoundWisdom/XTouchCompactDev/actions/runs/43005877417)，五张预览通过 [43006052440](https://github.com/NorthBoundWisdom/XTouchCompactDev/actions/runs/43006052440)；详见 [N6 诊断](reviews/N2-N8.md#n6--isolated-preview-lifecycle-and-timeout-diagnostics) |
| N5 原生交互无法验收 | 原生工具返回 `cgWindowNotFound` / 超时，未取得可操作窗口；隔离进程采样显示 AppKit 闲置循环，不是主线程死锁的证据 | [原生验收记录](NATIVE_ACCEPTANCE.md)。离屏预览不替代鼠标/剪贴簿操作 |
| 日志非有限 JSON 值中止测试进程 | 日志测试发现 macOS `NSJSONSerialization` 对 NaN 会抛 Objective-C 例外；`a677209` 在编码前验证 JSON 与有限时间值，使失败可终止且不重试 | [日志实现说明](REMOTE_HARDWARE.md#command-event-logs-u5-software-verification-only)；测试使用临时文件/注入写入器，没有运行 MIDI 发送命令 |

## 软件验证证据

| 源码/时期 | 验证记录 | 不代表的内容 |
| --- | --- | --- |
| 旧编译器/原生兼容时期 | [43001312226](https://github.com/NorthBoundWisdom/XTouchCompactDev/actions/runs/43001312226) 的 Linux 与旧 macOS 检查；[43007338487](https://github.com/NorthBoundWisdom/XTouchCompactDev/actions/runs/43007338487) 记录 Xcode 26.6 / Swift 6.3.3 的三作业时期结果 | macOS 15 与三作业方案是历史配置，现有配置以 `.github/workflows/ci.yml` 为准 |
| 观察与非电机工作台时期 | [43053024236](https://github.com/NorthBoundWisdom/XTouchCompactDev/actions/runs/43053024236) 覆盖当时观察、重构与工具检查 | 不扩展现场的控件/层/输出签收范围 |
| `2d3defc` | [43278244712](https://github.com/NorthBoundWisdom/XTouchCompactDev/actions/runs/43278244712) 两条 CI 通过；实际检出 `ae9504d` 的树与源码一致，依赖固定为 `c6b3083`；原生隔离启动与 ad-hoc 打包通过 | 当时缺少本地历史 SDK ZIP 的两项跳过，后来经固定哈希恢复后定向补测；不是当时 CI 已执行这些门禁的证明 |
| `61776a2` | [43366404885](https://github.com/NorthBoundWisdom/XTouchCompactDev/actions/runs/43366404885) Linux/macOS 通过；本地 154 Core、111 App Swift Testing、14 App XCTest、4 本地化、21 工具测试（共 304）及 78 工作流测试通过；38 项模拟器整合测试无跳过；原生隔离启动回报 `hardwareAccessed:false` | UI 目视、实机与 D2/D4 正式接入仍未验收/未实现；ZIP/DMG 仅为本地 ad-hoc，不是公证分发 |

离线录制审计的两份私有证据摘要、SHA-256 与“证据不足”结论见 [审计记录](CAPTURE_MOTOR_AUDIT.md)。冻结 SDK 的原始来源、哈希与许可在 [测试 fixture 说明](../Tests/Fixtures/FrozenSDKs/README.md)，不再依赖旧本地交付目录才能运行 CI。
