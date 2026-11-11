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
- 不引入第三方运行时依赖；不拷贝 PolyForm Noncommercial 或无许可证的代码（见 `docs/UPSTREAM.md`）。
- 审查重点（每项都会查）：
  1. 触摸期间绝不发电机指令；连接、重连、换层不自动归位。
  2. 输入地址与反馈地址、TX 通道与 Global RX 通道始终分开。
  3. “已发送”不等于“已到位”：`target` / `observed` / 上次指令是三个事实。
  4. 失败可见（通知或监视器），没有静默回退；未实机验证的内容不写成已验证。
  5. 视图里没有业务规则，`ConsoleModel` 之外没有 CoreMIDI 类型泄漏。

## 现状（2026-11-11）

- Core：出厂 Standard MIDI 映射、A/B 层、触摸所有权、反馈去重与失效、两个参数 bank，有测试。
- App：CoreMIDI 传输与端口选择；前端已替换为面板 + 检查器 + 工作区（见下）。
- 前端已完成并在 Mock 模式下实际运行检查：
  - `SurfacePanelView`：8 条通道（编码器、3 个按键、电动推子、推子下按键）、主推子、右侧 8 个编码器、
    Layer A/B、6 个走带键；13 段灯环按 `RingDisplay` + `RingStyle` 绘制，按键 LED 支持闪烁；
    推子可显示触摸高亮、实测位置标记和“电机暂缓”标记（数据到位后自动出现）。
  - `ControlInspectorView`：选中控件的身份、目标 / 实测 / 触摸读数、软件写入滑块、MIDI 地址（有数据才显示）。
  - `WorkspaceTabsView`：数值、MIDI 监视、连接（端口、两个通道、LED 变体）。
  - `ContentView`：顶栏（设备源、电机归位确认、连接状态）、错误条、自适应布局。
- B1 / B2 已接入：Mock 面板手势走设备 TX → 会话 → 设备 RX；实测位置、触摸、电机暂缓、按住状态
  均来自会话，LED / 灯环读取期望状态。触摸期间推子帽按实测位置绘制，软件目标可独立变化。
- 尚未获得位置输入时 `observed` 仍为 `nil`；未发送过灯环样式时 `style` 仍为 `nil`。
  B5 已提供参数标签与带单位详情；未绑定控件保持 nil。B3 已提供当前已应用映射的 MIDI 地址。
- 本轮验证：macOS 上 `swift test --jobs 2`（46 项 Core + 30 项 App + 3 项本地化）与 `swift build` 通过，原生可执行文件
  启动后保持运行 3 秒并正常终止。触摸闭环已做确定性集成测试；鼠标交互目视验收及实机验证尚未完成。

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

- [x] 8 个槽位状态机与确定性 Mock 时间线；绑定按键的主操作（空闲启动、运行中断、等待批准时批准）。
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

沿用 `docs/IMPLEMENTATION_PLAN.md` 的 P1 清单，另外核对前端做出的假设：

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

## 无硬件软件验收补记

B4–B10 与 F1–F6 已实现软件路径；F7 与 HW-1…HW-7 保持待办。说明及边界见
[软件工作流](docs/SOFTWARE_WORKFLOWS.md)。MCP 为本地静态令牌 JSON HTTP 端点，Mock Agent
不是实际外部 Agent；OSC 只有显式启用的受限输出，没有进入电机的接收路径。
启动、截图和网络测试使用隔离模式，不访问用户硬件、文件与 Keychain。
当前没有实机验证结论；预览生成检查不等同于鼠标交互验收。

## 验收审查修复

已补充跨层触摸与层不一致电机门禁、Mock 期间硬件触摸安全所有权、换模式取消旧电机意图、
实测推子吸附不回发自身电机、动作按键非锁存及 Agent 灯同步恢复。
配置编辑与批量分配保留既有数值；重置需独立确认。MCP 禁止远端自行批准，批次先校验并预留限流预算，
工具错误逐项返回；OSC 使用模型排程、注入时间/传输、排程存活心跳及可见停机通知。
另覆盖实际 BCR 文件导入、存储符号链接、通知分离关闭、本地化与空闲 tick 无发布。
实机 HW 清单仍未验收。

返工补记：OSC 静止值可无限期持续输出；tick 先校验旧排程心跳再刷新，真正超时才通知并停机。
重新对齐入口可重发当前层，保留触摸安全所有权；断线丢失 release 的恢复流程见软件工作流。
配置编辑保留两层未绑定控件目标值；死代码已删除，错误参数按显示语言翻译，测试按行为归档。

配置意图追认：`applyConfiguration` 与批量分配保留数值；`loadPreset` 与导入按新配置默认值替换，
已有非默认值时只确认一次。无比例换算，两条路径均不发电机指令。此批契约/视图改动经用户接受，
新增字段和意图在对应提交正文逐项列出，待前端作者审视；之后恢复后端提出、前端修改的约定。
