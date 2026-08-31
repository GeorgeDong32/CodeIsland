# InteractionCenter 迁移闭环矩阵

本文是对 08-31-fork-architecture 规划的代码核对补充。目的不是再描述一个理想模块，而是把当前每个等待/显示/解决通道落到明确的 owner、迁移切片和可观测测试上。所有行都以当前源码为证据；target owner 是未来设计建议，不表示本阶段已经修改了代码。

## 1. “闭环”定义

一个分支只有同时满足以下条件才算迁移闭环：

1. 入口有一个明确的归一化输入（provider、session generation、kind、correlation、sensitivity）。
2. 一个唯一状态 owner 保存 pending、presentation 和 resolution lifecycle；旧 queue 不再同时写。
3. 外部结果可以区分 user command、CLI/provider external resolution、transport failure、stale observation。
4. transport adapter 对每个 TransportToken/EffectID 至多执行一次，且 Center 不持有 continuation 或网络对象。
5. Snapshot 只读投影能被 SwiftUI、快捷键、companion 和诊断读取，不需要了解 reducer 内部结构。
6. 至少有一条 input trace 覆盖正常、replay、dismiss、跨 session、断开、失败和重启/旧观察。

当前最关键的闭环缺口是：Hook disconnect 按 session 批量 drain、无 tool ID 的 activity heuristic 会自动 allow、多数 companion command 忽略 sessionId、Codex requestId 只藏在 closure、Plan 和 companion 仍按 queue head 操作。这些不是 UI 重排问题，而是 resolution identity 尚未封闭。

## 2. 当前问题来源、阻塞通道与 resolution channel

HookEvent 会接受多个 event/session/tool ID 别名，并把完整 raw JSON 留在事件中（Sources/CodeIslandCore/Models.swift:166-230）。HookServer.routeKind 只把 PermissionRequest、特定 Gemini/Antigravity PreToolUse 和带显式 question/options 的 Notification 分成 permission/question（Sources/CodeIsland/HookServer.swift:305-319）；QuestionPayload 明确拒绝问号 heuristic（Sources/CodeIslandCore/Models.swift:386-418）。

| Source / request | 当前入口和判定 | 当前是否阻塞、谁持有等待 | 当前 resolution channel | 目标 owner / 迁移约束 | 必须锁定的测试 |
|---|---|---|---|---|---|
| 普通 Claude/fork PermissionRequest | HookServer permission 分支，最终 AppState.handlePermissionRequest（HookServer.swift:741-801；AppState.swift:1512-1618） | 是；HookServer Task 等 CheckedContinuation | Hook response JSON：allow/deny；由 adapter resume hook | Center 保存 normalized permission request；Hook adapter 只绑定 TransportToken、编码 response、exactly-once resume | 新请求、同 ID replay、同 ID 不同 input、并行无 ID、dismiss 后仍 pending、transport failure |
| ExitPlanMode | 同一 PermissionRequest；Plan helper 读取 permission_suggestions（AppState+Plan.swift:7-31） | 是；仍是 hook continuation | Auto accept setMode、plain allow、deny + feedback，均是 PermissionRequest response | Center 中是 permission 的 plan variant；provider response adapter 保留 setMode/feedback 编码；Plan 不得再 removeFirst/head-only | mode suggestion 优先级、plain allow 真正 dequeue、dismiss 不 resolve、RequestID action 不误伤别的 permission |
| AskUserQuestion（Claude hook） | PermissionRequest 路由中特殊 toolName，进入 handleAskUserQuestion（HookServer.swift:765-775；AppState.swift:1975-2097） | 是；hook continuation 被 QuestionResolution.hook 保存 | allow + updatedInput（questions/answers，Qoder 不接收 scalar answer；Pi 可带 details），或 deny | Center question request 携带 source capability；Claude adapter 负责 answer key、schema 和 deny；不能把它和普通 permission 共享无类型 action | 多题顺序、重复 question key、Qoder schema、Pi details、deny、空 payload immediate allow、secret redaction |
| Notification question（旧/插件 question） | 仅 rawJSON.question 为 String 才由 routeKind 识别；QuestionPayload.from 同时读取 options（HookServer.swift:305-319；Models.swift:410-418） | 当前按 blocking 处理；handleQuestion 保存 hook continuation（AppState.swift:1933-1972） | Notification + answer；drain 时 {} | 先与各 provider 确认 Notification 是否真的等待；稳定者声明 answer capability，不稳定者只能 Dismiss。不得默认推断空 answer 是 skip | 明确 question、普通 Notification 文本不入队、answer、dismiss、source 未支持时 ack、CLI 已自行继续时不误答 |
| Gemini / Google Antigravity PreToolUse approval | source normalized 后，PreToolUse 也 route 为 permission（HookServer.swift:305-313） | 是，除非 source policy immediate allow | Hook PermissionRequest response | source normalization/transport 在 adapter；Center 只接 normalized permission | 两个 source alias、PreToolUse 进入 permission、普通 PreToolUse 不误入 permission |
| Codex app-server item/tool/requestUserInput | JSON-RPC request method 单独 dispatch（AppState+CodexAppServer.swift:230-259） | 是；server->client request 等 JSON-RPC response | response id=requestId，result answers；skip/abandon 发 empty answers（AppState+CodexAppServer.swift:264-380） | Codex adapter 必须显式保存 requestId、client generation、thread/session；Center 不可只凭 synthetic HookEvent 识别 | request id、question id answer key、secret、queued behind another session、no client、empty answer |
| Codex serverRequest/resolved | notification dispatch；按 threadId 找 session（AppState+CodexAppServer.swift:230-245,358-372） | provider/native 已解决；CodeIsland 不应回复 | remove matching request，不发 response | 这是 external resolution observation，必须带 requestId + generation；不能只按 session/thread 批量删 | 同 thread 两 request、不同 requestId、stale resolved、resolved 后重复 user action |
| Codex app-server disconnect | observer 停止时 invalidate Codex questions（AppState+CodexAppServer.swift:135-151） | Codex channel 断开；hook queue 应继续 | 丢弃 Codex-only request，hook continuation 保留 | Codex adapter 以 client/transport generation 定位；不得调用全 session drain | Codex 与 hook 混排、旧 client disconnect 不清新 client question、恢复后旧 ack 不生效 |
| Cursor AskQuestion / AskUserQuestion | JSONL transcript tail 解析 tool_use，排除 run_async（JSONLTailer.swift:508-575）；AppState.applyCursorQuestionSignal 要求 transcript parent == session（AppState+TranscriptTailer.swift:126-170） | 是 Cursor 自己的 UI wait，但 CodeIsland 没有 response channel | 无 CodeIsland resolution；用户必须在 Cursor UI 回答 | Center 不应生成 actionable pending；使用 NativePromptObservation/displayWait，带 native-owned 标记 | 主 session pending/clear、subagent transcript 忽略、run_async 不阻塞、Cursor UI 提示无 answer button |
| Provider-native / Codex auto-review defer | PermissionRequest 但 CodexPermissionRules 判断应由 provider 处理（HookServer.swift:321-327,777-780） | 不在 CodeIsland 阻塞；向 provider 返回 {} | provider 自己的 review/TUI | adapter 的 defer policy；Center 不创建 pending，也不声称 resolved | Codex defer、AskUserQuestion 不 defer、其它 provider 不误 defer |
| 内置安全 tool | tool 在 Settings autoApproveTools 中即刻 allow（HookServer.swift:120-123,741-751） | 不阻塞 | provider-specific simple allow（AppState+HookResponses.swift:5-21） | tool capability/response adapter；不能绕过 source/session generation | 工具名单、Codex 不含 suppressOutput、无 UI/no queue |
| always-proceed source（Cursor YOLO、Antigravity Turbo 等） | source allow-list，AskUserQuestion 特意排除（HookServer.swift:125-143,754-763） | 不阻塞 | plain allow JSON | provider capability adapter；question 必须仍进入对应 question channel | alias normalization、AskUserQuestion 不被静默 allow、非白名单不 bypass |
| malformed/empty AskUserQuestion | 解析不到 askItems 时构造 updatedInput 并 immediate allow（AppState.swift:1995-2068） | 不阻塞；没有可展示 request | PermissionRequest allow + empty answers/updatedInput | provider adapter 可保留 malformed fallback；Center 接受 normalized no-op outcome，而非创建空请求 | 缺 questions、空 question、Qoder/Pi schema、continuation exactly once |
| 不带 question/options 的 Notification | routeKind 归为 event；processRequest 调 handleEvent（HookServer.swift:803-816） | 不阻塞 | {} ack | Event/session reconciliation adapter | question-like prose 不进入 question queue |

重要语义：当前 handlePermissionRequest 会 drain 同 session 的 questions，而 handleQuestion 会 drain 同 session 的 permissions；AskUserQuestion 会 drain 两者（AppState.swift:1537-1539,1954,2071-2072）。这与 PRD 的“跨 kind 有序序列、除非 provider 明确 superseded 不得隐式 drain”冲突，必须在 permission/question 切片中作为显式兼容决策，不可在 Center 移植时无声保留。

## 3. HookServer policy branch closure

HookServer 目前同时包含 ingress normalization、subsession routing、用户过滤、provider policy、transport lifecycle。目标不是把整个文件复制进 Center，而是把每个分支归到唯一 adapter 或 Center 输入。

| 当前分支 | 代码锚点 | 当前效果 | 目标归属 | Closure / architecture guard |
|---|---|---|---|---|
| Cursor/plugin/Codex sub-session pre-routing | HookServer.swift:550-651；processRequest 调用在 654-665 | mode leave/hide/merge；可重写 session_id、隐藏 response、标记 Codex child | SubsessionRoutingAdapter + SessionReconciliation；只把最终 normalized event 送 Center | Center 不读取 raw _ppid/plugin marker；merge/hide golden tests 保留，HookServer 仅一个 ingress seam |
| malformed JSON | HookServer.swift:667-670 | parse_failed response | HookTransportAdapter | no Center input；response once |
| unsupported source | HookServer.swift:702-706 | {} 并丢弃 | Source/Ingress adapter | unsupported source cannot create session/request；test all aliases |
| excluded cwd substring | HookServer.swift:708-715；pure helper 145-160 | {} 并丢弃背景插件 hooks | Ingress policy adapter | filtering before Center；保留 HookServerCwdFilterTests |
| remote cwd allow-list + tracked lifecycle bypass | HookServer.swift:718-734；helpers 163-207 | 非匹配 remote event 丢弃；tracked SessionEnd/Stop/Permission/Notification 等绕过 | RemoteIngressPolicy adapter | test missing cwd, workspace_roots, tracked session and stale session; never move remote security policy into UI |
| webhook fire-and-forget | HookServer.swift:736-739 | 在 route 前外发，不增加 UI wait latency | Webhook observer adapter | Center trace 不应等待 webhook；failure 不改变 resolution |
| built-in autoApproveTools | HookServer.swift:745-751 | immediate provider response | ProviderPolicy/HookResponse adapter | policy must be data/capability injected; no Center queue |
| always-approved source | HookServer.swift:754-763 | non-AskUserQuestion immediate allow | ProviderPolicy adapter | AskUserQuestion negative guard remains tested |
| AskUserQuestion special route | HookServer.swift:765-775 | monitor connection, await hook question continuation | HookInteractionAdapter normalizes question + transport token; Center owns lifecycle | no continuation in Center; exactly-once response effect |
| provider defer | HookServer.swift:777-780 | {} and provider handles review | Codex/provider capability adapter | trace has no pending; AskUserQuestion cannot be deferred |
| Auto active, non-Claude | HookServer.swift:782-790 | silent allow | Provider Auto adapter; Center only requested/observed state | no silent bypass if capability unknown; test provider-specific response |
| Auto active, Claude | HookServer.swift:782-793 | deactivate local Auto then enqueue/show permission | Center Auto context + Claude adapter | transition is requested→waiting confirmation; no claim CLI mode changed before observation |
| normal permission | HookServer.swift:795-801 | continuation parked and response sent after UI | HookInteractionAdapter + Center | TransportToken points one request; action effect includes EffectID |
| Notification question | HookServer.swift:803-811 | continuation parked | Question adapter + Center | capability says answer/reject only when protocol proven |
| non-blocking event | HookServer.swift:813-816 | AppState reducer + {} | SessionReconciliation adapter | no pending interaction created |
| peer disconnect | HookServer.swift:819-856 | cancelled/failed calls AppState.handlePeerDisconnect(sessionId) | HookTransportAdapter emits transport event with exact TransportToken; Center resolves only token owner | current session-wide drain is a blocker; add regression with two pending requests same session |
| five-minute timeout | HookServer.swift:858-869 | removes context, cancels connection; does not currently produce typed Center failure | HookTransportAdapter timeout effect | timeout must be request-scoped and Center state return to pending/error, never silently deny/retry dangerous action |
| send response/cancel | HookServer.swift:872-880 | marks responded before connection.cancel | HookTransportAdapter exactly-once executor | response mark and effect ack tested under action+disconnect race |

Sub-session policy is more than one merge/hide branch and must stay visible in the migration:

- Cursor Task transcript routing first decides leave/hide/merge at HookServer.swift:576-594. Leave may use the _ppid fallback at :578-580; hide returns a provider-appropriate hidden response at :581-583; merge rewrites to the resolved parent at :584-593.
- Plugin events with _via_plugin are separately handled at HookServer.swift:600-618. Hide returns hiddenPluginResponse; merge rewrites session_id only when source, _ppid and a matching active parent are proven.
- Codex/native child events are handled at HookServer.swift:620-649. Missing child/parent metadata is a no-op; hide returns hidden response; merge requires a parent and adds agent/subagent markers before serialization.
- The cheap byte probes and Cursor separate-mode fast path at HookServer.swift:550-572 are transport/ingress cost policy, not Center behavior. Center must only receive the post-routing normalized event and any typed hidden response effect.

monitorPeerDisconnect currently installs one stateUpdateHandler for each connection but calls a session-level drain; if a session has two in-flight requests, either cancellation can resolve both. This is a direct violation of TransportToken ownership, not merely an implementation detail.

## 4. AppState + ToolUseCache policy branches

The cache is both correlation memory and resolution policy today. Its data should be split: identity evidence stays in the provider/event adapter; lifecycle transitions are explicit Center inputs.

| Branch | Anchors | Current behavior | Future owner | Required mapping/tests |
|---|---|---|---|---|
| Cache only normalized PreToolUse with non-empty toolUseId | AppState+ToolUseCache.swift:23-39 | stores session, tool, description, input, timestamp keyed by toolUseId | Hook EventCorrelationAdapter | unit: aliases, empty ID ignored, TTL clock |
| Completed event PostToolUse/PostToolUseFailure/PermissionDenied | lines 42-53 | removes cache entry if matching ID | EventCorrelationAdapter emits ToolCompleted observation | Post/PostFailure/PermissionDenied matrix; unrelated ID no-op |
| Trae exception | lines 55-60,172-185 | shouldKeepQueuedPermissionForCompletedEvent returns true for trae/traecn/traecli | Provider capability policy; not generic Center heuristic | Trae vs all other source golden traces; explicit reason |
| Matching queued permission stale | lines 55-78 | removes one queue entry, resumes deny, advances/collapses surface | Center receives external/superseded resolution with evidence; Hook adapter executes deny effect only if required | no duplicate resume; non-head request preserves card; failed resolution observable |
| Activity with no correlatable tool ID | lines 81-132 | Pre/Post/Stop/UserPromptSubmit for same session allow-removes all queued no-ID permissions | High-risk provider adapter policy; Center accepts typed externalProgress only with evidence | two no-ID requests same session must not both be auto-allowed without provider contract; conflict with no-content-guessing PRD |
| Pending cache TTL prune | lines 135-139 | drops records older than 15 minutes | Correlation adapter clock/retention | deterministic time test; stale cache cannot mutate new session generation |
| Duplicate same toolUseId | lines 141-170 | if tool/input equal, deny old continuation and replace in same queue slot; differing input is distinct | Adapter proves replay; Center rebinds lifecycle to new TransportToken, preserving RequestID/dismiss/order | same id same input, same id different input, cross-session same id, old transport termination before rebind |
| Backfill from cache | lines 187-200 | fills missing session currentTool/toolDescription only | Session projection adapter, not interaction lifecycle | cache enrichment never changes Request identity; missing record no-op |

The current PreToolUseRecord does not include provider generation or a transport token. A recycled session/tool ID can therefore collide after restart. The migration must add generation at the adapter boundary and make toolUseId only one correlation component; never recover replay from content fingerprint alone.

## 5. UI, surface, shortcut and companion consumers

The following are all direct consumers found in production sources. They are migration clients, not independent owners of queue semantics.

| Consumer | Current direct access | Target interface | Migration/test mapping |
|---|---|---|---|
| Root SwiftUI surface switch | NotchPanelView.swift:198-260 reads AppState.surface, pendingPermission/pendingQuestion and queue positions; invokes approve/deny/answer/skip/dismiss | read-only InteractionSnapshot.surface + highlighted RequestID; actions send typed InteractionInput | render snapshot fixture; stale surface, dismissed still count, non-head session card |
| ApprovalBar | NotchPanelView.swift:1005-1199; callbacks from root lines 219-223 | Approval projection with request identity, plan variant and resolution capabilities; shared SessionIdentityLine/Navigator | action trace carries RequestID; allow/always/deny/dismiss exactly once |
| QuestionBar | NotchPanelView.swift:1218-1510; root callbacks lines 241-244 | Question projection + explicit capabilities (answer, dismiss, provider-named abandon/reject); no universal Skip | legacy Notification, AskUserQuestion, Codex, native-owned all render different capabilities |
| Question identity header | NotchPanelView.swift:1260-1286 only shows source/cwd if present and tap handler | always render SessionIdentityLine with session ID; use SessionNavigator | missing source/cwd still shows ID and jump affordance |
| SessionCard inline approval | NotchPanelView.swift:2325-2482 reads permissionQueue and invokes AppState methods; ExitPlan view uses surface at 2440-2446 | snapshot contains per-session pending summary and action IDs; Plan action named plain allow/approve-with-mode, dismiss separate | list with two sessions; card action resolves selected request, not queue head |
| SessionCard Cursor native wait | NotchPanelView.swift:2329-2333,2526-2547 reads cursorPendingQuestion and shows hint | native-owned display projection, no actionable Center request | no answer/skip command; clear signal removes display wait |
| SessionIdentityLine AUTO indicator | NotchPanelView.swift:2108-2190; indicator tap calls toggleAutoApprove | read Auto projection and send AutoToggle(sessionRef), not mutate snapshot | per-session requested/observed/unknown rendering; no global singleton |
| Plan preview/options | NotchPanelView+Plan.swift:9-97,100-219; AppState+Plan.swift:7-106 | Plan is permission variant projection and provider capability | remove Skip label/action; plain allow must be traced as resolution |
| Global shortcuts | AppDelegate.swift:226-254 targets surface.approvalSessionId/questionSessionId but actions currently call AppState; ShortcutAction includes skipQuestion (Settings.swift:559-585) | shortcut adapter resolves highlighted RequestID from snapshot and sends typed action | stale highlighted ID is no-op/error; no implicit global head; remove generic question skip |
| Panel click/activation | PanelWindowController.swift:313-329 directly collapses surface; active terminal lookup 673-680 reads activeSessionId/session | presentation/navigation adapters consume snapshot and SessionNavigator | click outside never hides unresolved data incorrectly; terminal activation uses existing three-check behavior |
| AppState top-level state | AppState.swift:118-231 owns sessions, two queues, surface, activeSessionId and computed head accessors | after cutover AppState holds upstream session projection only; Center is queue/presentation owner | architecture guard forbids queue/dismiss/Auto fields in AppState |
| Codex app-server adapter | AppState+CodexAppServer.swift:264-356 appends queue and writes surface; 358-372 removes on resolved | Codex adapter normalizes requestId/thread/client generation; Center emits response effect | response id and client generation tested independently from UI |
| Apple Companion publisher | AppleCompanionPublisher.swift:23-25 callbacks, 123-141 command switch | Companion adapter decodes wire command into RequestID action; no direct AppState head calls | old/new command compatibility; stale sequence/request rejected |
| Apple Companion/ESP32 state projection | ESP32StatePublisher.swift:189-249 chooses pending head; 346-482 builds payload and secret placeholder | projection adapter consumes read-only snapshot, includes pending RequestID when supported | state output golden tests; secret never leaves redacted projection |
| ESP32 interactive retries | ESP32StatePublisher.swift:161-175 uses delivery key; 296-309 key is source/status/tool/workspace/messages fingerprint | new protocol generation must use request identity; fingerprint remains display retry key only | two same-looking requests cannot share interactive identity |
| Buddy raw control | ESP32Protocol.swift:86-88,122-157 uses one-byte approve/deny/skip opcode | keep legacy display-only command adapter; only resolve when current legacy target is unambiguous, otherwise no-op | firmware compatibility tests, ambiguity test, no wrong-session resolution |
| DebugHarness | DebugHarness.swift:106-169,206-211 etc writes sessions/surface directly | fixture adapter builds Center input/seed snapshot; production guard excludes it from ownership rule | preview still renders; no product state API leakage |

There are also direct queue operations in AppState+Plan.swift:35-37,65-73,83-95 and Codex/Auto extensions. A grep-based architecture guard must cover all permissionQueue, questionQueue, surface =, approvePermission, denyPermission, answerQuestion, skipQuestion, toggleAutoApprove references, not only NotchPanelView.swift.

## 6. Apple Companion and ESP32 protocol compatibility

### 6.1 Current Apple Companion wire contract

AppleCompanionStatePayload has version, sequence, session/source/status/tool/workspace/messages, pendingAction, question, sessions and updatedAt (Sources/CodeIslandCore/AppleCompanionPayload.swift:118-190). The command has version, type, optional sessionId/source/answer, but no request ID or sequence (lines 192-214); it also has no dismiss command, while skipCurrentQuestion is the only question-oriented control. The publisher advertises protocol "1" (AppleCompanionPublisher.swift:27-34), always increments sequence and sends state (lines 105-120), but command handling ignores command.sessionId and forwards global callbacks (lines 123-140). answerCompanionQuestion then indexes questionQueue[0] (AppState.swift:1776-1806).

Current tests prove enum/raw-value and old state payload compatibility, but do not prove identity safety: AppleCompanionPayloadTests.swift:39-61; AppleCompanionPayloadCompatTests.swift:10-33. The existing version is required by the decoder (payload line 177; command synthesized Codable has the same requirement), yet no supported-version gate exists. A future incompatible integer can decode and be acted upon.

Bluetooth summary hardcodes version 1 and includes no request identity (AppleCompanionBluetoothPeripheral.swift:228-276). It redacts only through the already projected question text; the summary must never be changed to read raw HookEvent.

### 6.2 Proposed additive compatibility shape

Keep existing raw values and fields for old clients. Add, as optional fields:

- state: pendingRequestID, pendingRequestKind, sessionGeneration, and (if useful for command echo) lastAcceptedSequence;
- command: requestID, sessionId, sessionGeneration, observedSequence, and protocolVersion/minor;
- only use a new major version when wire meaning changes. Existing version 1 remains decodable.

Rules:

1. New CodeIsland sends requestID whenever an actionable pending request exists. RequestID is provider/session-generation/kind/correlation, not a content hash.
2. New companion sends requestID plus sequence it observed. Center resolves only if ID, session generation and current state match; stale/unknown ID is a visible no-op or error, never fallback to another session.
3. A legacy command with no requestID may use a compatibility adapter only when the current displayed pending target is unique and its optional sessionId matches. If ambiguous, reject safely and request fresh state. It must not call approveCurrentPermission/answerCompanionQuestion against arbitrary queue head.
4. Unknown major version is ignored with diagnostic; unknown optional fields are ignored. Known version with missing requestID is legacy mode, not permission to guess.
5. Sequence ordering is monotonic per publisher; stale state must not overwrite a newer companion display. Commands include observed sequence so a user action from an old card can be rejected.
6. Secret questions retain the existing placeholder behavior (ESP32StatePublisher.swift:234-240,443-480); IDs are not secret and may be exposed only if they cannot encode raw prompt text.
7. BLE/ESP32 one-byte controls cannot carry RequestID. Treat them as legacy controls: resolve only an unambiguous currently displayed target, and expose no cross-session selection. A future framed protocol can add version + request ID without reusing 0xF0-0xF2 semantics.

Compatibility test matrix:

| Case | Expected result |
|---|---|
| v1 state decoded by new app, no question field | succeeds with nil question/sessions empty (existing test) |
| new state optional requestID decoded by old client | old client ignores field and still displays known approval/question |
| new command with ID to matching pending request | one Center action/effect |
| new command with stale ID, wrong generation, wrong sequence | no resolution; state refresh/error |
| legacy command with one unique visible target | compatibility action resolves that target once |
| legacy command with two pending sessions or hidden/dismissed head | no-op/reject; never head fallback |
| unknown major version | ignore safely, diagnostic, no queue mutation |
| duplicate command / reconnect replay | EffectID idempotency, one provider response |
| secret pending question over MC/BLE/ESP32 | placeholder only; request metadata does not leak prompt |

## 7. SessionSnapshot field classification

The current snapshot mixes provider observations, display caches and fork interaction/reconciliation state (SessionSnapshot.swift:78-162). Classification below is intentionally explicit so the migration does not simply move the mixed struct behind a new name.

### 7.1 Upstream/provider fact or mapped lifecycle observation

These are facts or event-derived lifecycle fields that the Center may consume read-only through a reconciliation projection:

| Fields | Evidence | Target |
|---|---|---|
| status, currentTool, toolDescription, lastActivity, startTime | SessionSnapshot.swift:78-83,104; reduceEvent maps upstream event names at :931-989 and status cases at :1097-1204 | Upstream SessionSnapshot / SessionReconciliation projection. Center sees observation, not raw reducer internals |
| cwd, model, source, providerSessionId | fields :82-84,146,154; SessionStart applies source/cwd/model/provider metadata at :1205-1235 | Keep in upstream snapshot; mapper is the only Center seam |
| permissionMode | field :84; reducer updates and records mode at :1229-1232 and :1528 | Keep as current CLI-reported fact; Auto adapter compares it with requested mode |
| transcriptPath | fields :107-110; populated by hooks/discovery and consumed by JSONLTailer | upstream/session identity fact; native prompt observer may use it |
| terminal metadata: termApp, itermSessionId, ttyPath, kittyWindowId, tmuxPane, tmuxClientTty, tmuxEnv, termBundleId, cmuxSurfaceId, cmuxWorkspaceId, zellijPaneId, zellijSessionName, weztermPaneId, supersetWorkspaceId, supersetPaneId, orcaTerminalHandle, orcaWorktreeId, cliPid, cliStartTime | fields :119-145; persistence preserves activation metadata at SessionPersistence.swift:14-35,61-78 | keep as upstream/session discovery facts; SessionNavigator consumes read-only |
| sessionTitle/sessionTitleSource, remoteHostId/remoteHostName | fields :152-156; title/source and remote identity are provider/discovery metadata | keep as mapped upstream fact; display formatting remains outside Center |

subagents is a provider/session reconciliation projection, not a Center queue. It can remain on the upstream projection while adapter-owned subagent mapping is extracted. closedSubagentIds is a tombstone needed by Cursor/Codex folding (SessionSnapshot.swift:91-103,168-210); it should move to SessionReconciliationContext if upstream does not own it, but must not be treated as a user interaction request.

### 7.2 Derived display projection

These values are useful to display and companion projections but are not authoritative resolution state:

| Fields / values | Evidence | Target |
|---|---|---|
| toolHistory, totalToolCallCount | fields :89-90; recordTool appends bounded history at :391-397 | Display projection/cache; Center receives only request tool summary where needed |
| lastUserPrompt, lastAssistantMessage, recentMessages | fields :105-118; reduceEvent appends messages at :1007-1112 and :1121-1184 | Transcript/display projection; not Request identity |
| displayName, projectDisplayName, remoteDisplayName, shortModelName, mascotSource and similar computed properties | computed display helpers begin SessionSnapshot.swift:400 onward | UI/companion presentation adapter |
| gitBranch, gitIsWorktree | fields :159-162; asynchronous GitBranchReader update AppState.swift:1065-1087 | Display metadata adapter; never resolution policy |
| primarySource, active/total counts and queue-derived labels | SessionSnapshot summary at :906-915; queue positions AppState.swift:220-228 | InteractionSnapshot projection, not upstream snapshot |

### 7.3 Fork interaction, native-owned display, or provider-specific reconciliation state

| Field | Evidence of current fork ownership | Target and migration rule |
|---|---|---|
| observedPermissionMode | peak/escalate-only field and mutator SessionSnapshot.swift:84-88,364-375; persisted at SessionPersistence.swift:41,80 and restored AppState.swift:2828; read by Auto at AppState+AutoApprove.swift:154-166 | Remove from Core snapshot/reducer/persistence per PRD. Move to InteractionSessionContext.Auto.observedMode; retain legacy decode only to discard safely, never restore as confirmed CLI fact |
| cursorPendingQuestion | explicitly documented display-only, transient, never persisted at SessionSnapshot.swift:111-116; set/cleared by AppState+TranscriptTailer.swift:137-168 | NativePromptObservation/display context, not actionable Center request. Preserve parent-path/run_async guards and no answer effect |
| isYoloMode | field :157-158; AppState detects Cursor setting at :1435-1436; UI displays YOLO at NotchPanelView.swift:2420-2425 | Provider capability/observation adapter. Do not use it as generic Auto confirmation or put it in Center request lifecycle |
| taskRoundEnded | Cline-specific ordering guard and reset/drop logic in SessionSnapshot.swift:958-967,1133-1138 and TranscriptTailer.swift:196-202 | Cline SessionReconciliationContext; it is not generic status and must not block other providers |
| interrupted | Stop/cancel-derived display marker at SessionSnapshot.swift:1116-1119,1140-1203; UI tags it at NotchPanelView.swift:2334-2342,2420-2422 | Session display/completion projection. Center may observe lifecycle but does not resolve pending request solely from it |
| closedSubagentIds | insertion/tombstone bookkeeping at SessionSnapshot.swift:91-103,168-210; folding guard in reducer :1147-1163 | Subsession/session reconciliation context unless proven upstream-owned. Never use it to infer user resolution |

The key distinction is permissionMode versus observedPermissionMode: the former is a current upstream fact; the latter is a fork-owned peak-memory used to choose an Auto default. Restoring the latter after restart can make the UI claim a mode that the CLI no longer has, so persistence removal is a security/state-correctness requirement, not cleanup.

## 8. Migration slices and trace/test acceptance

Each slice has one state writer. Until a slice is complete, the old path remains the sole writer for that request kind; there is no long-lived double resume.

| Slice | State/owner change | Required trace and unit tests | Architecture guard / upstream sync acceptance |
|---|---|---|---|
| M0 model + trace harness | Add pure RequestID, SessionRef/generation, InteractionInput/Effect/Snapshot and provider capability descriptors; no UI/Hook change | input sequence golden tests: arrival, per-session ordering, dismiss, reveal, resolve, replay, stale ack, external resolve, failure; effects have EffectID + RequestID | Core module must not import SwiftUI/NWConnection/CheckedContinuation; test only public Interface |
| M1 session reconcile seam | Map SessionSnapshot observations into Center; separate native prompt and display projection | revision/generation stale observations; waiting -> processing does not resolve a RequestID; Cursor pending/clear | one mapper seam; SessionSnapshot no new fork fields; sync a current upstream SessionSnapshot change against mapper only |
| M2 Hook transport/correlation | Hook adapter owns normalization, continuation, TransportToken, response encoding, disconnect/timeout; Center owns pending lifecycle | exact-once response under approve+disconnect/replay; no-ID activity policy explicit; tool cache TTL and replay traces | HookServer leaves one ingress seam; no permissionQueue/dismiss writes; upstream hook changes only adapter mapper |
| M3 permission + plan | ordinary permission and ExitPlanMode variant move to Center; AppState+Plan becomes capability/response adapter | allow/deny/always/dismiss; Plan setMode/plain allow/feedback; queue does not cross-drain kinds without explicit evidence | no Plan removeFirst; no generic Skip; architecture guard catches old queue write |
| M4 questions | Notification/AskUserQuestion normalized as question variants; provider answer/reject capabilities explicit | multi wizard, answer key, Qoder/Pi payload, secret, native-owned exclusion, malformed fallback | UI no protocol branching; provider schema only adapter; question always Dismiss even without extra action |
| M5 Auto | per-session Auto context tracks requested/observed/capability; native auto preferred; explicit addRules fallback | Claude mode, acceptEdits, bypass explicit opt-in, unknown mode, request failure, session switch/disconnect | no global auto singleton; observedPermissionMode removed from snapshot/persistence |
| M6 SwiftUI/navigation | views consume InteractionSnapshot and send RequestID actions; SessionNavigator shared | Approval/Question/SessionCard same navigation success/failure/shake/collapse; stale action no-op; AskQuestion identity with missing cwd/source | grep guard forbids view/AppDelegate direct queue mutation and protocol-specific response JSON |
| M7 companion | additive RequestID/version fields; legacy adapters isolated | table in §6.2, plus sequence/replay/ambiguous legacy/secret tests | old v1 payload and command fixtures remain; new fields optional; ESP32 old byte markers unchanged |
| M8 cutover/rehearsal | remove old queues and fork fields; upstream sync validates conflict budget | full test suite, architecture guards, trace corpus replay, persistence migration from legacy file | rehearse merge/rebase with upstream/main; record conflict file count, semantic conflicts, and whether fork-owned modules changed |

### Minimum trace corpus

The following traces should be checked at the Center Interface, not by asserting private arrays:

1. permission A(s1) → dismiss A → permission B(s2) ⇒ B can be selected/revealed; A remains pending and badge-visible.
2. permission A(s1, id=t) → identical replay ⇒ one RequestID, old transport closed, dismiss preserved, one effect at most.
3. permission A(s1, id=t,input=x) → same t,input=y ⇒ two requests; no content-fingerprint merge.
4. question Q(s1) → permission P(s1) ⇒ no implicit drain unless provider emits typed superseded evidence.
5. two no-ID permissions same session → PostToolUse/Stop ⇒ no generic bulk allow; provider adapter must state whether evidence is sufficient.
6. A(s1) + B(s1) on separate transports → disconnect A ⇒ B remains pending.
7. Codex request id=r1 → user answer → response id=r1; old client disconnect/reconnect cannot send r1 twice.
8. Codex serverRequest/resolved requestId=r1 while r2 remains ⇒ only r1 external-resolves.
9. Cursor native pending ⇒ display wait only; no Center resolution action; new transcript clears it.
10. companion v1 head command, new ID command, stale ID command, unknown version, duplicate command ⇒ safe compatibility behavior.

### Existing tests to retain or migrate

Existing coverage already gives useful fixtures: AppStatePermissionFlowTests.swift (including provider defer), AppStatePermissionGateTests.swift (duplicate/replay), AppStateQuestionFlowTests.swift and AppStateAnswerRoutingTests.swift (multi-session action routing), AppStateAutoApproveTests.swift, AppStateCodexRequestUserInputTests.swift, AppStateCodexAppServerTests.swift, AppStateCursorQuestionTests.swift, JSONLTailerCursorQuestionTests.swift, HookServerCwdFilterTests.swift, RemoteCwdFilterTests.swift, HookServerCursorProbeTests.swift, HookServerCursorPpidFallbackTests.swift, AppleCompanionPayloadTests.swift, AppleCompanionPayloadCompatTests.swift, ESP32ProtocolTests.swift and SessionPersistenceTests.swift. Their assertions should move from private AppState queue state to trace outputs as each slice lands; protocol raw-value and legacy fixtures remain permanent.

## 9. Review blockers and assumptions requiring explicit sign-off

1. Notification question semantics are not proven uniform across all supported CLIs. A question/options payload is syntactically detectable, but blocking behavior and legal empty/deny response are provider contracts. The Question adapter capability table must be populated before enabling extra resolution actions.
2. The orphan activity heuristic currently resolves all no-ID permissions in a session with allow. This conflicts with conservative identity and can approve the wrong request when multiple requests overlap. Either obtain provider evidence or change the outcome to pending/error; do not blindly transplant it.
3. Session-level peer disconnect is too broad for the PRD’s TransportToken model. A bridge channel can carry more than one request; the adapter needs request-scoped close evidence or an explicit channel-wide typed event.
4. Plan helpers and companion callbacks bypass expected session/request identity. approvePlanWithMode, skipPlanAndResume, denyPermissionWithFeedback and answerCompanionQuestion currently use queue head. They must not be considered migrated merely because generic expectedSessionId helpers exist.
5. Codex requestId is captured in a closure and serverRequest/resolved ignores its requestId. The adapter must retain the ID as inspectable request metadata and compare it on external resolution.
6. Existing version: Int is not a compatibility gate. Additive optional fields are safe only if unknown major versions are rejected before action dispatch; old clients must never receive a new enum value with changed meaning.
7. cursorPendingQuestion is currently in SessionSnapshot despite being native-owned display state. Removing it too early can regress transcript-tail behavior; move it through a typed NativePromptObservation seam first, then remove the field.
8. observedPermissionMode is persisted as if it were session fact although it is fork peak-memory. Legacy files need a decode-and-discard migration; restoring it as confirmed mode violates CLI-first ownership.
9. The PRD says all cards share identity/navigation, but QuestionBar currently renders its header only when source/cwd exists (NotchPanelView.swift:1260-1286). The closure requires an explicit session ID projection even for sparse metadata.
10. ESP32’s one-byte controls cannot satisfy arbitrary RequestID semantics. Compatibility mode must deliberately narrow their target to the one unambiguous displayed request; otherwise the hardware surface should be display-only until a framed protocol exists.
11. Apple Companion has no current dismiss command. If dismiss is exposed remotely, it must be an additive RequestID-scoped presentation action; if not, the companion remains a resolution-only surface and the Mac UI remains the only dismiss/reveal owner.

No product source or authoritative planning artifact is changed by this research document.
