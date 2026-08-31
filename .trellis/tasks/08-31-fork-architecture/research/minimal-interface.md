# InteractionCenter：两入口深模块 Interface

本稿只定义 `InteractionCenter` 的规划 Interface，不修改产品代码。它以当前
`.trellis/tasks/08-31-fork-architecture/prd.md` 的已确认决策为约束，并以当前源码
作为迁移依据。

结论：`InteractionCenter` 对调用方只暴露两个入口：

```swift
@MainActor
@Observable
final class InteractionCenter {
    var snapshot: InteractionSnapshot { get }       // 唯一只读读取入口
    @discardableResult
    func send(_ input: InteractionInput) -> [InteractionEffect]
}
```

初始化所需的时钟、Occurrence ID 生成器和测试配置通过 `init(dependencies:)` 注入；
它是构造入口，不增加运行期命令入口。没有 `approvePermission()`、
`dismissQuestion()`、`pendingPermission(for:)`、`toggleAuto()` 或 `queueHead` 等专用
方法。所有事实、用户命令、Adapter 回执和 session 删除都经过同一个 `send` seam，
所有 UI 都只读同一个 `snapshot`。

这使它成为一个 deep Module：大量请求身份、每 session 排队、replay、optimistic
resolution、Auto 模式、CLI-first 呈现、跳转结果与失败反馈的行为隐藏在很小的
Interface 后。其 Interface（不只是 Swift 类型签名）还包含下面的 invariants、顺序
约束、错误模式和 Adapter 前置条件。

## 当前代码给出的 seam 依据

当前实现证明这些复杂度不应继续留在 upstream 热点文件中：

* `AppState.swift` 的公开/可观察状态包括 `permissionQueue`、`questionQueue`、
  `dismissedPermissionSessionIds`、`activeSessionId` 以及全局
  `autoApproveSessionId`/`autoApproveModeSnapshot`；其多处方法按数组 head 或
  session 搜索并直接 `resume` continuation。
* `Models.swift` 的 `PermissionRequest` 和 `QuestionRequest` 直接持有
  `CheckedContinuation` 或 Codex reply closure；`QuestionResolution` 因此把协议
  传输对象泄漏到了状态模型。
* `HookServer.swift` 目前创建/监控 `NWConnection`，然后把 continuation 交给
  `AppState`；它还包含 source、plugin、cwd、Codex/Cursor 路由和 auto 短路判断。
* `NotchPanelView.swift` 同时读取 queue、计算 session 位置、写入 `surface`，并在
  `ApprovalBar`、`QuestionBar`、`SessionCard` 内重复 `TerminalActivator.activate`、
  三次验证、失败声音/shake 和自动收起。
* `NotchPanelView+Plan.swift` 把 `ExitPlanMode` 当作 permission，并提供名为
  `Skip` 的 plain allow；`QuestionBar` 仍调用 `skipQuestion()`。这两个名称不能
  进入新 Interface。
* `SessionSnapshot.swift` 仍保存 fork-only 的 `observedPermissionMode`；
  `SessionPersistence.swift` 也序列化它。新模块不能把其它 fork 状态继续塞回这个
  upstream-owned 事实模型。

因此 seam 应位于 fork-owned 的 `InteractionCenter` 模块：
`HookServer` 只做事件规范化、transport token 注册和 effect 执行；
`NotchPanelView` 只将 snapshot 渲染为 View 并发送带目标 ID 的 action；
`SessionSnapshot` 只作为一个 upstream observation 输入，而不是状态 owner。

## Interface 的值类型

以下是接近 Swift 的规划类型。它们是值类型、`Sendable`、可测试；具体命名可以在
`design.md` 定稿，但不得增加按领域拆开的运行期入口。

### IDs、身份和到达

```swift
struct SessionID: Hashable, Sendable { let raw: String }
struct EffectID: Hashable, Sendable { let raw: UUID }
struct TransportToken: Hashable, Sendable { let raw: UUID }

enum InteractionKind: Hashable, Sendable {
    case permission
    case plan                         // ExitPlanMode 的显示 variant
    case question
}

struct StableRequestIdentity: Hashable, Sendable {
    let provider: String              // 规范化 source
    let providerRequestID: String     // upstream 可靠 request/tool ID
    let sessionID: SessionID
    let kind: InteractionKind
    let discriminator: String         // tool/input discriminator；可为空但不能猜 replay
}

enum RequestID: Hashable, Sendable {
    case stable(StableRequestIdentity)
    case occurrence(UUID)
}

struct RequestArrival: Sendable {
    let id: RequestID
    let sessionID: SessionID
    let content: RequestContent
    let resolutionCapabilities: ResolutionCapabilities
    let transport: TransportToken
    let association: RequestAssociation
    let receivedAt: Date
}

enum RequestAssociation: Sendable {
    case new
    case replay(of: RequestID)
}
```

`RequestID` 的规则是硬约束：

1. provider Adapter 从可靠的 upstream request/tool ID 生成 `.stable`，并按 session、
   kind、tool/input discriminator 限定作用域。已知某 CLI 会让并行调用共享
   `tool_use_id` 时，Adapter 必须补充 discriminator；不可证明关联时不能合并。
2. upstream ID 缺失或 Adapter 无法证明是 replay 时生成 `.occurrence(UUID)`，每次到达
   都是新 request。内容 fingerprint 不是身份。
3. 只有 Adapter 可以设置 `.replay(of:)`。它必须先明确结束旧 `TransportToken`，再
   把新 token 交给 `InteractionCenter`；旧 transport 未结束的 replay 是无效输入，
   Center 保留旧绑定并返回可诊断的 `invalidOrdering` effect/error。
4. replay 不改变 request 的队列 ordinal、dismiss 状态、已收集的 question draft 或
   resolving effect。只替换已由 Adapter 终结的 transport 绑定。已经完成的用户命令
   不会因为 replay 再发送一次。
5. App 重启不恢复 pending identity，也不从旧 payload 猜测 identity。CLI 重新上报
   后才创建/绑定事实；dismiss 状态不持久化。

`RequestContent` 不含 continuation、`NWConnection`、JSON `Data` 或 provider closure：

```swift
enum RequestContent: Sendable {
    case permission(PermissionContent)
    case plan(PlanContent)
    case question(QuestionContent)
}

struct PermissionContent: Sendable { /* tool, summary, input display data */ }
struct PlanContent: Sendable { /* plan text, allowed prompts, suggestion */ }
struct QuestionContent: Sendable {
    let items: [QuestionItem]
    let answerSchema: AnswerSchema
}
```

规范化仍由各 provider/Hook Adapter 负责；Center 不复制 upstream 的 JSON 探测或
response schema。`QuestionItem` 可以表达 AskUserQuestion 的 1–4 个问题，UI draft
可以是 renderer 的短暂输入，但最终 `answer([QuestionAnswer])` 必须一次性交给 Center。

### 输入：一个 reducer case 集合

```swift
enum InteractionInput: Sendable {
    case reconcile(UpstreamSessionObservation)
    case requestArrived(RequestArrival)
    case user(InteractionUserAction)
    case adapter(InteractionAdapterEvent)
    case sessionRemoved(SessionID)
}

enum InteractionUserAction: Sendable {
    case dismiss(RequestID)
    case reveal(RequestID)
    case resolve(RequestID, ResolutionCommand)
    case setAutoMode(SessionID, AutoModeIntent)
    case navigate(NavigationTarget)
}

enum NavigationTarget: Sendable {
    case request(RequestID)             // Center 从 request 找 session
    case session(SessionID)             // SessionCard 没有 request 时使用
}
```

`reconcile` 是唯一消费 upstream session 事实的入口；它不是让 Center 读取
`SessionSnapshot` 的第二条路径。AppState 以一个连续接入点把 `SessionSnapshot` 映射
成 `UpstreamSessionObservation`，内容包括 session identity、source/provider ID、
permission mode、terminal metadata、remote 标记、CLI pane 可见性和 provider
capabilities。未来 upstream 提供等价事实时，只替换这一映射。

`InteractionUserAction` 的命令均带稳定目标：request resolution/dismiss/reveal
必须携带 `RequestID`，navigation 也必须携带 `RequestID` 或 `SessionID`；不能恢复
“当前数组 head”或隐式全局快捷键目标。一个已不存在的 ID 是安全 no-op，并产生诊断
反馈，而不是操作另一个 request。

### Resolution 与 Auto 语义

```swift
enum ResolutionCommand: Sendable {
    case allowOnce
    case allowAlways
    case deny(message: String?)
    case allowPlan(mode: PlanAllowMode?)
    case answer([QuestionAnswer])
    case questionAction(QuestionAction)
}

enum PlanAllowMode: Sendable {
    case suggested(String)
    case manual                       // mode == nil 的 plain allow
}

enum QuestionAction: Sendable {
    case reject(reason: String?)
    case abandon
    case continueWithoutAnswer
}

enum AutoModeIntent: Sendable {
    case off
    case nativeAuto
    case acceptEditsWithRules
    case bypassPermissionsExplicit
}
```

`allowPlan(.manual)` 是原来的 plain allow，但 UI 名称是 Manual/Allow Plan，绝不能
叫 `Skip`。Question 始终拥有独立的 `Dismiss`（它只改变 presentation）；只有
`resolutionCapabilities` 声明了可测试协议语义时，UI 才展示来源明确的
`reject`、`abandon` 或 `continueWithoutAnswer`。不稳定的 provider 只展示 Answer
和 Dismiss，不猜一个通用 Skip。

Auto 是 session-scoped：`nativeAuto` 优先，provider 不支持时才允许显式的
`acceptEditsWithRules` fallback；`bypassPermissionsExplicit` 要求用户明确选择且
capability 允许，不能静默 fallback。Center 记录每个 session 的 observed mode、
requested mode、capability 和过渡状态；effect 已送达不等于 mode 已生效，只有后续
`reconcile` 事实匹配才是 confirmed。断开时清除 CodeIsland requested/context，不能
声称不可连接的 CLI 已切换。

### Adapter 回执

```swift
enum InteractionAdapterEvent: Sendable {
    case transportEnded(TransportToken, evidence: TransportEndEvidence)
    case resolutionSucceeded(EffectID)
    case resolutionFailed(EffectID, AdapterFailure)
    case autoModeDelivered(EffectID)
    case autoModeFailed(EffectID, AdapterFailure)
    case navigationFinished(EffectID, NavigationOutcome)
    case externallyResolved(RequestID, ExternalResolutionEvidence)
}
```

Adapter 的 effect 执行 exactly once，以 `EffectID` 去重；Center 也以 effect/request
状态忽略重复 ack。`resolutionSucceeded` 表示 Adapter 已按 provider 协议成功交付
response；它可以结束 request，但不把 Auto mode 直接标成 confirmed。若 provider
有独立的 resolved event，应发送 `externallyResolved`；它会结束 pending 或取消尚未
执行的重复 response。`transportEnded` 本身不自动 deny：只有 Adapter 具有明确的
provider 证据时才可同时发 `externallyResolved`。没有证据时，Center 保留 pending，
并显示可恢复错误。

### Effect：声明式，不是 side-effect 方法

```swift
enum InteractionEffect: Sendable {
    case deliverResolution(ResolutionEffect)
    case deliverAutoMode(AutoModeEffect)
    case navigate(NavigationEffect)
    case feedback(InteractionFeedback)
    case invalidOrdering(InteractionOrderingError)
}

struct ResolutionEffect: Sendable {
    let effectID: EffectID
    let requestID: RequestID
    let sessionID: SessionID
    let transport: TransportToken
    let command: ResolutionCommand
}

struct AutoModeEffect: Sendable {
    let effectID: EffectID
    let sessionID: SessionID
    let requested: AutoModeIntent
    let transport: TransportToken?    // provider may use a session command channel
}

struct NavigationEffect: Sendable {
    let effectID: EffectID
    let target: NavigationTarget
    let context: NavigationContext
}
```

Effect 只携带领域命令、ID 和不透明 token；Hook Adapter 负责将 allow/deny/answer、
Codex JSON-RPC response、Claude hook bytes、ZCode strict schema 等编码为真实协议。
Center 不持有 `CheckedContinuation`、`NWConnection` 或 JSON-RPC client。Effect runner
把回执再次送入 `send(.adapter(...))`，调用方不需要理解 pending/resolving 状态机。

`feedback` 只表达声音、错误突出显示或 shake nonce 等可观察结果；它不是让 Center
直接调用 `SoundManager` 或 SwiftUI。导航成功时 Center 按
`autoCollapseAfterSessionJump` 更新 presentation snapshot；失败时保留原 surface，
发出错误 feedback，复用当前声音/shake 行为。

## Snapshot：唯一读取入口

```swift
struct InteractionSnapshot: Sendable {
    let revision: UInt64
    let sessions: [SessionID: InteractionSessionSnapshot]
    let presentation: PresentationSnapshot
}

struct InteractionSessionSnapshot: Sendable {
    let id: SessionID
    let facts: SessionDisplayFacts
    let pendingCount: Int
    let pendingKinds: Set<InteractionKind>
    let requests: [RequestSnapshot]       // read-only cards, no transport objects
    let auto: AutoSnapshot
    let navigation: NavigationCapability
}

struct RequestSnapshot: Sendable {
    let id: RequestID
    let sessionID: SessionID
    let kind: InteractionKind
    let content: RequestContent
    let lifecycle: RequestLifecycle
    let presentation: RequestPresentation
    let availableActions: [ResolutionAction]
    let queuePosition: Int
    let error: InteractionError?
}

enum RequestLifecycle: Sendable {
    case pending
    case resolving(EffectID)
}

enum RequestPresentation: Sendable {
    case normal
    case dismissed
}

struct PresentationSnapshot: Sendable {
    let surface: Surface
    let prominentRequest: RequestID?
    let badgeCounts: [SessionID: Badge]
    let feedbackNonce: UInt64
}
```

Resolved request 不继续出现在 `requests`；必要的历史/诊断由独立 diagnostics 记录，
不让 UI 依赖内部 registry。`resolving` request 不在 surface 上显示卡片，但仍计入
`pendingCount`/badge，并可显示“提交中”。失败时回到 `.pending`，保留 `error`，
强制进入突出 selector。

Selector 的严格顺序：

1. resolving 失败的 request；
2. 用户显式 `reveal` 的 request；
3. 未 dismiss 的 waiting request；
4. 到达 ordinal（同 ordinal 用 Effect/ID 稳定 tie-breaker）。

同一 session 的 queue 只按 provider 到达顺序推进；不同 session 独立，不产生
head-of-line blocking。回答后通常选择同 session 的下一项，但失败和显式 reveal
优先。`dismiss` 永远不 dequeue、不 resolve、不 deny、不改变 CLI；它只将该
`RequestID` 标为 dismissed，session badge/待处理数量仍可发现。相同 request 的
replay 继承 dismissed；新的 request ID 不继承。用户 reveal 后直到 resolve 或再次
dismiss 都保持突出。

CLI-first 是 selector 的策略而非 UI 自己猜测：最终默认值是目标 CLI pane/tab
可见时只更新 badge/通知，不可靠或不可见时主动展开；当前迁移第一检查点使用
`legacyProminent`（新 request 主动展开），完成等价测试后才切到 adaptive。不存在
按 permission/plan/question 三套默认开关。

## 关键状态转换和排序

```text
requestArrived(new)
    ├─ pending + normal/dismissed → selector / badge
    └─ requestArrived(replay)
         └─ 保留 ordinal、dismiss、draft、resolution；只更新 transport

user.resolve(requestID, command)
    └─ pending → resolving + optimistic UI hide + deliverResolution(effectID)
         ├─ adapter.resolutionSucceeded → 移除并推进 selector
         ├─ adapter.resolutionFailed  → pending + prominent + error
         └─ externallyResolved         → 移除、取消重复 response、不再发送

user.dismiss(requestID) → pending/dismissed（badge 保留）
user.reveal(requestID)  → pending/normal（explicit priority）
```

硬 invariants：

* `RequestID` 是所有 request action 的目标；`EffectID` 与 `RequestID` 一一关联，
  resolving 中的重复点击只返回空 effects。
* 一个 request 同时最多有一个 in-flight resolution effect；任何 terminal result
  （success、failure、external）只能被消费一次。
* transport 绑定不能跨 request 重用；replay 绑定前旧 token 必须显式终结。
* queue ordinal 只由 `requestArrived(.new)` 分配；dismiss、reveal、replay、失败、
  session list 展示都不重排 queue。
* `reconcile` 可以确认 provider 已解决 request，但不因 session status 从
  waiting 变成 processing 就猜测一个具体 request，除非 upstream Adapter 提供明确
  request ID 证据。
* session removal 清除该 session 的 request/context/Auto 状态，并发出尚未完成
  transport 的安全终止 effect；不能把其它 session 的 action 迁移到 queue head。
* Auto requested/observed/confirmed 永远按 session 存储；Auto effect ack 不能伪造
  observed mode。危险 bypass 没有 capability 或没有显式 intent 时生成拒绝 feedback，
  不生成 deliver effect。
* 所有 snapshot 是只读值；SwiftUI 不可修改 queue、dismiss、resolution 或 Auto。

## Dependency categories 与 Adapter

按照 `codebase-design/DEEPENING.md`，外部 Interface 只暴露值和 effects；依赖留在
实现内部 seam。每个真实 seam 至少有生产与测试两个 Adapter。

### In-process

reducer、RequestID registry、per-session FIFO、selector、Auto transition 和
request lifecycle 是纯内存计算，直接以 `send` 的 input/effect/snapshot 测试。它们
不需要 public port；测试不读取 `pendingRequests` 等内部字段。

### Remote-but-owned / transport Adapter

Hook bridge/socket 和 Codex app-server 位于进程/协议 seam。生产 Adapter 由
`HookServer` 及 provider response encoder 组成：

* 注册 `TransportToken -> connection/continuation/client request`，但映射只存在
  Adapter；
* 规范化 source/session/request ID、判断 provider capability，然后发送
  `requestArrived`；
* 执行 `deliverResolution`/`deliverAutoMode`，以 `EffectID` exactly once 编码和
  回执；
* 处理 disconnect/timeout 和旧 token 终结；没有 provider 证据不擅自 deny。

测试 Adapter 是 in-memory transport，记录 effects，模拟 success/failure/replay/
external resolution。它不需要启动 `NWListener`，也不需要构造真正 continuation。
HookServer 的 source 探测、Cursor/plugin merge、remote cwd filter 仍留在接入点和
provider Adapter；Center 不复制 upstream normalizer。

### True external / navigation Adapter

`TerminalActivator`、`TerminalVisibilityDetector`、AppKit、Ghostty/iTerm/Terminal/
Zellij/WezTerm/Orca 等是 true external。生产 `SessionNavigatorAdapter` 执行：

1. `TerminalActivator.activate(session:sessionId:)` 的现有路由；
2. 120ms、320ms、640ms 三次可见性验证；
3. remote/no-session 的安全 no-op 或既有失败规则；
4. success/failure 回送 `navigationFinished`。

测试 Navigator Adapter 返回可控 outcome。这样 ApprovalBar、QuestionBar、SessionCard
和 AskQuestion 的 identity 都共享同一 `SessionIdentityLine` + Navigator seam，
不会各自复制跳转状态机；成功、失败声音/shake、`autoCollapseAfterSessionJump`
仍是可观察行为。

### Local-substitutable / persistence Adapter

`SessionPersistence` 只持久化上游 session 事实和 terminal metadata，不持久化
pending request、transport、dismiss 或 in-flight effect。现有 JSON 中的
`observedPermissionMode` 在过渡期间继续以 optional legacy key 解码但不回填
`SessionSnapshot`/`InteractionSessionContext`；下一次写出不再生成该 fork 字段，
从而兼容老文件而不延续错误所有权。若未来需要保存纯本地呈现偏好，应单独使用
`InteractionContextPersistence`，但本任务第一阶段不恢复 pending dismiss。

### Feedback/renderer Adapter

`SoundManager`、面板动画和 shake 是 external UI effects。生产 effect runner 把
`feedback` 转为声音/动画，SwiftUI 只由 `snapshot.presentation` 渲染。测试 runner
记录 feedback，验证失败路径，不依赖窗口或音频设备。

## 使用示例

### HookServer 到 Center

```swift
// Hook adapter owns connection/continuation; Center sees only an opaque token.
let token = transport.register(connection, provider: normalized.provider)
let arrival = normalizer.makeArrival(rawEvent, transport: token)
let effects = center.send(.requestArrived(arrival))
effectRunner.execute(effects)
```

`normalizer` 必须把可靠 request ID 或 occurrence ID、session、kind、content 和
capability 一次填完；不能先把 raw event 放进 Center 再让 Center 猜协议。

### SwiftUI action

```swift
let id = center.snapshot.presentation.prominentRequest

Button("Allow") {
    guard let id else { return }
    effectRunner.execute(center.send(.user(.resolve(id, .allowOnce))) )
}

Button("Dismiss") {
    guard let id else { return }
    effectRunner.execute(center.send(.user(.dismiss(id))) )
}
```

UI 不读取 queue head、不传 session-only implicit action，也不调用 continuation。
Session card 点击使用 `.navigate(.session(sessionID))`；request card header 使用
`.navigate(.request(requestID))`，所以 Navigator 仍能验证用户点的是哪个卡片。

### Adapter 回执和外部解决

```swift
// ResolutionEffect was executed exactly once by the transport adapter.
effectRunner.execute(center.send(
    .adapter(.resolutionSucceeded(effect.effectID))
))

// CLI answered in its own terminal; no duplicate UI response is sent.
effectRunner.execute(center.send(
    .adapter(.externallyResolved(requestID, evidence: .providerEvent))
))
```

Transport failure不会把 request 静默丢掉：

```swift
center.send(.adapter(.resolutionFailed(effectID, .writeFailed)))
// snapshot: pending + prominent + error; no automatic retry of a dangerous command
```

### Reconcile 和多 session

```swift
effectRunner.execute(center.send(.reconcile(
    upstreamMapper.map(sessionSnapshot, cliVisibility: visibility)
)))
```

Session A 的 request 被 dismiss 时，只隐藏 A 的卡片；Session B 仍按自己的 FIFO 和
global selector 浮现。全局快捷键先读取 `prominentRequest`，再构造带 RequestID 的
command，永远不会对任意数组 head 执行 allow/deny。

## 隐藏 implementation 的建议分层

`InteractionCenter` 内部可以有私有 Module/内部 seam，但不能把它们暴露给调用方：

1. `UpstreamReconciler`：将 typed observation 与 provider resolution facts 合并到
   `InteractionSessionContext`；不修改 `SessionSnapshot`。
2. `RequestRegistry`：保存 identity、transport token、ordinal、dismiss、draft、
   lifecycle 和 in-flight EffectID；实现 replay 前置条件及 exactly-once 去重。
3. `SessionQueues`：`[SessionID: OrderedSet<RequestID>]`，只维护每 session FIFO，
   不提供全局 queue head。
4. `PresentationSelector`：执行 priority、CLI visibility、explicit reveal 和
   legacy/adaptive 策略，输出 `PresentationSnapshot`。
5. `AutoPolicy`：逐 session 管 observed/requested/capability，生成 native-auto 或
   explicit rules effect，并阻止危险 fallback。
6. `NavigationCoordinator`：验证 target ID、生成 NavigationEffect，消费 outcome，
   保留 existing auto-collapse/feedback 行为。
7. `EffectIDFactory`/`Clock`：生产实现使用 live clock/UUID，测试实现确定性递增，
   使 trace 测试可复现。

这些是 implementation 或内部 seam，不是给 UI/Hooks 的额外 Interface。内部模块可
分别单测，但主行为测试必须穿过 `send`/`snapshot`；旧的 queue-head 单元测试在等价
trace 覆盖后应删除或迁移，而不是继续维护两套行为。

## 渐进迁移影响

严格按“每阶段只有一个 owner”迁移：

1. 新建上述值模型、纯 reducer 和 in-memory Adapter；保持当前新 request 主动展开，
   先完成 input/effect/snapshot trace（replay、dismiss、failure、external、multi-
   session ordering）。
2. 抽取共享 Navigator/Identity：把三份 terminal activation、验证和失败反馈移入
   Adapter/Coordinator，先做行为等价，不改变 CLI-first UX。
3. permission 切换为唯一由 Center 持有；HookServer 停止把 continuation 放入
   AppState；旧 `permissionQueue` 切换后立即停止写入。
4. 将 ExitPlanMode 变为 `RequestContent.plan`，移除 `Skip`；manual plain allow
   由 `allowPlan(.manual)` 表达；Plan 的 Dismiss 仍只隐藏。
5. question 切换为同一 registry，始终有 Dismiss；移除通用 Skip，按 capability
   暴露显式 action；Codex app-server 也只以 opaque token 走 Adapter。
6. Auto 迁为 `InteractionSessionContext` per session，移除全局 singleton 和
   `observedPermissionMode` 的 Core/reducer/persistence ownership；旧 JSON optional
   decode 仅为兼容。
7. SwiftUI 改为读取 `InteractionSnapshot`/发送 `InteractionUserAction`；
   `AppState` 只转发 observation/effects，不再暴露 queue、dismiss、Auto 方法。
8. 最后开启 adaptive CLI-first；在此之前保持 legacyProminent，避免把 migration 和
   UX 改变混在一起。

每一步可整体回滚；旧路径不得与新路径长期双写，尤其不得让两个 owner 同时 resume
同一 continuation。`AppState.swift`、`HookServer.swift`、`NotchPanelView.swift`
各保留一个连续 fork 接入区域；业务判断和 provider schema 不回流 upstream 热点。

## Depth、Locality、seam placement 的取舍

### Depth / Leverage

两入口让一个 `send` 同时覆盖 permission、plan、question、Auto、dismiss、replay、
transport failure、navigation 和 session removal。调用方只需理解“输入→effects→
snapshot”，不需理解十几个专用方法及其 head/index/session 参数。这比为三种 request
分别公开 `approve`/`answer`/`skip` 更 deep，测试也能用同一 trace 验证所有交互。

代价是 `InteractionInput`/`InteractionEffect` 枚举较宽，单个 case 需要准确的值类型；
这是把复杂度集中在一个 Module 内的有意选择。编译器仍会检查 command/content，且
错误目标 ID 不会落到其它 request。

### Locality

* provider 协议变化局限在 normalizer/transport Adapter；response bytes 不散落在
  AppState 和 View。
* 队列、dismiss、replay、Auto 和 selector 的修复只改 Center implementation；
  `SessionSnapshot` 保持 upstream-owned，持久化兼容只需 legacy decode。
* Terminal 跳转变化只改 SessionNavigator Adapter；Approval/Question/SessionCard
  不再重复三次验证和 shake。
* snapshot trace 是唯一行为证据；upstream sync 时可由 architecture guards 检查
  UI 不再直接访问 queue/continuation/Auto singleton。

### Seam placement 与未选择的方案

把 seam 放在 `AppState` 内部会让大型 upstream 文件继续成为状态 owner；放在
`HookServer` 会把网络生命周期和 UI queue 绑在一起；放在 `SessionSnapshot` 会污染
upstream model 并让 persistence/merge 承担 fork 语义。新 seam 放在 fork-owned
Interaction 模块，并在三处以薄 Adapter 接入，能让上游新增 hook/session/UI 能力只
影响规范化映射或单一渲染调用。

不选“只暴露当前 request + 每类型 resolve 方法”：它看似易迁移，却保留 queue head
竞态、重复 continuation 和协议分支，Depth 很浅。也不选长期新旧双写：replay、
disconnect 和 optimistic resolution 会使两套 owner 产生双重 response。

## Interface 验收面

在实现阶段，以下 trace 必须只通过 `send` 和 `snapshot` 断言：

* 同 ID、同 discriminator replay 保持 ordinal/dismiss，不重复 resolution；共享
  `tool_use_id` 但 discriminator 不同则生成两个 request。
* 无 ID occurrence 每次独立；App 重启后不猜 identity。
* A/B 两 session 各自 FIFO，A dismiss 不阻塞 B；global selector 遵守 failure /
  reveal / waiting / arrival 优先级。
* Plan manual 产生 plain allow effect；不存在 Skip action；Question 始终有
  Dismiss，provider capability 不足时没有额外 resolution action。
* resolve 立即 optimistic hide、进入 resolving；重复点击无第二 effect；success
  移除，failure 恢复 pending 并突出错误，external resolution 不发送重复 response。
* Auto 逐 session；native 优先，rules 仅显式 fallback，bypass 无 capability/intent
  时被拒绝；effect ack 不冒充 CLI confirmed，reconcile 才确认。
* navigation 使用稳定 target，验证成功才按设置 collapse；失败产生 sound/shake
  feedback；remote 不调用本地 terminal。
* reconcile/remove/session restart 不把 fork 状态写进 `SessionSnapshot`，旧
  `observedPermissionMode` 文件可读但新输出不再写回。

这些测试直接穿过外部 Interface，符合 “replace, don't layer”：当内部 reducer、
registry 或 selector 重写时，测试只因行为契约变化而改，不因 implementation 结构
变化而改。
