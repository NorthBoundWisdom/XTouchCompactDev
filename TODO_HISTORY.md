# 历史任务与验收记录（截至 2026-11-12）

> 本文为整理前 TODO 原文快照，仅供追溯；其中“本轮”“当前”“未推送”等均指记录当时。当前任务见 [TODO.md](TODO.md)，不要据此重复启动已完成工作。

# XTouchCompactDev 开发 TODO

> 目标：把 [BCR2000Dev](https://github.com/NorthBoundWisdom/BCR2000Dev) 的产品形态（虚拟面板、参数 / 功能系统、
> Agent 槽位、MCP、OSC、打包发布）移植到 X-TOUCH COMPACT。硬件语义不同，**不照搬 BCR 的 MIDI 假设**。
> 约束见 [AGENTS.md](AGENTS.md)，协议见 [docs/MIDI_PROTOCOL.md](docs/MIDI_PROTOCOL.md)，
> 阶段背景见 [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md)。本文是可执行的任务清单。

## 分工

| 角色 | 负责 | 不碰 |
| --- | --- | --- |
| 前端 | `Sources/XTouchCompactApp` 下的视图、`Theme.swift`、`PanelPresentation.swift`（前端契约）、本文 | Core、CoreMIDI、会话逻辑 |
| 后端（外部窗口） | `Sources/XTouchCompactCore`、`ConsoleModel.swift`、`CoreMIDIService.swift`、`ConsoleModel+Panel.swift`、工具与构建 | 视图文件与契约类型的字段含义 |
| 审查 | 前端作者按本文“验收”逐条审查后端提交 | — |

**唯一的交接面是 `ConsoleModel+Panel.swift`**：视图只读 `PanelSnapshot`、只发 `PanelIntents`。
后端把数据填进快照、把意图接到会话即可点亮对应界面，不需要改任何视图。
契约里的可选字段为 `nil` 表示“后端尚未提供”，界面会隐藏该读数；**不要用猜测值填充**。
需要新增字段或意图时在提交说明里提出，由前端改契约和视图。

### 提交与审查约定

- 一个 B 项一个提交（Conventional Commits），提交正文写明跑过的检查与未验证的部分。
- 每项必须带确定性单元测试，Core 测试保持可在 Linux 上运行；`swift test` 与 `swift build` 全绿。
- 除明确授权的SurfacePlugins共享业务包外不引入第三方运行时依赖；不拷贝 PolyForm Noncommercial 或无许可证的代码（见 `docs/UPSTREAM.md`）。
- 审查重点（每项都会查）：
  1. 触摸期间绝不发电机指令；连接、重连、换层不自动归位。
  2. 输入地址与反馈地址、TX 通道与 Global RX 通道始终分开。
  3. “已发送”不等于“已到位”：`target` / `observed` / 上次指令是三个事实。
  4. 失败可见（通知或监视器），没有静默回退；未实机验证的内容不写成已验证。
  5. 视图里没有业务规则，`ConsoleModel` 之外没有 CoreMIDI 类型泄漏。

## 现状（2026-11-12）

- **软件路径 B1–B10、F1–F6 已完成并经两轮代码审查**；实机验机已开始记录 USB/CoreMIDI 身份及操作员确认的
  Standard 模式指示，HW-1…HW-7 尚未签收，F7 待实测输入。见 [本次验机记录](docs/HARDWARE_SESSION_2026-11-11.md)。
- Core：出厂 Standard MIDI 映射与层无关解码、A/B 两套 bank、触摸所有权（跨层、跨传输、跨重连）、
  层不一致电机门禁、反馈去重与失效、参数 / 功能分配引擎、Mock 设备、共享AgentPlugin七态演示、OSC编码与安全门、受保护存储。
- App：CoreMIDI 传输与端口选择、面板 + 检查器 + 工作区（数值、参数、Agent、MIDI 监视、连接）、
  本机 MCP 端点、受限 OSC 输出、三语界面；运行时排程由模型持有，不依赖窗口。
- 契约：视图只读 `PanelSnapshot`、只发 `PanelIntents`。未获得位置输入时 `observed` 为 `nil`，
  未发送过灯环样式时 `style` 为 `nil`，未绑定控件的 `label` / `detail` 为 `nil`。
- 共享Agent宿主C0–C2已完成：唯一RemoteRegistry拥有插件值；版本1配置翻译为中性动作/指示灯绑定，
  参数使用共享0锚点/平分取低规则。构建只消费Git锁定SHA的build目录副本，见[共享包说明](docs/SURFACE_PLUGINS.md)。
  没有两个宿主之间的源码依赖；跨宿主一致性与Linux验收由工作区监督汇总。
- 共享插件TODO_REVIEW整改阶段，macOS Swift 6.4.2上161项Swift（Core81、App Swift Testing68、
  App XCTest9、本地化3）及25项Python通过；格式、命令和diff校验通过。
  共享事件静默记账/4Hz运动策略、1024容量、2秒gap故障边界已接入；新增surface写预算和默认关闭的模拟管理权限。
  默认instance ID与另一宿主统一，OSC区持续说明可信回传/独立心跳和本版本无内建receiver配置。
  最终产品源与原生Debug/Release/签名/ZIP/DMG/隔离启动证据在工作区reports/C.md按提交记录。
  Linux与实机不由这些检查推定；工作区监督另汇总Linux证据。
- 面板改动 rebase 到 `origin/main`（`42a843a`）后的本地验证：macOS Swift 6.4.2 上
  `swift test --build-path build/swiftpm --jobs 2`（83 项 Core + 89 项 App + 3 项本地化，共 175 项）、
  `swift build`、25 项工作流测试、命令验证与 SwiftFormat/Ruff 检查通过。
  合并后原生应用构建、ad-hoc 签名验证及隔离启动冒烟通过；设备离线，未执行新的实机读回或电机试验。
  此前原生打包、签名、启动冒烟、13 项工作流测试通过；观察页面三种隔离预览已生成并检查。
  调整前最新的 [远端运行 43053024236](https://github.com/NorthBoundWisdom/XTouchCompactDev/actions/runs/43053024236)
  已覆盖观察、重构及非电机工具；当时的 Linux、旧 macOS 和 Xcode 26.6 新 macOS 三条作业均通过。
  用户已确认观察页面的实机 UI 响应；N5 的五项控制台鼠标验收仍单列待完成。
- 当前 CI 仅保留 `core-linux` 与 `app-macos`。后者使用 macOS 26 / 固定 Xcode 26.6，保留格式、测试、
  Debug 原生启动及 Release 打包；2026-11-12 按用户要求移除 macOS 15，并把 modern 作业改名为 `app-macos`。
- 下一步见文末“后续待办”：阶段一（剩余 N5 鼠标验收）→ 阶段二（实机）→ 阶段三（功能方向）。

## 后端任务（按顺序）

### B1 Mock 设备 —— 让面板手势走真实输入路径

BCR 的做法是“Mock 下面板就是硬件”。这里同样需要，否则触摸与电机逻辑在界面上无法演示。

- [x] Core 新增 `MockXTouchCompact`（纯值类型）：持有物理状态（9 个推子位置与触摸、16 个编码器、39 个按键、
  当前层），把手势编码成**设备会发出的 TX 消息**，并消费主机发来的 RX 消息更新自身的 LED、灯环、电机位置。
- [x] 电机模拟确定性：收到电机指令后推子位置立即（或按注入的时钟分步）到位；**被触摸时忽略电机指令**并计数，
  用于断言主机没有发。
- [x] 复现 `docs/MIDI_PROTOCOL.md` 的本地行为：转动编码器覆盖远程灯环、走带键重绘整组 LED、
  物理 A/B 键换层不发消息。
- [x] `ConsoleModel` 在 Mock 模式下把手势交给 Mock，再把 Mock 的输出喂给 `session.receive`；
  会话的反馈回给 Mock。实体模式行为不变。
- [x] 填上意图：`touchFader`、`pushEncoder`、`releaseButton`；`moveFader` / `turnEncoder` / `pressButton`
  改走 Mock 输入路径，`setFader` / `setEncoder` 保持为软件写入。

验收：单测覆盖“触摸 → 软件写入 → 无电机指令 → 松开 → 恰好一条对位指令”的 Mock ↔ 会话闭环；
在界面上拖住推子时从检查器软件写入，推子帽保持在手下并出现暂缓标记，松开后回到目标。

### B2 暴露呈现所需的状态

- [x] `CompactState` 增加只读查询：`observedFader(_:)`、`isTouched(_:)`、`isMotorPending(_:)`、
  `desiredButton(_:)`（含 `.blink`）、`desiredRing(_:)`、`desiredRingStyle(_:)`，以及按住中的按键 / 编码器按下。
- [x] 适配层填上 `FaderPresentation.observed / isTouched / isMotorPending`、
  `EncoderPresentation.style / isPushed`、`ButtonPresentation.isDown`，`ring` 与 `light` 改读会话的期望状态
  而不是从 bank 推算。

验收：每个查询有单测；`PanelPresentationTests.testAdapterReflectsBankValuesAndLeavesUnreportedFieldsNil`
里对 `nil` 的断言改成对真实值的断言。

实现备注：测试已改名为 `testAdapterReflectsSessionStateAndLeavesUnreportedFieldsNil`，仍保留对尚未报告值的
`nil` 断言。切层取消旧层暂缓的电机目标，保留物理触摸；松手不会隐式归位，需再次明确软件写入或手动归位。
App 测试使用 `ConsoleModel(startsMIDI: false)`，不启动真实 CoreMIDI 客户端；MIDI 服务协议注入已在 B4 完成。

### B3 MIDI 地址描述

- [x] `FactoryStandardMap` 增加 `inputAddress(for:layer:)` 与 `feedbackAddress(for:)`，返回结构化地址
  （消息类型、通道、编号），覆盖推子、触摸、编码器、编码器按下、按键；触摸与编码器按下没有反馈地址时返回 nil。
- [x] 适配层用它填 `PanelIntents.addressing`（文本格式如 `CC ch1 #28`、`Note ch1 #0`）。

验收：对 `docs/MIDI_PROTOCOL.md` 两张表逐行断言，含“Layer B 推子 1 输入 CC 28、反馈 CC 1”这一反例。

实现备注：`MIDIAddress` 分离消息类型、零基通道与编号，显示通道为 1–16；Note 地址涵盖按下与释放。
编码器的主反馈地址为灯环显示，额外的 `encoderRingStyleAddress(encoder:)` 描述样式地址；检查器同时标明
`RingDisplay` / `RingStyle`。触摸和编码器按下不伪造反馈地址，非法索引返回 nil。适配层只读取已应用的会话映射，
未点击“应用配置”的通道草稿不会影响显示；地址查询不发送 MIDI。协议表、独立通道及只读适配已覆盖确定性测试，
实机地址仍待 HW 清单验证。

### B4 ConsoleModel 可测试化与通知、监视器模型

- [x] 抽出 `MIDIService` 协议并注入；增加 `startsMIDI: Bool`。`PanelPresentationTests` 使用不启动硬件的模型，服务测试显式注入假服务。
- [x] `error: String?` 改为带级别、可关闭的通知（info / warning / error，可带动作）；持久性问题单独一条。
- [x] MIDI 日志从 `[String]` 改为结构化事件：时间、方向、来源（mock / hardware / agent）、消息、
  对应的 `CompactControl?`、是否被忽略；保留上限。提供清空。
- [x] `configure()` 目前会清空软件数值：改为保留数值，只重建映射并失效反馈缓存；确需重置时显式提示。

验收：已覆盖假 MIDI 服务下重连、发送失败、端口缺失、监视器清空与注入时钟；发送失败后电机历史失效但不自动归位。
配置保留 A/B 数值与物理触摸，取消旧的暂缓指令，松手不隐式归位。持久性通知留由 B6 的存储错误接入。

### B5 参数与功能系统（移植 BCR 的核心价值）

来源参考：BCR2000Dev 的 `SurfaceConfiguration.swift`、`SurfaceEngine.swift`、`SurfaceSession.swift`、
`BulkAssignment.swift`。按 X-TOUCH 语义重写，不要机械改名。

- [x] `ParameterDefinition`（名称、分组、单位、范围、默认值、连续 / 开关、步长吸附、`agentWritable`）。
- [x] 功能分配：`(CompactControl, CompactLayer)` → 参数 / Agent 主操作 / 复位参数组 / 步进 / 指定值 / 循环。
  A、B 两层是两套独立分配。
- [x] 软件参数是唯一事实来源：硬件输入改参数，参数决定反馈（电机、灯环、LED）。同一参数绑定多个控件时互相同步；
  推子的同步遵守触摸仲裁，并明确 Agent 与人同时写入时谁赢（建议：触摸中的人赢，松开后以最后一次软件值对位）。
- [x] 编码器：出厂预设发的是带加速的**绝对值** 0…127；参数映射与灯环 13 段量化分开处理。
- [x] 内置预置：首次启动用中性的默认配置（9 个推子 + 16 个编码器对应通用参数，一行按键对应 Agent 1–8）；
  领域示例作为可显式载入的预置。配置带版本号和设备型号标记，**拒绝载入 BCR2000 的配置**。
- [x] 适配层填 `label` / `detail`（参数名与带单位的值）。

验收：闭环测试“Mock 输入 → 引擎 → Mock 反馈”；导入 BCR 配置被拒并有可见原因；触摸仲裁有测试。

### B6 持久化

来源参考：BCR 的 `JSONFileStore.swift`、`ProtectedJSONFile.swift`。

- [x] `~/Library/Application Support/XTouchCompactConsole/` 下保存功能配置、设备档案（两个通道、LED 变体、
  手动端口选择）。非法文件保留原件并另存指纹备份，显示持续提示；保存失败不伪装成功。
- [x] 设备档案永不被静默改写；手动选择的端口缺失时不自动换路由。
- [x] 冒烟 / 集成测试使用临时目录，不碰用户文件与 Keychain。

### B7 Agent 槽位与 Mock Agent

来源参考：BCR 的 `AgentModels.swift`、`ConsoleViewModel+Agents.swift`。

- [x] 8个共享AgentPlugin槽位与七态Mock时间线；空闲启动进入queued，+0.45秒running，+2.65秒等待批准，
  批准后+2.25秒完成。硬件和界面可批准，远程禁止自批；状态机仅在共享包中。
- [x] LED 映射利用本设备的闪烁能力：例如等待批准 = 闪烁，运行 = 常亮。两种 LED 速度编码都要有测试。

### B8 通用 MCP 接口

来源参考：BCR 的 `MCPRouter.swift`、`MCPModels.swift`、`MCPInputValidation.swift`、`MCPHTTPServer.swift`、
`MCPController.swift`、`docs/MCP.md`。

- [x] 仅绑定 127.0.0.1、默认关闭、Token 存 Keychain、权限与限速、调用记录。
- [x] Agent 写入与界面写入走同一管线，推子写入同样受触摸仲裁；监视器标为 AGENT。
- [x] 工具 schema 暴露层与触摸状态，让客户端知道一次写入是否被暂缓。

### B9 OSC 输出与安全门

来源参考：BCR 的 `MotionSafetyGate.swift`、`OSCCodec.swift`、`OutputController.swift`、`OSCParameterAdapter.swift`。

- [x] 移植安全门（限位、限速、心跳、先关后开使能、启动不自动恢复输出）。
- [x] 评估“实际回传 → 电动推子”：只有在触摸仲裁和归位确认都成立时才允许回传驱动电机，默认关闭。

### B10 构建、打包与工具链

来源参考：BCR 的 `configs/`（`macos_workflow.py`、`app_build.json`、`format_repo.py`、`githooks/`）、
`tools/mcp_integration.py`、`tools/capture_readme_screenshots.py`、`CONTRIBUTING.md`、`assets/`。

- [x] `.app` 构建、ad-hoc 签名、ZIP / DMG、校验和；启动冒烟（`--startup-smoke`）。
- [x] 隔离集成测试模式（独立目录与内存凭据），供原生验收与截图脚本使用。
- [x] SwiftFormat / Ruff 提交钩子与 `CONTRIBUTING.md`；CI 增加 App 测试目标与格式检查。
- [x] 不移植 DriverKit 相关内容：没有证据表明本设备需要。

### HW 实机到货后（需现场操作，逐项记录到 `docs/`）

沿用 `docs/IMPLEMENTATION_PLAN.md` 的 P1 清单，另外核对前端做出的假设。按三个阶段做，前一阶段没记录完不进下一阶段：

1. **只听不发**（Hardware 模式下不做任何软件写入）：HW-1、HW-7、HW-2、HW-3。
2. **非电机输出**（一次一个控件）：HW-5、HW-4，以及下面的假设 2。
3. **电机输出**（单个推子、小步、手离开面板）：HW-6，以及下面的假设 3。

电机安全策略建立在三条**未验证的固件行为假设**上，任何一条不成立都要先改 Core 再继续：

1. 物理 A/B 键换层后，设备改用另一层的 TX 地址发送（主机靠这一点发现层不一致）；
   触摸中换层时，松手事件用哪一层的地址发出。属阶段 1。
2. 设备收到 Program Change 后确实切到主机指定的层（“重新对齐”依赖这一点）。属阶段 2。
3. 电机运动过程中设备是否回报推子位置；当前策略把“未触摸的位置回报”一律视为可能的电机进度，不驱动任何电机。属阶段 3。

- [ ] HW-1 端口名、VID / PID、固件版本、TX 通道与 Global RX 通道。
- [ ] HW-2 **按键编号与物理位置**：前端假设 1–24 是编码器下方三行（每行 8 个），25–32 在推子下方，
  33 是主推子按键，34–39 是走带键（上排 快退 / 快进 / 循环，下排 录音 / 停止 / 播放）。逐键按下核对，
  不符时只改 `PanelLayout`。
- [ ] HW-3 编码器编号：前端假设 1–8 是顶排，9–16 是右侧两列四行、按行读。
- [ ] HW-4 灯环五种样式的实际点亮方式（`RingLEDs` 里 pan / fan / spread / trim 是近似画法）与灯环、按键 LED 颜色。
- [ ] HW-5 按键 LED 速度编码（0/1/2 还是 0/2/3）、闪烁节奏。
- [ ] HW-6 单个推子慢速小步电机测试、触摸时停止、松开对位；确认无电机反馈回路。
- [ ] HW-7 物理 A/B 键按下时的实际行为，以及主机如何发现层不一致。

## 前端后续（等对应后端项完成后由前端做）

- [x] F1 参数工作区、参数编辑与功能分配编辑器、批量分配（依赖 B5）。
- [x] F2 Agent 工作区（依赖 B7）。
- [x] F3 MCP 设置与输出设置面板、输出读数（依赖 B8、B9）。
- [x] F4 “载入预置…”与按需启用的专业面板菜单（依赖 B5、B6）。
- [x] F5 结构化 MIDI 监视（方向、来源、对应控件、清空）与可关闭通知条（依赖 B4）。
- [x] F6 无标题栏窗口、应用图标、README 截图与截图脚本（依赖 B10）。
- [ ] F7 实机核对后的面板修正（依赖 HW-2…HW-5）。
  - 主推子上方已补 INTERFACE（USB）、MIDI（IN / OUT）、FOOT（SW / EXP）、MODE（MC）四组状态灯。
    Mock 的 USB 常亮，MIDI 按设备视角收发短亮 200 ms，未模拟踏板操作时 FOOT 熄灭，Standard 模式 MC 熄灭。
    新增前端契约 `PanelSnapshot.surfaceStatus`；真机六灯均保留 nil（界面标为未知），不从端口、USB MIDI 流量或已发送指令推断物理灯态。
    MIDI 短亮时长与 FOOT / MIDI 灯颜色为 UI 模拟，尚未实机验证。
  - 已移除观察面板的“最近的实体操作”卡片；通过“启用写回”显式退出观察并关闭只听模式。
    启用本身不发送 MIDI，不重放旧目标；触摸与层不一致门禁保留。`--hardware-control` 可显式启动到实体写回控制台。
  - 根据 2026-11-12 操作员校准，E9–E16 面板模拟左半灯逐颗熄灭、中点保留中心灯、右半灯逐颗亮起；
    E1–E8 增加单灯 / 相邻双灯过渡。新增 `EncoderPresentation.localRingAppearance`，与 MIDI `style`、物理读数分开。
    已匹配左侧值 18 / 22 / 32 / 43、中点 64、右端 127，以及顶排双灯值 6 / 10；其余区间插值近似。
    未确认对应硬件样式编号、完整切换边界或各层一致性，不写设备预设。见 [灯环校准](docs/RING_CALIBRATION_2026-11-12.md)。
  - 启动镜像新增 `hardwareValues` 实体数值历史（按输入 UID / 已配置 TX 通道隔离，编码器按层保存），
    缓存以“≈”标记、未知显示“—”；不会把缓存或已发指令当作本次实测，也不恢复触摸或自动回放电机目标。
    `PanelSnapshot.hardwareDisplayLayer` 与软件层分离，B 层位置可显示而不改 A 层参数或解除层门禁。
    实机现场观察到仅触摸发送 101…109 / 111…119 的 127 / 0；移动 F1 后收到 Layer B 的 CC28=1…8。
    这不是全量读回验证；官方表未列出全量位置查询也不证明不支持。缓存是备用方案，未探测或发送未知 SysEx。
  - [ ] **启动全量真实位置读回仍待验证，不能写成“不支持”**：分别检查设备上电、USB 重连、App 接入时的
    主动回报及已知只读查询，并排除监听太晚或解析过滤。先前“不可能读取”的判断已撤回；设备离线时仅更新此记录。
    若验证可读，应优先用真实回报同步面板；读取与电机驱动分开，启动不自动归位。见 [调查记录](docs/STARTUP_READBACK_INVESTIGATION.md)。

## 验收记录

- 无硬件软件验收：B4–B10 与 F1–F6 的边界见 [软件工作流](docs/SOFTWARE_WORKFLOWS.md)。MCP 为本机静态令牌
  JSON HTTP 端点，Mock Agent 不是实际外部 Agent；OSC 只有显式启用的受限输出，没有进入电机的接收路径。
  启动、截图和网络测试使用隔离模式，不访问用户硬件、文件与 Keychain。
- 代码审查修复（提交 `90fd823`…`1ccd038`，每个提交正文列出契约变更与检查项）：
  - 触摸：层无关解码、跨层 / 跨模式 / 跨重连的触摸所有权、层不一致时挡住全部电机输出、显式“重新对齐当前层”。
  - 电机：实体推子回报不驱动自身电机；未触摸的回报不驱动任何电机。
  - LED：动作键与未分配键不再锁存；Agent 灯由会话缓存，换层、重连、套用配置时同步恢复。
  - MCP：批次先整体校验并预留限速预算；未知方法返回 -32601；远端不能批准等待中的槽位。
  - OSC：模型排程、可注入时钟与传输、排程存活心跳（静止值可持续输出）、停机必有通知。
  - 配置：`applyConfiguration` 与批量分配保留数值；`loadPreset` 与导入改用新配置默认值并只确认一次；
    非 X-TOUCH COMPACT 配置在文件路径上被拒并给出原因；存储拒绝符号链接。
- 此批契约 / 视图改动由后端直接完成，属一次性例外；之后恢复“后端在提交说明里提出、前端改契约和视图”。

## 后续待办

### 已完成

- [x] N1 **远端 CI 必需检查转绿**（最近一次：[运行 43001312226](https://github.com/NorthBoundWisdom/XTouchCompactDev/actions/runs/43001312226)）。
  `core-linux`（官方 `swift:6.2-noble` 容器）与 `app-macos`（macos-15，Swift 6.1.2：建置、全部测试、签名打包、启动冒烟）通过。
  经过：
  - `eea7a22`：SwiftPM 原生构建把 `zh-Hans.lproj` 输出成小写，本地化查找强制解包崩溃；改为兼容小写并回退英文。
  - `9302a27`、`1a99f43`：Swift 6.1.2 拒绝 Network 回调里隐式捕获的 `self`；七处 MainActor Task 显式再捕获并用具名引用，未关闭并发检查。
  - `95f2d89`：runner 上截图进程 30 秒超时，原因未查明；截图改为手动 `capture_previews` 诊断，默认关闭，见 N6。
  - `77bd10a`：`actions/checkout` 升到 v7.0.1，Linux 改用官方容器，消除 Node 20 弃用警告。

### 阶段一：现在可做，不依赖硬件

按顺序做，N2–N5 是进入实机阶段前的门槛：

- [x] N2 **前端作者审视契约与视图改动**：`PanelSnapshot.pendingPreset`、`mcpPort`；`PanelIntents.realignLayer`、
  `resetParameters`、`applyConfiguration`（取代 `loadConfiguration`）、`loadPreset`、`confirmLoadPreset`、
  `cancelLoadPreset`；视图 `ParameterWorkspace`、`WorkspaceTabsView`、`ExternalServicesSettings`。
- [x] N3 `confirmLoadPreset` 改为无参数，由模型使用自己的 `pendingPreset`（契约改动，前端做；随 N2 一起）。
- [x] N4 **B10 工具链审查**：已审查 `configs/*.py`、`tools/*.py`、提交钩子与打包流程，修复路径/语言资源/冒烟校验问题；见 [审查记录](docs/reviews/N2-N8.md)。
- [ ] N5 **鼠标交互目视验收**：Mock 模式下逐项过一遍并把结果记到 `docs/`——拖住推子时软件写入出现暂缓标记、松手对位；
  层不一致警告与重新对齐；预置替换确认框；OSC 停机通知；MCP 开关与令牌复制。
  本次原生工具返回 `cgWindowNotFound` / 超时，未取得可操作窗口；[验收步骤与阻塞记录](docs/NATIVE_ACCEPTANCE.md)。
- [x] N7 **实机记录准备**（后端提出、前端做界面）：
  - MIDI 监视器目前只保留最近 120 条且不能导出，阶段 1 的逐控件抓取没法留档。增加“导出监视记录”或抓取会话
    （带时间、原始字节、解码结果、主机当前层），输出到用户选择的文件。
  - 新建 `docs/HARDWARE_BRINGUP.md` 记录模板：HW-1…HW-7 各一节，写明操作步骤、预期、实际、抓取文件名和结论。
  - Hardware 模式增加“只听不发”开关（阶段 1 用）：打开时不向设备发送任何消息，包括连接时的 Program Change 和 LED 同步。
    现在切到 Hardware 会立即发层断言和非电机反馈，做不到纯被动抓取。

可延后，不挡实机：

- [x] N6 远端截图超时：旧窗口 `.task` 入口在运行 43005877417 再次超时；改为独立 AppKit 入口后，
  [手动作业 43006052440](https://github.com/NorthBoundWisdom/XTouchCompactDev/actions/runs/43006052440) 五张预览全部通过。
  已下载并目视核对产物；加入阶段日志、超时采样、进程回收与诊断产物保留。截图仍为按需作业。
- [x] N8 编译器版本覆盖：保留旧 macOS / Linux 6.2 作业，新增明确选择 Xcode 26.6 的 `app-macos-modern`。
  实际 Swift 6.3.3 的完整测试、建置、签名应用和启动冒烟已在运行 43007338487 通过；版本门禁拒绝低于 6.2 的编译器。
  本机仍为 Swift 6.4.2，明确接受这一小段差异；没有放宽 Swift 6 并发检查。
  以上为历史三作业方案；2026-11-12 已按用户要求合并为 Linux + macOS 26 两作业，modern 改名 `app-macos`，不再保留 macOS 15。

### 阶段二：实机到货后

- [x] 按用户要求增加前端“硬件观察”页面：触摸/松手高亮、实测位置跟随、旋钮/按键输入、最近操作与覆盖计数；
  未报告值保持未知，输入层与主机层分开；锁定只听不发，不执行参数分配或 Agent 操作。
  `--hardware-observe` 可直接启动并选择 JSONL 录制路径。三种原生离屏预览已检查；用户已确认实机 UI 响应正常，
  56 条真实触摸/松手输入及其覆盖范围已记录，未发送输出。此确认不替代 HW 全部项目及 N5 五项验收。
  此次前端契约和观察适配由同一任务按用户明确要求完成；没有更改硬件配置。
- [ ] HW-1…HW-7（见上，按三个阶段的顺序），每项结果记到 `docs/HARDWARE_BRINGUP.md`。
- [ ] 三条固件假设逐条写明成立或不成立；不成立的先改 Core 并补测试，再继续输出测试。
- [ ] F7 按 HW-2…HW-5 的结果修正面板；`docs/MIDI_PROTOCOL.md` 把“未实测”的标注改成实测结论。
- [ ] 实机通过后更新 README 的阶段说明；是否打版本 tag 由用户决定。

### 接下来的提交拆分

本轮整理按两项本地提交交付：`343a354` 纯状态与显示契约的重构，以及实机证据/后续计划文档。
`CompactInputObserver` 已移到 Core；前端契约集中在 `PanelPresentation.swift`，单一适配层负责状态映射和通道显示换算。
现有观察界面及只听不发策略保持不变。后续每行独立提交，功能未实施前不勾选：

| 顺序 | 建议提交 | 范围与验收 | 前置 |
| --- | --- | --- | --- |
| C1 | `fix(capture): preserve existing evidence and record session metadata` | 已实现：拒绝覆盖，记录应用提交、端口、已配置通道与未知硬件字段。测试已存在文件、写入失败、正常结束及缺失结束标记；原始证据不进 Git | `7b05211`，无需硬件输出 |
| C2 | `feat(bringup): add per-layer input coverage review` | A/B 分层显示位置范围、触摸/松手配对、编码器/按键覆盖；导出带指纹的检查摘要。补 F6、全部位置、16 编码器及按下、39 按键、跨层松手证据；覆盖计数不自动等同验收通过 | C1；操作员在观察页面操作设备 |
| C3 | `feat(bringup): add explicit nonmotor test controls` | 只提供单个按键 off/on/blink、单个灯环及显式层断言；两种 LED 编码分开，保存实际响应。白名单测试保证不产生推子电机指令 | Stage 1 记录审查完成；独立确认 Global RX，不能从 TX 推断 |
| C4 | `feat(bringup): add single-fader motor acceptance` | 单推子小步、触摸阻断与松手一次对位、层不一致、重连和无回路验收；需要新鲜实测位置与明确操作，不自动移动、不使用全体归位 | Stage 2 及固件假设 1/2 已成立，再由操作员执行 Stage 3 |
| C5 | `docs: sign off hardware bringup with scoped evidence` | 按证据更新 HW-1…HW-7、F7、协议与 README；未测内容继续保留未知。N5 五项单独填写实际结果 | 对应现场项目完成，不按代码测试推定通过 |

- [x] C1 软件实现：描述符独占创建证据文件、拒绝覆盖/符号链接，失败可见且不补写成功结束标记；
  录制头记录构建提交/脏工作区、已连接和手选端口、已应用 TX/RX，实际 Global RX 与固件保留未知。
  工作流将可核验的构建来源嵌入应用；Swift 与工作流测试覆盖写入/刷新失败及元数据边界。
- [x] C2 软件实现：A/B 分层 89 个输入动作的范围、按下/松手配对、异常与实际地址；
  记录按下层、保持期间另一层的输入及松手地址层（包括松手仍沿用旧层地址）。
  导出 JSON、SHA-256 校验和与原始录制快照；显式区分实时前缀、完整录制和无原始录制。
  连接变化写入录制；输入身份切换或应用 TX 改变会重新累计覆盖，安全触摸所有权仍保留。
- [ ] C2 实体验收：在新版 **A/B 覆盖检查** 中完成两层全部控件及跨层松手，停止录制并导出摘要。
  当前仅有已确认的观察 UI 和旧录制的 56 条 A 层触摸输入，不能据此签收其他控件/层/固件假设。
- [x] C3 软件准备（按用户要求先继续开发）：有类型的单键灯/灯环/层断言命令、原始字节预览、
  操作员前置确认、单条发送与人工结果记录；默认许可为空，RX 不从 TX 推断，测试选择不改设备档案。
  写前审计刷新成功后才允许发送；端口 ID 与连接代数在 CoreMIDI 队列中再核对，普通参数/Agent 回馈仍被阻断。
  断线/重连、换端口、改配置、停止/失败录制、清空观察或离开测试页面会撤销许可，且不自动重试或清理灯光。
- [ ] C3 实体验收：完整 Stage 1 记录审查后，独立确认 Global RX 与固件版本，再由操作员显式允许输出；
  核对两套 LED 编码、灯环样式、层断言及实际响应，记录在抓取文件和摘要。当前没有 C3 实机结论。
- [ ] C4 仍等待现场前置：Stage 1/2 与固件假设 1/2 完成后再推进单推子电机验收；
  若实机推翻固件假设，先修 Core 与回归测试，不按模拟测试推定实机已通过。

后续需要推送时先核对远端 main，保持正常提交历史，观察现有 `core-linux` / `app-macos` 两条 CI；没有新需求就不修改 CI 配置。
本轮不发布版本，不改硬件档案，不提前实现 D1–D5；实机结论齐备后再确认参数数值持久化与真实 Agent 的产品方向。

### 阶段三：实机验证之后的功能方向

需要先定方向再开任务。建议顺序是 D1 → D3 → D4 → D2，D5 最后：

- [ ] D1 参数数值是否持久化。现在只保存配置与设备档案，数值是会话状态，重启回到默认值。
  改动小、对日常使用影响大，建议最先定；无论怎么定，启动都不得自动归位电机。
- [ ] D3 MCP 权限目前只有“允许写入”一个开关加参数级 `agentWritable`；接入真实 Agent 前是否需要更细的授权。D4 的前置。
- [ ] D4 真实外部 Agent 进程接入（现在只有 Mock 时间线）。依赖 D3 与实机上的触摸仲裁验证。
- [ ] D2 OSC 输出目前只有一个参数、固定地址 `/xtouch/value`；是否需要多参数与可配置地址。有具体接收端需求时再做。
- [ ] D5 Mackie Control 模式、编辑器预置导入、相对编码器模式：见 `docs/IMPLEMENTATION_PLAN.md` 的 P2，特性化之前不做。


## 共享插件迁移（本轮）

- [x] C0：130项基线测试；锁定Agent灯光/自批限制/无电机边界，保留nonmotor工作台。
- [x] C1：共享参数规则、版本1配置兼容、固定远端/完整SHA锁与Git物化获取。
- [x] C2：七态Agent、原子注册、中性ActionReference/IndicatorID、多实例隔离、来源审批。
- [x] C3：架构/构建/参数及Agent时间线说明对齐。跨宿主M1由监督窗口验收。
- [x] M2：显式可选机器人、底盘、参数输出与示例参数集装配；默认仍只Agent。OSC改用共享安全门，
  缺少可信actual/独立heartbeat时保持关闭；带独立保护字段的示例采用v2配置，旧v1原shape不变。
- [x] M3：共享surface_远程合同、capabilities/events与独立typed bindings；保留旧get_state/set_parameter/agent_primary。
  同一registry拥有GUI/clock/旧与新工具的plugin值；mutation仍需宿主写权限，output enable默认拒。

用户本轮明确授权同一开发线程负责必要的PanelSnapshot/PanelIntents、适配器和视图调整；
这不改变视图只读快照/只发意图的边界。实机记录与既有HW/N5/C4等未验收项目保持原状态。


### TODO_REVIEW 本轮收敛

- [x] P1：HB/actual静默提交，output只在status/reason/parameterID/limited改变时写事件；最新值和UI仍每步提交。
  sim idle静默，motion最多4Hz且critical即时；1024容量与慢cursor真实溢出测试保留。
- [x] P2-1：new surface独立60次/1秒预算；reset需写权限加默认关闭的simulation administration，realtime始终拒remote advance。
  legacy三工具的权限、schema/envelope和错误语义保持。
- [x] P2-2：两模拟器显式2秒最大catch-up，过大gap fault/revoke而不追帧；未知actual不冒充stopped，小步不清fault或自动恢复。
- [x] P2-3：默认instance IDs使用共享constants：agent.mock/robot.reference/chassis.reference/output.parameters；无short-ID alias。
- [x] P3-6：OSC设置区持续展示三语可信destination actual/独立heartbeat及无内建receiver配置说明，心跳帮助改实际0.3秒。

硬件/鼠标验收与旧实机checklist状态不由本轮代码/离屏预览签收；U1发布仍暂停。


## 上游后继补记：4d91cec

本次rebase保留上游已实现的参数数值持久化、独立Agent电机授权和踏板输入。它们取代上面原始快照中的D1/D3待定状态；当前结论见TODO.md。N5增加两项后共七项，仍需人工填写；踏板极性/范围等仍未实测。原历史快照不改写为已经完成这些后继。
