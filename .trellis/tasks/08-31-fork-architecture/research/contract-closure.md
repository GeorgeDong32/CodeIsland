# InteractionCenter 契约收敛提案

本文只收敛 `.trellis/tasks/08-31-fork-architecture/` 的规划契约，不修改
`prd.md`、`design.md`、`implement.md` 或产品代码。它针对当前实现中的几个闭环问题：
Plan 的 canonical shape、展示型 Question 与阻塞型 Question 的差异、非取消
continuation 的终结、SessionRef generation、visibility observation、Auto 的实际命令
通道、低信任输出脱敏、effect 执行归属以及 terminal ledger 的容量和重试语义。

## 1. 收敛后的外部 Interface

InteractionCenter 仍然是一个无 I/O、串行 reducer 风格的 deep Module。调用方只学习
一个写入口和一个读模型：

```swift
@MainActor
final class InteractionCenterStore {
    var snapshot: InteractionSnapshot { get }

    @discardableResult
    func send(_ input: InteractionInput) -> [InteractionEffect]
}
```

`send` 不调用 continuation、网络、AppKit、音效或 SwiftUI；它只改变内部状态并返回
有序 effects。Store 是唯一调用 `InteractionEffectExecutor` 的地方。Center 不再同时
注入一个会执行 effects 的 sink；否则 `send` 返回值和 sink 可能造成双重 response。

纯 reducer 可以作为实现内部的测试 seam，但不是外部 Interface：

```swift
struct InteractionCenterModel {
    init(configuration: InteractionConfiguration,
         dependencies: InteractionDependencies)

    var snapshot: InteractionSnapshot { get }
    mutating func send(_ input: InteractionInput) -> [InteractionEffect]
}
```

`InteractionDependencies` 只包含 deterministic clock、ID factory、ledger policy 和
纯 configuration；它不能创建网络 singleton。生产 Store 负责 `@MainActor` 串行化，
测试直接驱动 Model 的 input trace。

### 1.1 Canonical Plan-as-permission variant

Plan 只有一个身份模型。`InteractionRequestKind` 不包含 `.plan`；Plan 是 permission
content 的 variant，不是新的 queue lane 或新的 lifecycle：

```swift
enum InteractionRequestKind: Hashable, Sendable {
    case permission
    case question
}

enum RequestContent: Sendable, Equatable {
    case permission(PermissionContent)
    case question(QuestionContent)
}

struct PermissionContent: Sendable, Equatable {
    let toolName: String?
    let summary: String?
    let displayInput: DisplayValue?
    let variant: PermissionVariant
}

enum PermissionVariant: Sendable, Equatable {
    case regular
    case plan(PlanContent)
}

struct PlanContent: Sendable, Equatable {
    let planText: SensitiveText?
    let allowedPromptCount: Int
    let suggestedMode: PlanMode?
}

enum PlanMode: Hashable, Sendable {
    case suggested(String)
    case manual
}
```

因此：

- regular permission 与 plan 共享同一个 `RequestID` 规则、session ordinal、dismiss、
  replay、resolving 和 failure path；
- `ResolutionCommand.allowPlan(.manual)` 的 wire intent 是 plain allow，但 UI 语义是
  `Allow plan/Manual`，永远没有 `skipPlan` 或通用 `Skip`；
- adapter 负责将 `ExitPlanMode` 编码为 provider response；Center 只验证 variant 和
  capability，不构造 JSON；
- `question` 不能通过 tool name 或 source 字符串猜测为 permission/plan。

### 1.2 可选 resolution channel/transport

Question 统一的是内容和本地生命周期，不是所有来源都有可用的 response channel。
请求行为明确表达“只展示”或“必须有响应通道”：

```swift
struct RequestBehavior: Sendable, Equatable {
    let resolution: ResolutionRequirement
    let ordering: OrderingLane
    let defaultPresentation: PresentationPreference
    let sensitivity: Sensitivity
}

enum ResolutionRequirement: Sendable, Equatable {
    case displayOnly
    case required(ResolutionCapabilities)
}

enum ResolutionChannel: Sendable, Equatable {
    case none
    case response(TransportToken)
}

struct RequestArrival: Sendable, Equatable {
    let id: RequestID
    let session: SessionRef
    let kind: InteractionRequestKind
    let behavior: RequestBehavior
    let content: RequestContent
    let channel: ResolutionChannel
    let association: RequestAssociation
    let receivedAt: Date
}
```

Center 的验证规则是：`displayOnly` 必须使用 `.none`，且只能产生 dismiss/reveal
等呈现行为；`required` 必须使用 `.response(token)`，并且 token 只能由对应 adapter
消费。`TransportToken` 是 opaque 值，Center 不知道 Hook continuation、Codex JSON-RPC
request 或未来 CLI 的具体实现。

这覆盖了现有代码的差异：Hook Notification 可以是 display-only，AskUserQuestion
使用 Hook response token，Codex `item/tool/requestUserInput` 使用 app-server token，
Cursor transcript question 可以没有 channel。若某 provider 需要新的 resolution
语义，必须通过强类型 capability 增加，而不是塞一个字符串 action。

```swift
struct ResolutionCapabilities: Sendable, Equatable {
    let allowAlways: Bool
    let planModes: Set<PlanMode>
    let questionActions: Set<QuestionResolutionAction>
}

enum QuestionResolutionAction: Hashable, Sendable {
    case reject
    case abandon
    case continueWithoutAnswer
}

enum ResolutionCommand: Sendable, Equatable {
    case allowOnce
    case allowAlways
    case allowPlan(PlanMode)
    case deny(message: String?)
    case answer([QuestionAnswer])
    case questionAction(QuestionResolutionAction)
}
```

`Dismiss` 是 Center 的 presentation command，不是 resolution capability。display-only
question 的 action 只能是 Dismiss/reveal；不稳定的空回答、空 JSON 或 Codex nil response
不得在 Center 中被重命名为 Skip。

## 2. SessionRef generation authority 与 request-before-observation

### 2.1 唯一 generation authority

`SessionSnapshot`、HookServer 和 Codex adapter 都不能各自递增 generation。由一个共享的
`SessionGenerationAuthority` 持有 `(provider, providerSessionID)` 到当前 `SessionRef`
的映射；它是进程内、可替换的本地依赖：

```swift
struct SessionKey: Hashable, Sendable {
    let provider: ProviderID
    let providerSessionID: String
}

struct SessionRef: Hashable, Sendable {
    let key: SessionKey
    let generation: UInt64
}

struct SessionIdentityFact: Sendable, Equatable {
    let key: SessionKey
    let lifecycle: SessionLifecycleFact
    let evidence: SessionGenerationEvidence
    let sequence: UInt64
}

enum SessionLifecycleFact: Sendable, Equatable {
    case opened
    case observed
    case closed(SessionCloseReason)
}

@MainActor
protocol SessionGenerationAuthority {
    func current(for key: SessionKey) -> SessionRef?
    func apply(_ fact: SessionIdentityFact) -> SessionRef
    func isCurrent(_ ref: SessionRef) -> Bool
}
```

实现规则：

1. 同一 generation 的重复 observation 是幂等的；只有明确的 open/reopen evidence 才
   递增 generation。仅因为 request 正文或同名 session 到达，不能 reopen。
2. Close 只使当前 generation 失效；后到的旧 observation、transport token 和 effect
   ack 均为 stale，不能创建新 session。
3. authority 在 App restart 后从空状态开始。旧持久化 display facts 不恢复旧
   generation，也不恢复 pending interaction；必须等 fresh observation 才产生新的
   SessionRef。
4. Request adapter 和 SessionObservationAdapter 共享 authority；二者不能从 raw string
   各自构造 `SessionRef`。

`InteractionCenter` 只接受已经绑定 generation 的 `SessionObservation` 和
`RequestArrival`；它不复制 discovery、PID、cwd 或 native-app 合并启发式。

### 2.2 request-before-observation

Hook/Codex request 可能先于 SessionSnapshot/discovery observation。请求不能因为观察尚未
到达而被静默丢弃，也不能由 Center 凭正文猜 generation。Request ingress adapter 持有
一个有界等待区：

```swift
struct PendingIngressPolicy: Sendable, Equatable {
    let maxRequestsPerSessionKey: Int
    let maxAge: Duration
}

enum RequestIngressResult: Sendable, Equatable {
    case admitted(RequestArrival)
    case buffered(BufferToken)
    case finalizedWithoutResolution(DiagnosticCode)
}

protocol RequestIngressBuffer {
    func accept(_ raw: UnboundRequest) -> RequestIngressResult
    func bind(_ ref: SessionRef) -> [RequestArrival]
    func expire(now: Date) -> [TransportToken]
    func remove(_ key: SessionKey) -> [TransportToken]
}
```

buffer 条件是可配置且可测试的：超过 per-key capacity 或 maxAge 时，adapter 必须对
对应 token 执行一次 provider-safe finalization，并发出诊断；不得把 request 转移到
另一个 session。Observation 到达后按原 arrival order 绑定同一 generation，再送入
Center。Session closed/removal 会清空该 key 的等待区。

Center 的 session input 采用单一 canonical 生命周期：

```swift
enum InteractionInput: Sendable {
    case sessionObserved(SessionObservation)
    case requestArrived(RequestArrival)
    case visibilityChanged(VisibilityObservation)
    case user(InteractionUserAction)
    case adapter(InteractionAdapterEvent)
}
```

`sessionRemoved` 不再作为第二条可独立复活状态的删除路径；它先由 authority 转成带
generation 的 `.closed` observation，再送入 Center。这样不会出现 `sessionObserved(.closed)`
和 `sessionRemoved` 双重清理或旧 close 复活新 session。

## 3. disconnect finalization：不取消 continuation，但不把它伪装成 deny

现有 `CheckedContinuation<Data, Never>` 不能 cancel；因此“disconnect 后既不响应又
exactly once”不是可执行契约。Adapter 必须拥有 `OnceResponder`，而 Center 只记录
transport 事实：

```swift
struct OnceResponder<Response>: Sendable {
    // adapter-owned; the implementation atomically accepts the first finish only
    func finish(_ response: Response) -> Bool
}

enum TransportEndEvidence: Sendable, Equatable {
    case responseDelivered
    case providerResolved(ExternalResolutionEvidence)
    case peerDisconnected
    case timedOut
    case replacement
}

enum TransportFinalization: Sendable, Equatable {
    case providerSafeNeutral(TransportEndReason)
    case externallyResolved(ExternalResolutionEvidence)
}

enum InteractionEffect: Sendable, Equatable {
    case deliverResolution(
        effectID: EffectID,
        requestID: RequestID,
        token: TransportToken,
        command: ResolutionCommand
    )
    case finalizeTransport(
        effectID: EffectID,
        token: TransportToken,
        finalization: TransportFinalization
    )
    // other typed presentation, navigation and Auto effects
}
```

发生 `peerDisconnected`/`timedOut` 且没有 external-resolution evidence 时：

1. Center 将 request 标为 `pending(unavailable)`，保留 ordinal、dismiss 和 badge；不
   产生 deny/allow resolution；
2. Center 产生一次 `finalizeTransport` effect；adapter 使用其协议适配器中预先定义的
   provider-safe neutral response 调用 `OnceResponder.finish`，然后丢弃 token；
3. 若协议没有可证明安全的 neutral response，该 adapter 不得把 continuation 注册为
   `ResolutionChannel.response`，而必须在 ingress 层 quarantine/拒绝并给出诊断。这是
   production adapter 的硬 gate，不允许用 deny 作为默认补洞；
4. `OnceResponder` 的第一次 finish 是唯一合法 resume；重复 disconnect、timeout、
   response ack 或 cleanup 只能返回 false/no-op；
5. 后续 replay 若有 proof，可以用新 token 重新绑定同一 request；没有 proof 则创建
   occurrence request。旧 token 永远不能再次 deliver。

这里的 “exactly once” 只承诺本地 continuation/response callback 的一次 finalization
和 adapter 的一次提交尝试；在没有 provider idempotency/ack 的网络上，不声称 wire delivery
exactly once。`deliveryUnknown` 不得自动重试。

## 4. Visibility input 与 adaptive policy

`TerminalVisibilityDetector` 是 I/O adapter，不应在 Center 或 SwiftUI 内同步调用。把
检测结果作为带 generation/revision 的事实输入：

```swift
struct VisibilityObservation: Sendable, Equatable {
    let session: SessionRef
    let state: CLIVisibility
    let source: VisibilityEvidence
    let revision: UInt64
    let measuredAt: Date
}

enum CLIVisibility: Sendable, Equatable {
    case visible
    case notVisible
    case unknown
}

enum VisibilityEvidence: Sendable, Equatable {
    case terminalTab
    case terminalFrontmost
    case nativeAppFrontmost
    case unavailable
}

struct PresentationPolicy: Sendable, Equatable {
    let mode: PresentationPolicyMode
    let visibilityMaxAge: Duration
}

enum PresentationPolicyMode: Sendable, Equatable {
    case legacyProminent
    case adaptiveCLIFirst
}
```

Center 只使用当前 generation 的最新 revision；过期 observation 或超过
`visibilityMaxAge` 的事实视为 `.unknown`。adaptive 模式的 selector 是：visible 时
badge/notification，notVisible 或 unknown 时主动展开；用户 explicit reveal 始终优先。
Phase 1 设为 `legacyProminent`，通过行为等价后才切换 adaptive。不得为 permission、
plan、question 增加三个不同开关。

测试 fake 必须能按序送入 visible → stale notVisible → unknown → notVisible，并验证
selector 不被 stale observation 改写；生产 adapter 才负责 120/320/640ms 的导航验证，
Center 只接收最终 visibility facts。

## 5. Auto：真实 command transport 和状态机

Auto toggle 不能借用当前 pending permission 的 continuation：那会在用户只切换 Auto
时隐式 allow/resolve permission，违反产品决策。需要一个明确的 provider Auto control
adapter；若 provider 没有独立控制通道，Center 返回 unavailable feedback，而不是暗中
使用 pending response。

```swift
struct AutoCapabilities: Sendable, Equatable {
    let nativeAuto: Bool
    let acceptEditsRules: Bool
    let explicitBypass: Bool
    let independentControlChannel: Bool
}

enum AutoModeIntent: Sendable, Equatable {
    case off
    case enableNative
    case enableAcceptEditsRules
    case enableBypassExplicit
}

enum AutoCommand: Sendable, Equatable {
    case setMode(ProviderPermissionMode)
    case addRules([AutoRule])
    case removeRules([AutoRule])
}

struct AutoCommandTransaction: Sendable, Equatable {
    let session: SessionRef
    let commands: [AutoCommand]       // ordered, adapter executes as one intent
    let controlToken: AutoControlToken
}

struct AutoControlToken: Hashable, Sendable {
    let rawValue: UUID
}

enum AutoPhase: Sendable, Equatable {
    case idle
    case transitioning(EffectID, requested: AutoModeIntent)
    case delivered(EffectID, requested: AutoModeIntent)
    case confirmed(AutoMode)
    case unknown
    case failed(AutoFailure)
}

struct AutoSnapshot: Sendable, Equatable {
    let observedMode: ProviderPermissionMode?
    let requestedMode: AutoModeIntent?
    let capabilities: AutoCapabilities
    let phase: AutoPhase
}
```

Center 将 intent 编译成 typed transaction：

| intent | capability/command | 禁止行为 |
| --- | --- | --- |
| `enableNative` | `setMode(.auto)` | 没有 native capability 时静默改走 bypass |
| `enableAcceptEditsRules` | `setMode(.acceptEdits)` → `addRules` | 把规则 fallback 当 native auto |
| `enableBypassExplicit` | `setMode(.bypassPermissions)` → `addRules` | 没有 explicit capability 时发送 |
| `off` | `setMode(.default)` → owned `removeRules` | 删除不属于 CodeIsland 的规则 |

`AutoCommandAdapter` 是生产 provider adapter 与 in-memory fake 之间的真实 seam：

```swift
protocol AutoCommandAdapter {
    func submit(_ transaction: AutoCommandTransaction,
                completion: @escaping (Result<AutoDelivery, AutoAdapterFailure>) -> Void)
}
```

生产 adapter 可使用 provider 独立控制通道；若只能在 permission response 中附带
`updatedPermissions`，它必须声明 `independentControlChannel == false`，Center 不得用
该 continuation 代替 Auto command transport。实现阶段必须先证明至少一个 production
channel，否则 Auto phase 只能交付 typed unavailable feedback。

状态转换：

```text
idle
  --user intent + capability + control token--> transitioning(effectID)
transitioning
  --adapter delivered--> delivered(effectID)
transitioning
  --not delivered--> failed(error)
transitioning/delivered
  --matching SessionObservation--> confirmed(mode)
transitioning/delivered
  --disconnect/close/unknown--> unknown (clear requested context)
```

delivery 只说明 transaction 已由 adapter 提交；只有后续 observation 的
`permissionMode` 与目标匹配才能 confirmed。Auto 不 resolve 当前 request，不影响别的
session；session close/disconnect 清理 requested/context，但不声称远端 mode 已改变。

## 6. Audience-specific privacy projections

Center 的内部/本机 UI 需要 secret question 内容，但 companion、ESP32、日志和 trace
不应获得 raw `RequestContent`。将 read model 分成两个不可混用的 typed projection：

```swift
struct InteractionSnapshot: Sendable, Equatable {
    let local: LocalInteractionSnapshot
    let external: RedactedInteractionSnapshot
}

struct LocalInteractionSnapshot: Sendable, Equatable {
    let sessions: [SessionRef: LocalSessionSnapshot]
    let requests: [RequestID: LocalRequestSnapshot]
    let presentation: PresentationSnapshot
}

struct RedactedInteractionSnapshot: Sendable, Equatable {
    let sessions: [SessionRef: RedactedSessionSnapshot]
    let requests: [RequestID: RedactedRequestSnapshot]
    let presentation: RedactedPresentationSnapshot
}

struct RedactedRequestSnapshot: Sendable, Equatable {
    let id: RequestID
    let session: SessionRef
    let kind: InteractionRequestKind
    let title: String?
    let sensitivity: Sensitivity
    let pending: Bool
    let availableActionKinds: Set<ExternalActionKind>
}
```

`LocalRequestSnapshot.content` 可以包含经过 `SensitiveText` 标注的 question；
`RedactedRequestSnapshot` 只包含标题、kind、pending/count、字段类型和 redacted
placeholder，不包含回答正文、options、raw HookEvent、Codex request JSON 或
`DisplayValue` 原树。companion adapter 的 Interface 只接受
`RedactedInteractionSnapshot`，architecture guard 禁止它直接引用 local projection。
trace/debug serializer 只能序列化 redacted projection；secret regression 必须断言
原文和选项都不出现。

纯 projection 是 in-process implementation，不为测试暴露第二个 Center seam；它从同一
内部 state 生成 local/external 两个 facet，避免 UI 和 companion 各自重解析 provider
payload。

## 7. Single effect executor

Effects 的返回值必须有一个执行者，且保持数组顺序。建议定义一个 coordinator-owned
executor：

```swift
protocol InteractionEffectExecutor {
    func execute(
        _ effects: [InteractionEffect],
        report: @escaping (InteractionAdapterEvent) -> Void
    )
}

enum InteractionAdapterEvent: Sendable, Equatable {
    case transportEnded(TransportToken, evidence: TransportEndEvidence)
    case resolutionSucceeded(EffectID)
    case resolutionFailed(EffectID, AdapterFailure)
    case autoModeDelivered(EffectID)
    case autoModeFailed(EffectID, AutoAdapterFailure)
    case visibilityIgnored(VisibilityObservation, DiagnosticCode)
    case externallyResolved(RequestID, ExternalResolutionEvidence)
}
```

Store 的唯一流程是 `effects = center.send(input)` → `executor.execute(effects)` →
executor 将回执重新送回同一个 `center.send(.adapter(...))`。HookTransportAdapter、
CodexTransportAdapter、AutoCommandAdapter、Navigator 和 feedback adapter 都是
executor 的内部 dispatch slots；它们不能直接修改 AppState 或 Center，也不能各自创建
第二个 effect runner。

executor 以 `EffectID` 做 at-most-once submission ledger：重复执行请求只返回既有结果，
不会第二次 resume、写 response 或发 Auto transaction。`send` 返回 effects 的顺序是
契约；若某 effect 失败，后续 effect 只有在其依赖允许时才执行，Center 必须收到 typed
failure，而不是被静默吞掉。

## 8. Terminal ledger、容量、eviction 和 retry

Resolved/external records 用于吸收迟到 ack、replay 和 replacement race，但不能无限增长：

```swift
struct TerminalLedgerPolicy: Sendable, Equatable {
    let maxEntries: Int
    let retention: Duration
}

struct TerminalRecord: Sendable, Equatable {
    let requestID: RequestID
    let outcome: TerminalOutcome
    let effectIDs: Set<EffectID>
    let endedAt: Date
}

enum TerminalOutcome: Sendable, Equatable {
    case resolved
    case externallyResolved(ExternalResolutionEvidence)
    case abandoned
}
```

eviction 规则：先移除 `endedAt + retention <= now` 的记录；仍超过 capacity 时按最旧
`endedAt` 淘汰。eviction 只忘记 dedup 证据，不重开 request、不发送 response。迟到的
effect/token ack 在 ledger 内命中时是 no-op；eviction 后仍只能产生 diagnostic，不能
通过旧 `EffectID` 改变当前 state。新的 upstream arrival 必须由 identity adapter 生成
新的 occurrence，或提供完整 replay proof；相同 stable ID 不得因为 ledger 被淘汰而
自动复活旧生命周期。

失败与 retry 分三类：

```swift
enum AdapterFailure: Sendable, Equatable {
    case notDelivered(reason: String)
    case deliveryUnknown(reason: String)
    case protocolRejected(reason: String)
    case unavailable(reason: String)
}
```

- `notDelivered`：request 回到 `pending(error)` 并突出显示。用户再次点击才创建新的
  `EffectID`；Center 不自动 retry。
- `deliveryUnknown`：保持 `resolving`/`awaitingExternalConfirmation`，不产生第二个危险
  effect；等待 provider external resolution 或 adapter 得到明确 not-delivered 事实。
- `protocolRejected`/`unavailable`：回到 pending error，不更改 CLI 事实；用户可在有新
  token/replay 后显式重试。

`resolutionSucceeded` 表示 adapter 完成其承诺的本地协议提交，不等于 Auto confirmed。
对 resolution 的 wire exactly-once 只能在 provider 支持 idempotency 时额外声明；本模块
默认承诺的是每个 `EffectID` 一次本地提交和每个 `TransportToken` 一次 finalization。

## 9. 分阶段 single-owner projections

迁移期间不允许 Center 与旧 `permissionQueue`/`questionQueue` 长期双写。旧调用方可以
暂时存在，但它们只能是 projection/command adapter：

```swift
struct LegacyInteractionProjection {
    let snapshot: InteractionSnapshot

    var permissionQueue: [LegacyRequestView] { /* read-only projection */ }
    var questionQueue: [LegacyRequestView] { /* read-only projection */ }
}

struct LegacyCommandAdapter {
    func approve(_ requestID: RequestID) -> InteractionInput
    func deny(_ requestID: RequestID) -> InteractionInput
    func dismiss(_ requestID: RequestID) -> InteractionInput
}
```

推荐的所有权切换规则：

1. **模型阶段**：Center、generation authority、arrival buffer、transport/effect ledger
   只在 fake adapter trace 中存在；所有 request kind 都有 canonical representation，
   但不接生产 UI。
2. **Ingress/permission 阶段**：生产 ingress 将 permission 和 plan（plan variant）
   送入 Center。旧 permission API 改为 command adapter；旧 queue 属性改为 snapshot
   projection，停止保存/写入旧数组。Question 不能继续另写第二个 Center queue；在其
   resolution UI 尚未迁移时，先以 typed question record 进入同一 registry/ordinal，
   由旧 UI 只读 projection。
3. **Question 阶段**：Hook Notification、AskUserQuestion、Codex 和 Cursor 的 source
   adapter 分别声明 `displayOnly` 或 `required(channel)`；旧 QuestionRequest/
   continuation closure 只留在 transport registry。Question command 转成 Center
   `send`，旧 `skipQuestion` 不再有入口。
4. **Auto/reconcile 阶段**：SessionObservationAdapter 是唯一 snapshot mapper；移除
   `observedPermissionMode` 的 fork ownership，Center context 持有 requested/phase，
   AutoCommandAdapter 执行独立 transaction。
5. **UI/companion 阶段**：Notch/shortcut 只读 local snapshot 并携带 RequestID；
   companion 只消费 redacted facet；所有“current”协议命令被替换为显式 target ID，
   旧协议仅在兼容 adapter 中解析，不回写旧 queue。
6. **Adaptive 阶段**：visibility adapter 输入稳定后，切换
   `legacyProminent` → `adaptiveCLIFirst`；这是 policy flag 的一次切换，不改变 owner。

如果实现阶段不能在 Phase 2 就让 Question record 进入同一 registry，则必须明确延后
“跨 permission/plan/question 单一 ordinal”这个不变量；不能一面运行两个 queue，一面
声称已满足跨 kind ordering。

旧白盒测试在对应 slice 切换后删除或改写为 Center Interface trace；不通过新 projection
继续断言内部数组。每一阶段的 rollback 只恢复 adapter routing，不恢复 Center/legacy
双写。

## 10. 依赖类别、Depth/Locality 与可扩展性的边界

| 依赖 | 类别 | seam/测试实现 |
| --- | --- | --- |
| reducer、identity proof、generation、queue、selector、ledger、redaction | in-process | 直接穿过 Center Interface 的 deterministic trace |
| clock、ID factory、arrival buffer、snapshot mapper fixture | local-substitutable | fake/in-memory implementation |
| Hook bridge、Codex app-server、Auto control channel | remote-but-owned | production adapter + in-memory exactly-once fake |
| AppKit/Terminal/Accessibility/Sound/companion output | true external | production adapter + recording/fake adapter |

纯 in-process 逻辑不再为测试公开内部 port；只有确实有 production 与 test 两个实现的
适配点才形成外部 seam。这样 Center 的 Interface 保持 deep：调用方仍只需了解
`send → effects → adapter events` 和 read-only snapshot，ordering、identity、retry、
privacy 和 lifecycle 复杂度集中在一个地方。

扩展性有意不是无限开放：

- 新 provider 若能映射到 permission variant/question content 和已有 resolution
  capability，只需新增 adapter；
- 新 provider 若需要新的核心语义（新的 queue ordering、resolution lifecycle、危险
  action、privacy audience 或 Auto phase），必须修改封闭的 typed Interface、状态机和
  trace tests；这是 hybrid closed contract 的明确成本；
- 不用 `[String: Any]`、任意 `providerAction` 或 generic Skip 逃避该成本。否则 Interface
  会变成 shallow pass-through，验证和安全策略重新散落到 UI/adapter；
- `DisplayValue` 可以扩充已验证的值树，但不能携带 continuation、raw JSON、closure 或
  未声明的敏感值。

## 11. 必须通过的 Interface invariants

以下断言应成为 Center trace、adapter contract 和 architecture guard 的最小集合：

1. **Plan canonical**：所有 Plan 的 `kind == .permission` 且
   `content == .permission(.variant(.plan(...)))`；不存在 `.plan` kind、`skipPlan` 或
   plan 专属 queue。
2. **Channel validity**：display-only request 永远没有 transport/resolution effect；
   blocking request 永远有唯一 token；channel/session/request identity 不匹配时不入队。
3. **Request-before-observation**：无 current generation 时只进入有界 buffer；bind 后
   保持 arrival order；过期/overflow 一次 neutral finalization，绝不换 session。
4. **Stale generation**：旧 SessionRef 的 observation、transport ack、resolution
   effect 和 user action 都是 no-op diagnostic，不复活新 session。
5. **Single owner**：旧 queue 只能由 Center snapshot 投影产生，旧 command 只能发送
   input；source guard 禁止新的 `append/remove/resume` 写入 legacy arrays。
6. **Cross-kind ordering**：同一 SessionRef 的 permission/plan/question 共用 ordinal；
   不同 session 无 HOL blocking；新 kind 到达不隐式 drain/deny 旧 request。
7. **Disconnect finalization**：token-scoped；peer disconnect 不等于 deny；同一
   `OnceResponder` 最多 finish 一次；重复 disconnect/timeout/replay ack 不产生第二个
   response。
8. **Resolution retry**：resolving 中重复 action 无 effect；not-delivered 只在用户
   显式 retry 后产生新 EffectID；delivery-unknown 不自动 retry。
9. **Auto**：native capability 优先；fallback 只在 capability 明确时生成；Auto command
   不消费 pending permission continuation；delivery 不等于 confirmed，confirmation 只
   来自后续 observation。
10. **Visibility**：stale/过期 visibility 变为 unknown；adaptive unknown 主动展开；
    legacy mode 与 adaptive mode 的切换不改变 request owner。
11. **Privacy**：local snapshot 可读 secret；redacted projection、companion、log、trace
    永远没有 secret/raw provider payload；测试使用 sentinel secret 检查字节不出现。
12. **Effect executor**：同一 EffectID 只提交一次，effects 按返回顺序执行，所有回执
    经过唯一 executor 回到 Center；adapter 不直接修改 AppState/Center。
13. **Terminal ledger**：TTL/capacity eviction 确定；ledger 内 late ack/replay 是 no-op，
    eviction 后也不能用旧 EffectID 变更新 state；terminal request 不因 duplicate arrival
    重新打开。

这些契约关闭后，才能把 `implement.md` 的每个 phase gate 写成可执行的 trace/adapter/
guard 测试，而不是继续依赖 `permissionQueue`、`questionQueue` 或 continuation 的内部
白盒状态。
