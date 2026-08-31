# InteractionCenter 实施计划

本文件是已获授权的后续实现执行计划；task 在 gate review 前仍保持 `planning`，本文件
完成不会自动 start task。实现按下列 owner、matrix 和 gates 执行，不在本次文档编辑中
修改产品代码。

## 1. 全局执行规则

### 唯一 owner

每个 phase 只允许一个模块写入相应事实：

* Phase 0：InteractionCenter model（仅测试，不接生产），并建立 generation authority/
  ingress buffer 的纯 contract。
* Phase 1：SessionNavigator（仍由旧 AppState/UI 持有 request lifecycle）。
* Phase 2：Center 独占 normalized permission/plan/question registry 的 ingress 生命周期；
  旧 permission/question queue 只可 read-only projection，不能继续写入。
* Phase 3：Center 独占 permission（含 plan variant）resolution；不恢复 Skip。
* Phase 4：Center 独占 question lifecycle；旧 QuestionRequest/continuation 只留在
  transport registry，旧 queue 只可 projection。
* Phase 5：Center 独占 InteractionSessionContext 和 per-session Auto；旧 singleton/
  observedPermissionMode 不再写入。
* Phase 6：snapshot/action 成为 UI/shortcut/companion 唯一读写 seam；companion 只读
  redacted facet，legacy command 走 compatibility adapter。
* Phase 7：只切换 presentation policy 到 adaptive CLI-first，并清理旧接入。

可以暂时保留桥接 Adapter，但一个 request kind 完成切换后，旧路径必须立即停止
写入。禁止新旧 queue、dismiss、Auto 或 continuation lifecycle 长期双写。每个 phase
在提交前记录 owner、测试 gate 和回滚点。

### 运行纪律

* 所有 Center 输入在一个 MainActor/串行 reducer 上按接收顺序消费；一次 send 的
  effects 按返回数组顺序执行。
* provider normalization、JSON/JSON-RPC、connection、continuation、AppKit 和
  SoundManager 不进入纯 Center model。
* provider Adapter 只能生成 closed typed permission/question kind（Plan 是
  `PermissionVariant.plan`）与已命名
  capability/action；不能通过字符串 kind/action 绕过类型安全。
* SessionRef generation、RequestID、EffectID、TransportToken 不可省略为 session
  字符串；旧 generation 的结果一律 stale/no-op。
* 每 phase 的测试先使用 deterministic clock/ID factory、recording transport 和
  fake navigator；真实 socket、terminal、animation 只做独立 contract/smoke test。
* 所有 effects 的唯一 source 是 `send` 返回数组；一个 coordinator-owned executor 按
  数组顺序执行并回送 ack，禁止 sink、fire-and-forget 或 adapter 直接回写 Center。

Rollback 默认是 phase-atomic：owner switch、adapter routing、projection 和 guards 一起
回退。唯一例外是 provider effect 已经离开进程（wire response/Auto command/terminal
activation 不可撤销）：先停止新输入并用 ledger/OnceResponder 将 in-flight token 收束到
`delivered`、`deliveryUnknown` 或 neutral finalization，再回退本地 owner；绝不同时恢复
旧 writer。该 exception 必须记录在 phase evidence，并由下一次 fresh observation/review
确认，不能伪造 wire rollback。

## 2. 常用验证命令

以下命令在对应源码和测试存在后执行；本次 artifact convergence 不执行它们：

~~~bash
# 快速编译与全量测试
swift build
swift test

# Center 外部 Interface 的 interaction traces
swift test --filter InteractionCenterTraceTests
swift test --filter InteractionCenterIdentityTests
swift test --filter SessionGenerationAuthorityTests
swift test --filter InteractionCenterOrderingTests
swift test --filter InteractionCenterPrivacyTests
swift test --filter InteractionCenterIngressTests
swift test --filter InteractionRequestAdmissionPolicyTests
swift test --filter InteractionTransportFinalizerTests
swift test --filter InteractionEffectExecutorTests
swift test --filter InteractionTerminalLedgerTests
swift test --filter InteractionVisibilityTests
swift test --filter InteractionPresentationOwnershipTests
swift test --filter InteractionCompletionSurfaceTests
swift test --filter InteractionAutoCompilerTests

# Adapter 与导航 contract
swift test --filter HookTransportAdapterTests
swift test --filter CodexTransportAdapterTests
swift test --filter SessionNavigatorTests
swift test --filter InteractionArchitectureGuardTests
swift test --filter AppleCompanionProtocolCompatTests
swift test --filter ESP32ProtocolTests

# 现有高风险回归
swift test --filter AppStatePermissionFlowTests
swift test --filter AppStateQuestionFlowTests
swift test --filter AppStateAnswerRoutingTests
swift test --filter AppStateAutoApproveTests
swift test --filter HookServer

# 仅检查规划实现的格式/冲突标记
git diff --check
rg -n '<<<<<<<|=======|>>>>>>>' Sources Tests
~~~

如果 SwiftPM 只接受 test target 名称而不接受类名，则用同一目标的全量命令：

~~~bash
swift test --target CodeIslandTests
swift test --target CodeIslandCoreTests
~~~

每个 phase 的最低 gate 是该 phase 专项 test、swift build 和受影响旧回归；Phase 7
还必须跑 swift test 全量。失败时停止推进，不用“暂时跳过”替代 gate。

## 3. Branch / consumer migration matrix

以下矩阵是切换的完整边界。每行只允许一个 target writer；同 phase 内 legacy 仅能读取
projection 或转换为 typed input，不能保留第二个 lifecycle。

| 当前分支/消费者 | 目标 owner 与 phase | 切换证明 |
| --- | --- | --- |
| HookServer byte probe、JSON parse、source/plugin/Cursor/Codex sub-session leave/hide/merge、cwd/remote filters | Ingress/Subsession/Source policy adapters，Phase 2；Center 只收到 post-routing normalized input | alias、malformed、cwd、tracked lifecycle、_ppid/plugin/Codex parent golden tests；raw policy 不进 UI |
| Hook built-in auto tools、always-proceed source、provider defer、Claude Auto branch | Provider policy adapter，Phase 2/5；Center 只接 typed admission/Auto observation | AskUserQuestion 不被 allow-list 绕过；provider defer 无 pending；未知 capability 不静默 bypass |
| 普通 PermissionRequest、ExitPlanMode、AskUserQuestion hook continuation | HookInteractionAdapter + Center registry，Phase 2/3/4；每个 blocking channel 一个 token/OnceResponder | response schema、replay、channel mismatch、disconnect/timeout、continuation once |
| Notification question / plugin question | Question adapter，Phase 4；`displayOnly` 或 `blocking(capabilities)` 必须由 provider contract 声明 | 普通 Notification 不误入队；不稳定来源只有 Dismiss；不把空 payload 叫 Skip |
| ToolUseCache duplicate、TTL、无 ID activity heuristic | EventCorrelationAdapter，Phase 2；无证据不 bulk-allow，改 pending/error 或 typed external progress | shared ID collision、same/different input、cross-generation、TTL、two no-ID requests |
| Codex requestUserInput、serverRequest/resolved、client replacement/close | Codex transport adapter，Phase 4；requestId + client generation 可观察并带 token | r1/r2 独立 resolution，旧 client ack no-op，resolved 不回第二份 response |
| Cursor `cursorPendingQuestion`、run_async/parent transcript guards | NativePromptObservation + reconciliation adapter，Phase 1/5/6；native-owned 无 answer effect | parent mismatch、run_async、pending/clear；Center 不生成 actionable request |
| AppState `permissionQueue`/`questionQueue` 与 approve/deny/answer/skip helpers | Legacy read-only projection + command adapter，Phase 2→6；最终删除 writer | source guard 覆盖所有 append/remove/resume/head index；每个 command 带 RequestID |
| AppState+Plan helpers (`removeFirst`/plain allow/feedback) | PermissionVariant.plan adapter，Phase 3 | regular/plan 共享 ordinal；manual plain allow；无 Skip/head fallback |
| AppState Auto singleton、observedPermissionMode | InteractionSessionContext + AutoCommandAdapter，Phase 5 | per-session requested/observed/confirmed；独立 control channel；旧字段 decode-discard |
| SessionSnapshot reducer/discovery fields | SessionObservationAdapter，Phase 1/5；snapshot 只保留 upstream fact，输出 typed `SessionDisplayObservation` + `SessionNavigationObservation` | all display/route fields mapped; stale revision/generation atomically discarded；waiting→processing 不 resolve；field classification guard |
| Root surface、ApprovalBar、QuestionBar、SessionCard、AskQuestion identity | local InteractionSnapshot + SessionNavigator，Phase 1/6 | typed display facts populate sparse metadata/session ID; navigation snapshot preserves terminal/remote routes; target ID action；共同 retry/feedback/collapse |
| Global shortcuts / current queue head callbacks | prominent RequestID selector adapter，Phase 6 | no prominent = no-op；stale/hidden target 不操作另一个 head |
| Apple Companion publisher/command | versioned redacted projection + compatibility adapter，Phase 6/7 | optional ID/generation/sequence、unknown major、legacy ambiguity、duplicate ack |
| ESP32/BLE one-byte controls | legacy narrow-target adapter，Phase 6/7 | only one unique displayed target；ambiguous/cross-session no-op；旧 opcode 不变 |
| Terminal visibility/retry/AppKit activation | SessionNavigator + VisibilityObservation，Phase 1/7 | 120/320/640ms route preserved；visibility revision/max-age；remote/failure behavior |

**Single-writer rule:** Phase 2 starts one Center registry for all normalized records, even if
old UI remains. Legacy arrays become computed views only; no phase may add a second append,
remove, continuation resume, or queue-head command. A slice is not complete until its row's
writer guard and trace gate pass.

### Review-blocker closure checklist

The 14 adversarial blockers are closed by explicit artifact sections (not by an implied future
implementation):

| # | Blocker | Closure location |
| ---: | --- | --- |
| 1 | canonical request kind; Plan is permission variant | `design.md` §3.1–3.2; Phase 0/3; matrix Plan row |
| 2 | optional typed resolution channel: blocking/displayOnly/nativeOwned | `design.md` §3.2, §4.1, §5.2; Phase 2/4 |
| 3 | single SessionRef generation authority | `design.md` §3.1/3.3; Phase 0/5; generation guard |
| 4 | request-before-observation buffering and expiry | `design.md` §3.1/§4.1; Phase 0/2; ingress traces |
| 5 | one executor, returned effects only | `design.md` §4.3–4.4; global execution rule; executor test |
| 6 | bounded terminal ledger, eviction and retry semantics | `design.md` §5.5; Phase 0; ledger tests |
| 7 | disconnect neutral finalization for non-cancellable continuation | `design.md` §4.2/§5.2; Phase 2/4; OnceResponder contract |
| 8 | exact branch/consumer migration boundary | this §3 matrix, including Hook, ToolUseCache, Codex, Cursor, UI, shortcuts and hardware |
| 9 | per-phase single writer and read-only legacy projection | this §1 and §3; `design.md` §11; every phase gate |
| 10 | adaptive visibility as typed revision/generation input | `design.md` §4.1/§5.4/§6.2; Phase 1/5/7 |
| 11 | independent typed Auto command channel | `design.md` §6.1; Phase 5 and Auto control contract |
| 12 | audience-specific local/redacted projections | `design.md` §5.1/§6.3; Phase 0/4/6; privacy guards |
| 13 | companion version/RequestID/sequence compatibility | `design.md` §6.4; Phase 6/7; companion matrix tests |
| 14 | SessionSnapshot classification plus typed display/navigation projection and operational sync/rollback closure | `design.md` §3.3/§5.1/§6.5/§11; `refs/remotes/upstream/main` (shown as `upstream/main`), GitButler rollback and fixed evidence path in Phase 7/§13 |

## 4. Phase 0：typed model、SessionRef 和 trace harness

### 交付物

1. 在 fork-owned Interaction 模块创建两入口 Center：snapshot（local + redacted
   external，只读）和 `send(InteractionInput) -> [InteractionEffect]`，不注入 effect sink。
2. 创建 closed typed `InteractionRequestKind`（仅 permission/question）；Plan 使用
   `PermissionVariant.plan`，并为 request 定义 blocking/displayOnly/nativeOwned behavior。
3. 创建 `SessionGenerationAuthority`（唯一 open/reopen/close generation owner）、
   `SessionRef`、RequestID（stable/occurrence）、EffectID、opaque TransportToken 和
   typed ReplayProof。
4. 创建 bounded `RequestIngressBuffer`（per SessionKey capacity + TTL），typed
   SessionObservation、NativePromptObservation、VisibilityObservation、snapshot、
   lifecycle、Auto command transaction、NavigationEffect/Feedback。
5. 内置 per-session 跨 kind ordinal、replay proof、stale revision/generation、
   token/effect ledger（TTL/capacity/eviction）、selector、dismiss/reveal、optimistic
   resolution、neutral transport finalization 和 Auto transition 的纯实现。
6. 创建 TestClock、deterministic ID factory、in-memory adapters、唯一 effect executor、
   recording effects，以及 local/external redacted projections。

### 必须先实现的 traces

* basic permission/plan/question arrival、resolve、success、failure；Plan request 的 kind
  永远是 permission variant；displayOnly/nativeOwned 无 resolution effect；
* dismiss/reveal/replay/occurrence/shared tool ID collision；
* `initialOpen`/`providerObservation`/`providerClose`/`explicitReopen` 的首建、幂等重复、
  close 后递增和旧 generation stale ack；
* A(permission -> plan -> question) 与 B 独立 ordering、无 global HOL blocking；
* token-scoped disconnect、OnceResponder neutral finalization、duplicate/late ack、
  effect-before-external、external-before-effect、session close；
* request-before-observation bind order、buffer TTL/capacity overflow；
* Auto native/rules/bypass negative、独立 command channel、observed/requested/delivered/
  confirmed；
* secret question local vs companion/log redaction、companion version/ID compatibility；
* stale observation/visibility、generation replacement 和 old ack no-op；
* effect executor only consumes returned effects、terminal ledger eviction/retry policy。
* `notDelivered` → pending(error) 与 `deliveryUnknown` → awaitingExternalConfirmation 两条
  lifecycle；unknown 不产生第二个 resolution effect。
* completion fact/Surface selection：Center owns semantic surface/completion presentation，
  SwiftUI only renders，completion card never resolves a pending request。
* local `Surface` 与 external `RedactedSurface` 类型隔离；external completion 只有 session/
  revision，不包含 completion message 或 secret request content。

### Gate 和 rollback

~~~bash
swift test --filter InteractionCenterTraceTests
swift test --filter InteractionCenterIdentityTests
swift test --filter SessionGenerationAuthorityTests
swift test --filter InteractionCenterOrderingTests
swift test --filter InteractionCenterPrivacyTests
swift test --filter InteractionCenterIngressTests
swift test --filter InteractionEffectExecutorTests
swift test --filter InteractionTerminalLedgerTests
swift test --filter InteractionVisibilityTests
swift test --filter InteractionPresentationOwnershipTests
swift build
~~~

Owner 是新 Center model；生产 App 无新输入。失败时用 GitButler `but undo` 撤销最近
操作，或由 owner 丢弃该独立 phase commit；不触碰旧 AppState。不得在此 phase 加
production feature flag 或双写。

~~~bash
but undo
# 或：but discard <phase-0-commit-id>
~~~

## 5. Phase 1：SessionNavigator 行为等价提取

### 交付物

1. 定义 Navigator 的生产 Adapter 和 fake Adapter；Center 只产生 NavigationEffect，
   不引入 TerminalActivator/AppKit。visibility detector 只发布带 SessionRef、revision、
   evidence、measuredAt 的 `VisibilityObservation`，不在 Center/UI 同步探测。
2. 将 ApprovalBar、QuestionBar、SessionCard、AskQuestion identity 的点击路径统一
   到 SessionIdentityLine + Navigator seam。
3. 保留 TerminalActivator.activate(session:sessionId:) route、remote no-op、现有
   120ms/320ms/640ms 三次 visibility check、失败声音/shake 和
   autoCollapseAfterSessionJump。
4. Navigator action 携带 RequestID 或完整 SessionRef；不从 queue head 推断目标。

### Gate 和 rollback

~~~bash
swift test --filter SessionNavigatorTests
swift test --filter NotchPanelViewTests
swift test --filter OrcaAndZedActivationTests
swift test --filter AppStatePermissionFlowTests
swift build
~~~

用 fake visibility/activation 验证成功、失败、取消、remote、stale target 和
visible→stale notVisible→unknown 序列。确认四类
调用方不再各自拥有 jump retry Task 后，才移除旧重复实现。失败时整片恢复旧 UI jump
调用，不撤销 Phase 0 model；rollback 使用该 phase 的 GitButler 逆操作，或在已提交
分支上执行：

~~~bash
# Gate 失败且这是最近一次 GitButler 操作
but undo
# 已形成独立 phase commit 时，由 owner 以 GitButler 选择性丢弃该 commit
but discard <phase-1-commit-id>
~~~

实际仓库只使用 GitButler；`but undo` 适用于最近操作，`but discard` 只在 owner 已确认
phase commit 边界后使用。禁止绕过 GitButler 做历史回滚。

## 6. Phase 2：permission lifecycle、token disconnect 和 reconcile projection

### 交付物

1. Hook ingress Adapter 保留现有 byte probe、source/plugin/Cursor/remote cwd 过滤和
   upstream normalization；新增唯一 `SessionGenerationAuthority` 使用的
   `SessionObservation` mapper 和 RequestArrival。request-before-observation 先进入有界
   SessionKey buffer，绑定后按 arrival order 送 Center。
2. Hook Adapter 注册每个 blocking request 的 continuation/connection 为 opaque
   TransportToken + adapter-owned OnceResponder；displayOnly 无 channel；没有安全 neutral
   response 的 provider quarantine，不伪造 deny。
3. Center 独占 normalized permission/plan/question registry、跨 kind queue、RequestID/
   replay、dismiss/reveal、resolution/terminal ledger；Phase 2 即让 question record 进入
   同一 registry，即使旧 Question UI 暂时只读取 projection。HookServer 停止直接调用
   AppState permission methods。旧 queues 只生成 projection。
4. transport disconnect/timeout 按 token 定位单 request；Center 产生一次
   `finalizeTransport(providerSafeNeutral)`，adapter finish responder once 后丢弃 token；
   半关闭不当作 true disconnect；session-wide channel close 只能经显式 typed evidence。
5. Center 的 first production policy 使用 legacyProminent，新 request 行为与当前等价；
   effect 只经 coordinator-owned executor 返回数组执行。
6. SessionSnapshot 仍是 upstream reducer 的 owner；mapper 只向 Center 投影必要事实，
   不在本 phase 把 fork 字段塞入 snapshot。ToolUseCache 无 ID activity 不能 generic bulk
   allow，须保留 pending/error 或 typed external evidence。

### Gate

~~~bash
swift test --filter InteractionCenterTraceTests
swift test --filter InteractionCenterOrderingTests
swift test --filter InteractionCenterIdentityTests
swift test --filter HookTransportAdapterTests
swift test --filter InteractionRequestAdmissionPolicyTests
swift test --filter InteractionTransportFinalizerTests
swift test --filter HookServerCwdFilterTests
swift test --filter HookServerCursorPpidFallbackTests
swift test --filter AppStatePermissionFlowTests
swift test --filter AppStateAnswerRoutingTests
swift build
~~~

必须特别检查：A1/A2/B1 在 A1 token disconnect 后只有 A1 受影响；同 session
permission/plan/question 不出现两个数组的隐式 drain；replay 只在 proof 且旧 token
已终结后替换。Hook adapter contract 还需验证 OnceResponder neutral finalization exactly
once、`TransportFinalizationResult.quarantined` 的安全分支、oversize/parse-safe response、
half-close、no-ID activity policy 和 buffer overflow 行为。

### Rollback

Phase 2 切换 Hook ingress 的唯一 owner 后，如果 gate 失败，整片把 routing 恢复到旧
AppState permission owner；Center 不接生产 arrival，保留 Phase 0 测试。禁止只恢复某
个 queue 方法而留下 Center/旧 owner 双写；legacy projection 可保留但不能重新成为 writer。

~~~bash
but undo
# 或：but discard <phase-2-commit-id>
~~~

## 7. Phase 3：Plan variant 与 Skip 移除

### 交付物

1. ExitPlanMode 由 provider Adapter 归一化为 `kind == .permission` 且
   `PermissionVariant.plan` 的 typed request，保留 plan text、allowed prompt count、
   suggested mode。
2. Plan action 只使用 allowPlan(suggested/manual)、deny-with-feedback 和 Dismiss；
   manual 的 wire effect 是历史 plain allow，但按钮和 Interface 都不叫 Skip。
3. Plan 与 regular permission 共享 SessionRef queue ordinal、identity、dismiss、
   replay、optimistic resolving 和 failure path。
4. provider-specific updatedPermissions/setMode/feedback 编码只在 Adapter。

### Gate 和 rollback

~~~bash
swift test --filter InteractionCenterTraceTests
swift test --filter AppStatePermissionFlowTests
swift test --filter AppStateAutoApproveTests
swift test --filter NotchPanelViewTests
swift build
~~~

加入 source guard，禁止新 UI/Center enum 出现 `.plan` kind、skipPlan、
skipCurrentQuestion 等通用 Skip 语义。plan manual 的 effect 必须是一次 plain allow；
Dismiss 不产生 resolution effect。失败时只回滚 Plan slice 到 regular permission variant，
不能重新引入 Skip。

~~~bash
but undo
# 或：but discard <phase-3-commit-id>
~~~

## 8. Phase 4：Question lifecycle、capability 和 Codex token

### 交付物

1. Hook Notification、AskUserQuestion 和 Codex app-server requestUserInput 都归一化
   为 typed question content，进入 Center 的同一 registry/跨 kind queue；每个 source
   明确声明 `blocking(capabilities)` 或 `displayOnly`。Cursor transcript 走
   `nativeOwned` NativePromptObservation，不创建 actionable request。
2. Codex Adapter 以 request ID + client generation 建立 opaque token；不把 closure 或
   JSON-RPC client 放进 Center。Hook/Codex continuation 由 adapter-owned OnceResponder
   负责 neutral finalization。
3. Question 始终由 Center 提供 Dismiss；只有 typed capability 存在时才提供
   reject、abandon 或 continueWithoutAnswer，不能显示通用 Skip。displayOnly 只能
   dismiss/reveal，无 response effect。
4. Answer 使用稳定 key/position、multi-select 和 custom input 的强类型值；secret
   content 只供本机 renderer，companion/log 走 redacted projection。
5. serverRequest/resolved、peer/CLI terminal resolution 和 replacement client 都
   变成 external resolution/typed transport event；迟到 ack 不产生 response。
6. 旧 question queue 和 AppState question methods 在切换后停止写入。

### Gate

~~~bash
swift test --filter InteractionCenterTraceTests
swift test --filter InteractionCenterPrivacyTests
swift test --filter CodexTransportAdapterTests
swift test --filter AppStateQuestionFlowTests
swift test --filter AppStateCodexRequestUserInputTests
swift test --filter AppStateAnswerRoutingTests
swift test --filter JSONLTailerCursorQuestionTests
swift build
~~~

需要覆盖 Hook disconnect 只终结其 token、OnceResponder neutral finalization、Codex client
replacement 不接受旧 generation、external-before-effect/effect-before-external 两种竞态，
displayOnly/nativeOwned 无 response，以及 Question Dismiss 不改变 CLI 等待。失败时整体
恢复旧 question owner；不要在旧 queue 上叠加新的 capability 判断。

~~~bash
but undo
# 或：but discard <phase-4-commit-id>
~~~

## 9. Phase 5：reconcile seam、per-session Auto 和 legacy field 移除

### 交付物

1. 将所有 SessionSnapshot/discovery/app-server 事实通过一个
   SessionObservationAdapter 投影给 Center；mapper 只消费共享
   `SessionGenerationAuthority`，携带 SessionRef generation、revision/sequence、CLI
   visibility、provider capability、`SessionDisplayObservation` 和
   `SessionNavigationObservation`，以及可选 `CompletionObservation`。display facet 必须
   覆盖 project/cwd/source/status/tool、subagents、recent messages、git、remote/provider IDs；
   navigation facet 必须覆盖 terminal route metadata、remote route 和 provider session ID。
   mapper 不传完整 SessionSnapshot/raw JSON，且用同一 revision 原子组装两 facet；stale 或
   duplicate generation/revision 同时丢弃。waiting→processing 不 resolve request；只有
   upstream completion fact 才允许 Center 生成 completion surface。
2. Center context 以 SessionRef 存储 observed mode、requested mode、phase、in-flight
   effect 和 Auto capability；完全移除全局 autoApproveSessionId 假象。按字段分类把
   permissionMode 留为 upstream fact，把 observedPermissionMode 移至 context。
3. native auto 优先；不支持时才是显式 acceptEdits + addRules；bypass 必须 explicit
   dangerous intent + capability。由独立 `AutoCommandAdapter`/control token 提交有序
   AutoCommandTransaction；不得消费 pending permission continuation。
4. effect delivery ack 只能说明 transaction 已提交；后续 CLI observation 才可变成
   confirmed。disconnect/unknown 清除本地 requested/context，不能显示已生效；visibility
   通过带 generation/revision/max-age 的 VisibilityObservation 输入，过期即 unknown。
5. 旧 sessions.json 的 optional observedPermissionMode 继续可读但不再写出、不回填
   Center-owned state；保留其它 terminal/provider/closed-subagent persistence。先把
   cursorPendingQuestion 迁移到 NativePromptObservation，再移除 fork/native field。
6. stale revision/generation observation 只能 no-op/diagnostic，不能复活已关闭 session。

### Gate

~~~bash
swift test --filter InteractionCenterTraceTests
swift test --filter InteractionCenterIdentityTests
swift test --filter InteractionCenterOrderingTests
swift test --filter InteractionSessionReconciliationTests
swift test --filter InteractionSessionObservationMappingTests
swift test --filter InteractionSessionNavigationObservationTests
swift test --filter InteractionSessionDisplayProjectionTests
swift test --filter InteractionSessionStaleRevisionTests
swift test --filter InteractionAutoModeTests
swift test --filter InteractionAutoCompilerTests
swift test --filter InteractionPersistenceCompatibilityTests
swift test --filter InteractionNativePromptObservationTests
swift test --filter InteractionFieldClassificationTests
swift test --filter InteractionSessionSnapshotOwnershipTests
swift build
~~~

另外加入旧 sessions.json fixture：旧文件可加载 display/navigation facts；启动后
interaction registry 为空，等待 CLI 重新上报。确认 Core SessionSnapshot、reducer、
persistence 新写路径、Auto tests 均不再拥有 observedPermissionMode；field-classification
guard 覆盖 native prompt、Cline/subagent bookkeeping 不被当作 generic resolution。旧
snapshot、persistence、Auto 和 primary-source fixtures/行为在上述新 suites 中改写，
不作为 Phase 5 owner gate。

`InteractionSessionObservationMappingTests` 断言所有字段只经 mapper 进入两个 typed facets；
`InteractionSessionNavigationObservationTests` 断言 local navigation 保留现有 terminal/
remote routes；`InteractionSessionDisplayProjectionTests` 断言 facts 可填充 local session
card；`InteractionSessionStaleRevisionTests` 断言旧 generation/revision 不会部分更新 facts
或 route。

### Rollback

Auto/field removal 必须作为一个 phase 回滚：恢复旧 Auto owner 和 legacy decode，不恢复
旧 permission/question 双写，也不把新 requested state 写回 SessionSnapshot。

~~~bash
but undo
# 或：but discard <phase-5-commit-id>
~~~

## 10. Phase 6：SwiftUI、shortcuts 和 companion 收敛

### 交付物

1. NotchPanelView 只读取 `InteractionSnapshot.local`，按 canonical permission/question
   （含 plan variant）渲染 typed content；所有 action 带 RequestID，session card navigation
   带完整 SessionRef。companion/ESP32 只能读取 `snapshot.external`。
   local session cards consume the typed display facts and navigation snapshot; no view reads
   SessionSnapshot or reconstructs terminal routes.
2. ApprovalBar、QuestionBar、SessionCard 和 AskQuestion 统一
   SessionIdentityLine/Navigator；移除 queue.firstIndex、permissionQueue、
   questionQueue、continuation 和 provider response branch。
3. AppDelegate global shortcuts 先读取 prominentRequest 再发送 RequestID action；无
   prominent request 时 no-op，不操作任意 queue head。
4. Apple Companion 使用 additive optional protocol fields（RequestID、session generation、
   observed sequence、supported major/minor）；unknown major 在 action dispatch 前拒绝。
   v1 无 ID command 只在唯一可见 target 且 session 匹配时适配，其他情况 no-op/refresh。
   ESP32/BLE 旧一字节 opcode 同样只允许唯一 displayed target；不扩展旧 opcode 语义。
   两者都消费 redacted projection/pending counts，不直接读取 request content/queue，不绕过
   Center resolve；Mac remains Dismiss/reveal owner。
5. AppState 只转发 upstream observation、user input 和 effects；HookServer 只执行
   ingress/token/effect adapter。

### Gate

~~~bash
swift test --filter InteractionArchitectureGuardTests
swift test --filter NotchPanelViewTests
swift test --filter GlobalHotKeyManagerTests
swift test --filter ESP32BridgeManagerQueueTests
swift test --filter AppleCompanionPayloadTests
swift test --filter InteractionCenterPrivacyTests
swift test --filter InteractionProjectionIsolationTests
swift test --filter InteractionNavigationProjectionTests
swift test
~~~

Architecture guards 必须失败于以下回流：UI 直接写 queue/dismiss/Auto、action 不含
RequestID、UI 组协议 JSON、Center/AppState 持有 continuation、SessionSnapshot 出现
fork-only 字段、三张卡片重新声明 jump retry、companion 引用 local snapshot 或忽略
protocol major/target sequence。外围 projection 的 secret trace 必须只输出 placeholder。

### Rollback

回滚整个 UI/外围 seam 到 snapshot 前的旧调用方；Center 仍是已接入 request owner，
不可仅把一张卡片切回 queue head，否则会造成两套 writer 和 stale action。

~~~bash
but undo
# 或：but discard <phase-6-commit-id>
~~~

## 11. Phase 7：adaptive CLI-first 和清理

### 交付物

1. 在所有 legacy-prominent behavior-equivalence traces 通过后，把统一 selector 切到
   adaptive CLI-first：只接受带 SessionRef generation/revision/max-age 的
   VisibilityObservation；目标 CLI pane/tab visible 时 badge/notification，not visible 或
   unknown/过期时主动展开。
2. 保留 explicit reveal、failure prominence、session badge/pending counts 和 dismiss
   可发现性；不增加 permission/plan/question 三套策略开关。
3. 清除旧 permission/question queue、dismiss session Set、global Auto methods 和
   upstream hotspot 的 fork branches；只保留必要单一接入区与 adapter。
4. 执行一次以 `refs/remotes/upstream/main` 为 target 的 sync rehearsal，证明 fork-owned module 不需要
   人工修改，并将证据固定保存到
   `.trellis/tasks/08-31-fork-architecture/research/upstream-sync-evidence.md`：记录
   upstream revision、命令、冲突文件数、semantic conflict 数、每热点 seam 数和
   fork-owned module 是否变化。

### Gate

~~~bash
swift test
swift build
swift test --filter InteractionArchitectureGuardTests
git diff --check

# 只读演练；不修改当前分支。由 gate owner 在 review 时将输出/摘要写入固定 evidence path。
SYNC_BASE=$(git merge-base HEAD refs/remotes/upstream/main)
git merge-tree "$SYNC_BASE" HEAD refs/remotes/upstream/main
~~~

演练记录至少包括：

~~~text
upstream revision:
hotspot file -> seam count / conflict count / semantic-conflict count
fork-owned modules changed: yes/no + reason
manual policy decisions required: list
~~~

git merge-tree 输出只用于分析，不代表功能或结构 gate 自动通过；gate owner 将摘要写入
`.trellis/tasks/08-31-fork-architecture/research/upstream-sync-evidence.md`。若需要真实
临时 worktree，先由 owner 确认目标路径和清理方式，不能对 workspace/root 做破坏性操作。

### Rollback

Adaptive policy 是独立 rollback 单位：问题出现时只恢复 legacyProminent selector，不
回滚 Center owner、token safety 或 typed lifecycle。清理旧路径的提交必须在 adaptive
行为 gate 后单独提交，便于整体逆操作。

~~~bash
but undo
# 或：but discard <phase-7-adaptive-commit-id>
~~~

## 12. Test design 和 evidence ledger

### Center trace harness

每条 trace 保存：

* redacted input projection；
* send 返回的 ordered effect projection；
* snapshot local/external 的 revision、SessionRef generation、request lifecycle、presentation、
  queue ordinal、counts、error kind；
* deterministic RequestID/EffectID，不保存真实 UUID、secret 文本或 raw protocol。

Trace 严禁通过 @testable 读取 private registry、queue array、continuation、effect ledger
或 AppKit。必须断言唯一 executor 只执行 returned effects、OnceResponder 只 finalizes
一次、terminal ledger TTL/capacity 可重现。旧白盒 queue tests 在对应 Center trace 覆盖并且
owner 切换后删除或改写，遵循 replace-don't-layer。

### Adapter contract

Center trace 不能替代这些 Adapter tests：

| Adapter | 必须证明 |
| --- | --- |
| Hook ingress/transport | aliases/filter/merge 保留；request-before-observation buffer；half-close 不触发 disconnect；token disconnect 精确定位；OnceResponder neutral finalization exactly once；各 provider response schema；oversize/parse safe |
| Codex transport | request ID/client generation；answer result schema；resolved 不回包；replacement 不接受旧 ack |
| Session mapper/generation | shared generation authority；source/provider generation、revision、PID/native namespace 规则复用；request-before-observation bind；projection 不含 fork state；stale close 不复活 |
| Auto control | independent control token；ordered native/rules/bypass commands；delivery/confirmed distinction；no permission continuation |
| Navigator/visibility | activation route、remote no-op、三次 visibility check、VisibilityObservation revision/max-age、failure feedback、auto-collapse |
| SwiftUI/companion | local vs redacted projection；action target ID/sequence/version；无 queue/raw protocol；empty/stale/ambiguous legacy state；secret redaction |

### 结构 gate

在 Phase 6/7 增加 InteractionArchitectureGuardTests 或等价 source guard：

* AppState/HookServer/View 不再写 Center-owned queue/dismiss/Auto；
* HookServer 只有 normalization/token/effect 接入；
* raw JSON/protocol strings 只在 provider Adapter/codec；
* SessionGenerationAuthority 是唯一 generation writer；SessionSnapshot 不出现 requested/
  dismissed/navigation/observed fork fields；permissionMode 与 observedPermissionMode 的
  field classification 正确；cursorPendingQuestion 只经 NativePromptObservation；
* 所有 request UI action 带 RequestID，导航带 RequestID/SessionRef；
* Approval/Question/SessionCard 不复制 retry/shake/collapse 状态机；
* companion 只能消费 redacted projection，且 unknown major/stale sequence/ambiguous legacy
  commands 不执行；
* 只有一个 coordinator-owned effect executor，Center 无 sink、continuation 或 network object；
* terminal ledger 有 TTL/capacity/eviction，Auto 有独立 control channel；
* 没有 generic stringly request kind/action framework。

## 13. Upstream sync 验收

实现完成且所有 tests 通过后，以当前 `refs/remotes/upstream/main` 做一次无破坏 rehearsal。验收不是
“文件没有冲突”这一单一数字，而是：

1. upstream 改动 Hook、session、terminal 或 UI 后，冲突主要落在单一连续 Adapter seam；
2. 需要人工理解 fork policy 的 semantic conflicts 有明确清单且不散布在多个热点；
3. fork-owned Interaction 模块无需为了吸收 upstream 事实而修改；
4. SessionSnapshot 仍只有 upstream facts，AppState/HookServer/NotchPanelView 没有新的
   fork policy branch；
5. 每个 exception（第二接入区、临时 bridge）都有 design rationale、owner 和删除
   phase，不成为未记录的长期 seam。

## 14. 完成定义

只有同时满足以下条件，task 才能通过 planning gate 并交给 owner start review：

* PRD、design、implement 与实际 settled decisions 一致，无未决产品决策；
* 两入口 Interface、closed typed kind/action、SessionRef generation、token-scoped
  disconnect、privacy redaction、cross-kind ordering 都有 trace/contract evidence；
* 每个 phase 的唯一 owner、rollback boundary 和专项命令在实现时执行并记录；
* 全量 swift test/build、architecture guards 和 sync rehearsal 在实现时通过；
* acceptance matrix 中无“未验证”项；
* owner gate review 接受三份 artifact 后，才允许 task start；本文件不会自动启动 task。
