# InteractionCenter 技术设计

## 1. 目标和决定

InteractionCenter 是 fork-owned 的 deep Module。它把 permission、plan 和 question
的请求生命周期、每 session 排序、dismiss/reveal、resolution ledger、Auto requested
状态、presentation selector 和 navigation operation 统一到一个 seam；调用方只学习
send(Input) -> [Effect] 与只读 snapshot。

权威外部 Interface 只有两个运行期入口：

~~~swift
@MainActor
final class InteractionCenterStore {
    var snapshot: InteractionSnapshot { get }

    @discardableResult
    func send(_ input: InteractionInput) -> [InteractionEffect]
}
~~~

init(dependencies:) 只注入时钟、ID factory、generation authority、arrival-buffer 和
ledger policy；不得注入会执行 effects 的 sink。不得新增 approvePermission()、
skipQuestion()、pendingQueue、toggleAuto()、subscribe() 等 public 方法或可变字段。
所有调用方都经过 send，所有读取都经过 snapshot；唯一 executor 只执行 send 返回的
effects（见 §4.4）。纯 reducer model 可以是 Store 的内部实现/测试 seam。

本设计采用 hybrid：核心 request kind 和 resolution action 是关闭的强类型集合；
provider Adapter 可以提供强类型 capability descriptor，但不能把任意字符串 kind、
action、raw JSON envelope 或 generic request framework 引入 Center。新增语义必须先
证明属于已有生命周期；否则增加一个有测试的核心类型/policy 和专用 Adapter，而不是
把 provider-defined 字符串偷偷交给 UI。

设计优先级保持 PRD：降低长期 upstream sync 冲突 > 保持现有交互行为 > 减少第一轮
重构量。

## 2. 所有权和稳定 seam

| 区域 | upstream/生产事实 | fork-owned 责任 | 稳定 seam |
| --- | --- | --- | --- |
| SessionSnapshot、event reducer、discovery | session status、source/provider ID、terminal metadata、permission mode、CLI 生命周期 | 不保存 request queue、dismiss、requested Auto、navigation state | SessionObservationAdapter 的 typed `SessionDisplayObservation` + `SessionNavigationObservation` projection |
| SessionGenerationAuthority | provider/session identity 的 open/reopen/close 事实及 monotonic generation | 不解析 request body，不由各 adapter 私自递增 | shared authority + typed SessionIdentityFact |
| HookServer、Codex client | bytes/JSON-RPC、connection、continuation、request ID、disconnect/timeout、协议 response | 不保存 presentation 或业务 queue | TransportToken + InteractionInput/InteractionEffect |
| InteractionCenter | 上游事实的本地交互投影 | request identity、跨 kind per-session queue、lifecycle、dismiss/reveal、Auto 请求、selector、navigation operation | 两入口 Interface |
| NotchPanelView、shortcuts、companion | SwiftUI/设备渲染 | 不判断 provider 协议、不读 queue、不写状态机 | InteractionSnapshot + typed user action |
| SessionNavigator | AppKit、terminal app、Accessibility | 不改变 request/Auto 事实 | NavigationEffect/typed result |
| SessionPersistence | 兼容已有 session display/navigation 数据 | 不持久化 pending request、transport、dismiss 或 in-flight effect | legacy decode / new write mapper |

每个 upstream 热点文件只保留一个连续接入区域。AppState.swift 只保留 Center 的
持有以及 coordinator 对 returned effects 的转发；HookServer.swift 只保留 ingress
normalization、token registry、OnceResponder 和 executor dispatch；NotchPanelView.swift
只保留 snapshot renderer 和 action dispatch；SessionSnapshot.swift 不出现 fork-only 字段。

## 3. 外部强类型值

### 3.1 SessionRef、RequestID 和 replay

session ID 不是足够的 transport 身份。用 provider namespace 和 generation 防止同一
CLI ID 重开后被旧 event/ack 复活：

~~~swift
struct ProviderID: Hashable, Codable, Sendable {
    let rawValue: String              // normalized source
}

struct SessionKey: Hashable, Codable, Sendable {
    let provider: ProviderID
    let providerSessionID: String
}

struct SessionRef: Hashable, Codable, Sendable {
    let key: SessionKey
    let generation: UInt64
}

enum InteractionRequestKind: Hashable, Codable, Sendable {
    case permission
    case question
}

struct StableRequestKey: Hashable, Codable, Sendable {
    let upstreamID: String
    let kind: InteractionRequestKind
    let discriminator: String?        // tool/input discriminator
}

enum RequestCorrelation: Hashable, Codable, Sendable {
    case stable(StableRequestKey)
    case occurrence(UUID)
}

struct RequestID: Hashable, Codable, Sendable {
    let session: SessionRef
    let correlation: RequestCorrelation
}

struct EffectID: Hashable, Codable, Sendable { let rawValue: UUID }

struct TransportToken: Hashable, Sendable {
    let session: SessionRef
    let rawValue: UUID
}

struct ChannelToken: Hashable, Sendable {
    let session: SessionRef
    let rawValue: UUID
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

enum SessionGenerationEvidence: Sendable, Equatable {
    case initialOpen
    case explicitReopen
    case providerObservation
    case providerClose
}

@MainActor
protocol SessionGenerationAuthority {
    func current(for key: SessionKey) -> SessionRef?
    func apply(_ fact: SessionIdentityFact) -> SessionRef
    func isCurrent(_ ref: SessionRef) -> Bool
}
~~~

规则：

1. provider Adapter 负责将可靠的 upstream request/tool ID 放入 stable key，并结合
   session、generation、kind 和必要 discriminator。当前回归已证明并行工具可能共享
   tool_use_id，裸 ID 不能证明 replay。
2. 无可靠 ID、ID 冲突或无法证明关联时使用 occurrence；相同内容 fingerprint 永远
   不能合并。Occurrence ID 在进程内生成，App 重启后不复用旧 pending identity。
3. RequestArrival.association 只有 .new 或带 typed ReplayProof 的 .replay(of:)。只有
   provider Adapter 能给 proof。旧 transport 必须先以 transportEnded/明确终止事实
   结束，才可绑定 replacement token。
4. replay 保留 request 的 session generation、queue ordinal、dismiss/reveal、
   question draft 和 resolving effect；只更新 transport binding。已完成命令不因
   replay 重发。
5. `SessionGenerationAuthority` 是唯一 generation authority：同一 generation 的
   observation 按 `(key, sequence)` 幂等，只有 `initialOpen`/`explicitReopen` evidence
   可递增且必须在前一 generation closed 后发生；request 正文、同名 session 或普通
   disconnect 都不能 reopen。重复 open/close 事实是 no-op，旧 generation 的 observation、
   request arrival、transport result 或 removal 只产生 stale/ignored diagnostic，不能改变
   新 SessionRef。
   - 无 current 时只有 `opened + initialOpen` 建立首个 generation；
     `providerObservation`/`providerClose` 先到会被拒绝并保留在 ingress diagnostic。
   - current 未 closed 时 `providerObservation` 只更新同 generation 的最新 sequence；
     重复 sequence 是 no-op。current 已 closed 时，只有 `opened + explicitReopen` 建立
     下一个 generation；重复 reopen、close 或旧 sequence 都是幂等 no-op。
6. authority 在 app restart 后从空状态开始；旧 persistence facts 不恢复 generation。所有
   adapter 使用 authority 返回的完整 SessionRef，禁止从 raw provider string 各自构造。

Request 可以先于 SessionSnapshot observation 到达。provider ingress 先把未绑定 request
放入有界 `RequestIngressBuffer`（按 SessionKey 限容量、TTL）；authority 产生明确 current
generation 后按原 arrival order bind，再送入 Center。buffer overflow/expiry 只产生一次
provider-safe neutral finalization 和 diagnostic，不换绑其它 session；close 由 authority
转成带 generation 的 closed observation，不能用另一条独立 remove 路径复活 session。

### 3.2 Request content 和 capability

核心内容不使用 [String: Any]：

~~~swift
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

struct QuestionContent: Sendable, Equatable {
    let items: [QuestionItem]
    let answerSchema: AnswerSchema
}

enum RequestBehavior: Sendable, Equatable {
    case blocking(ResolutionCapabilities)
    case displayOnly
    case nativeOwned
}

enum ResolutionChannel: Sendable, Equatable {
    case none
    case response(TransportToken)
}
~~~

DisplayValue 是已消毒的只读树；不含 connection、continuation、closure、raw
HookEvent 或协议 bytes。QuestionItem 保存稳定 answer key、provider 顺序、multi-select
和 sensitivity；UI 可以在本机维护短暂输入 draft。

Capability 也保持强类型：

~~~swift
struct ResolutionCapabilities: Sendable, Equatable {
    let allowAlways: Bool
    let planModes: Set<PlanMode>
    let questionActions: Set<QuestionResolutionAction>
}

enum PlanMode: Hashable, Sendable {
    case suggested(String)
    case manual
}

enum QuestionResolutionAction: Hashable, Sendable {
    case reject
    case abandon
    case continueWithoutAnswer
}
~~~

Adapter 可以声明这些已知能力的子集；不得发任意 "skip"、"providerAction" 或
字符串 action。没有稳定协议语义时 question 只有 answer 和 Center 注入的 Dismiss。
Plan 的 plain allow 是 `PermissionVariant.plan` + `PlanMode.manual`，UI 不显示 Skip。
`nativeOwned` 是 Cursor 等 provider 自有 UI 的 typed display observation，不是可解析的
Center request；它没有 channel、answer 或 resolution effect。

### 3.3 Session observation

SessionObservation 是唯一 reconcile 输入，不是 SessionSnapshot 的别名：

~~~swift
struct SessionObservation: Sendable, Equatable {
    let session: SessionRef
    let lifecycle: UpstreamSessionLifecycle
    let permissionMode: ObservedPermissionMode
    let providerCapabilities: ProviderCapabilities
    let display: SessionDisplayObservation
    let navigation: SessionNavigationObservation
    let cliVisibility: CLIVisibility
    let completion: CompletionObservation?
    let revision: UInt64
    let observedAt: Date
}

enum UpstreamSessionLifecycle: Sendable, Equatable {
    case active
    case idle
    case waiting
    case closed
}

enum ObservedPermissionMode: Sendable, Equatable {
    case defaultMode
    case auto
    case acceptEdits
    case bypassPermissions
    case unknown(String?)
}

enum ProviderPermissionMode: Sendable, Equatable {
    case defaultMode
    case auto
    case acceptEdits
    case bypassPermissions
}

enum CLIVisibility: Sendable, Equatable {
    case visible
    case notVisible
    case unknown
}
~~~

ProviderCapabilities 是 typed 字段：native auto、acceptEdits/rules、explicit bypass、
question actions 等；不要用一个 supportsAuto: Bool 把危险 fallback 隐藏起来。
`display` 和 `navigation` 是同一个 observation envelope 的 typed facets：display 只包含
可渲染的 session facts，navigation 只包含既有 terminal/remote route 所需字段；两者都不
携带完整 `SessionSnapshot`、raw JSON、connection 或 provider continuation。mapper 提供
envelope 的 `revision`，Center 只有在 SessionRef generation 仍 current 且 revision 严格
新于已应用值时，才原子地更新两个 facet；旧或重复 revision 同时丢弃，不能出现 facts 已
更新但 route 仍来自旧 session 的半更新。

### 3.4 Core value types and ownership

下列值是 Interface 的完整词汇；它们不是由 provider 传入的未定义字典：

~~~swift
enum Sensitivity: Sendable, Equatable { case `public`, privateData, secret }

struct SensitiveText: Sendable, Equatable {
    let value: String
    let sensitivity: Sensitivity
}

indirect enum DisplayValue: Sendable, Equatable {
    case text(String)
    case number(Double)
    case boolean(Bool)
    case list([DisplayValue])
    case object([String: DisplayValue])
    case redacted(Sensitivity)
}

struct QuestionOption: Sendable, Equatable {
    let key: String
    let label: SensitiveText
}

struct QuestionItem: Sendable, Equatable {
    let key: String
    let prompt: SensitiveText
    let options: [QuestionOption]
    let allowsMultiple: Bool
}

struct AnswerSchema: Sendable, Equatable {
    let keysInProviderOrder: [String]
    let allowsCustomText: Bool
}

enum QuestionAnswerValue: Sendable, Equatable {
    case option(String)
    case custom(SensitiveText)
}

struct QuestionAnswer: Sendable, Equatable {
    let questionKey: String
    let values: [QuestionAnswerValue]
}

struct ProviderCapabilities: Sendable, Equatable {
    let auto: AutoCapabilities
    let questionActions: Set<QuestionResolutionAction>
    let canNeutralFinalize: Bool
}

struct NavigationContext: Sendable, Equatable {
    let terminal: TerminalTarget?
    let isRemote: Bool
}

enum TerminalTarget: Sendable, Equatable {
    case local(bundleID: String)
    case remote(hostID: String)
    case unavailable
}

struct SessionDisplayFacts: Sendable, Equatable {
    let title: String?
    let project: String?
    let source: String?
    let cwd: String?
    let model: String?
    let status: String?
    let currentTool: String?
    let toolDescription: String?
    let subagents: [SubagentDisplayFact]
    let recentMessages: [RecentMessageFact]
    let git: GitDisplayFact?
    let providerSessionID: String?
    let remote: RemoteDisplayFact?
}

struct SubagentDisplayFact: Sendable, Equatable {
    let id: String
    let title: String?
    let status: String?
}

enum MessageRole: Sendable, Equatable {
    case user
    case assistant
    case system
}

struct RecentMessageFact: Sendable, Equatable {
    let role: MessageRole
    let preview: SensitiveText?
}

struct GitDisplayFact: Sendable, Equatable {
    let branch: String?
    let isWorktree: Bool
}

struct RemoteDisplayFact: Sendable, Equatable {
    let hostID: String
    let hostName: String?
}

struct SessionDisplayObservation: Sendable, Equatable {
    let session: SessionRef
    let facts: SessionDisplayFacts
}

struct TerminalRouteFact: Sendable, Equatable {
    let termApp: String?
    let itermSessionID: String?
    let ttyPath: String?
    let kittyWindowID: String?
    let tmuxPane: String?
    let tmuxClientTTY: String?
    let tmuxEnvironment: String?
    let termBundleID: String?
    let cmuxSurfaceID: String?
    let cmuxWorkspaceID: String?
    let zellijPaneID: String?
    let zellijSessionName: String?
    let weztermPaneID: String?
    let supersetWorkspaceID: String?
    let supersetPaneID: String?
    let orcaTerminalHandle: String?
    let orcaWorktreeID: String?
    let cliPID: Int32?
    let cliStartTime: Date?
}

struct SessionNavigationObservation: Sendable, Equatable {
    let session: SessionRef
    let context: NavigationContext
    let route: TerminalRouteFact
    let providerSessionID: String?
    let remote: RemoteDisplayFact?
}

struct CompletionNotice: Sendable, Equatable {
    let session: SessionRef
    let message: String
    let revision: UInt64
}

struct CompletionObservation: Sendable, Equatable {
    let session: SessionRef
    let message: String
    let revision: UInt64
}

enum Surface: Sendable, Equatable {
    case collapsed
    case sessionList
    case request(RequestID)
    case completion(CompletionNotice)
}

struct RedactedCompletionNotice: Sendable, Equatable {
    let session: SessionRef
    let revision: UInt64
}

enum RedactedSurface: Sendable, Equatable {
    case collapsed
    case sessionList
    case request(RequestID)
    case completion(RedactedCompletionNotice)
}

struct Badge: Sendable, Equatable {
    let pendingCount: Int
    let kinds: Set<InteractionRequestKind>
}

struct NavigationSnapshot: Sendable, Equatable {
    let context: NavigationContext
    let route: TerminalRouteFact
    let canNavigate: Bool
    let lastFailure: String?
}

struct RedactedSessionSnapshot: Sendable, Equatable {
    let session: SessionRef
    let title: String?
    let pendingCount: Int
    let pendingKinds: Set<InteractionRequestKind>
}

struct RedactedPresentationSnapshot: Sendable, Equatable {
    let surface: RedactedSurface
    let prominentRequest: RequestID?
}

enum ExternalActionKind: Hashable, Sendable {
    case allow
    case deny
    case answer
}

enum AvailableResolutionAction: Sendable, Equatable {
    case allowOnce
    case allowAlways
    case deny
    case allowPlan(PlanMode)
    case answer
    case questionAction(QuestionResolutionAction)
}

enum InteractionError: Sendable, Equatable {
    case invalidIdentity
    case invalidChannel
    case blockedByEarlierRequest(RequestID)
    case unavailable(String)
    case adapterFailure(String)
}

enum AdapterFailure: Sendable, Equatable {
    case notDelivered(String)
    case deliveryUnknown(String)
    case protocolRejected(String)
    case unavailable(String)
}

struct InteractionFeedback: Sendable, Equatable {
    let message: String
    let severity: FeedbackSeverity
}

enum FeedbackSeverity: Sendable, Equatable { case info, warning, error }

enum InteractionDiagnostic: Sendable, Equatable {
    case code(DiagnosticCode)
    case stale(String)
    case ambiguousLegacyTarget
}

enum DiagnosticCode: Sendable, Equatable {
    case invalidIdentity
    case invalidChannel
    case staleGeneration
    case staleRevision
    case bufferExpired
    case bufferOverflow
    case unsupportedSource
    case unknownProtocolMajor
}

struct BufferToken: Hashable, Sendable { let rawValue: UUID }

enum SessionCloseReason: Sendable, Equatable {
    case providerClosed
    case userClosed
    case staleReplacement
}

enum SessionChannelEndEvidence: Sendable, Equatable {
    case providerSessionClosed
    case providerRestarted
}

enum TransportEndReason: Sendable, Equatable {
    case peerDisconnected
    case timedOut
    case replacement
    case ingressExpired
}

enum CancellationReason: Sendable, Equatable {
    case externallyResolved
    case superseded
    case sessionClosed
}

enum ExternalResolutionEvidence: Sendable, Equatable {
    case providerRequestID
    case supersededBy(RequestID)
    case providerSessionClosed
}

enum NavigationOutcome: Sendable, Equatable {
    case succeeded
    case unavailable
    case failed(String)
}

enum AutoRule: Sendable, Equatable { case tool(String, scope: String?) }
struct AutoDelivery: Sendable, Equatable { let effectID: EffectID }
struct AutoAdapterFailure: Sendable, Equatable { let message: String }
enum AutoPhase: Sendable, Equatable {
    case idle
    case transitioning(EffectID)
    case delivered(EffectID)
    case awaitingConfirmation(EffectID)
    case confirmed(ProviderPermissionMode)
    case unknown
    case failed(String)
}
struct AutoSnapshot: Sendable, Equatable {
    let observedMode: ObservedPermissionMode?
    let requestedMode: AutoModeIntent?
    let phase: AutoPhase
}

struct LegacyRequestView: Sendable, Equatable {
    let id: RequestID
    let kind: InteractionRequestKind
    let isPending: Bool
}

enum PresentationPolicyMode: Sendable, Equatable {
    case legacyProminent
    case adaptiveCLIFirst
}

struct PresentationPolicy: Sendable, Equatable {
    let mode: PresentationPolicyMode
    let visibilityMaxAge: Duration
}
~~~

Completion ownership is explicit: upstream/session reconciliation owns the fact that a session
completed; Center owns whether a `CompletionNotice` wins the presentation selector and when the
surface collapses; local SwiftUI only renders `Surface`, while low-trust consumers render the
separate `RedactedSurface`, and neither sends completion-resolve actions. Navigator owns physical
activation success/failure, while it never mutates completion or request lifecycle. These surface
types are therefore not AppState/UI writers and a completion card cannot accidentally resolve a
request.

## 4. 两入口 Interface 的输入和输出

### 4.1 Input

~~~swift
enum InteractionInput: Sendable {
    case sessionObserved(SessionObservation)
    case requestArrived(RequestArrival)
    case nativePromptObserved(NativePromptObservation)
    case visibilityChanged(VisibilityObservation)
    case user(InteractionUserAction)
    case adapter(InteractionAdapterEvent)
}

struct NativePromptObservation: Sendable, Equatable {
    let session: SessionRef
    let isPending: Bool
    let title: String?
    let revision: UInt64
}

struct VisibilityObservation: Sendable, Equatable {
    let session: SessionRef
    let state: CLIVisibility
    let evidence: VisibilityEvidence
    let revision: UInt64
    let measuredAt: Date
}

enum VisibilityEvidence: Sendable, Equatable {
    case terminalTab
    case terminalFrontmost
    case nativeAppFrontmost
    case unavailable
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

struct PendingIngressPolicy: Sendable, Equatable {
    let maxRequestsPerSessionKey: Int
    let maxAge: Duration
}

struct UnboundRequest: Sendable, Equatable {
    let key: SessionKey
    let bufferToken: BufferToken
    let correlation: RequestCorrelation
    let kind: InteractionRequestKind
    let behavior: UnboundRequestBehavior
    let content: RequestContent
    let channel: UnboundResolutionChannel
    let receivedAt: Date
}

enum UnboundRequestBehavior: Sendable, Equatable {
    case blocking(ResolutionCapabilities)
    case displayOnly
}

struct ProviderResponseHandle: Hashable, Sendable {
    let rawValue: UUID
}

enum UnboundResolutionChannel: Sendable, Equatable {
    case none
    case response(ProviderResponseHandle)
}

protocol TransportTokenFactory {
    func bind(
        _ handle: ProviderResponseHandle,
        to session: SessionRef
    ) -> TransportToken
}

protocol RequestIngressBuffer {
    func accept(_ request: UnboundRequest) -> RequestIngressResult
    func bind(
        _ session: SessionRef,
        tokenFactory: any TransportTokenFactory
    ) -> [RequestArrival]
    func expire(now: Date) -> [BufferToken]
    func remove(_ key: SessionKey) -> [BufferToken]
}

`bind` 只接受 authority 已确认的 `SessionRef`：它用 `correlation` 生成
`RequestID(session:correlation:)`，用 `TransportTokenFactory` 把未绑定的 response handle
绑定到同一 generation，再按原 arrival order 生成 `RequestArrival`。无 channel 的 draft
只能是 `.displayOnly`；`.blocking` draft 缺少 handle 时在 `accept` 阶段 quarantine，不能
在 bind 阶段猜测 token。native-owned prompt 不进入此 buffer。

enum RequestIngressResult: Sendable, Equatable {
    case admitted(RequestArrival)
    case buffered(BufferToken)
    case finalizedWithoutResolution(DiagnosticCode)
}

struct NormalizedHookEvent: Sendable, Equatable {
    let provider: ProviderID
    let sessionKey: SessionKey
    let branch: HookAdmissionBranch
    let content: RequestContent?
    let receivedAt: Date
}

enum HookAdmissionBranch: Sendable, Equatable {
    case regularPermission
    case exitPlanMode
    case askUserQuestion
    case notificationQuestion
    case cursorNativePrompt
    case safeBuiltInTool
    case alwaysProceedSource
    case providerOwnedReview
    case ordinaryEvent
    case malformed
    case unsupported
}

struct RequestAdmissionContext: Sendable, Equatable {
    let session: SessionRef?
    let capabilities: ProviderCapabilities
    let sourceAllowed: Bool
}

enum RequestAdmissionEffect: Sendable, Equatable {
    case enqueue(RequestArrival)
    case buffer(UnboundRequest)
    case nativeOwned(NativePromptObservation)
    case sendProviderResponse(ProviderResponsePlan)
    case quarantine(QuarantineReason)
    case ignore(AdmissionIgnoreReason)
}

struct RequestAdmission: Sendable, Equatable {
    let branch: HookAdmissionBranch
    let effect: RequestAdmissionEffect
}

enum ProviderResponsePlan: Sendable, Equatable {
    case safeToolAllow
    case alwaysProceedAllow
    case providerOwnedAck
    case malformedQuestionFallback
    case ordinaryAck
}

enum QuarantineReason: Sendable, Equatable {
    case noSafeNeutralResponse
    case missingGeneration
    case bufferLimit
    case unsupportedChannel
}

enum AdmissionIgnoreReason: Sendable, Equatable {
    case unsupportedSource
    case excludedWorkingDirectory
    case unrelatedEvent
}

protocol RequestAdmissionPolicy {
    func decide(
        _ event: NormalizedHookEvent,
        context: RequestAdmissionContext
    ) -> RequestAdmission
}

Hook policy is typed and ordered before Center:

| Branch | Admission effect | Center behavior |
| --- | --- | --- |
| safe built-in tool | `safeToolAllow` | no request |
| always-proceed source (AskUserQuestion excluded) | `alwaysProceedAllow` | no request |
| provider-owned review | `providerOwnedAck` | no request |
| regular permission / ExitPlanMode | `enqueue` (`PermissionVariant.regular/plan`) | blocking request if channel is safe |
| AskUserQuestion | `enqueue` with question + required channel | question lifecycle |
| Notification question | `enqueue` displayOnly or blocking only when capability proves it | no generic Skip |
| Cursor prompt | `nativeOwned` | display observation only |
| malformed/unsupported/event/filter | typed response, quarantine, or ignore | no guessed request |

The policy never branches on raw JSON inside SwiftUI or Center. Provider response codecs turn
`ProviderResponsePlan` into bytes; `RequestAdmissionEffect.enqueue` is the only path that can
create a Center request, and an unbound request must first use `RequestIngressBuffer`.

enum RequestAssociation: Sendable {
    case new
    case replay(of: RequestID, proof: ReplayProof)
}

struct ReplayProof: Sendable, Equatable {
    let providerIDMatches: Bool
    let generationMatches: Bool
    let upstreamIDMatches: Bool
    let discriminatorMatches: Bool
}
~~~

`RequestArrival.id.session` 必须等于 `session`，且 blocking 的 response token 必须绑定同一
SessionRef；displayOnly/nativeOwned 不得携带 channel。native-owned prompt 使用单独的
typed observation，不能伪造一个缺少 responder 的 request。身份/behavior/channel 不一致
时不入队，返回 `invalidIdentity`/`invalidChannel` diagnostic。

`SessionGenerationAuthority` 将 session close 转为 `sessionObserved(.closed)`；Center 不
接受不带 generation 的独立 remove input。request ingress 若尚未绑定 observation，必须先
经 `RequestIngressBuffer`，不能被 Center 直接猜测或静默丢弃。

~~~swift
enum InteractionUserAction: Sendable {
    case dismiss(RequestID)
    case reveal(RequestID)
    case resolve(RequestID, ResolutionCommand)
    case setAutoMode(SessionRef, AutoModeIntent)
    case navigate(NavigationTarget)
}

enum ResolutionCommand: Sendable, Equatable {
    case allowOnce
    case allowAlways
    case deny(message: String?)
    case allowPlan(mode: PlanMode)
    case answer([QuestionAnswer])
    case questionAction(QuestionResolutionAction, reason: String?)
}

public enum AutoModeIntent: Sendable, Equatable {
    case off
    case enable
    case bypassExplicit
}

enum NavigationTarget: Sendable, Equatable {
    case request(RequestID)
    case session(SessionRef)
}
~~~

Plan resolution 不允许 allowOnce 代替 typed allowPlan；provider Adapter 将
allowPlan(.manual) 编成历史 plain allow。Question answer 必须按其 answer key/顺序
交付；UI 的 multi-select/custom input 在 QuestionAnswer 中是强类型值。

### 4.2 Adapter event 和 token-scoped disconnect

~~~swift
enum InteractionAdapterEvent: Sendable {
    case transportEnded(
        token: TransportToken,
        evidence: TransportEndEvidence
    )
    case sessionChannelEnded(
        session: SessionRef,
        channel: ChannelToken,
        evidence: SessionChannelEndEvidence
    )
    case resolutionSucceeded(EffectID, request: RequestID, token: TransportToken)
    case resolutionFailed(
        EffectID,
        request: RequestID,
        token: TransportToken,
        failure: AdapterFailure
    )
    case autoModeDelivered(EffectID, session: SessionRef)
    case autoModeAwaitingConfirmation(EffectID, session: SessionRef)
    case autoModeFailed(EffectID, session: SessionRef, failure: AdapterFailure)
    case navigationFinished(EffectID, outcome: NavigationOutcome)
    case externallyResolved(RequestID, evidence: ExternalResolutionEvidence)
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

enum ProviderNeutralResponse: Sendable, Equatable {
    case hookEmptyObject
    case codexEmptyAnswers
    case notificationAck
}

struct TransportFinalizationRequest: Sendable, Equatable {
    let token: TransportToken
    let reason: TransportEndReason
    let response: ProviderNeutralResponse
}

struct NeutralFinalizationReceipt: Sendable, Equatable {
    let token: TransportToken
    let response: ProviderNeutralResponse
}

enum TransportFinalizationResult: Sendable, Equatable {
    case finalized(NeutralFinalizationReceipt)
    case quarantined(TransportQuarantine)
    case failed(AdapterFailure)
}

protocol TransportFinalizer {
    func finalize(
        _ request: TransportFinalizationRequest,
        responder: any OnceResponder<ProviderNeutralResponse>
    ) -> TransportFinalizationResult
}

enum TransportQuarantine: Sendable, Equatable {
    case noSafeNeutralResponse(TransportToken)
    case malformedChannel(TransportToken)
}

// Production adapters own the atomic once-only callback/continuation wrapper.
// Center never stores or invokes this object.
protocol OnceResponder<Response>: Sendable {
    func finish(_ response: Response) -> Bool
}
~~~

默认 TransportToken 只绑定一个 request。transportEnded 通过 token lookup，只清理
该 request；它不按 session 批量 drain。若 Codex client 或其它 provider 真正拥有
session-wide channel，Adapter 必须提供 channel token 和明确 providerSessionClosed
证据；Center 才能逐项标记 unavailable/externally resolved。普通 disconnect/timeout
没有 provider resolution 证据时不能自动 deny。非取消 continuation 由 adapter 的
`OnceResponder` 完成一次 provider-safe neutral finalization；没有可证明 neutral response
的 provider 不得注册为 blocking channel，而应 quarantine/diagnostic。

Provider-neutral mapping 是 adapter-owned 且必须有 contract test：Hook blocking
`PermissionRequest` 只在 provider 契约证明 `{}` 为 neutral 时映射为
`.hookEmptyObject`；Codex `requestUserInput` 映射为 `.codexEmptyAnswers` 只有其协议明确
接受空 answers；displayOnly Notification 可用 `.notificationAck`，但无 response channel
时不需要 finalizer；Cursor nativeOwned 不注册 token。若任一映射不安全，ingress 返回
`TransportQuarantine.noSafeNeutralResponse`，不把 request admission 成 blocking，也不以
deny/allow/empty answer 猜测填洞。

resolutionSucceeded 仅接受匹配的 EffectID、RequestID、token 和 SessionRef generation；
迟到或重复结果幂等忽略。externallyResolved 代表 CLI/peer 已经以事实解决 request，
可在 resolution effect 之前或之后到达。

### 4.3 Effects

~~~swift
enum InteractionEffect: Sendable {
    case deliverResolution(ResolutionEffect)
    case finalizeTransport(FinalizeTransportEffect)
    case changeAutoMode(AutoModeEffect)
    case cancelTransport(CancelTransportEffect)
    case navigate(NavigationEffect)
    case feedback(InteractionFeedback)
    case diagnostic(InteractionDiagnostic)
}

struct ResolutionEffect: Sendable {
    let effectID: EffectID
    let requestID: RequestID
    let token: TransportToken
    let command: ResolutionCommand
}

struct FinalizeTransportEffect: Sendable {
    let effectID: EffectID
    let requestID: RequestID
    let token: TransportToken
    let finalization: TransportFinalization
}

struct AutoModeEffect: Sendable {
    let effectID: EffectID
    let transaction: AutoCommandTransaction
}

struct CancelTransportEffect: Sendable {
    let effectID: EffectID
    let requestID: RequestID
    let token: TransportToken
    let reason: CancellationReason
}

struct NavigationEffect: Sendable {
    let effectID: EffectID
    let target: NavigationTarget
    let context: NavigationContext
}
~~~

Effects 是声明式且有序；唯一 `InteractionEffectExecutor` 只消费 `send` 返回的数组，
按顺序交给对应 Adapter，完成后再以 `send(.adapter(...))` 回传。Center 不产出 Data、
JSON-RPC result、AppKit 对象、continuation 或 network object。每个 resolution/finalize
effect 必须同时有唯一 EffectID 与明确 RequestID/token；Adapter 的 ledger 保证本地一次
提交和一次 responder finalization。Adapter 不得绕过 executor 直接修改 Center/AppState。

### 4.4 Single effect executor

Store 外部的 coordinator 执行唯一流程：

~~~swift
protocol InteractionEffectExecutor {
    func execute(
        _ effects: [InteractionEffect],
        report: @escaping (InteractionAdapterEvent) -> Void
    )
}
~~~

`effects = store.send(input)` 是唯一 effect source；coordinator 是唯一 executor caller。
不向 Store 注入 sink，不允许 Hook/Codex/Auto/Navigator 各自 fire-and-forget，也不允许
executor 再回调另一个 Store。每个 EffectID 的 at-most-once submission ledger 由 executor/
adapter 共同执行，重复回执只产生 no-op diagnostic。

## 5. Snapshot、生命周期和 selector

### 5.1 Snapshot 是唯一读面

~~~swift
struct InteractionSnapshot: Sendable, Equatable {
    let revision: UInt64
    let local: LocalInteractionSnapshot
    let external: RedactedInteractionSnapshot
}

struct LocalInteractionSnapshot: Sendable, Equatable {
    let sessions: [SessionRef: InteractionSessionSnapshot]
    let requests: [RequestID: InteractionRequestSnapshot]
    let presentation: PresentationSnapshot
}

struct RedactedInteractionSnapshot: Sendable, Equatable {
    let sessions: [SessionRef: RedactedSessionSnapshot]
    let requests: [RequestID: RedactedRequestSnapshot]
    let presentation: RedactedPresentationSnapshot
}

protocol LocalInteractionReader {
    var value: LocalInteractionSnapshot { get }
}

protocol ExternalInteractionReader {
    var value: RedactedInteractionSnapshot { get }
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

struct InteractionSessionSnapshot: Sendable, Equatable {
    let session: SessionRef
    let facts: SessionDisplayFacts
    let completion: CompletionNotice?
    let pendingCount: Int
    let pendingKinds: Set<InteractionRequestKind>
    let auto: AutoSnapshot
    let navigation: NavigationSnapshot
}

struct InteractionRequestSnapshot: Sendable, Equatable {
    let id: RequestID
    let session: SessionRef
    let kind: InteractionRequestKind
    let content: RequestContent
    let lifecycle: RequestLifecycle
    let presentation: RequestPresentation
    let availableActions: [AvailableResolutionAction]
    let queuePosition: Int
    let error: InteractionError?
}

enum RequestLifecycle: Sendable, Equatable {
    case pending
    case resolving(EffectID)
    case awaitingExternalConfirmation(EffectID)
}

enum RequestPresentation: Sendable, Equatable {
    case normal
    case dismissed
}

struct PresentationSnapshot: Sendable, Equatable {
    let surface: Surface
    let prominentRequest: RequestID?
    let badgeCounts: [SessionRef: Badge]
    let feedbackNonce: UInt64
}
~~~

The nested `display.session` and `navigation.session` must equal the envelope `session`; a
mismatch is an invalid-identity diagnostic and neither facet is applied. `SessionObservationAdapter`
maps `display.facts` one-to-one into the local
`InteractionSessionSnapshot.facts`, and maps `navigation.context`/`navigation.route` into its
local `NavigationSnapshot`; it never hands the full upstream snapshot to Center. The redaction
projector derives `RedactedSessionSnapshot` and `RedactedSurface` from those typed facets, keeping
cwd, recent-message previews, terminal handles, PID, and raw provider identifiers out of the
external reader unless a separately declared public label is needed.

Resolved request 可以在一个 bounded diagnostic ledger 中保留结果，但不再出现在
pending requests 或 counts 中。resolving request 立即从卡片 surface 隐藏，仍计入
session pending/badge，并可展示 submitting。失败恢复为 pending + error，突出显示。
`local` 只供本机 renderer；companion/ESP32/log/trace 只能接收 `external`，不能引用
`InteractionRequestSnapshot.content`、options、raw HookEvent 或 provider JSON。
Concrete reader adapters receive only their respective facet (`LocalInteractionReader` or
`ExternalInteractionReader`); a companion publisher has no type-level path to the local reader.

### 5.2 合法生命周期

~~~text
arrival(new) -> pending(normal or dismissed)
pending --dismiss--> pending(dismissed)
pending --reveal--> pending(normal, explicit priority)
pending --resolve--> resolving(effectID) + optimistic hide
resolving --resolutionSucceeded--> removed/resolved
resolving --externallyResolved--> removed/resolved externally
resolving --resolutionFailed--> pending(error, prominent)
resolving --deliveryUnknown--> awaitingExternalConfirmation(effectID)
awaitingExternalConfirmation --externallyResolved--> removed/resolved externally
pending --externallyResolved--> removed/resolved externally
transportEnded(no evidence) -> pending(unavailable error), never implicit deny
~~~

`blocking(capabilities)` request 必须拥有一个与 SessionRef 匹配的 response token；
`displayOnly` request 只允许 presentation action，不产生 resolution effect；
`nativeOwned` 只通过 `NativePromptObservation` 显示/清除，不进入 request lifecycle。
channel 缺失、重复或 session 不匹配时返回 diagnostic，不以 deny、空 answer 或 queue
drain 修复。

不变量：

* resolving 同一 request 的重复 allow/deny/answer 不产生第二个 effect。
* success ack 或 CLI external resolution 才结束 request；按钮点击不是 CLI 事实。
* `notDelivered` 使 request 回到 pending(error)；failure 不自动重试危险命令，用户再次确认
  才产生新的 EffectID。`deliveryUnknown` 进入 awaitingExternalConfirmation，既不重发
  也不恢复为可点击 pending，直到 provider external resolution 或明确 not-delivered。
* peer disconnect/timeout 不可取消 `CheckedContinuation`；adapter 必须执行一次
  `finalizeTransport(providerSafeNeutral)`，Center 保留 pending/unavailable，不伪造 deny。
  provider 没有安全 neutral response 时，request 在 ingress quarantine，不注册 blocking
  channel。重复 disconnect/timeout/response 只命中 responder/ledger no-op。
* dismiss 只改变 presentation，不 dequeue、allow、deny、resolve 或改变 permission
  mode。dismissed request 保留 badge/数量，replay 继承 dismissed；新 RequestID 不继承。
* stale action（不存在、旧 generation 或已 terminal 的 RequestID）安全 no-op，并产生
  typed diagnostic；不得 fallback 到另一个 request/head。

### 5.3 跨 kind per-session ordering

每个 SessionRef 只有一个 ordered request sequence，permission、plan、question 共享
同一 arrival ordinal；不允许旧有的两个全局数组再通过索引猜顺序。

* 同一 session 的普通可解析 request 按 provider arrival 顺序推进；后一个 request
  不能越过仍 pending/resolving 的前一个。
* 不同 session 之间没有 head-of-line blocking。selector 可以选择另一个 session
  的 eligible request。
* reveal 可以显示指定 request 的详情，但不能用 resolution action 越过同 session
  的更早 unresolved request；若 target 被前项阻塞，返回 blockedByEarlierRequest
  diagnostic。
* provider 若确实替代了旧 request，Adapter 必须携带旧 RequestID 的
  externallyResolved(.superseded) 证据；新 kind 到达本身不隐式 drain/deny 旧 kind。
* resolution 后通常优先同 session 的下一项；其它 session 的 higher-priority failure
  或 explicit reveal 仍可成为 global prominent。

### 5.4 Presentation policy

selector 固定顺序：

1. resolving/transport failure 的 pending request；
2. 用户 explicit reveal 的 request；
3. 未 dismissed 的 waiting request；
4. arrival ordinal，再以 stable ID/occurrence UUID 做 deterministic tie-break。

系统自动 present 与用户 reveal 分开记录；用户 reveal 在 resolve 或再次 dismiss 前保留
突出。dismissed request 永不成为自动卡片，但仍在 badge/session list 中可发现。

第一迁移检查点使用 legacyProminent：新 request 主动展开，先证明模型行为等价。最终
默认切换到 adaptive CLI-first：CLI pane/tab 可见时只更新 badge/notification；不可见
或 visibility unknown 时主动展开。不存在按 permission/plan/question 拆开的策略开关。

### 5.5 Terminal ledger 和 retry

Center/adapter ledger 只用于 dedup late ack、replay 和 replacement race，必须有确定的
policy：

~~~swift
struct TerminalLedgerPolicy: Sendable, Equatable {
    let maxEntries: Int
    let retention: Duration
}
~~~

先移除 `endedAt + retention <= now` 的记录，仍超容量时按最早 `endedAt` 淘汰；eviction
只忘记 dedup 证据，不重开 request。ledger 命中或淘汰后的旧 EffectID/token ack 都是
diagnostic/no-op。`notDelivered` 使 request 回 pending(error)，只能在用户再次确认时
产生新的 EffectID；`deliveryUnknown` 保留 resolving/awaiting external，不自动重试危险
命令。网络无 provider idempotency 时，不宣称 wire exactly-once。

## 6. Auto、navigation 和 privacy

### 6.1 Per-session Auto

InteractionSessionContext 内每个 SessionRef 保存：

~~~text
observedMode       = upstream/CLI fact
requestedMode      = CodeIsland last explicit intent
capability         = typed provider capability
phase              = idle | transitioning | confirmed | unknown | failed
inFlightEffect     = optional EffectID
~~~

实际状态枚举还区分 `delivered` 与 `awaitingConfirmation`：前者是 control adapter 已接收
transaction 的可观察 ack，后者是同一 EffectID 已进入等待 CLI fact 的状态。两者都不是
`confirmed`；只有匹配的 `SessionObservation.permissionMode` 才能完成确认。

Auto 使用独立 control channel，不借用 pending permission continuation：

~~~swift
struct AutoCapabilities: Sendable, Equatable {
    let nativeAuto: Bool
    let acceptEditsRules: Bool
    let explicitBypass: Bool
    let independentControlChannel: Bool
}

enum AutoCommand: Sendable, Equatable {
    case setMode(ProviderPermissionMode)
    case addRules([AutoRule])
    case removeRules([AutoRule])
}

struct AutoControlToken: Hashable, Sendable {
    let session: SessionRef
    let rawValue: UUID
}

struct AutoCommandTransaction: Sendable, Equatable {
    let session: SessionRef
    let commands: [AutoCommand]
    let controlToken: AutoControlToken
}

protocol AutoCommandAdapter {
    func submit(
        _ transaction: AutoCommandTransaction,
        completion: @escaping (Result<AutoDelivery, AutoAdapterFailure>) -> Void
    )
}
~~~

`AutoControlToken` 本身带 `SessionRef`；compiler 生成的 transaction 必须复制该 session，
token/session 不一致时拒绝提交，不得把 Auto command 送到另一个 session。

`AutoModeIntent` 是 public typed command intent，只有 `enable`、`off` 和显式
`bypassExplicit`。Center 内部的 capability compiler 负责选择 provider 命令，不把 provider
字符串泄漏给 UI：

~~~swift
enum AutoCompileError: Sendable, Equatable {
    case unavailable
    case independentChannelRequired
    case bypassNotPermitted
}

struct AutoCommandCompiler {
    func compile(
        _ intent: AutoModeIntent,
        capabilities: AutoCapabilities,
        token: AutoControlToken
    ) -> Result<AutoCommandTransaction, AutoCompileError>
}
~~~

Compiler rules are deterministic:

| Intent | Required capability and compiled commands | Failure |
| --- | --- | --- |
| `enable` | native auto → `setMode(.auto)`; otherwise explicit accept-edits/rules → `setMode(.acceptEdits)` + owned `addRules` | unavailable; never silent bypass |
| `off` | independent control channel → `setMode(.defaultMode)` + owned `removeRules` | unavailable; do not consume permission token |
| `bypassExplicit` | independent channel + explicit bypass → `setMode(.bypassPermissions)` | `bypassNotPermitted` |

The compiler never removes provider-owned rules. `AutoCommandAdapter` is the only command
transport; a pending permission response is never an Auto channel.

Lifecycle is explicit: user intent creates `transitioning(effectID)`; adapter delivery creates
`delivered(effectID)`; the typed `autoModeAwaitingConfirmation` event creates
`awaitingConfirmation(effectID)`; a matching upstream observation creates `confirmed(mode)`.
Failure creates `failed`, and disconnect/unknown creates `unknown` while clearing local request.

native auto 优先；明确不支持时才生成 acceptEdits + addRules transaction。bypass 只在
用户明确选择 `bypassExplicit` 且 provider capability 允许时生成，否则只返回
安全 feedback。若 `independentControlChannel == false`，Center 不得借用 permission
response token，Auto phase 只能返回 typed unavailable feedback。delivery ack 不能把 mode
标为 confirmed；后续 reconcile 的 observed mode 才能确认。关闭/断开清除本地 requested/
context，不声称远端已改变。Auto 不隐式 resolve 当前 permission，也不影响其它 session。

### 6.2 SessionNavigator

Navigator 是与 Center 配合的第二个 deep Module，但不扩展 Center 的运行期入口；
Center 只发/收 NavigationEffect 和 typed outcome。生产 Adapter 继续使用：

1. TerminalActivator.activate(session:sessionId:) 现有 route；
2. 120ms、320ms、640ms 三次 visibility check；
3. remote/no-terminal 的既有安全规则；
4. failure sound/shake 与 autoCollapseAfterSessionJump 的现有语义。

Approval、Question、SessionCard 和 AskQuestion 共用 SessionIdentityLine，header
action 使用 navigate(.request(requestID)) 或 navigate(.session(sessionRef))，不复制
jump Task。Navigator success 由 Center 按设置更新 surface；failure 保留 surface，
发出 error feedback/nonce。

### 6.3 Privacy/redaction

SensitiveText.sensitivity、QuestionItem 内的 typed `SensitiveText` 字段和 DisplayValue 是
privacy contract：

* 本机 SwiftUI renderer 可读取回答所需 secret text；
* companion/ESP32、日志、diagnostic、trace projection 只能读取 redacted projection
  （例如 [redacted]、题目类型和 pending count）；
* 不允许外围 Adapter 取得 raw HookEvent 或自行重新解析 DisplayValue；
* CustomDebugStringConvertible/trace serializer 默认脱敏，测试必须覆盖 secret question。

### 6.4 Companion/ESP32 compatibility

Apple Companion 的现有 v1 payload/command 字段保持不变；新字段只以 optional 方式增加：
`pendingRequestID`、`pendingRequestKind`、`sessionGeneration`、`observedSequence` 和
协议 major/minor。新客户端 action 必须携带 RequestID、SessionRef generation 及它所看
到的 sequence；Center 只接受仍匹配的 pending target。unknown major 在 action dispatch
前拒绝并 diagnostic；unknown optional field 忽略。

旧 v1 command 没有 RequestID 时，只能由 compatibility Adapter 在 target 唯一、可见且
其 optional sessionId 匹配时转成显式 RequestID action；多个 session、dismissed/hidden
target 或缺少唯一性时安全 no-op 并请求刷新，不得回退 queue head。Apple Companion 仍
不提供远端 Dismiss；Dismiss/reveal 由 Mac local projection 保持。ESP32/BLE 的旧一字节
opcode 只能使用同一唯一 displayed target，不能表达跨 session 选择；未来 framed protocol
才可增加 ID，不复用旧 opcode 含义。secret question 只能出现在 external redacted facet。

### 6.5 SessionSnapshot field classification

SessionSnapshot 的字段不按“是否方便 UI”决定所有权，而按事实来源分类：
下表中的 display fields 只能进入 `SessionDisplayObservation`，route fields 只能进入
`SessionNavigationObservation`；两者由同一个 `SessionObservationAdapter` 组装为一个
revision envelope，不能让 UI 读取 SessionSnapshot 本身。

| 分类 | 字段（按现有 `SessionSnapshot`） | 唯一 writer | Center/consumer 读取 |
| --- | --- | --- | --- |
| upstream/provider fact | `status`, `currentTool`, `toolDescription`, `lastActivity`, `startTime`, `cwd`, `model`, `permissionMode`, `transcriptPath`, `source`, `providerSessionId` | single SessionSnapshot reducer owner（discovery 只能提交 typed reducer event） | 唯一 `SessionObservationAdapter`; Navigator 只读 terminal metadata |
| upstream/provider fact | `termApp`, `itermSessionId`, `ttyPath`, `kittyWindowId`, `tmuxPane`, `tmuxClientTty`, `tmuxEnv`, `termBundleId`, `cmux*`, `zellij*`, `weztermPaneId`, `superset*`, `orca*`, `cliPid`, `cliStartTime`, `remoteHostId`, `remoteHostName` | single terminal-metadata reducer owner（discovery/bridge 只能提交 typed metadata event） | `SessionObservationAdapter` 与 `SessionNavigator` 只读 |
| provider reconciliation fact | `subagents`, `closedSubagentIds`/tombstones | one provider/session reconciliation adapter per context（该字段唯一 writer） | `SessionObservationAdapter`/display projection；不参与 request resolution |
| derived display | `toolHistory`, `totalToolCallCount`, `lastUserPrompt`, `lastAssistantMessage`, `recentMessages`, `sessionTitle`, `sessionTitleSource`, `gitBranch`, `gitIsWorktree` | single display projector（只读 upstream facts，生成新 projection） | SwiftUI/companion projection；不参与 identity |
| fork/native/provider reconciliation | `observedPermissionMode`, `cursorPendingQuestion`, `isYoloMode`, `taskRoundEnded`, `interrupted` | 迁移期每个字段各有一个 owner：Auto context、NativePromptObservation adapter、provider capability context、Cline context、interruption reconciler；最终不再写 `SessionSnapshot` | typed observation/projection；不得写回 SessionSnapshot 或通用 request |

`permissionMode` 是当前 CLI fact；`observedPermissionMode` 是 fork peak-memory，迁移后
从 Core snapshot/reducer/persistence 移除，只做 legacy decode-and-discard。`cursorPendingQuestion`
先由带 parent/run_async guard 的 NativePromptObservation 消费，再移出 snapshot。Cline 的
`taskRoundEnded`、native `isYoloMode`、subagent tombstone 等保持 provider-specific context，
不得驱动 generic resolve。所有 terminal metadata 继续供 Navigator 只读使用。

### 6.6 Persistence compatibility

SessionPersistence 继续读取旧 sessions.json 的 terminal metadata、provider ID、
closed subagent tombstone 等 upstream display facts。旧 optional
observedPermissionMode 在过渡期可以解码，但 mapper 不回填 Center-owned mode，新的
写路径不再生成该 fork 字段。pending request、transport token、dismiss/reveal、
in-flight effect 和 generation-specific interaction context 不跨 App restart 恢复；
CLI 重新上报后才建立事实。

## 7. Data flow 和 Adapter

~~~text
Hook bytes / Codex JSON-RPC
  -> provider ingress Adapter
       (filter, existing normalization, generation authority, bounded request buffer,
        identity proof, token registry/OnceResponder)
  -> center.send(.sessionObserved / .requestArrived / .nativePromptObserved)
  -> [InteractionEffect]
  -> one InteractionEffectExecutor -> transport / Auto / navigator / feedback Adapter
  -> center.send(.adapter(...))

existing reducer + discovery -> SessionSnapshot
  -> one SessionObservationAdapter projection
       (SessionDisplayObservation + SessionNavigationObservation)
  -> center.send(.sessionObserved(...))

SwiftUI / shortcut / companion
  <- center.snapshot.local (Mac renderer) / .external (low-trust projection)
  -> center.send(.user(... stable RequestID/SessionRef ...))
~~~

依赖按 DEEPENING 分类：

* **In-process**：identity proof、registry、cross-kind queue、lifecycle、selector、
  Auto transition、redaction projector；直接穿过 Center Interface 测试。
* **Local-substitutable**：in-memory context、deterministic clock/ID factory、旧文件
  mapper；用 fixture/recording Adapter 测试，不让 Center 创建 singleton。
* **Remote-but-owned**：Unix hook bridge、Codex app-server transport；生产
  HookTransportAdapter/CodexTransportAdapter，测试用 in-memory exactly-once Adapter。
* **True external**：AppKit、terminal applications、Accessibility、SoundManager、
  companion；生产 Navigator/feedback Adapter，测试用 fake/recording Adapter。

一个 Adapter 只有在 production 与 test 两个实现都存在时才形成真实 seam。纯 reducer
的内部模块不公开 port，避免为了测试而把 implementation 变成浅层 pass-through。

## 8. Failure/ordering matrix

| 事件 | Center 结果 | 禁止行为 |
| --- | --- | --- |
| stable ID + proof replay | 保留 ordinal/dismiss/lifecycle，更新 token | 重发用户命令、重新 sound/present |
| stable ID 冲突无 proof | Adapter 生成 occurrence；或 quarantine | 覆盖现有 request |
| unknown RequestID action | 无状态变更，diagnostic | 操作 queue head |
| action 与 kind/capability 不匹配 | validation diagnostic | 产生 transmit effect |
| resolving duplicate action | 空 effect | 第二次 resume/response |
| resolution failure | pending + error + prominent | 自动重试危险决定 |
| deliveryUnknown | awaitingExternalConfirmation；等待 external resolution | 第二个危险 effect 或伪造 not-delivered |
| external resolution race | removed/external；迟到 ack no-op | 第二份 response |
| token disconnect 无 evidence | token 对应 request unavailable/pending | 按 session 批量 deny |
| disconnect/timeout with channel | 一次 finalizeTransport(providerSafeNeutral)；responder finish once | 假造 deny 或第二次 resume |
| displayOnly/nativeOwned request | 只保留 presentation / native-prompt observation | 生成 resolution effect |
| session-channel close + provider evidence | 逐 request 终结/标记事实 | 把普通 EOF 当 deny |
| stale generation observation/ack | 忽略，记录 diagnostic | 覆盖新 session |
| stale/expired visibility | 当作 unknown，按 adaptive policy 处理 | 用旧可见性抑制展开 |
| Auto toggle | 独立 control transaction；delivery 后等待 observation | 消费 pending continuation |
| terminal ledger hit/eviction | late ack no-op/diagnostic；不重开 request | 依旧旧 ID 重试 |
| secret content to companion/log | redacted projection | 原文泄漏 |
| old persistence file | 可读 upstream facts，interaction empty | 猜 pending identity |

## 9. 测试和结构验收

测试只通过 send、返回 effects 和 snapshot stable/redacted projection；不能读 private
queue、identity map、continuation 或 AppKit。至少需要这些 interaction traces：

* permission basic：arrival -> allow -> success；optimistic hide、single effect、resolve。
* Plan：manual plain allow；无 Skip；suggested mode 与 deny-with-feedback 保留。
* Hook/AskUserQuestion/Codex question：同一 typed question lifecycle；answer key/order
  正确；capability 不足时只有 Dismiss。
* dismiss/reveal：pending、badge、replay hidden inheritance、新 ID 不继承。
* identity：shared tool ID collision、occurrence、proof replay、generation replacement。
* request-before-observation：有界 buffer 保序 bind、TTL/容量 overflow 的 neutral finalization、
  close 后 stale request no-op。
* cross-kind/session ordering：A(permission, plan, question) FIFO；B 不被 A 阻塞；旧
  kind 只有显式 superseded 才结束。
* transport：token-scoped disconnect、duplicate/late ack、effect-before-external 和
  external-before-effect、session channel close。
* effect executor：send 返回数组只有一个 executor 消费，EffectID duplicate 不二次提交；
  `deliveryUnknown` 不自动 retry，terminal ledger TTL/capacity eviction 可重现。
* Auto：per-session requested/observed/confirmed；native 优先、rules fallback、
  bypass negative test、独立 control channel、disconnect unknown。
* visibility：revision/generation/max-age、visible/notVisible/unknown 与 stale observation。
* session observations：display facet 覆盖 project/cwd/source/status/tool、subagents、recent
  messages、git、remote/provider IDs；navigation facet 保留 terminal/remote route；stale
  revision 同时丢弃两者，不出现 facts/route 半更新。
* audience/companion：local secret 与 redacted facet；v1/optional ID、unknown major、
  stale sequence、ambiguous legacy command、ESP32 one-byte compatibility。
* navigation：request/session target、remote no-op、三次 check、failure feedback、
  auto-collapse。
* stale observation/remove、persistence compatibility、secret redaction。

结构 guards 必须检查：热点文件没有 queue/dismiss/Auto writer；UI action 含 RequestID
或完整 SessionRef；raw protocol 只在 Adapter；SessionSnapshot 没有 fork-only 字段；
Approval/Question/SessionCard 没有重复 jump retry 状态机；companion 不绕过 snapshot。

## 10. Depth、Locality 和 seam placement 取舍

两入口的 Depth/Leverage 来自一个 reducer Interface 覆盖所有生命周期；caller 不需要
学习 permission/question/CLI 各自的 continuation、queue index 或协议响应。关闭的类型
集合牺牲了“零核心改动添加未知 request”的表面扩展性，但避免 generic stringly
framework 把 schema、风险和 provider 判断推回 UI，安全性和可测试性更强。

Locality 来自三处隔离：provider 字段/协议在 ingress/transport Adapter；AppKit 跳转
在 Navigator；fork state 在 InteractionCenter context。未来 upstream 增加等价事实时
只改 typed mapper，不复制 reducer 或修改多个调用方。

把 seam 放入 SessionSnapshot 会污染 upstream model/persistence；放入 HookServer 会
让 transport 与 presentation 继续耦合；放入每张 SwiftUI 卡片会复制状态机。把 seam
放在 fork-owned Center，并用薄 Adapter 接入，能将 upstream 冲突集中到少量连续区域。

## 11. Migration compatibility shape

迁移顺序、每 phase owner、测试 gate 和 rollback 命令见 implement.md。设计约束是：

* 每个 phase 只有一个 writer；切换 request kind 后旧 queue 立即停止写入。
* Adapter bridge 可以短期存在，但旧 queue 只能是 read-only projection，旧 command 只能
  转换为带 RequestID 的 input；不允许两套 business lifecycle 双写或双重 resume。
* 第一阶段生产行为仍 legacy-prominent；adaptive CLI-first 只能作为最后独立切换。
* 每 phase 可整体回滚到上一 owner；保留 upstream hooks/session 能力，不回滚为长期
  fork 大文件副本。
* 每次 upstream sync rehearsal 记录热点文件冲突数、需人工理解的语义冲突数、
  fork-owned 模块是否无需修改，以及 seam 数量；“本次零冲突”不是唯一证明。
* rehearsal 基于正确的 `refs/remotes/upstream/main` ref（`upstream/main` 只是其 shorthand），证据固定写入
  `.trellis/tasks/08-31-fork-architecture/research/upstream-sync-evidence.md`，包括
  revision、命令、冲突文件/semantic conflict、每个热点 seam 和 fork-owned module 改动。

迁移期间的兼容形状固定如下：

~~~swift
struct LegacyInteractionProjection {
    let permissionQueue: [LegacyRequestView]   // computed, never stored
    let questionQueue: [LegacyRequestView]     // computed, never stored
}

struct LegacyCommandAdapter {
    func approve(_ requestID: RequestID) -> InteractionInput
    func deny(_ requestID: RequestID) -> InteractionInput
    func answer(_ requestID: RequestID, _ answer: QuestionAnswer) -> InteractionInput
    func dismiss(_ requestID: RequestID) -> InteractionInput
}
~~~

Phase 2 建立统一 registry 后，legacy queues 只由 `InteractionSnapshot` 投影；所有 legacy
command 必须先解析为显式 RequestID，找不到或 target ambiguous 就 diagnostic/no-op。旧
方法不得继续 append/remove/resume，也不得按 queue head 代替 ID。每个 phase 的 writer、
legacy read-only consumer、切换 gate 和 rollback boundary 见 implement.md matrix。
