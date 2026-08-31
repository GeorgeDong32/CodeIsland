# InteractionCenter implementation context

本文件是 .trellis/tasks/08-31-fork-architecture 的实现/验收速查表。它压缩
design.md、implement.md、caller-test-interface.md、flexible-interface.md、
minimal-interface.md、contract-closure.md 和 migration-closure-matrix.md 的已确认
结论；设计和实施计划仍是权威决定。本文件只记录实现者在切片时必须保持的契约、现有
代码边界、测试证据和回滚条件。

## 1. 不可改变的外部契约

InteractionCenter 是 fork-owned deep module。唯一运行期 seam：

~~~swift
@MainActor
final class InteractionCenterStore {
    var snapshot: InteractionSnapshot { get }
    @discardableResult
    func send(_ input: InteractionInput) -> [InteractionEffect]
}
~~~

不得新增 public approve/deny/skip/pending/toggle/subscribe 方法、可变 queue、effect
sink 或 raw JSON 入口。调用方只能读 snapshot、发 typed input；一个 coordinator-owned
executor 按 send 返回数组顺序执行 effects，再以 typed adapter input 回送结果。Center
内部 reducer 可纯化、可替换，但 AppKit、SwiftUI、socket、JSON/JSON-RPC、continuation、
SoundManager 不得进入 model。

### 类型、身份与 ingress

* ProviderID + SessionKey(provider, providerSessionID) 标识跨 provider 会话。
  SessionRef(key, generation) 才是运行期身份；RequestID(session, correlation)、
  EffectID、opaque TransportToken(session, UUID) 和 ChannelToken 不得退化为 String。
* InteractionRequestKind 关闭为 permission | question。Plan 是
  PermissionVariant.plan(PlanContent)，不是第三种 kind。请求内容为 typed
  PermissionContent/QuestionContent；不得使用 [String: Any]、provider 原始 JSON。
  QuestionItem 需有稳定 answer key、provider order、multi-select、sensitivity。
* Resolution behavior 关闭为 blocking(ResolutionCapabilities)、displayOnly、
  nativeOwned；channel 为 none | response(TransportToken)。只有 blocking 且
  capability 允许的动作才生成 resolution effect。没有通用 Skip：普通 permission
  的手动 allow 是 typed allowOnce/allowAlways；Plan 使用 typed allowPlan；question
  按 answer key/order。Dismiss 只改变 presentation，不结束 transport。
* 唯一 SessionGenerationAuthority 负责 open/reopen/close 和 monotonic generation。
  adapter 不能从 raw session ID 私自递增/构造 SessionRef。同 generation observation
  幂等；旧 generation 的 request、observation、ack、remove 是 stale/no-op，不能复活
  新会话。app restart 不从 persistence 恢复 generation。
* Request 可先于 SessionSnapshot。Ingress 先按 SessionKey 放入有界、带 TTL 的
  RequestIngressBuffer，generation 明确后按 arrival order bind；overflow/expiry
  只做一次 provider-safe neutral finalization + diagnostic，不换绑其它 session。
  reliable upstream ID 才能形成 StableRequestKey；共享 tool ID、无 ID、冲突或不能
  证明 replay 时使用 occurrence UUID。相同 fingerprint 不能自动合并。

### 状态、顺序和失败

生命周期为 arrival -> pending；dismiss/reveal 仅 presentation；resolve -> resolving
（可 optimistic hide）；effect/external success -> terminal；effect failure ->
pending(error, prominent)。仅 token-scoped disconnect 不能表示 deny：没有终止证据时
进入 unavailable/error pending；非 cancellable continuation 用 neutral finalization
（例如 safe disconnect response），且 OnceResponder 只能完成一次。明确 provider
终止、显式 externallyResolved 或同 effect 的成功/失败才可 terminal。

每个 session 有跨 permission/plan/question 的单一 ordinal；A session 的序列不能被 B
阻塞，也不能隐藏 global head-of-line。新 kind 不自动 drain/deny 旧 request；只有
provider 明确 superseded evidence 才能结束旧 request。selector 优先级：
resolution failure > explicit reveal/prominent > waiting > session-local ordinal。
Terminal ledger 必须 bounded（TTL + capacity + 明确 eviction）。notDelivered 回到
pending(error)，用户 retry 生成新 EffectID；deliveryUnknown 保持 resolving/waiting
external，不能危险自动重试。late/duplicate ack、旧 token、旧 generation 都记录为
diagnostic 并保持状态不变。

### Auto、navigation 和隐私

Auto 是独立的 per-session command channel，不复用 pending continuation。分离
requested/delivered/observed/confirmed/unknown；delivery 不等于 confirmed，只有
SessionObservation 或明确 provider ack 才确认。native auto 优先；acceptEdits +
addRules 只在 typed capability/explicit fallback 允许时使用；bypass 只能来自明确
intent + capability。Auto command 失败不应 resolve permission。

Center 只产生 typed NavigationEffect；SessionNavigator 保留现有
TerminalActivator.activate(session:sessionId:)、remote no-op、120/320/640ms
visibility checks、失败 feedback/shake、auto-collapse。navigation 不改变 request
事实，visibility 以 SessionRef + revision + evidence + measuredAt 输入，防 stale
结果覆盖新状态。

local snapshot 可含需要本机显示的敏感值；external facet（Apple Companion、ESP32、
log、trace）只能拿 redacted projection，永不传 raw HookEvent/provider JSON、
continuation、token、socket 或 question secret。send 的 input/effect/snapshot
trace 也分 local 与 redacted projection。

## 2. 现有代码的完整迁移边界

表中“现状”是可观察热点；“目标 writer”是切片后唯一事实写入方。桥接期间 legacy
array 只能 computed/read-only projection；一个 kind 完成切换后不得双写。

| 现有分支/消费者（定位） | 目标 owner / 迁移证明 |
| --- | --- |
| HookEvent 路由、byte probe/JSON、source/plugin/Cursor/Codex sub-session leave/hide/merge、cwd/remote 过滤（Sources/CodeIslandCore/Models.swift:166-230；Sources/CodeIsland/HookServer.swift:305-327,550-651,654-817） | Phase 2 Ingress/Subsession/Source adapters；Center 只收 normalized typed input。alias、malformed、cwd、tracked lifecycle、_ppid/plugin/Codex parent golden tests。 |
| Hook routeKind 的 built-in tools、always-proceed source、provider defer、Claude Auto（HookServer.swift:741-801） | Phase 2/5 provider policy + Auto observation。AskUserQuestion 不能被 allow-list 绕过；defer 必须显式 capability，未知 capability 不静默 bypass。 |
| 普通 PermissionRequest、ExitPlanMode、AskUserQuestion continuation 及 disconnect（HookServer.swift:654-817,819-880；AppState.swift:1512-1618） | Phase 2/3/4 HookInteractionAdapter + Center；每个 blocking channel 有 token/OnceResponder。测试 response schema、replay、channel mismatch、timeout/disconnect、continuation once。 |
| Notification/plugin question 分支（AppState.swift:1933-2097；Hook routing 同上） | Phase 4 typed question adapter。Notification 若仅展示则 displayOnly；blocking 必须 provider contract 声明。来源不稳定时只有 Dismiss，不能伪造 Skip。 |
| ToolUseCache PreToolUse/Post/PostFailure/PermissionDenied、Trae 保留、stale deny、无 ID activity bulk allow、TTL/replay（Sources/CodeIsland/AppState+ToolUseCache.swift:23-200） | Phase 2 EventCorrelationAdapter。same/different input、shared ID collision、cross-generation、TTL、两个 no-ID request trace；无证据不 bulk-allow，改 typed external progress 或 pending/error。 |
| Codex requestUserInput、requestId closure、serverRequest/resolved、replacement/close（Sources/CodeIsland/AppState+CodexAppServer.swift:230-372） | Phase 4 Codex adapter。每个 requestId 独立；client generation + token 可见；旧 client ack no-op；resolved 不发送第二份 response。 |
| Cursor cursorPendingQuestion、run_async/parent transcript guard、Notch 条件（Sources/CodeIsland/AppState+TranscriptTailer.swift:126-225；Sources/CodeIsland/JSONLTailer.swift:508-575；Sources/CodeIsland/SessionSnapshot.swift:111-116；NotchPanelView.swift:2329-2333,2526-2547） | Phase 1/5/6 NativePromptObservation/reconciliation。nativeOwned 不生成 CodeIsland answer effect；验证 parent mismatch、run_async、pending/clear。 |
| AppState permission/question queues、head/index、approve/deny/answer/skip、drain/remove/disconnect（Sources/CodeIsland/AppState.swift:118-231,1512-1618,1630-1638,1933-2461） | Phase 2 起 Center registry 唯一 writer；legacy queues 只 projection，command adapter 每次携带 RequestID。architecture guard 覆盖所有 append/remove/resume/head command，最终删除旧 writer。 |
| Plan removeFirst/plain allow/feedback（Sources/CodeIsland/AppState+Plan.swift:7-106） | Phase 3 PermissionVariant.plan。regular/plan 共享 ordinal；manual plain allow 可用；无 Skip/head fallback。 |
| Auto singleton、clear、queue drain、observed mode（Sources/CodeIsland/AppState+AutoApprove.swift:10-211；AppState.swift:192,1419-1436） | Phase 5 InteractionSessionContext + AutoCommandAdapter。每 session requested/observed/confirmed/unknown，旧 singleton/observed field 停止写入；旧 persisted observed mode decode-discard。 |
| Snapshot discovery/reducer、mode merge、persistence restore（Sources/CodeIsland/SessionSnapshot.swift:78-162,364-375,958-967,1116-1203；SessionPersistence.swift:4-101；AppState.swift:2828-2887） | Phase 1/5 SessionObservationAdapter。只投影 upstream fact；stale revision/generation 不得 resolve；waiting→processing 不得隐式 resolve。 |
| Root surface、ApprovalBar、QuestionBar、SessionCard、identity 和 queue-derived display（Sources/CodeIsland/NotchPanelView.swift:198-260,1005-1199,1218-1510,2325-2482） | Phase 1/6 local InteractionSnapshot + Navigator。稀疏 metadata 也显示 session ID；每个 action 指定 target RequestID/SessionRef，不读 queue head。 |
| Global shortcut/current-head callbacks（Sources/CodeIsland/AppDelegate.swift:226-254；PanelWindowController.swift:313-329,673-680） | Phase 6 prominent RequestID selector adapter；无 prominent target no-op，stale/hidden target 不操作别的 head。 |
| Apple Companion publisher/command/version payload（Sources/CodeIsland/AppleCompanionPublisher.swift:23-25,123-141；AppleCompanionPayload.swift:118-214） | Phase 6/7 versioned redacted projection + compatibility adapter。加入 optional request ID/kind/generation/sequence；unknown major 在 action 前 reject；legacy 无 ID 仅 unique visible target + matching session。 |
| ESP32/BLE one-byte controls/summary（Sources/CodeIsland/ESP32StatePublisher.swift:189-249,296-309,346-482；ESP32Protocol.swift:86-88,122-157） | Phase 6/7 narrow-target adapter。旧 opcode 保持；仅一个唯一 displayed target 才可 action，ambiguous/cross-session no-op；summary 不泄漏 secret。 |
| terminal visibility/AppKit activation/retry（PanelWindowController.swift:313-329,673-680；AppState.swift:777 及导航调用链） | Phase 1/7 SessionNavigator + VisibilityObservation。保留 remote/failure/route 行为；四类调用方不再各自拥有 jump retry Task 后才能删重复实现。 |

### SessionSnapshot 字段分类

不能把 fork-only interaction state 继续塞入 upstream snapshot。

* 上游事实（继续由 discovery/reducer 产生）：status、currentTool、lastActivity、
  start/cwd/model/source/providerID、permissionMode、transcript、terminal、remote、
  subagents，以及 upstream lifecycle/identity。permissionMode 是事实，不等于 Auto
  observed。
* 派生 display（可由 snapshot/adapter 重建，必要时保留 display persistence）：
  history/messages/session title/git branch/primary/counts 等 UI display projection。
* fork/native/provider reconciliation state（移入 InteractionSessionContext 或 typed
  observation）：observedPermissionMode、Cursor pending question、isYoloMode、
  taskRoundEnded、interrupted、closedSubagentIds，以及 pending/dismiss/reveal、
  generation、transport、Auto requested、visibility revision。Cursor pending 为
  native-owned observation；不建立 answer queue。

当前 observed mode persistence 位于 SessionPersistence.swift:39-41,79-80，restore
位于 AppState.swift:2828-2850；迁移时允许旧数据 decode 但 discard observed field，
不能把它重新写回 upstream。closedSubagentIds 若继续用于 display/reconciliation，
需明确 owner；否则不得由旧 merge 逻辑复活 closed child。

## 3. 实现切片、writer 和安全回滚

| Phase | 唯一写入方与内容 | 完成 gate / 回滚点 |
| --- | --- | --- |
| 0 | Center typed model/test；generation authority、ingress buffer、ordinal、ledger、selector、dismiss/reveal、optimistic resolution、neutral finalization、Auto/privacy projection。生产 App 不接 input。 | Center trace/identity/order/privacy/ingress/executor/ledger/visibility tests + build；失败只撤销该 phase（GitButler but undo，或 owner 确认 commit 后 but discard <phase-commit>），不改 AppState。 |
| 1 | SessionNavigator/fake navigator；visibility adapter；统一 ApprovalBar/QuestionBar/SessionCard/AskQuestion target identity；Center 仅发 NavigationEffect。 | Navigator/UI/high-risk permission tests + build；确认旧 jump retry 无第二 owner 后再删。 |
| 2 | Center normalized registry（permission/plan/question arrival）、Hook/source/correlation adapters、token/OnceResponder；legacy queue read-only。 | Hook golden + ingress/replay/correlation/disconnect tests；guard 所有旧 append/remove writer。 |
| 3 | Center permission resolution + Plan variant；plain allow，明确无 Skip。 | regular/plan shared ordering、capability and response schema tests。 |
| 4 | Center question lifecycle；Hook/AskUser/Codex typed question；Cursor native-owned。 | answer key/order, Dismiss, Codex requestId/generation, duplicate resolved tests。 |
| 5 | InteractionSessionContext、single reconcile seam、per-session Auto、visibility revision/max-age；旧 Auto singleton/observed writer 消失。 | Auto requested/observed/confirmed/unknown and persistence compatibility tests。 |
| 6 | UI/shortcuts/companion/ESP32 只读 local/redacted snapshot、发 typed action；prominent selector 和 protocol adapter。 | structural guards + SwiftUI/shortcut/companion/ESP32 compatibility tests。 |
| 7 | 仅在 behavior-equivalence evidence 后切 adaptive CLI-first，删旧 queues/fields/bridges。 | full test/build、diff/marker checks、upstream sync rehearsal evidence；保留旧协议窄兼容。 |

每一 phase 只允许一个 writer；adapter 可以暂存 transport registry，但不可拥有第二个
lifecycle。阶段完成的证据应写明 owner、专项测试、旧回归、sync/rollback point。禁止
用 feature flag 掩盖双写或以暂时跳过 gate 推进。

## 4. Trace-first 测试与架构护栏

### 测试 harness

用 deterministic Clock、ID factory、in-memory generation authority、recording
transport/executor、fake Navigator；不需要 @testable 读取内部字段。每条 trace 记录：
输入（local projection）、返回 effects（按序）、executor ack、最终 local snapshot 和
external redacted snapshot。断言状态和可观察行为，不断言 dictionary/array 内部布局。

最低 trace 集合：

1. regular permission、Plan permission、question arrival/resolve/success/failure；
   Plan 永远是 permission variant；displayOnly/nativeOwned 无 resolution effect。
2. dismiss/reveal、optimistic hide/retry、stable replay、occurrence、相同 tool ID
   collision、same/different input。
3. A(session) permission→plan→question 与 B(session) 并行；无 global HOL，ordinal
   跨 kind，selector 只选真实 prominent RequestID。
4. request-before-observation bind、buffer TTL/capacity overflow、session reopen
   generation、stale observation/request/ack/removal。
5. token disconnect、explicit transport end、OnceResponder neutral finalization、
   duplicate/late ack、effect-before-external、external-before-effect、close。
6. notDelivered、deliveryUnknown、terminal ledger TTL/capacity eviction、explicit
   retry、新 EffectID、危险 action 不自动重试。
7. Auto native/rules/bypass negative、独立 command token、requested/delivered/
   observed/confirmed/unknown；Auto failure 不 resolve permission。
8. stale visibility revision、route success/failure/remote、Navigator retry 序列。
9. local secret 可见而 companion/log/trace external projection redacted；companion
   unknown major、optional ID/generation/sequence、legacy ambiguity；ESP32 narrow target。

### Adapter contract 与现有回归

* HookTransportAdapter：所有 route/filter/defer/continuation response、malformed/alias、
  source/plugin/Cursor/Codex parent、disconnect/timeout/once。
* EventCorrelationAdapter：ToolUseCache duplicate、TTL、stale deny、no-ID 不 bulk allow。
* CodexTransportAdapter：requestId r1/r2、replacement generation、server resolved、
  response exactly once。
* NativePromptObservation：Cursor pending/clear、run_async、parent mismatch，始终
  nativeOwned/no answer effect。
* AutoCommandAdapter：capability matrix、native priority、explicit fallback、per-session
  isolation、persistence discard。
* SessionNavigator：existing activation route、remote no-op、120/320/640ms checks、
  failed feedback、stale target。
* SwiftUI/shortcut/Companion/ESP32：snapshot-only read、targeted action、redaction、
  version/sequence/ID compatibility。

计划中的命令（对应实现存在后执行）：

~~~bash
swift build
swift test
swift test --filter InteractionCenterTraceTests
swift test --filter InteractionCenterIdentityTests
swift test --filter InteractionCenterOrderingTests
swift test --filter InteractionCenterPrivacyTests
swift test --filter InteractionCenterIngressTests
swift test --filter InteractionEffectExecutorTests
swift test --filter InteractionTerminalLedgerTests
swift test --filter InteractionVisibilityTests
swift test --filter HookTransportAdapterTests
swift test --filter CodexTransportAdapterTests
swift test --filter SessionNavigatorTests
swift test --filter InteractionArchitectureGuardTests
swift test --filter AppleCompanionProtocolCompatTests
swift test --filter ESP32ProtocolTests
swift test --filter AppStatePermissionFlowTests
swift test --filter AppStateQuestionFlowTests
swift test --filter AppStateAnswerRoutingTests
swift test --filter AppStateAutoApproveTests
swift test --filter HookServer
git diff --check
rg -n '<<<<<<<|=======|>>>>>>>' Sources Tests
~~~

若 SwiftPM 不接受类名过滤，再执行 swift test --target CodeIslandTests、
swift test --target CodeIslandCoreTests。每个 phase 至少专项 test + swift build +
受影响旧回归；Phase 7 需全量测试。

### Architecture guards

静态 guard 必须在 CI/phase gate 执行：

1. Center 是唯一 request lifecycle/Auto/selector writer；AppState 只持有 Store、转发
   returned effects，旧 queue 不 append/remove/resume。
2. UI、shortcut、companion、ESP32 只读 snapshot、发 typed action；不得访问 HookEvent、
   provider JSON、continuation、queue head、Auto singleton。
3. 所有 actionable action 带 RequestID 或完整 SessionRef；session String 不能独立
   选择目标；Plan 不能出现 generic Skip。
4. Hook/Codex bytes、socket、JSON、connection、continuation 只在 adapter；Center 不
   依赖网络/AppKit/SoundManager。
5. SessionSnapshot 不新增 fork-only pending/dismiss/transport/generation/requested
   Auto 字段；persistence mapper 对 observed mode 只兼容 decode-discard。
6. 所有 effects 来源是 send 返回数组，只有一个 executor；每个 resolution/finalize
   有 EffectID + RequestID + TransportToken。
7. companion/ESP32 external projection 必须 redacted；unknown protocol major 在 action
   前拒绝，legacy no-ID 只允许唯一、同 session、可见 target。
8. 每 phase 记录 single writer；禁止第二 queue、第二 generation authority、第二
   navigation retry Task。

## 5. 同步、回滚与完成证据

Phase 7 的 sync rehearsal 不是口头确认，必须留下
.trellis/tasks/08-31-fork-architecture/research/upstream-sync-evidence.md，至少记：

* 进行 sync 前的 upstream revision、fork revision、工作树状态和命令；
* conflict locations 与 semantic conflicts 的数量/列表（尤其 AppState.swift、
  HookServer.swift、SessionSnapshot.swift、UI/companion 热点）；
* 每个冲突的裁决：upstream fact 保留、fork Center seam 保留、兼容 adapter 是否需要；
* fork-owned changes unchanged 的 diff/测试证据，以及 behavior-equivalence 回归结果；
* 未决风险、恢复/回退点和下一次 sync 的 owner。

同步应基于正确的 upstream/main 证据，不使用 destructive reset/checkout。阶段失败
优先保留工作树并用 GitButler 的 phase 边界回滚：最近操作 but undo，已确认独立
phase commit 才能 but discard <phase-commit>；不能回滚掉其它 agent 的改动或把旧
AppState 恢复成双写状态。若 sync 只在实验 worktree，须在合并前重放对应 trace、
architecture guards、全量 build/test。

交付前 checklist：

* [ ] typed interface、generation authority、request-before-observation buffer、token/
  effect/terminal ledgers 已有外部 trace；
* [ ] Hook、ToolUseCache、Codex、Cursor、Plan、Auto、UI、shortcut、Companion、ESP32
  每行迁移矩阵都有 target writer、contract test、guard；
* [ ] local/external projection 经过 secret/redaction trace；
* [ ] non-cancellable disconnect neutral finalization、duplicate/late/stale ack、
  no-ID correlation、terminal retry 已验证；
* [ ] SessionSnapshot field classification、legacy persistence decode-discard 已验证；
* [ ] Navigator behavior equivalence、adaptive visibility 和 protocol compatibility 已验证；
* [ ] sync evidence、rollback point、git diff --check、conflict marker scan 和
  Phase 7 全量测试已留档。

## 6. 仍需主动挑战的风险

* Notification question 的“displayOnly 还是 blocking”不能从 payload 猜；必须由 provider
  capability 明示，否则 UI 看似有按钮却无安全 response channel。
* 当前 ToolUseCache 无 ID activity 的 bulk allow 与 stale matching deny 都是隐含安全
  policy；迁移后若仅换类型、不保留证据边界，会把另一个并发 request 放行。
* Hook disconnect、Codex serverRequest/resolved、replacement 和 process/session close
  可能同时到达；没有 token + generation + OnceResponder ledger 就会二次 response 或
  把新 generation 删除。
* Cursor pending 是 native-owned observation；若 SwiftUI 仍按旧 cursorPendingQuestion
  展示为可回答 queue，会产生没有 provider channel 的假按钮。
* Auto 现为 singleton 且 effective mode 读 observed field；仅改名为 per-session 不足，
  必须将 requested/delivered/observed/confirmed 分阶段并隔离 command channel。
* Companion 当前缺 RequestID/sequence，command handler 还可能忽略 session；增加字段
  后必须定义 v1 legacy ambiguity、unknown major reject、duplicate command 幂等，否则
  外部设备会操作错误 request。
* ESP32 旧 one-byte opcode 天生没有目标身份；兼容只能是唯一可见目标的窄策略，不能
  假装成为通用 interaction protocol。
* closedSubagentIds、taskRoundEnded、interrupted 兼具 upstream/reconciliation 语义，
  必须在 owner 表中逐字段决定；迁移中若仍由两个 reducer 写入，sync 冲突会把 session
  重新打开或错误显示 idle。
* Adaptive CLI-first 只能在现有 UI/terminal/remote 行为等价证据后切换；没有 evidence
  时提前清理 legacy projection 会让不可见 request 无法恢复。
