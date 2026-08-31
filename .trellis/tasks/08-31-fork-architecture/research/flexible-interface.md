# InteractionCenter：面向未来请求类型的深模块 Interface 研究

本文只研究目标 Interface，不修改产品代码。术语遵循 `codebase-design`：
InteractionCenter 是 Module；`send`/只读 snapshot 是 Interface；Hook、CLI、terminal、
SwiftUI 和 companion 是 Adapter；接入位置是 seam；目标是用较小的 Interface 获得较高
的 Depth、Leverage 和 Locality。

## 1. 结论

建议把 InteractionCenter 设计成一个串行、无 I/O 的 reducer-like deep module：

```swift
@MainActor
struct InteractionCenter {
    var snapshot: InteractionSnapshot { get }
    mutating func send(_ input: InteractionInput) -> [InteractionEffect]
}
```

调用方只需要知道三件事：

1. 把规范化的 session/request observation、用户动作和 transport 事件送入 `send`；
2. 消费只读 `snapshot`；
3. 执行返回的声明式 `InteractionEffect`，完成后再把 success/failure/disconnect 等
   事实送回 `send`。

Center 不持有 `CheckedContinuation`、`NWConnection`、JSON-RPC client、AppKit 对象或
SwiftUI binding。它只管理事实之上的 request 生命周期、每 session 队列、dismiss/reveal、
resolution ledger、Auto 状态、presentation selector 和导航操作状态。这样 upstream 的
hook 字段、CLI 协议或 terminal 实现变化，通常只影响相应 Adapter，而不会扩散到 UI、
AppState 调用方或生命周期状态机。

这不是把所有东西做成一个“万能 JSON API”。核心 Interface 只开放生命周期需要的
规范化值；请求的正文、字段和可用 resolution action 由 request adapter 声明。已知的
permission/plan/question 可以有强类型内容和专用 renderer，未知类型仍可通过 descriptor
获得通用呈现和 action capability。其余语义超出 descriptor 能表达的地方，明确进入
扩展 seam，而不是悄悄把 provider 判断塞进 Center。

## 2. 外部 Interface 的类型

以下是 Swift 风格的设计草图；名称和字段是契约候选，不是要求直接复制进生产代码。

### 2.1 identity 与 session

```swift
struct SessionID: Hashable, Sendable, RawRepresentable {
    let rawValue: String
}

struct ProviderID: Hashable, Sendable, RawRepresentable {
    let rawValue: String       // claude, codex, future provider…
}

struct SessionRef: Hashable, Sendable {
    let id: SessionID
    let provider: ProviderID
    let generation: UInt64      // 同一 provider id 重开时区分旧 transport
}

struct RequestID: Hashable, Sendable {
    let provider: ProviderID
    let session: SessionRef
    let correlation: RequestCorrelation
}

enum RequestCorrelation: Hashable, Sendable {
    case stable(StableRequestKey)
    case occurrence(OccurrenceID)
}

struct StableRequestKey: Hashable, Sendable {
    let upstreamID: String
    let discriminator: String?  // 只有 adapter 能证明时才填写
}

struct OccurrenceID: Hashable, Sendable { let rawValue: UUID }
```

`RequestID` 是来源限定的稳定身份，不是全局的裸 `toolUseId`。`StableRequestKey` 至少
包含可靠 upstream request/tool ID，并按需结合 session、kind、tool 或 input discriminator。
现有回归已经证明同一 `tool_use_id` 可能被并行工具调用共享，所以 Center 不会仅凭
`toolUseId` 合并 replay。

身份合并的 proof 必须由 provider adapter 提供，建议在 arrival 中显式表达：

```swift
enum RequestIdentityClaim: Sendable {
    case new(RequestID)
    case replay(of: RequestID, proof: ReplayProof)
}

struct ReplayProof: Sendable, Equatable {
    let upstreamID: String
    let sessionAndGenerationMatch: Bool
    let discriminatorMatch: Bool
    let reason: ReplayReason
}
```

如果 adapter 不能证明是 replay，就生成新的进程内 occurrence ID；不得用内容 fingerprint
猜测合并。App 重启后不恢复 pending identity，也不从相同正文推断旧 request。若 provider
的 request ID 被复用但正文或 discriminator 冲突，adapter 必须改用 occurrence/new key，
Center 不得覆盖现有 pending request。

`generation` 是防止旧连接/旧 session 事件复活新 session 的内部可观察输入；外部 UI 仍以
`SessionID` 和完整 `RequestID` 操作。若 provider 没有 generation，adapter 在明确的
SessionStart/reopen 事实处创建它。

### 2.2 upstream/session observation

`SessionSnapshot` 是 upstream/session 事实的只读输入，不应传入 Center，也不应添加 fork
字段。接入层把它映射为最小 `SessionObservation`：

```swift
struct SessionObservation: Sendable, Equatable {
    let session: SessionRef
    let lifecycle: SessionLifecycle
    let providerSessionID: String?
    let source: ProviderID
    let permissionMode: ObservedPermissionMode?
    let providerCapabilities: ProviderCapabilities
    let navigation: NavigationTarget?
    let observedAt: Date
    let revision: UInt64?
}

enum SessionLifecycle: Sendable, Equatable {
    case active
    case idle
    case waiting
    case removed(reason: RemovalReason)
}

enum ObservedPermissionMode: String, Sendable, Equatable {
    case `default`, auto, acceptEdits, bypassPermissions, unknown
}
```

只传递 Center 做决定所需的字段：mode 是 CLI 已观察到的事实，capability 是 provider
能力，navigation 是由 `SessionNavigator` 可用的目标。cwd、terminal bundle、PTY、
`SessionSnapshot` 的所有历史/工具/消息字段继续由 upstream owned 模块拥有；若将来
upstream 提供等价事实，只替换 mapper。

### 2.3 可扩展 request envelope

request 的生命周期和正文分开。生命周期核心不应该为每个 CLI 新增一个 `switch`；
provider adapter 负责把 hook/app-server/raw event 转成 envelope：

```swift
struct RequestEnvelope: Sendable, Equatable {
    let identity: RequestIdentityClaim
    let session: SessionRef
    let kind: RequestKind
    let behavior: RequestBehavior
    let content: RequestContent
    let actions: [ResolutionActionDescriptor]
    let transport: TransportToken
    let arrivedAt: Date
}

struct RequestKind: Hashable, Sendable, RawRepresentable {
    let rawValue: String       // permission, question, future provider kind…
}

struct RequestBehavior: Sendable, Equatable {
    let blocking: Bool
    let ordering: OrderingLane
    let dismissable: Bool
    let defaultPresentation: PresentationPreference
    let sensitive: Sensitivity
}

enum OrderingLane: Sendable, Equatable {
    case serial                    // 默认：同 session 保持 provider 顺序
    case keyed(String)             // 只有 provider 明确证明可并行时使用
}

enum RequestContent: Sendable, Equatable {
    case permission(PermissionContent)
    case question(QuestionContent)
    case extension(ExtensionContent)
}
```

Plan 不是第二套生命周期：它以 permission 的一种 `PermissionContent.variant == .plan`
进入同一 queue 和 resolution ledger。这样 Plan 的 plain allow 是明确的 `allow` action，
而不是 UI 里的 `Skip`。

建议的内容模型是有限的、可安全展示的值，而不是让 Center 接收 `[String: Any]`：

```swift
struct PermissionContent: Sendable, Equatable {
    let toolName: String?
    let summary: String?
    let input: DisplayValue?
    let variant: PermissionVariant
}

enum PermissionVariant: Sendable, Equatable {
    case regular
    case plan(plan: DisplayValue?)
}

struct QuestionContent: Sendable, Equatable {
    let items: [QuestionItem]
    let isSecret: Bool
}

struct ExtensionContent: Sendable, Equatable {
    let title: String
    let summary: String?
    let sections: [DisplaySection]
    let fields: [InputField]
    let renderer: RendererKey?
}
```

`DisplayValue` 必须是 JSON-like 但已消毒的 value（string/number/bool/list/object 的
只读树），不能带 continuation 或 arbitrary closure。`Sensitivity` 和 `isSecret` 使
snapshot projector 可以对 companion/ESP32 等低信任 Adapter 做 redaction；question 的
敏感正文不能因为加入统一 snapshot 而被远程设备串出。

### 2.4 resolution action 与 capability

resolution action 是 provider 能力声明，不是 UI 猜出来的按钮：

```swift
struct ResolutionActionDescriptor: Sendable, Equatable, Identifiable {
    let id: ResolutionActionID
    let semantic: ResolutionSemantic
    let label: LocalizedLabel
    let input: InputSchema?
    let risk: ActionRisk
}

struct ResolutionActionID: Hashable, Sendable, RawRepresentable {
    let rawValue: String
}

enum ResolutionSemantic: Sendable, Equatable {
    case allow
    case deny
    case answer
    case abandon
    case setMode
    case providerDefined
}

struct ResolutionCommand: Sendable, Equatable {
    let request: RequestID
    let action: ResolutionActionID
    let input: ActionInput?
}
```

Center 只检查 `action` 是否在该 request 的 descriptor 中、输入是否满足 schema，然后
把 opaque-but-typed command 放进 effect。实际 JSON、Codex response、Claude
`updatedInput`、ZCode strict schema 等协议细节留给 adapter。

所有可交互 question 都由 Center 注入本地 `Dismiss` presentation action；它不属于
resolution capability，不会向 CLI 发送回答/deny。若 Question adapter 能稳定表达额外
语义，可声明名称准确的 `reject`、`abandon` 或 `continue-without-answer`；不能稳定
表达时只显示 Dismiss。不得跨来源把它们统称 `Skip`。Plan 同理，允许的“继续但不改变
mode”是明确的 `allow`，不再有 `Skip` action。

### 2.5 Auto capability

Auto 是 session context 的另一条 lifecycle，不是 request 的隐式全局 flag：

```swift
struct AutoCapability: Sendable, Equatable {
    let supportedStrategies: [AutoStrategyDescriptor]
    let canUseDangerousMode: Bool
}

struct AutoStrategyDescriptor: Sendable, Equatable, Identifiable {
    let id: AutoStrategyID
    let mode: AutoModeID
    let native: Bool
    let dangerous: Bool
}

struct AutoCommand: Sendable, Equatable {
    let session: SessionRef
    let intent: AutoIntent
}

enum AutoIntent: Sendable, Equatable {
    case enable(preferred: AutoModeID?)
    case disable
}
```

Center 选择 provider 原生 `auto`；无原生能力时只能选择 adapter 明确注册的
`acceptEdits + addRules` strategy。`bypassPermissions` 必须同时满足用户显式 intent 和
provider capability，不能静默 fallback。Auto 的 snapshot 至少分开：

```swift
struct AutoSnapshot: Sendable, Equatable {
    let observedMode: ObservedPermissionMode?
    let requestedMode: AutoModeID?
    let phase: AutoPhase
    let capability: AutoCapability
    let error: InteractionError?
}

enum AutoPhase: Sendable, Equatable {
    case unavailable
    case idle
    case requesting(effect: EffectID)
    case confirmed
    case unknown
    case failed
}
```

mode observation 来自 CLI event；requested 不得直接变成 confirmed。断开时清理
CodeIsland context，但没有新事实时不宣称 CLI 已被关闭或已切 mode。

### 2.6 Input、Effect 与 transport token

```swift
enum InteractionInput: Sendable {
    case sessionObserved(SessionObservation)
    case requestArrived(RequestEnvelope)
    case user(UserInteraction)
    case transport(TransportEvent)
    case sessionRemoved(SessionRemoval)
    case tick(now: Date)
}

enum UserInteraction: Sendable {
    case resolve(ResolutionCommand)
    case dismiss(request: RequestID)
    case reveal(request: RequestID)
    case navigate(session: SessionRef, operation: NavigationOperationID)
    case setAuto(AutoCommand)
}

enum InteractionEffect: Sendable, Equatable {
    case transmit(ResolutionEffect)
    case changeAutoMode(AutoModeEffect)
    case cancelTransport(TransportToken, reason: CancelReason)
    case navigate(NavigationEffect)
    case notify(InteractionNotification)
}

struct ResolutionEffect: Sendable, Equatable {
    let id: EffectID
    let request: RequestID
    let transport: TransportToken
    let command: ResolutionCommand
}

struct AutoModeEffect: Sendable, Equatable {
    let id: EffectID
    let session: SessionRef
    let transport: TransportToken
    let command: AutoCommand
}
```

`TransportToken` 是 adapter 创建的 opaque identity，不是 socket 或 continuation 的
引用；它只允许 adapter 自己查找传输资源。Center 的实现可以把 token 存在 request
record 中，但绝不存 `CheckedContinuation`。`EffectID` 是全局唯一且可持久于一次进程
生命周期的 idempotency key。

transport 回报必须带齐 effect/request/token，避免旧连接的 ack 误伤新 request：

```swift
enum TransportEvent: Sendable {
    case effectSucceeded(effect: EffectID, request: RequestID, token: TransportToken)
    case effectFailed(effect: EffectID, request: RequestID, token: TransportToken, error: InteractionError)
    case disconnected(token: TransportToken, reason: DisconnectReason)
    case externallyResolved(request: RequestID, resolution: ExternalResolution)
    case transportEnded(token: TransportToken)
}
```

Hook adapter 在 transport registry 中保存 connection/continuation，并在执行
`ResolutionEffect` 时 exactly once。Codex app-server adapter 保存 JSON-RPC response
路由；两个 adapter 都从同一 Interface 接入。Center 返回的 effect 顺序就是 adapter
应执行的顺序；adapter 回报必须幂等，未知/重复 effect 的回报只能被忽略并记录诊断。

### 2.7 只读 snapshot

```swift
struct InteractionSnapshot: Sendable, Equatable {
    let revision: UInt64
    let sessions: [SessionInteractionSnapshot]
    let requests: [RequestSnapshot]
    let presentation: PresentationSnapshot
}

struct SessionInteractionSnapshot: Sendable, Equatable {
    let session: SessionRef
    let pendingCount: Int
    let pendingKinds: [RequestKind]
    let auto: AutoSnapshot
    let navigation: NavigationSnapshot
}

struct RequestSnapshot: Sendable, Equatable {
    let id: RequestID
    let kind: RequestKind
    let content: RequestContent
    let phase: RequestPhase
    let presentation: RequestPresentation
    let actions: [ResolutionActionDescriptor]
    let error: InteractionError?
}

enum RequestPhase: Sendable, Equatable {
    case pending
    case resolving(effect: EffectID, action: ResolutionActionID)
    case resolved(ResolutionOutcome)
}

enum RequestPresentation: Sendable, Equatable {
    case prominent
    case badgeOnly
    case dismissed
    case optimisticHidden
}
```

snapshot 中没有 queue index、raw `HookEvent`、continuation、closure 或 Network object。
`requests` 的排序由 Center 保证（session queue order，再按 deterministic tie-breaker），
UI 不得自己按 global queue head 猜测。终结 request 可短暂留在 snapshot 作为可测试的
`resolved` tombstone；实现可以按 bounded retention 清理，pending count 永远不包含它。
敏感请求在面向 remote Adapter 的 projector 中必须输出 redacted content。

## 3. 不变量、顺序与错误模式

### 3.1 生命周期不变量

每个 request 的合法迁移为：

```text
arrival → pending
pending --resolve--> resolving --success--> resolved
pending --external resolution--> resolved(externally)
resolving --external resolution--> resolved(externally)
resolving --transport failure--> pending + prominent error
pending --dismiss--> pending + dismissed/badgeOnly
```

- `dismiss` 永远不 dequeue、deny、allow、answer、取消 CLI 等待或变更 mode。
- `resolving` 立即从卡片隐藏，但仍算 session pending/transitioning；重复点击相同
  request 不产生第二个 effect。
- 只有匹配的 success ack 或 CLI external-resolution fact 才结束 resolution；按钮点击
  本身不是事实。
- transport failure 恢复 pending、保留用户 action 的错误上下文并突出显示；危险
  决策不自动重试。
- 旧 transport 在 replay 重新绑定前必须收到 `transportEnded` 或被明确取消；旧 ack
  不能解决新绑定。
- peer/CLI 先行解决时，Center 进入 externally resolved，并对尚未执行的重复 effect
  发出 `cancelTransport`；不再发送第二份 response。
- session removed 是 source-of-truth 的移除事实：停止呈现并终结该 session 的
  transport；不伪造 deny。若 adapter 只能报告断开而没有 resolved/remove 事实，pending
  保留为 unavailable/error，等待重新观察或明确外部解决。

### 3.2 identity 与 replay

- 同一 `RequestID` 的 replay 继承 dismissed 状态、queue ordinal、phase 和 action
  history，不重新发 sound、不重新呈现、不重复决策。
- 同 session 的新 `RequestID` 不继承旧 request 的 dismiss 状态。
- 缺少可靠 upstream ID 的到达全部是 occurrence；相同正文不构成 replay proof。
- 同一 request 的到达可替换 transport binding，但必须先明确终结旧 token；旧 token
  的 failure/ack 对新 token 无效。

### 3.3 queue 与 presentation ordering

- Center 在单一 actor/reducer 串行处理 `send`；一次 send 的 effects 按数组顺序执行。
- 每个 session 有独立 queue/lane；serial lane 保持 provider arrival ordinal。默认
  后一个 blocking request 不能越过前一个，防止同一 CLI 的因果步骤乱序。
- 不同 session 之间没有 head-of-line blocking。全局 selector 只选择当前突出项。
- selector 优先级固定为：`resolving failure` > `explicit reveal` > 普通 waiting，
  再按 arrival ordinal 和 stable deterministic tie-breaker。
- dismiss 的 request 不突出但继续出现在 badge/pending count；用户 reveal 后在 resolve
  或再次 dismiss 前保持 prominent。
- resolution 后通常优先同 session 下一项；其他 session 的更高优先级 failure/reveal
  可以抢占突出显示。
- 所有 UI、快捷键、companion command 都必须携带 RequestID，不能隐式操作 queue head。

### 3.4 stale input 与协议错误

| 输入 | Center 行为 |
| --- | --- |
| malformed/无法呈现的 envelope | 不创建 request；返回诊断 notification 或由 adapter ack 安全空响应 |
| 未知 `RequestKind`，但 descriptor 完整 | 走 extension generic renderer 与 descriptor actions |
| 未知 `RequestKind`，descriptor 不完整 | quarantine/安全忽略；不猜测 action，不创建阻塞卡片 |
| stale session revision | 忽略过期 observation；不倒退已确认事实 |
| unknown RequestID user action | 无状态改变，返回可观测的 ignored notification |
| action 不在 capability 或 input invalid | 无状态改变，snapshot 给 validation error；无 transmit effect |
| 重复 resolve/旧 effect ack | 幂等忽略；不能重复 resume 或改变新 phase |
| stable ID 冲突且无 replay proof | 作为新 occurrence（或 adapter quarantine），不得覆盖旧 request |
| disconnect 无 external resolution | request 保留 pending/unavailable，不自动 deny |
| request 在 session removed 后到达 | 需新的 generation/reopen fact；旧 generation 直接忽略 |

`InteractionError` 应有 machine-readable code、用户可见 summary 和是否可重试的风险
标记。Transport failure 的 retryability 不等于自动重试许可；普通 answer 也应由用户
再次确认，危险 allow/deny 永不由 selector 自动重放。

## 4. 使用方式

### 4.1 Hook adapter

现有 `HookServer` 不再调用 `appState.handlePermissionRequest(... continuation:)`。
它解析/过滤/规范化 raw event，注册自己的 transport token，然后送入 Center：

```swift
let token = hookTransport.register(connection, requestMetadata: rawEvent)
let envelope = hookAdapter.normalize(rawEvent, session: facts, token: token)
let effects = center.send(.requestArrived(envelope))
hookTransport.execute(effects)
```

`hookTransport.execute` 只处理 `.transmit`、`.cancelTransport`、`.notify` 等适配职责；
发送结果再回送：

```swift
center.send(.transport(.effectSucceeded(
    effect: effect.id,
    request: effect.request,
    token: effect.transport
)))
```

Hook adapter 继续负责协议编码、connection lifetime、disconnect/timeout 和 exactly-once
resume。Center 只看到 token 和声明式 command。

### 4.2 SwiftUI/快捷键/companion

```swift
let viewState = center.snapshot

ForEach(viewState.requests.filter { $0.presentation != .badgeOnly }) { request in
    RequestCard(request: request) { action, input in
        center.send(.user(.resolve(.init(
            request: request.id, action: action, input: input))))
    } onDismiss: {
        center.send(.user(.dismiss(request: request.id)))
    }
}
```

UI 只展示 snapshot 并发送 RequestID/actionID；它不读取 queue、不访问 continuation、
不判断 Codex/Claude/ZCode 的 response JSON，也不更新 `SessionSnapshot`。Question UI
始终渲染本地 Dismiss；只有 snapshot 的 `actions` 中明确存在额外 capability 才渲染
其 provider-specific action。

companion/ESP32 也是 snapshot/action adapter。对没有能力安全展示 secret content 的
设备，只接收 redacted snapshot 和明确的 pending count，不绕过 Center 直接 resolve。

### 4.3 upstream event 与外部解决

```swift
center.send(.sessionObserved(mapper.map(sessionSnapshot)))
center.send(.transport(.externallyResolved(
    request: requestID,
    resolution: .peerAnswered
)))
```

`SessionSnapshot` mapper 是一个单向 adapter；将来 upstream 加入 hook request ID、
permission mode revision 或 native auto capability 时，只修改 mapper/provider adapter。
若没有可靠关联，仍按 occurrence 处理。

### 4.4 navigation

```swift
center.send(.user(.navigate(session: session, operation: operationID)))
// Effect: .navigate(NavigationEffect)
center.send(.transport(.navigationSucceeded(operationID)))
// or navigationFailed(operationID, error)
```

`NavigationTarget` 和 `SessionNavigator` adapter 隐藏现有 terminal 路由、三次可见性
验证、失败声音/shake 以及 `autoCollapseAfterSessionJump`。Center 只维护 operation、
成功/失败 snapshot 和 panel preference；它不把 `TerminalActivator` 或 AppKit 引用纳入
Interface。

## 5. 隐藏 implementation 与深度来源

Center 内部可以拆成 private/internal seams，但这些不出现在外部 Interface：

```text
InteractionCenter
├─ sessionFacts + InteractionSessionContext store
├─ RequestIdentityIndex / replay proof checker
├─ per-session OrderingLanes
├─ RequestLifecycle + EffectLedger (exactly-once/idempotency)
├─ PresentationSelector + dismiss/reveal store
├─ AutoPolicy (capability + observed/requested reconciliation)
├─ NavigationCoordinator
└─ SnapshotProjector / redaction
```

实现必须把 fork 派生状态存入独立的 `InteractionSessionContext`，按 session id/epoch
索引；不能回写 `SessionSnapshot`。建议字段包括：request records、arrival ordinal、
dismissed/revealed request IDs、pending error、auto requested/confirmed、in-flight effect
ledger、navigation feedback。dismiss 不跨重启持久化 pending identity；普通 app restart
等待 CLI 重新上报事实。

一个最小的初始化配置可以注入：

```swift
struct InteractionCenterConfiguration {
    let clock: any InteractionClock
    let idFactory: any InteractionIDFactory
    let policyRegistry: any RequestPolicyRegistry
    let presentation: PresentationPolicy
}
```

生产和测试都显式提供 dependencies，不由 Center 创建全局 singleton。`policyRegistry`
不是让每个调用方注册行为；它是 Center 内部/初始化时加载的 built-in + provider
profiles。调用者仍只有 `send` 和 snapshot。

### 依赖分类与测试 seam

| dependency | Deepening 分类 | seam/adapter | 测试方式 |
| --- | --- | --- | --- |
| identity、ordering、lifecycle、selector、redaction | in-process | 无外部 port | 直接用 deterministic clock/id factory 测 reducer Interface |
| `InteractionSessionContext`、bounded tombstone、settings | local-substitutable | memory context adapter；若未来持久化再加 persistence port | memory adapter + restart/reconcile trace |
| Hook Unix socket/continuation、Codex app-server | true external（本机 transport 仍是外部协议） | `HookTransportAdapter`、`CodexTransportAdapter` | in-memory exactly-once adapter；少量协议 contract tests |
| upstream `SessionSnapshot`/hook normalizer | remote/upstream-owned input | `SessionFactMapper`/provider adapter | fixture observations；不让 Center 读 raw JSON |
| TerminalActivator、AppKit、AppleScript、可见性 detector | true external | `SessionNavigatorAdapter` | fake navigator 回报 success/failure；少量真实 macOS smoke test |
| Sound/notification/companion | true external presentation | `NotificationAdapter`、snapshot publisher | recording adapter，断言 effect，不断言系统声效 |
| SwiftUI | adapter | snapshot/action renderer | interaction trace + view-model projection；不测 Center 内部字段 |

这符合 DEEPENING 的 seam discipline：in-process 逻辑直接通过 Center Interface 测试；
真正存在 production/test 两种实现的 transport、navigation、notification 才定义
Adapter seam。不要为了测试把 identity index 或 policy registry 公开。

## 6. extensibility、Depth 与 Locality 的权衡

### 新 CLI / 新 hook 字段

理想路径只有 provider adapter 改动：

```text
raw hook/app-server event
  → provider normalizer + identity proof + capability
  → InteractionInput
  → InteractionCenter
  → generic snapshot/effect
  → provider transport adapter / UI adapter
```

新字段若只是更好的 request identity、mode observation、question metadata 或 terminal
capability，新增 mapper fixture 即可。Center 不复制 upstream normalization/detection，
也不需要把新字段加入 `SessionSnapshot` 的 fork overlay。

### 新 request kind

若新请求只需要“阻塞、显示 descriptor、可 dismiss、提供若干 action、等待 ack”，它应
只实现 provider `RequestEnvelope` 归一化和 `ExtensionContent`/action descriptors；
generic renderer 可以立即支持。

若需要专属视觉布局，可添加 `RendererKey` 对应的 UI Adapter，仍复用 Center lifecycle。
若需要专属 transport，只增一个 transport Adapter。已有 permission/plan/question 的
trace 测试不变。

### 新语义的门槛

extension descriptor 不是无限能力。以下情况需要明确增加一个内部 policy profile 或
新的 seam：

- 新请求会改变另一个 request 的合法性，而不只是自己的 pending/resolve；
- 需要跨 session 的 ordering/lock 语义，而不是现有 serial/keyed lane；
- resolve 是多阶段事务，有补偿动作或必须等待多个 provider 事实；
- 它需要不同于 `pending → resolving → resolved` 的安全生命周期；
- 它有不可抽象为 field/action schema 的强交互编辑器或连续 streaming state。

此时不要在 UI 里偷偷判断 kind，也不要把一堆 optional callback 塞进 `RequestEnvelope`。
新增可测试的 `RequestPolicy`/renderer/transport seam，让变化仍局部化。

## 7. 哪里会变浅（以及拒绝的设计）

以下做法会让 InteractionCenter 成为一个 shallow pass-through module，应该在设计评审
中拒绝：

1. **把 `[String: Any]`、raw `HookEvent` 或协议 JSON 放入 snapshot。** 每个 UI/测试都
   必须懂 provider 字段，Interface 几乎等于 implementation；而且 secret/redaction
   和 upstream 冲突重新扩散。
2. **为每个 CLI 暴露 `approveClaude`、`answerCodex`、`skipQoder` 等方法。** 调用方
   数量随 provider 增长，重复 action/lifecycle 规则；正确 seam 是 descriptor + opaque
   command + provider transport adapter。
3. **Center 直接持有 continuation/network/AppKit。** transport 变化会迫使业务 reducer、
   UI 和测试一起改，且 disconnect/timeout 极易 double resume。
4. **把 terminal metadata、`TerminalActivator` 规则和可见性重试搬到 UI。** 三张卡片
   再次复制 jump/feedback/collapse 状态机，丢失 SessionNavigator 的 Locality。
5. **为了“开放”暴露十几个内部 store/protocol。** 测试开始依赖 queue index、effect
   ledger、identity table；内部 refactor 不再安全，Depth 反而下降。
6. **把所有未来 request 强行压成 question/permission。** 表面减少类型，却会把错误
   resolution semantics 和风险放入 UI 猜测；`ExtensionContent` + capability 或专用
   policy 更诚实。
7. **让 generic renderer 支持无限任意 widget。** schema 会膨胀成第二个 UI framework，
   每个 caller 需要理解 layout；复杂新体验应有 dedicated renderer adapter，核心只管
   lifecycle。
8. **双写旧 queue 与 Center。** 这不是兼容 Interface，而是两个 state owner；会产生
   duplicate effect/resume，破坏可验证的 source-of-truth。

真正的 extensibility frontier 是：Center 对生命周期、presentation、resolution ledger
和 session policy 保持深；provider payload、协议编码和复杂渲染通过明确 Adapter seam
扩展。若新增行为必须修改 selector/lifecycle 的核心，先证明它是共享产品语义，再扩展
policy profile；不要为避免一次 core change 而设计一个比实现更大的万能 Interface。

## 8. 分阶段迁移与回滚界限

每阶段都只允许一个 owner 写入事实；adapter 可以暂时桥接旧调用，但不能长期双写。

### Phase 0：纯模型和 trace test

- 创建 `InteractionInput`/`InteractionEffect`/snapshot 草图及 in-memory transport。
- 迁移测试到 Center Interface：identity、replay、dismiss、failure、external
  resolution、多 session ordering、Auto requested/confirmed、navigation feedback。
- 不接 production；可删除整个目录回滚。

### Phase 1：SessionNavigator 行为等价提取

- 将 ApprovalBar、QuestionBar、SessionCard 的 identity/jump/retry/shake/collapse
  接入统一 Navigator module。
- 保留现有 `TerminalActivator.activate(session:sessionId:)`、三次可见性检查及设置
  语义，Center 只接收 navigation effects/result。
- 验证后移除旧卡片的 jump state machine。

### Phase 2：permission lifecycle

- Hook adapter registry 持有 continuation/connection，发 `requestArrived`；Center
  独占 permission request records 和 queue。
- 完成一个 request 类型的切换后，旧 `permissionQueue` 立即停止写入；AppState 只做
  SessionSnapshot mapping/effect dispatch。
- 先保持当前新 request 主动展开行为，避免同时改变 UX。

### Phase 3：Plan variant

- `ExitPlanMode` 归入 permission variant；`allow`、mode change、deny-with-feedback
  都是 action descriptors。
- 删除 Skip descriptor/按钮；plain allow 直接表达继续而不改 mode。

### Phase 4：question lifecycle

- 迁移 Notification、AskUserQuestion、Codex app-server question 到同一 request model。
- 本地 Dismiss 为统一 presentation action；仅由 adapter capability 暴露清晰的额外
  resolution action。
- 移除 question-specific queue writes 和 `skipQuestion` 的跨来源协议判断。

### Phase 5：per-session Auto

- Auto context 按 SessionRef 存 observed/requested/capability/phase。
- CLI event 只通过 observation 确认；关闭/断开不做虚假确认。
- 移除 `SessionSnapshot.observedPermissionMode`、Core reducer/persistence/test 中的
  fork-only mode 历史；仍保留 upstream `permissionMode`。
- 移除全局 `autoApproveSessionId` 假象；旧 Auto methods 不再写第二 owner。

### Phase 6：SwiftUI/snapshot 收敛

- `NotchPanelView`、AppDelegate shortcuts、companion publisher 只读取 snapshot 并发送
  RequestID action。
- `AppState.swift` 不保存 fork queue/dismiss/Auto；`HookServer.swift` 只规范化 input、
  管 token、执行 effects；UI 不判断 provider 协议。
- 增加 architecture guards 防止 queue/raw continuation 回流热点文件。

### Phase 7：adaptive CLI-first

- 在行为等价完成且已有 trace evidence 后，启用目标 CLI pane/tab 可见时 badge/notification、
  不可判断时主动展开的 adaptive policy。
- 手动 reveal、failure prominence、session badge/pending counts 保持既定优先级。

每个 phase 的回滚单位是整个阶段（adapter routing + owner switch + tests），不是单个
字段。以 upstream/main 做 sync rehearsal，记录冲突文件、需要人工理解业务语义的冲突、
以及 fork-owned 模块是否无需修改；若新字段只能通过修改大型 upstream 文件才能接入，
说明 seam 未足够稳定，应在下一阶段前修正。

## 9. 验收重点

通过 Center Interface 的 interaction trace 至少覆盖：

- stable identity、shared tool id collision、occurrence ID 与 replay proof；
- dismiss 不 resolve，dismissed badge/reveal 和 app restart 后不猜 identity；
- optimistic hide、single effect、success/failure restore、external resolution 和
  disconnect；
- 同 session serial order、跨 session 无 HOL blocking、selector priority；
- Plan 无 Skip、Question 总有 Dismiss、capability action 的来源明确；
- per-session Auto 的 requested/unknown/confirmed、危险 mode 无静默 fallback；
- navigation success/3-check failure feedback/auto-collapse；
- secret question 的 local/redacted snapshot；
- session removal、旧 generation event、stale ack 不复活状态。

测试断言只使用 input、ordered effects 和 snapshot/outcome，不访问 continuation、queue
array、identity table 或 policy implementation。这样测试就是 Interface 的 test surface，
实现可以在不重写行为测试的情况下更换内部结构。
