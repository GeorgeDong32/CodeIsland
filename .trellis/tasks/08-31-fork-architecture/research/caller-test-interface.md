# InteractionCenter：调用方接口与 trace 测试研究

> 本文是 `.trellis/tasks/08-31-fork-architecture/prd.md` 的调用方/测试研究，目标是为 `design.md` 和 `implement.md` 提供可直接落地的 Interface、seam、Adapter 与验收证据。本文不改变产品代码。

## 结论摘要

建议把 `InteractionCenter` 做成一个单写 Interface 的深模块：

```swift
protocol InteractionCenter {
    var snapshot: InteractionSnapshot { get }
    mutating func send(_ input: InteractionInput) -> [InteractionEffect]
}
```

所有调用方只需要学习 `Input → Effect → Snapshot` 三件事：

- Hook adapter 和 Codex app-server adapter 把外部协议规范化成 `InteractionInput`，保存自己的 connection/continuation/JSON-RPC request id，并执行 Center 返回的 transport effect。
- session reconciliation adapter 把 upstream 的 `SessionSnapshot`、discovery 或 app-server 状态映射成只读 `SessionObservation`，不能把 `SessionSnapshot` 交给 Center 让其重新解析。
- SwiftUI、快捷键、Buddy/companion 只读取 `InteractionSnapshot`，用稳定的 `RequestID` 发送动作；不能读取或修改 queue、continuation、协议 payload 或 Auto 内部状态。

这会让 Center 的 Interface 成为唯一的测试面。测试可以用同一组输入序列驱动模型，断言规范化 snapshot 和声明式 effects，不依赖 SwiftUI、NWConnection、CheckedContinuation、Codex 进程或内部数组。

## 现状证据：调用方现在各自拥有一部分状态机

### Hook adapter

`HookServer.processRequest` 先做 sub-session byte probe/JSON 路由，再构造 `HookEvent`，然后在同一个大型文件中做 source filter、Auto approve、Codex auto-review defer、AskUserQuestion 分流，并把 continuation 直接交给 `AppState`（`Sources/CodeIsland/HookServer.swift:654-817`）。Permission 和 question 的 connection teardown 也由这里监控；disconnect 时按 session 调 `handlePeerDisconnect`，而不是按 request/transport token 定位（`HookServer.swift:819-870`）。

这带来两个 seam 问题：

1. Hook protocol 的解析/过滤本来适合 upstream-owned adapter，但 fork policy（Auto、是否展示、请求生命周期）现在混在 transport 文件里。
2. “一条 connection 对一个 session”不等于“一条 connection 对一个 request”。多个并行工具请求、replay 或同 session 的不同 request 会使 session 级 disconnect 误伤其他 request。

### AppState 与 Hook request

`AppState` 目前公开可变的 `permissionQueue`、`questionQueue`、`dismissedPermissionSessionIds`，并保存单一的 `autoApproveSessionId`/`autoApproveModeSnapshot`（`Sources/CodeIsland/AppState.swift:118-230`）。Permission 的 replay 通过同 `tool_use_id` 替换 continuation；输入不同则入队（`AppState.swift:1550-1564` 及 `AppState+ToolUseCache.swift`）。

回答会直接从 queue 移除 request、组装 provider-specific JSON、resume continuation；dismiss 只写 session-level Set；disconnect/drain 会按 session 为全部等待项 deny 或返回空（`AppState.swift:1650-1705`, `1880-1980`, `2070-2140`, `2300-2390`）。这些是应保留的可观察行为，但不应再是 UI 或 Center 的传输实现。

现有回归测试已经捕获了迁移必须保留的事实：

- dismiss 后 request 仍 pending，peer disconnect 才结束它（`AppStatePermissionFlowTests.swift`）。
- stale card 的 action 不能答错另一个 session；`expectedSessionId` 是当前临时的防护（`AppStateAnswerRoutingTests.swift`）。
- replay 的 request 不能重新唤醒已 dismiss 的卡片；同 ID 但不同 input 必须被视为新 request（`AppStatePermissionGateTests.swift`）。
- 一个 session 的旧卡被 drain 后不能挡住其他 session；不能以全 queue 非空判断当前卡仍然有效（`AppStatePermissionGateTests.swift`）。

迁移时应把这些测试重写为 Center trace，而不是继续增加对 queue 的白盒断言。

### Codex app-server adapter

Codex app-server 不是 Hook connection：`item/tool/requestUserInput` 是 server→client JSON-RPC request，AppState 当前把 `requestId` 捕获到 `QuestionResolution.codexAppServer` 闭包中；`serverRequest/resolved` 则不回包而直接移除 question（`Sources/CodeIsland/AppState+CodexAppServer.swift:230-370`）。断开时只清理 app-server question，Hook-backed continuation 保留。

因此 `TransportToken` 必须是不透明的 adapter-owned token，不能假定所有 transport 都是 `Data` continuation，也不能用 session id 代替 request id。Codex adapter 必须证明：外部 resolved 后不会再发 JSON-RPC response，replacement client 不会复用旧 request 的 token。

### Session reconciliation

Hook event 的 session 状态先由 `reduceEvent` 改写 `SessionSnapshot`，再由 `AppState.handleEvent` 做异步 branch/title/transcript 等工作；discovery 则由 `integrateDiscovered` 按 provider id、source、cwd、PID、native-app namespace 等规则合并（`Sources/CodeIslandCore/SessionSnapshot.swift:931-1288`, `Sources/CodeIsland/AppState.swift:3154-3370`）。恢复持久化 session 时还会加载 `observedPermissionMode`（`Sources/CodeIsland/SessionPersistence.swift:4-101`, `AppState.swift:2783-2875`）。

这说明 Center 不应成为第二个 session reducer，也不应复制 discovery 的合并启发式。它需要一个唯一的 `reconcile` seam，接收 upstream 已决定好的、足够小的观察投影；新 upstream 事实只替换 adapter 的映射。

### SwiftUI、快捷键和外围输出

`NotchPanelView` 按 `surface` 决定卡片，再按 session 在全局 queue 中找 request，直接调用 `approvePermission`, `answerQuestion`, `skipQuestion`, `dismissPermissionPrompt`（`Sources/CodeIsland/NotchPanelView.swift:190-275`）。`ApprovalBar`、`QuestionBar`、`SessionCard` 还分别复制 terminal activation、三次可见性验证、失败声音/shake 和 auto-collapse（`NotchPanelView.swift:1005-1199`, `1215-1618`, `2300-2670`）。

快捷键同样直接从 `surface` 读取 session 并调用 AppState（`Sources/CodeIsland/AppDelegate.swift:226-254`）；ESP32/Apple Companion 读取 queue head 并把数据投影到其他设备（`Sources/CodeIsland/ESP32StatePublisher.swift:190-240`）。这些都应成为 snapshot/effect adapter，特别是任何“当前 request”都必须显式携带 `RequestID`，而不是隐式使用 head。

## 推荐的深模块与 seam

### 1. Center 的外部 Interface

建议生产实现分成一个纯模型和一个 observation store，但对调用方暴露同一个 Interface：

```swift
struct InteractionCenterModel {
    init(configuration: InteractionConfiguration)
    var snapshot: InteractionSnapshot { get }
    mutating func send(_ input: InteractionInput) -> [InteractionEffect]
}

@MainActor
@Observable
final class InteractionCenterStore {
    var snapshot: InteractionSnapshot { get }
    func send(_ input: InteractionInput) -> [InteractionEffect]
}
```

`InteractionCenterStore` 只负责串行调用 model、发布 snapshot、把 effects 交给 App/adapter 执行；规则都在 model 后面。测试直接使用 model，避免 `@MainActor` 和 SwiftUI 生命周期污染 trace。 `send` 要求在一个串行执行上下文中调用；同一输入只能被消费一次。若实现用 class 而不是 struct，仍必须保持上述单一写 Interface。

建议的公开值类型（名字可调整，但语义不应缩减）：

```swift
struct SessionID: Hashable, Codable, Sendable { let rawValue: String }
struct RequestID: Hashable, Codable, Sendable {
    let sourceNamespace: String
    let value: String
}
struct EffectID: Hashable, Codable, Sendable { let rawValue: UUID }
struct TransportToken: Hashable, Sendable { let rawValue: UUID }

enum InteractionInput: Sendable {
    case sessionObserved(SessionObservation)
    case requestArrived(InteractionRequestArrival)
    case userAction(InteractionAction)
    case transportEvent(InteractionTransportEvent)
    case externalResolution(ExternalResolution)
    case sessionRemoved(SessionRemoval)
    case presentationPolicyChanged(PresentationPolicy)
}

enum InteractionAction: Sendable {
    case allowOnce(requestID: RequestID)
    case allowAlways(requestID: RequestID)
    case deny(requestID: RequestID)
    case answer(requestID: RequestID, answers: [AnswerValue])
    case dismiss(requestID: RequestID)
    case reveal(requestID: RequestID)
    case setAuto(sessionID: SessionID, mode: RequestedAutoMode)
    case navigate(sessionID: SessionID, requestID: RequestID?)
}
```

`InteractionRequestArrival` 至少包含 `requestID`、`sessionID`、`kind`、安全的展示 payload、`transportToken`、adapter 声明的 capabilities 和 arrival ordinal（由 Center 生成）。`kind` 是 `.permission`, `.plan`, `.question`，不能让 UI 通过 tool/source 字符串猜 variant。Question payload 要保留 answer key、顺序、multi-select、secret 标记；secret 文本不能进入 companion/日志 projection。

`SessionObservation` 是 upstream projection，不是 `SessionSnapshot` 的别名：

```swift
struct SessionObservation: Sendable {
    let sessionID: SessionID
    let source: String
    let providerSessionID: String?
    let cwd: String?
    let terminal: TerminalIdentityObservation
    let status: UpstreamSessionStatus
    let permissionMode: String?
    let isRemote: Bool
    let providerLifecycle: ProviderLifecycleObservation
    // display-only upstream fields can be added deliberately, not by exposing Snapshot.
}
```

其中 `permissionMode` 是 CLI/upstream 已观察到的事实；`requestedMode`、dismiss、presentation、navigation capability 等 fork-owned 字段不能加入 `SessionSnapshot` 或 observation。 `sessionRemoved` 必须带 generation/identity（至少 `SessionID` 加 provider generation），避免旧 discovery 结果重建已关闭的同名 session。

### 2. Snapshot 是 UI 的唯一读面

```swift
struct InteractionSnapshot: Equatable, Sendable {
    let sessions: [SessionID: InteractionSessionSnapshot]
    let requests: [RequestID: InteractionRequestSnapshot]
    let presentation: PresentationSnapshot
    let autoBySession: [SessionID: AutoSnapshot]
}

struct InteractionRequestSnapshot: Equatable, Sendable {
    let id: RequestID
    let sessionID: SessionID
    let kind: RequestKind
    let lifecycle: RequestLifecycle
    let presentation: RequestPresentation
    let capabilities: ResolutionCapabilities
    let transportState: TransportState
    let error: InteractionError?
}
```

Snapshot 应提供 UI 需要的 typed projection（例如 `prominentRequest`, `pendingCountsByKind`, `sessionIdentity`, `badgeState`），不提供可变 queue、continuation 或原始 provider JSON。SwiftUI 只 switch `presentation` 和 `request.kind`，不再通过 `SessionSnapshot.permissionMode` 推断 Auto，也不再用 `queue.firstIndex` 计算动作目标。

### 3. Effects 是 adapter 的唯一执行面

```swift
enum InteractionEffect: Sendable {
    case deliverResolution(
        effectID: EffectID,
        requestID: RequestID,
        token: TransportToken,
        resolution: ResolutionIntent
    )
    case changeProviderAuto(
        effectID: EffectID,
        sessionID: SessionID,
        token: TransportToken?,
        mode: RequestedAutoMode
    )
    case cancelTransport(
        effectID: EffectID,
        requestID: RequestID,
        token: TransportToken
    )
    case requestNavigation(NavigationRequest)
    case present(requestID: RequestID, reason: PresentationReason)
    case collapse(reason: CollapseReason)
    case playSound(SoundCue)
    case scheduleCompletion(SessionID)
}
```

Center 不产出 `Data`、`NWConnection`、`CheckedContinuation` 或 JSON-RPC client。 `ResolutionIntent` 是 `.allow`, `.allowAlways`, `.deny`, `.answer(...)` 或 adapter capability 对应的明确 action；Plan 的 plain allow 不叫 `skip`。 `present/collapse/playSound` 是声明式结果，UI/OS adapter 负责动画和具体声音。

EffectID 与 RequestID 必须同时出现：RequestID 是业务生命周期，EffectID 是一次命令尝试。重复 transport ack 以 EffectID 去重；旧 effect 的 ack 不能改变新 generation。

## 状态不变量（Interface 的一部分）

这些不变量要写进 `InteractionCenter` 的文档注释，并由 trace/property tests 验证；它们不是 implementation detail。

### 请求身份和 replay

1. RequestID 必须是 source namespace 限定的稳定身份。可靠 upstream id 只能由 adapter 在有足够证据时用于关联；`tool_use_id` 本身不能证明 replay，因为当前测试已证明并行调用可能共享它。
2. adapter 无法证明关联时必须为每次 arrival 生成 occurrence ID；不能用内容 fingerprint 猜测合并。
3. replay 绑定旧 lifecycle，保留 `dismissed`、队列位置和 resolution 状态；旧 transport token 先终结，再允许 replacement token 绑定。已完成的用户命令不能因为 replay 再执行。
4. App 重启后不持久化/猜测 pending identity；等待 CLI 重新上报。持久化只恢复 upstream session display metadata 和导航所需事实。

### Queue、presentation 和 stale action

1. queue 是每个 session 的 request ordinal；所有 variant 共用这一 ordinal，不能分别维护 permission/question queue 后再猜顺序。若 provider 明确宣告旧 request 已被替代，adapter 必须发 `externalResolution(.superseded)`，不能由“新 request 到达”隐式 deny 旧 request。
2. 同一 session 内 provider arrival order 不变；不同 session 互不产生 head-of-line blocking。
3. `dismiss(requestID)` 只改变 presentation，request 仍 pending、badge 计数仍可发现，不 dequeue、不 deny、不 allow、不改变 CLI。
4. `reveal(requestID)` 只针对当前 ID；同 request 的 replay 继承 dismissed/revealed 状态，新 ID 不继承。
5. presentation selector 必须确定性排序：`resolving failure > explicit reveal > waiting request > arrival ordinal`；同一优先级按 session/request arrival ordinal 和稳定 ID tie-break。隐藏的 request 不能成为当前 card。
6. 所有 user action 必须带 RequestID。找不到该 ID 时输出 `ignoredStaleAction`/`collapseStalePresentation` 类声明式 effect，不得落到另一个 request。

### Resolution、ack 和断连

1. user resolution 后 lifecycle 变为 `resolving(effectID)`，snapshot 立即隐藏卡片，但可显示 session badge 的提交中状态。
2. resolving 状态上的第二次 allow/deny/answer 不产出第二个 effect。
3. adapter 以 token/effectID exactly once 执行并发送 `.succeeded` 或 `.failed`。成功 ack 或 CLI 的 external resolution 才把 request 变为 resolved。
4. transport failure 把 request 恢复为 pending，保存 error，提升 presentation；危险决策不自动重试。用户可显式再次 action，产生新的 EffectID。
5. 外部 resolution 在 effect 尚未执行时应取消 pending effect；若已在飞行，Center 将 request 标记 externally resolved，迟到 ack 只能 no-op。adapter 的 token ledger 还必须丢弃重复 response。
6. disconnect/timeout 是 transport 事实，不等价于用户 deny。按 request token 清理其 transport；如果 provider 明确表示请求已结束，才发 external resolution。session removal 可以终止该 session 的 transport，但不得伪装成成功。

### Auto mode

1. Auto 状态按 session 保存：`observedMode`、`requestedMode`、capability、transitioning/confirmed/unknown/error 分开。
2. 只有 upstream 后续 observation 才能把 requested mode 变成 confirmed；断连/未知状态不能显示为已生效。
3. adapter 优先 provider 原生 auto，明确声明不支持后才能使用 `acceptEdits + addRules`；`bypassPermissions` 仅显式危险 action + capability 才可用。
4. Auto 的改变不能偷偷 resolve 当前 permission，也不能影响其他 session。新 permission 到达时 provider-specific 行为必须由 adapter capability/policy 明确声明，而不是 HookServer 的 source 分支。

### Session observation 与 snapshot

1. upstream observation 可以刷新 session metadata/status，但不能覆盖 Center-owned request lifecycle、dismiss、requested Auto 或 navigation result。
2. `SessionStart`/discovery 的 replacement 必须以 provider generation/identity 防止旧结果复活 request；关闭 session 后迟到 event 只可被 adapter 明确标为新 generation。
3. Center 不写 `SessionSnapshot`，不往其中加入 fork-only 字段；`InteractionSessionContext` 以 SessionID 关联。
4. secret question 只在本机 UI 需要的 projection 中保留；companion、日志和 trace projection 使用 redacted placeholder。

## 三类调用方的具体流程

### Hook permission/plan

```text
NWConnection bytes
  -> HookIngressAdapter.decode/filter/normalize
  -> .sessionObserved(observation)
  -> .requestArrived(permission-or-plan, RequestID, TransportToken)
  -> [present, playSound]
  -> SwiftUI reads snapshot.prominentRequest
  -> .userAction(.allowOnce(requestID))
  -> [deliverResolution(effectID, requestID, token, .allow)]
  -> Hook adapter encodes provider response + resumes its continuation once
  -> .transportEvent(.succeeded(effectID))
  -> resolved; next session-local request may present
```

Hook adapter 自己拥有 connection context、half-close 与 true teardown 区分、continuation ledger、5 分钟 timeout 和 provider JSON encoder。Center 只看到 transport token 和 high-level intent。当前 HookServer 的“half-close 不算 peer disconnect”修复应保留在 adapter contract test，不应复制到 Center。

Plan arrival 的 `kind` 是 `.plan`，UI action 仍为 allow/deny（或 adapter 声明的 `requestChanges`），没有 `Skip`。plain allow 的 wire encoding 由 Claude/Codex 等 adapter 各自提供。

### Hook question 与 Codex app-server question

两者都进入同一 `.question` snapshot，区别只在 adapter：

```text
Hook Notification / AskUserQuestion -> HookQuestionAdapter(token=continuation)
Codex item/tool/requestUserInput   -> CodexAdapter(token=requestId + clientGeneration)
                                       \\
                                        -> same Center question lifecycle
```

UI answer 只发送 `AnswerValue`（按 question answer key/position），Center 生成 `deliverResolution`。Hook adapter 组装 `hookSpecificOutput`；Codex adapter 组装 `ToolRequestUserInputResponse`。Question `dismiss` 始终存在；reject/abandon/continue-without-answer 只有 adapter capability 明确时才出现在 snapshot。无法稳定表达时只保留 dismiss。

Codex `serverRequest/resolved` 变成 `.externalResolution(requestID, source: .provider)`，不产生 deliver effect；app-server replacement 使用新的 client generation，旧 token 的 ack/reply 一律 no-op。

### Session reconciliation

建议建立 `SessionObservationAdapter`，但不要把 upstream reducer/discovery 逻辑搬进 Center：

```text
HookEvent -> existing upstream reducer -> SessionSnapshot
discovery/app-server -> existing reconciliation -> SessionSnapshot
SessionSnapshot (read-only projection)
  -> SessionObservationAdapter
  -> center.send(.sessionObserved(...))
```

event 的 request arrival 仍由对应 ingress adapter 发出；两个 input 在主 actor 上按接收顺序提交。若 upstream 事件可以乱序（当前 Cline/background hook、Codex discovery/close 都存在），observation 必须携带 provider timestamp/sequence/generation，由 adapter 或 Center 明确丢弃 stale observation，而不是让后来的旧 status 覆盖等待状态。

### SwiftUI、快捷键和 companion

`NotchPanelView`：

```text
snapshot.presentation.prominentRequest
  -> render snapshot.requests[id]
  -> Button { center.send(.userAction(.deny(requestID: id))) }
```

卡片点击 session identity 时，UI 发 `.userAction(.navigate(sessionID, requestID?))` 并执行 `requestNavigation` effect；不能从 surface/queue head 重新找目标。Buddy/快捷键若只代表当前 prominent request，先从 snapshot 读取其 RequestID 再发送；若 snapshot 没有当前 action，则 no-op。ESP32/Apple Companion 只消费一个稳定的 `CompanionProjection`（由 snapshot 生成），不能再直接读取 queue。

## SessionNavigator 的配套 Interface

Navigation 是另一个深模块；Center 记录 capability/请求并发出 effect，终端/OS 细节属于 Navigator adapter。建议保留一个统一的 async Interface：

```swift
struct SessionNavigator {
    init(
        activator: any TerminalActivationPort,
        visibility: any TerminalVisibilityPort,
        feedback: any NavigationFeedbackPort,
        settings: NavigationSettings
    )

    func navigate(
        session: SessionNavigationTarget,
        collapsePolicy: CollapsePolicy
    ) async -> NavigationResult
}
```

Production adapter 把现有 `TerminalActivator.activate(session:sessionId:)` 接入；visibility port 依次执行 120ms/320ms/640ms 三次检查；failure feedback 负责声音和 shake，成功按 `autoCollapseAfterSessionJump` 返回 collapse。Remote session 是 no-op/unsupported 的 typed result，不调用本机 terminal。这样 ApprovalBar、QuestionBar、SessionCard、快捷键使用同一个 Navigator，不再复制 Task/retry/shake/collapse 状态机。

Navigator 的结果可以通过 `InteractionInput.navigationResult`（若由 Center 持有错误呈现）或单独的 UI coordinator 消费；关键是四个调用方共用一个 Interface 和同一组 port fakes。不要为了“统一”把 AppKit/NWWorkspace 引入纯 Center 模型。

## Trace 测试方案

### Harness

建立 `InteractionTraceHarness`，只依赖 `InteractionCenterModel`：

```swift
struct TraceStep {
    let input: InteractionInput
    let expected: SnapshotProjection
    let effects: [EffectProjection]
}

struct InteractionTraceHarness {
    var center: InteractionCenterModel
    var transport = RecordingTransportAdapter()
    var trace: [TraceRecord] = []

    mutating func send(_ input: InteractionInput) {
        let effects = center.send(input)
        trace.append(.init(
            input: input.redactedProjection,
            snapshot: center.snapshot.stableProjection,
            effects: effects.redactedProjection
        ))
    }
}
```

规则：

- projection 去掉 `Date`、UUID 随机部分和 secret 文本；保留 RequestID/EffectID 的 deterministic fixture 值、ordinal、lifecycle、presentation、session counts、error kind、effect kind/target。
- 每个 trace 只通过 `snapshot` 和 `[effects]` 观察结果；禁止 `@testable` 读取 Center 的 queue、dict、continuation 或私有 reducer。
- `RecordingTransportAdapter` 只验证 effect contract：记录 `(EffectID, RequestID, token, resolution)`，测试显式注入 success/failure/external event，模拟重复 ack、迟到 ack、adapter crash 和 replacement token。
- 用 `TestClock`/显式 `now` input，避免 `Date()`、Task.sleep、真实 animation 和 NSWorkspace 让 trace flaky。
- 同一 trace 可接 Hook fake、Codex fake、UI action fake；若换 adapter 后 snapshot/effect projection 相同，说明 Center 的深度和 locality 真实存在。

### 必须覆盖的 trace

| 场景 | 输入序列 | 关键断言 |
| --- | --- | --- |
| permission basic | observe → permission arrival → allow → ack | pending/present → resolving/optimistic hide → resolved；仅一个 deliver effect |
| plan semantics | plan arrival → allow | effect intent 为 plain allow；没有 skip action/capability |
| question variants | Hook question / AskUserQuestion / Codex question → answer | 同一 question snapshot；答案按 key/position；各 adapter 只改变 wire effect |
| dismiss | arrival → dismiss | request 仍 pending，badge/count 保留，ไม่มี resolve effect；另一个 session 可 present |
| reveal | dismissed → reveal | 同 request 恢复 prominence；新 RequestID 不继承 dismissed |
| stale UI action | A、B arrival → A external resolution → action(A) | A action no-op + stale presentation effect；B 不被回答/deny |
| replay | A arrival → dismiss → replay same proven identity | A 不复活，不重复 effect，dismiss/ordinal 保留；replacement token 正确绑定 |
| same id parallel | A(tool/input1) → A(tool/input2) | 两个 occurrence/request；不因相同 tool id 合并 |
| transport failure | arrival → allow → failed(effect) | resolving → pending + prominent error；不自动重试；下一次显式 action 新 EffectID |
| duplicate/late ack | allow → success → same success / old failure | 后续 ack no-op，不改变 resolved 或新 request |
| external resolution race | arrival → allow → external resolved → late ack | externally resolved；不产生第二个 response，迟到 ack 无效 |
| disconnect | A1、A2、B1 → disconnect token A1 | 仅 A1 transport 终止；B1/A2 不被 session 级误伤，除非 provider 明确整 session close |
| session ordering | A1、A2、B1 → resolve A1 | A2 优先于 B1 的 session-local next；B1 不被 A 的 pending head 阻塞；selector deterministic |
| question/permission replacement | A permission → provider superseded → A question | 旧 request 由显式 external/superseded 输入结束；不能因新 arrival 隐式 deny |
| session removal | A pending/resolving → removed | request/transport terminal outcome 明确；不存在 ghost card；旧 observation 不复活 |
| observation refresh | pending A → session status/metadata updates | upstream facts 更新；dismiss/resolving/request identity 不丢 |
| Auto | observe capability → setAuto → ack/observe mode | per-session requested/confirmed/unknown；危险 fallback 无法静默发生；不 resolve permission |
| privacy | secret question → companion projection | snapshot 本机 UI 可用；外传/log projection 为 placeholder |

### Adapter contract tests

Center trace 不替代 adapter 测试，二者职责必须分开：

| Adapter | 独立测试证据 |
| --- | --- |
| Hook ingress/transport | aliases normalize；source/cwd filters；half-close 不触发 disconnect；true teardown 按 token 清理；continuation exactly once；response encoding 各 provider schema；oversized/parse failure 安全响应 |
| Codex app-server | request id/client generation 回显；answers result schema；`serverRequest/resolved` 不回包；断线只清理 dead-channel questions；replacement client 不接受旧 ack |
| Session observation | `SessionSnapshot` projection 不带 fork state；provider/native namespace、PID、generation 规则复用已有 reconciliation；stale discovery/close 不复活 session |
| SwiftUI projection | 每个 Button/action 都带 snapshot 中的 RequestID；UI 不访问 queue/continuation/raw JSON；空/过期 request 显示空态或 collapse |
| SessionNavigator | activation route、remote no-op、三次 visibility check、failure feedback、auto collapse 使用 fakes 验证；不把 AppKit 放进 Center model |
| Companion/shortcut | 从同一 projection 获得目标 ID；没有 prominent request 时不操作任意 queue head；secret redaction |

## 分阶段迁移与每片 rollback 边界

每片只有一个状态 owner；不允许新旧 queue 长期双写。每片完成后才切换下一片，失败时整片回滚到前一 owner。

| Slice | 交付物与唯一 owner | 可验证出口/回滚点 |
| --- | --- | --- |
| 0. Pure model | Interaction types、Center model、trace harness；无 production caller | 所有上表基础 trace 绿；删除新目录不影响 app |
| 1. SessionNavigator | 把 Approval/Question/SessionCard 的跳转共性提取成 Navigator + fakes | 现有 jump tests 与新 port tests 等价；rollback 为旧调用方恢复各自调用，但不再改 Center |
| 2. Hook permission | Hook adapter 将 permission/plan arrival/resolution 接入 Center；旧 permission queue 停止写入 | permission/replay/dismiss/failure/disconnect trace + hook contract 绿；rollback 由 Hook adapter 回到旧 AppState owner，Center 不接收生产请求 |
| 3. Plan variant | ExitPlanMode 变 `.plan`；删除 Skip 语义，plain allow 显式编码 | plain allow wire trace、Plan UI capability guard 绿；rollback 保留 provider adapter，不恢复通用 Skip |
| 4. Questions | Hook Notification/AskUserQuestion 和 Codex app-server 共用 question lifecycle | multi-answer、secret、Codex external resolved/reconnect traces 绿；一次只切一个 provider adapter |
| 5. Reconciliation | `SessionObservationAdapter` 作为唯一 `reconcile` seam；Center context 与 SessionSnapshot 分离 | snapshot projection/close-generation/discovery regression 绿；旧 session reducer 仍是 upstream owner，不能双写 Center-owned state |
| 6. Auto | per-session Auto context、requested/observed/capability；移除 singleton/observed fork field | Auto safety traces + persistence compatibility 绿；危险 mode 测试必须先过再切 production |
| 7. UI/外围 | SwiftUI、快捷键、ESP32/Apple Companion 只读 snapshot/发送 ID；surface 变成 presentation projection | architecture guards + UI action wiring + companion projection 绿；任何直接 queue 访问阻断合并 |
| 8. Adaptive policy/cleanup | 最后启用 CLI-first adaptive；删除旧 queue/dismiss/Auto 字段和 adapter branch | behavior-equivalence trace 先绿，再 UX trace；发现问题回滚 adaptive policy，而不回滚 Center owner |

## Architecture guard 与 upstream sync 验收矩阵

### Guard

建议加入 `Tests/CodeIslandTests/InteractionArchitectureGuardTests.swift` 或独立脚本，读取源码路径并在 CI 失败；它们是结构证据，不应只靠 reviewer 记忆。

| Guard | 检查 | 失败示例 |
| --- | --- | --- |
| single owner | `AppState.swift`、旧 queue extensions、UI 不声明/写 Center-owned queue/dismiss/Auto | `permissionQueue.append`, `dismissedPermissionSessionIds.insert`, `toggleAutoApprove` from View |
| UI read/write seam | `NotchPanelView.swift` 只能 import/读取 `InteractionSnapshot`、发送 typed action | `pendingPermission(forSession:)`, `queue.firstIndex`, `surface` 根据 queue 自行修正 |
| request identity | UI/快捷键/companion action 必须含 RequestID | 无 ID 的 `approveCurrentPermission` 隐式 head |
| Hook locality | `HookServer.swift` 只有 ingress normalization/token/effect execution 接入区 | `isAutoApprovedSource`, plan/question policy、queue mutation |
| protocol locality | raw JSON、`hookSpecificOutput`、JSON-RPC result 只能在 adapter/codec | SwiftUI 检查 source/tool 并组 JSON |
| snapshot purity | `SessionSnapshot.swift` 不出现 fork-only fields；`InteractionSessionContext` 才能保存 requested/dismiss/navigation | `observedPermissionMode`, `dismissed`, `requestedAuto` 回流 Core snapshot |
| navigator reuse | Approval/Question/SessionCard/shortcut 不包含重复 retry delays、TerminalActivator、shake/collapse state machine | 三处重新定义 `[120ms,320ms,640ms]` |
| variant capabilities | UI 不把所有 question resolution action 拼成 `Skip` | Notification 空答案、Codex abandon、AskUser deny 共用一个字符串 |
| transport safety | continuation/NWConnection/Codex client 只在 adapter | Center model 持有 continuation 或 connection |

Guard 需要允许 diagnostics、upstream reducer 和协议 codec 的合法调用，但 fork policy 的复杂判断必须集中在 Center/其 adapter，而不是通过简单“文件集中”放过跨层 branch。每个例外要有源码行注释和对应 trace/contract test。

### Acceptance matrix

| 需求/不变量 | 权威证据 | 通过条件 |
| --- | --- | --- |
| 小 Interface / 深模块 | `InteractionCenter` public surface + compile-time caller fixtures | caller 只需 `snapshot`/`send`；没有 queue/transport/internal reducer 依赖 |
| permission/plan/question 统一 lifecycle | Center trace projection | 三种 kind 都有 pending/resolving/resolved/external/failure；Plan 无 Skip |
| dismiss 语义 | dismiss/reveal/multi-session traces | pending 与 badge 保留；无 resolution effect；同 request replay 继承隐藏 |
| optimistic resolution | allow/deny/answer + ack/failure traces | action 立即 hide，failure 恢复并突出；重复 action 无重复 effect |
| exactly-once transport | Hook/Codex adapter contract + duplicate ack trace | 每个 EffectID/token 至多一次 wire response；迟到 ack no-op |
| replay/identity | replay、same-id-different-input、no-ID occurrence traces | 只有 adapter 有证据时 merge；无证据永不猜测 |
| per-session ordering | A1/A2/B1 ordering trace | session 内 ordinal 保持；B 不被 A 的 pending head 阻塞 |
| external resolution | provider resolved/disconnect/close traces | 不重复 response；旧 request 不复活；disconnect 不等于 deny |
| Auto 安全 | capability/mode traces + dangerous-mode negative tests | per-session requested/observed 分离；unknown 不显示 confirmed；bypass 非静默 fallback |
| reconciliation single seam | projection test + source guard | Center 只接 `SessionObservation`；upstream mapper 是唯一入口；旧快照字段不回流 |
| navigation 行为等价 | Navigator fake port trace | 既有 activation route、3 次验证、feedback、auto-collapse、remote 行为保持 |
| UI/外围薄 adapter | compile fixture + architecture guard + projection tests | UI/shortcut/companion 无 queue/raw protocol/ID-less action |
| persistence compatibility | old `sessions.json` fixture + restore trace | 旧文件可读；pending identity 不猜；fork context 不污染 upstream snapshot |
| secret/privacy | secret question projection/companion test | companion/log 不输出原文；本机回答仍按 key 正确传输 |
| migration locality | 每个 slice 的 owner/rollback log | 每片只有一个 writer；切换后旧路径停止写入；可整片回滚 |
| upstream sync | 临时 upstream/main sync rehearsal 记录 | 每个热点文件至多一个连续接入 seam；记录冲突文件数、语义冲突数；fork-owned 模块无需人工修改 |

Sync rehearsal 不应以“本次没有冲突”作为唯一证据。应保存：

```text
upstream revision:
hotspot file -> seam count / conflict count / semantic-conflict count
fork-owned modules changed: yes/no + reason
manual policy decisions required: list
```

建议用一次临时 worktree 或 `git merge-tree` 做无破坏演练，并把结果附在任务记录；验收重点是 upstream 修改 Hook/session/UI 后，冲突是否停留在一个 adapter 接入区，而不是要求 upstream 文件永远零 diff。

## 对 PRD 假设的挑战与补充风险

### 1. “按 session 独立 queue”还不足以定义顺序

如果 Center 仍按 permission/question 分开 queue，只是把两个全局数组换成多个字典，后一个 variant 仍可能越过前一个 request。建议明确“每 session 一个跨 variant ordinal”，并要求 provider 用 explicit superseded/external event 结束旧项。否则迁移会把当前 `drainPermissions`/`drainQuestions` 的隐式 deny 重新藏进 Center。

### 2. session-level disconnect 不符合 exactly-once 目标

当前 `handlePeerDisconnect(sessionId:)` 会 drain 同 session 全部 pending，而 HookServer connection context 也只保存 session id。这与每个 resolution effect 有 token 的要求冲突。必须把 connection/continuation 与 RequestID/TransportToken 绑定；若 provider 真的把一个连接作为 session-wide channel，adapter 要明确发 `sessionTransportClosed`，不能伪装为每个 request 的 deny。

### 3. optimistic hide 与 external resolution 存在竞态

用户 action 后到 adapter ack 前，CLI 可能在 terminal/TUI 中自行解决。仅靠 Center 的 cancel effect 不足以阻止已经发出的网络写入；adapter 必须有 generation/token ledger，Center 对迟到 ack 做幂等 no-op，并在 trace 中覆盖 effect-before-external 与 external-before-effect 两种顺序。

### 4. “未来 upstream 等价事实”必须是 typed mapping，不是第二个 reducer

当前 `reduceEvent`、discovery merge、Codex thread close 各自会改变 session lifecycle。若 Center 直接消费 raw HookEvent，下一次 upstream 字段改名会迫使 Center、HookServer 和 UI 一起改。应把 normalization/reconciliation 保持在 adapter，Center 只消费小型 projection，并记录 source sequence/generation。

### 5. Auto 的 provider fallback 仍可能成为隐藏协议策略

“优先 native auto，fallback acceptEdits + addRules”需要 capability 版本、失败语义、清理语义和危险模式确认；只写一个布尔 `supportsAuto` 会把 provider 差异重新推入 UI。 `AutoCapability` 应由 adapter 声明可执行 intent 和 confirmation event，Center 只做状态生命周期。

### 6. presentation selector 的优先级需要避免隐式抢焦点

`resolving failure > explicit reveal > waiting > arrival` 是可行默认值，但“explicit reveal 永久突出”与新 request/error 同时发生时要有确定 tie-break，并区分用户主动 reveal 与系统自动 present。否则不同调用顺序会产生不同卡片，trace 难以复现，也会让 CLI-first adaptive 迁移同时改变多个 UX 变量。

### 7. App restart/persistence 不能只移除 observedPermissionMode 就结束

当前持久化还保存 terminal/multiplexer identity、closed subagent tombstone、provider session id；这些 upstream display/navigation 事实必须继续兼容。另一方面，pending request 和 dismiss 不应从旧文件恢复。应增加“旧文件可读 + request identity 空”的 restore trace，而不是简单删字段导致 decode 破坏。

### 8. secret question 和外围设备是信息泄漏风险

Codex `isSecret` 已有本机 placeholder 逻辑，但统一 snapshot 很容易被 ESP32/Apple Companion 投影成原文。projection 必须携带 sensitivity，且 trace 要断言 redaction；不能只在一个 UI view 里处理。

### 9. SwiftUI 的“只读 snapshot”仍需控制大对象和 actor 交互

`SessionSnapshot` 很大且含 `[String: Any]` 风格 payload；如果每个输入都复制完整 snapshot，UI/companion 可能抖动。建议 Center snapshot 使用 typed、按 session 的轻量 projection；tool input 详情按 request 需要懒取或 redacted。Store 在 MainActor 发布，model 可在纯测试中同步演算，避免 Task ordering 成为业务事实。

### 10. 同一 RequestID 在不同 transport generation 的回放必须显式定义

PRD 已要求旧 transport 终结再绑定新 transport，但没有规定 Center 是否允许“同 RequestID、新 token、新 generation”。建议 request snapshot 保存 `transportGeneration`；replay 只能替换 token 而不能重置 lifecycle，旧 generation 的 failure/success 全部忽略。否则 replacement client 的 ack 可能解决错误的 retry。

## 最小落地建议

`design.md` 应把本文的两层 seam 写成明确边界：

1. `InteractionCenterModel`：纯、深、唯一写 Interface；包含 identity/lifecycle/queue/presentation/Auto/context 规则。
2. `InteractionCenterStore`：MainActor/Observation adapter，只做串行转发和 snapshot 发布。
3. `HookInteractionAdapter` 与 `CodexInteractionAdapter`：两个真实 transport adapter；分别持有 continuation 或 JSON-RPC token，证明“两个 adapter”使 seam 合理。
4. `SessionObservationAdapter`：唯一 reconcile seam，不复制 upstream reducer/discovery。
5. `SwiftUIInteractionAdapter`、`CompanionProjectionAdapter`、`SessionNavigator`：薄消费方；通过 input/effect 连接，不拥有业务状态机。

首个实现 PR 只需加入 model/types/trace fixtures，不接 production；第二个 PR 接 Navigator；之后按 permission → plan → questions → Auto → UI 的顺序切 owner。每个 PR 必须附对应 trace、architecture guard 和 owner/rollback 记录，才能把“低冲突同步”从意图变成可观察事实。


