# Fork 架构与上游同步策略

## Goal

形成一份经讨论确认、可分阶段实施的 fork 架构与上游同步策略：在保留 Auto 模式、跨区域跳转、permission/plan/question 可 dismiss，以及 CLI-first 使用方式的同时，把自有行为集中在少量稳定 seam 后，降低持续吸收 upstream hook、session 与 UI 增强时的冲突和维护成本。

本次继续固化规划与实现契约；实现授权已经给出，但 task 仍保持 `planning`，直到
gate review 接受这些 artifacts 后才可 start。本文编辑本身不启动实现。

## Confirmed Facts

- 仓库以上游 remote-tracking ref `refs/remotes/upstream/main` 为基准（通常显示为
  `upstream/main`），当前本地 `main` 相对上游存在长期 fork 改动。
- 自有增强已经部分集中到 `AppState+AutoApprove.swift`、`AppState+Plan.swift`、`AppState+HookResponses.swift` 和 `NotchPanelView+Plan.swift`。
- 主要冲突热点仍是上游的大型文件：`AppState.swift`、`NotchPanelView.swift`、`HookServer.swift` 与共享的 `SessionSnapshot.swift`。
- permission、plan 与 question 都具有“等待用户处理、可在面板或 CLI 查看、可跳回所属 session”的共同交互形态，但当前状态和 UI 路径并未统一。
- Approval、Question 与 SessionCard 中存在相似的 terminal 激活、可见性验证、失败反馈和自动收起逻辑。
- `QuestionBar` 没有复用显示短 session ID 的 `SessionIdentityLine`；它只在 source 或 cwd 存在时渲染临时 context 行并附加跳转手势，因此 AskQuestion 的顶部身份与跳转能力随元数据完整度变化。
- `ApprovalBar`、`QuestionBar` 与 `SessionCard` 分别实现了相似但独立的激活、重试验证、失败 shake 和自动收起逻辑，当前没有统一的 `SessionNavigator` Interface。
- 当前 permission dismiss 以 session ID 记录；dismiss 只隐藏面板，不应隐式解决 CLI 中仍 pending 的请求。
- Trellis 已在仓库初始化，当前任务保持 `planning` 状态。

## Requirements

- 用 `codebase-design` 的 Module、Interface、seam、Adapter、Depth、Leverage 与 Locality 术语描述目标设计。
- 明确 upstream-owned 与 fork-owned 行为及数据的归属，限制上游热点文件中的自有接入点数量和复杂度。
- 明确 permission、plan、question 的请求身份、生命周期、dismiss/reveal 与 resolution 语义。
- 明确 Auto 模式的产品语义、安全限制、session 范围及各 CLI 差异。
- 明确跨区域跳转覆盖范围、成功判定、失败反馈和跳转后的面板行为。
- 明确 CLI-first 呈现策略及默认值。
- 形成兼容现有持久化数据和渐进迁移的方案，避免一次性大改。
- 设计测试应以目标深模块的 Interface 为测试面，不依赖内部字段。

## Constraints

- 设计目标按以下顺序权衡：降低长期 upstream 同步冲突 > 保持自有交互行为一致 > 减少首轮重构量。
- 优先吸收 upstream 的 hook、CLI、terminal 与 session 能力增强，不复制其归一化或探测实现。
- 自有功能不能依赖长期维护大段 upstream 文件副本。
- dismiss、跳转和 Auto 不得意外 resolve、deny 或丢失仍在等待的请求。
- 实现授权不等于立即 start；必须先通过本任务的 gate review，确认三份 artifact、
  migration matrix、trace plan 和 rollback boundary。

## Product Ownership Decisions

- 产品语义上，CLI 是 session、request 与 permission mode 的 source of truth；CodeIsland 是增强显示和快捷控制界面。
- 实现上采用分属所有权：CLI/upstream event 拥有请求是否存在、是否解决及 CLI 模式事实；CodeIsland 拥有 dismiss/reveal、展示优先级、跳转反馈和本地呈现偏好。
- CodeIsland 发出的 allow、deny、answer 或 Auto mode change 是命令，不应仅凭按钮点击永久假定 CLI 状态已经改变；后续 CLI 事件负责确认事实。
- 第一阶段目标是建立完整 `InteractionCenter`，统一 permission、plan、question 的生命周期，而不是先落一个临时的 fork policy seam。
- `InteractionCenter` 拥有规范化 request、queue、dismiss/resolution、Auto 与呈现策略等逻辑生命周期；Hook adapter 保留 connection/continuation、协议编码、disconnect/timeout 与 adapter-owned OnceResponder 的本地一次 finalization 职责；不对无 idempotency 的 wire 宣称 exactly-once。
- `InteractionCenter` 通过声明式 effect 请求 adapter 完成传输，adapter 再把成功、失败或断开事件反馈给它；Center 不直接持有 Swift continuation 或网络对象。
- Request identity 采用来源限定的稳定身份：由 CLI adapter 使用可靠的 upstream request/tool ID，并在需要时加入 session、kind、tool/input discriminator；只有 adapter 能证明关联时才合并 replay。
- 确认是 replay 时保留原 request 的 dismiss 状态和队列位置，旧 transport 必须明确终结后再绑定新 transport；不得重复执行已经完成的用户命令。
- 缺少可靠 upstream ID 时，为每次到达生成进程内 occurrence ID，并保守地视为新请求；不得仅凭内容 fingerprint 合并。
- App 重启后不根据请求内容猜测 pending identity，而是等待 CLI 重新上报事实。
- Dismiss 只改变当前 RequestID 的 presentation，不 resolve、deny、dequeue 或改变 CLI 状态。
- Dismissed request 仍通过所属 session 的类型 badge 与待处理数量保持可发现；用户可以恢复详情或跳转 CLI。
- 同一 request 的 replay 继承 dismissed 状态；同 session 的新 RequestID 不继承旧 dismiss，而是重新执行呈现策略。
- 第一阶段不提供 session 级 snooze；App 重启后也不恢复 pending request 的 dismiss 状态。
- CLI-first 的目标默认策略为自适应：目标 CLI pane/tab 可见时只更新 badge/通知；目标不可见或无法可靠判断时主动展开。
- 架构迁移的第一个检查点保持当前“新 request 主动展开”的行为，先验证 InteractionCenter 行为等价；自适应策略在后续独立步骤启用，避免把状态迁移与 UX 改变混在同一回归面。
- 用户手动 reveal 的 request 在 resolve 或再次 dismiss 前保持突出显示。
- 不为 permission、plan、question 分别增加默认策略开关；可在后续设计中评估统一的 always-prominent / adaptive / badge-only 设置。
- Auto 是 per-session 能力，不是全局单例，也不是脱离 CLI permission mode 的 CodeIsland 私有自动批准器。
- 每个 session 分别跟踪 CLI 已确认的 `observedMode`、CodeIsland 发出的 `requestedMode` 与 provider capability；只有 CLI 后续事实能把 transitioning 状态确认成已生效。
- Auto 优先请求 provider 原生 `auto`；不支持时才使用明确配置的 `acceptEdits + addRules` adapter。
- UI-facing `AutoModeIntent` 是 closed typed public intent，仅有 `enable`、`off` 和显式
  `bypassExplicit`；capability compiler 决定 provider command，不向 UI 暴露字符串命令。
- `bypassPermissions` 不得成为普通 Auto 的静默 fallback，只能在用户显式启用危险模式且 CLI capability 允许时使用。
- 开关 Auto 只作用于所选 session；断开时清理 CodeIsland 状态，但不得声称已改变无法连接的 CLI。
- 无法确认 mode 时显示 requested/unknown，而不是已生效；不得继续维持“全局只追踪一个 Auto session”的 UI 假象。
- 所有 permission、plan、question 与 session 卡片必须复用同一 session identity/navigation 模块；顶部 session ID 的显示和可点击性不得依赖 source/cwd 是否齐全。
- 跳转增强的目标是修复公共 session identity 在不同卡片中的能力不一致，不要求把所有内容区或整张交互卡都变成点击目标。
- 共享 `SessionNavigator` 必须与现有可靠跳转行为对齐：继续使用既有 `TerminalActivator.activate(session:sessionId:)` 路由、三次可见性验证、失败声音/shake，以及 `autoCollapseAfterSessionJump` 设置；本任务不重新定义 fallback 产品规则。
- AskQuestion 的公共 session identity 接入同一 Navigator Interface；迁移后 Approval、Question、SessionCard 不再分别实现跳转重试和收起状态机。
- Plan 卡片移除 `Skip`；该动作实际执行 plain allow 并 dequeue，不得继续以类似展示动作的名称与 `Dismiss` 并列。
- Question 卡片始终提供 `Dismiss`，并移除跨来源的通用 `Skip`。
- Question adapter 只有在能给出明确、可测试的协议语义时，才声明额外 resolution capability；UI 使用来源对应的明确名称（例如 reject/abandon/continue-without-answer），不得把 Notification 空回答、AskUserQuestion deny 与 Codex 空 answers 都叫作 Skip。
- 某来源无法稳定表达额外 resolution action 时，只显示 `Dismiss`；这是允许且优先于猜测协议语义的 fallback。
- Fork 派生状态存放在独立、以完整 `SessionRef`（provider/session ID/generation）关联的
  `InteractionSessionContext`；upstream `SessionSnapshot` 作为 CLI/session 事实的只读输入。
- Auto requested/confirmed 状态、request identity、dismiss/presentation 和 navigation capability 不再加入 `SessionSnapshot`。
- 现有 fork 字段 `observedPermissionMode` 在迁移完成后从 Core snapshot、reducer、persistence 与相关测试中移出；当前 `permissionMode`、terminal metadata 和 provider session ID 等上游事实继续留在 snapshot。
- `InteractionCenter` 通过单一 reconcile seam 消费 upstream snapshot；未来 upstream 提供等价事实时，只替换该映射，不扩散到 UI/Hook 调用方。
- `SessionObservation` 必须携带 typed `SessionDisplayObservation` 与
  `SessionNavigationObservation`：display facet 覆盖 project/cwd/source/status/tool、subagents、
  recent-message previews、git、remote/provider IDs；navigation facet 覆盖既有 terminal
  route metadata、remote route 和 provider session ID。两者只由 mapper 从 upstream facts
  生成，不把完整 `SessionSnapshot` 或 raw JSON 穿过 Center seam。
- mapper 对 display/navigation 使用同一 SessionRef generation 与 revision；Center 只原子应用
  current generation 的严格更新 revision，stale/duplicate 同时丢弃。local snapshot 可消费
  完整 typed facets，external projection 只输出 redacted labels/counts，不输出 cwd、消息预览、
  terminal handles、PID 或 raw provider identifiers。
- SessionRef generation 只有共享的 `SessionGenerationAuthority` 可以创建或递增；
  SessionSnapshot、HookServer、Codex adapter 不得各自从字符串推导 generation。request
  先于 observation 到达时，ingress 进入按 `(provider, providerSessionID)` 有界、带 TTL
  的等待区，绑定明确 generation 后按原到达顺序送入 Center；过期/溢出只做 provider-safe
  neutral finalization，不换绑另一个 session。
- generation authority 只接受 typed `initialOpen`、`explicitReopen`、
  `providerObservation`、`providerClose` evidence；同一 `(SessionKey, sequence)` 重复
  open/observe/close 必须幂等，只有已 close 后的显式 reopen 才递增 generation。普通 request、
  disconnect 或同名 session 不得 reopen。
- Request 的 resolution channel 是可选且强类型的：`blocking(capabilities)` 必须有
  唯一 response token，`displayOnly` 必须无 channel 但仍可 dismiss/reveal，
  `nativeOwned` 只产生 typed native-prompt display observation，不进入可操作 request
  queue。没有稳定安全响应的 provider 不得伪造 deny/empty answer 来填 channel。
- `InteractionCenter` 的外部写 Interface 采用 reducer 风格：所有 session observation、
  request arrival、native/visibility observation、user action 与 transport event 都通过
  `send(InteractionInput) -> [InteractionEffect]`；session removal 先由 generation authority
  转为带 generation 的 closed observation，不能走第二条无身份的删除 API。
- 所有调用方读取统一、只读的 `InteractionSnapshot`；SwiftUI 不得直接修改 queue、dismiss 或 resolution 状态。
- completion fact 由 upstream/session observation 提供；`InteractionCenter` 独占 semantic
  surface、prominent request、completion-card selector 与 collapse timing，SwiftUI 只按
  snapshot 渲染，Navigator 只报告物理跳转结果，不得通过 completion card resolve request。
  local `Surface` 可以包含 completion message；external 只接收独立的 `RedactedSurface`
  （session/revision，不含 message），避免 surface projection 绕过 privacy boundary。
- `send` 只返回有序声明式 effects；不存在注入 Center 的 effect sink，也不存在第二个
  adapter 自行执行 effects。唯一 executor 由 coordinator 消费返回数组、按顺序 dispatch，
  并把 typed ack 再送回 Center。
- 测试以 input 序列、输出 effects 和 snapshots 为测试面；内部 reducer/策略属于 implementation 或内部 seam，不扩充外部 Interface。
- 用户 resolution action 后，UI optimistic hide，但 request 内部进入 `resolving`；只有 adapter success ack 或 CLI external resolution 才结束生命周期。
- 每个 resolution effect 同时携带唯一 EffectID 与 RequestID；adapter exactly-once 执行并反馈 success/failure，resolving 期间重复点击不得产生第二个 effect。
- transport failure 使 request 回到 pending 并突出错误，不自动重试危险决策；snapshot 可在 session badge 显示短暂提交中状态。
- `notDelivered` 与 `deliveryUnknown` 是不同的 typed lifecycle：前者回到
  `pending(error)`，后者进入 `awaitingExternalConfirmation`，不得自动 retry 或伪造已解决；
  只有 provider external resolution 或明确 not-delivered 事实才能继续。
- 非取消 continuation 的终结由 transport adapter-owned `OnceResponder` 完成：disconnect/
  timeout 只产生 token-scoped `finalizeTransport(providerSafeNeutral)` effect，不是 deny；
  没有可证明 neutral response 的 channel 不得注册为 blocking。承诺仅限本地 callback 一次
  finalization 和每个 EffectID 一次提交尝试，不宣称网络 wire exactly-once。
- terminal/dedup ledger 必须有显式 TTL、容量和 oldest-first eviction；命中或已淘汰的旧
  ack 都不得重开 request，`deliveryUnknown` 不得自动 retry。
- 同 request replay 绑定现有生命周期，不重新决策；peer/CLI 已自行解决时标记 externally resolved，并取消未执行的重复响应。
- Pending queue 按 session 独立拥有；同一 session 内保持 provider 到达顺序，不同 session 之间不得产生 head-of-line blocking。
- 全局 presentation selector 只选择当前突出 request，优先级为 resolving failure、explicit reveal、普通 waiting request，再按到达时间排序；回答后通常优先推进同 session 下一项。
- Session list 同时展示各 session 的 pending 数量和类型；dismiss 一个 session 的 request 不影响其他 session 浮现。
- 全局快捷键与所有 UI action 必须携带 RequestID，只作用于当前突出 request，不得隐式操作全局 queue head。
- `InteractionCenter` 采用 hybrid Interface：核心 request kind 关闭为强类型的 permission
  与 question，Plan 是 permission 的 `PermissionVariant.plan`；resolution action 使用关闭
  枚举。provider adapter 可以声明强类型 capability descriptor，但不得把任意字符串
  request/action 或通用 JSON envelope 引入 Center。
- canonical kind 只有 `permission` 与 `question`；Plan 必须是
  `PermissionVariant.plan`，不设 `.plan` kind、独立 queue 或 `skipPlan`。Request 行为
  明确区分 blocking、displayOnly、nativeOwned，channel/token 与 session/request identity
  一致性由 Center 验证。
- Request identity 使用带 provider、session generation、kind 和 correlation 的 `SessionRef`/`RequestID`；同一个 provider session ID 重开时 generation 必须递增，旧 observation、transport token 和 effect ack 不得复活新 session。
- pending queue 是每个 `SessionRef` 一个跨 permission/plan/question kind 的有序序列；同 session 保持 provider 到达顺序，除非 adapter 以明确 RequestID 证据发送 superseded/external resolution，不得因另一个 kind 到达而隐式 drain、deny 或越过旧 request。
- disconnect、timeout 和 replacement 都按 `TransportToken` 定位；默认 token 只绑定一个 request。session 级 channel 关闭必须由 adapter 以明确 typed evidence 表达，不能用 session ID 批量误伤其它 pending request。
- request content 和 snapshot 使用 typed display values 与 sensitivity 标记；本机 UI 可以读取 secret question 的必要内容，但 companion、日志、trace projection 和其它低信任 Adapter 必须输出 redacted placeholder，不能通过 raw JSON 绕过脱敏。
- upstream observation 必须带 provider generation，且按 revision/sequence 丢弃 stale observation；仅 status 从 waiting 变为 processing 不能猜测某个 RequestID 已 resolved。
- adaptive CLI-first 的 visibility 是带 generation、revision、evidence 和 max-age 的
  `VisibilityObservation` input；过期视为 unknown，unknown 与 not-visible 主动展开，
  visible 只 badge/notification，explicit reveal 永远优先。
- Auto 必须走独立 typed `AutoCommandAdapter`/control token 和有序 command transaction，
  不得借用 pending permission continuation；delivery 只表示 adapter 接收，后续 CLI
  observation 才能确认 mode。
- 本机与低信任消费者使用不同 projection type：local projection 可显示必要 secret，
  companion/ESP32、日志和 trace 只可取得 redacted projection；raw request content 不能
  通过 companion 或通用 JSON 绕过脱敏。
- local/external reader adapter 只接受各自 facet 类型，companion publisher 在类型和
  architecture guard 上都不能取得 local reader 或重解析 raw content。
- Apple Companion 协议以 optional RequestID、session generation、observed sequence 和
  supported major/minor 做 additive compatibility；unknown major 拒绝 action，旧 v1
  无 ID command 仅在唯一可见 target 且 session 匹配时兼容，否则安全 no-op。ESP32 旧一字节
  opcode 只允许同样的唯一 target 兼容，不承诺跨 session 选择。
- 迁移采用分阶段替换且每阶段保持单一状态 owner，不进行可能双重 resume/response 的长期新旧双写。
- 固定迁移顺序为：纯 Interaction 模型与测试 → SessionNavigator 行为等价提取 → permission lifecycle → Plan variant/移除 Skip → question lifecycle/Dismiss/能力动作 → per-session Auto/移除 observedPermissionMode → SwiftUI snapshot/action 收敛 → adaptive CLI-first。
- 每个 request 类型完成切换后，旧 queue/状态路径立即停止写入；每阶段必须可整体回滚，并在行为等价测试通过后才推进。
- 低冲突同步以明确接入预算和真实 upstream sync 演练验收，不以自有文件集中或功能测试通过代替结构指标。
- `AppState.swift` 不再保存 fork queue/dismiss/Auto 状态；`HookServer.swift` 只负责规范化 input、transport token 与 effect execution；`NotchPanelView.swift` 只读取 snapshot、发送 RequestID action；`SessionSnapshot.swift` 不包含 fork-only 字段。
- 每个 upstream 热点文件原则上只有一个连续接入区域；第二处接入必须在设计中说明其不可合并原因。
- SessionSnapshot 字段必须按 upstream/provider fact、derived display projection、
  fork/native/provider-specific reconciliation 分类；`permissionMode` 保留为 CLI fact，
  `observedPermissionMode` 移至 Center Auto context 并 legacy decode-and-discard，
  `cursorPendingQuestion` 先经 NativePromptObservation，再移出 snapshot；其它 native/
  provider bookkeeping 不得被当作 generic resolution。
- Sync 演练记录冲突文件数、需要人工理解业务语义的冲突数，以及 fork-owned 模块是否保持无需修改。
- sync evidence 固定写入 `.trellis/tasks/08-31-fork-architecture/research/upstream-sync-evidence.md`，
  记录 `refs/remotes/upstream/main` revision、merge-tree/rehearsal 命令、每个热点 seam/conflict 数、
  semantic conflict 和 fork-owned module 是否需要修改。
- Architecture guards 防止 fork state 回流 `SessionSnapshot`、SwiftUI 直接操作 queue，或协议判断进入 UI；interaction trace 测试覆盖 replay、dismiss、transport failure、external resolution 与多 session ordering。

## Request Identity Evidence

- `HookEvent` 能从多种字段规范化 `toolUseId`，但该字段可缺失。
- 现有回归测试证明：同一 `tool_use_id` 可能被并行工具调用共享，仅凭它不能判断 replay；需要结合 session、tool 和 input 等信息。
- 现有行为会在确认 replay 时替换 continuation，并确保旧 continuation 得到终结。
- 对没有 `tool_use_id` 的 permission，现有实现只能利用同 session 的后续活动作保守清理，无法精确关联。
- Codex app-server question 路径具有独立 `requestId`；不同 CLI 的关联能力并不一致。
- 现有 `HookServer` 的 disconnect 监控按 session ID 清理；迁移必须收窄到 request-scoped transport token，并为真正 session-wide channel close 使用显式证据。
- 现有 session discovery、Codex app-server close 与 background hook 可能乱序；mapper 必须提供 generation/revision，Center 不得让旧观察覆盖新事实。
- 统一 snapshot 会被 ESP32/Apple Companion 等外围 Adapter 消费；question 的 secret 标记和 redacted projection 是安全要求，不是 UI 细节。
- 现有 queue 分为 permission/question 两个数组；目标是单一跨 kind session ordinal。provider 明确 superseded 前，不得用新 kind 的到达隐式否决旧 kind。

## Decision Closure

- grilling 已关闭所有产品、UX、兼容性和风险决策；`design.md` 固化技术 Interface，`implement.md` 固化迁移、验证和回滚步骤。
- 实现授权已经给出，但本任务仍保持 `planning`，直到 gate review 检查三份 artifact、
  migration matrix、trace plan 和 rollback boundary；完成规划文件不自动 start task。

## Acceptance Criteria

- [ ] 所有用户拥有的产品、UX、兼容性与风险决策均经 grilling 明确确认。
- [ ] `prd.md` 明确目标、范围、约束、可观察验收行为与 out-of-scope。
- [ ] `design.md` 定义少量稳定 seam、每个深模块的 Interface、状态所有权、数据流与 Adapter。
- [ ] `design.md` 说明与 upstream hook/session/UI 变更的兼容和同步方式。
- [ ] `implement.md` 给出可独立验证、可回滚的迁移顺序及测试策略。
- [ ] SessionObservation 以同一 generation/revision 携带 typed display/navigation facets，
  能填充 local session facts 与既有 terminal routes；stale input 原子丢弃，external 只取
  redacted projection。
- [ ] 最终方案不要求 SwiftUI、`HookServer` 或多个 `AppState` 调用方理解 Auto/dismiss/跳转的内部状态机。
- [ ] 用户/owner gate review 接受最终摘要、matrix、trace、rollback 和 sync evidence path
  后，才允许 task start；此项是执行闸门，不是未决产品决策。

## Out of Scope

- 本 convergence pass 只修改规划 artifacts；后续实现按 `implement.md` 分阶段修改产品代码，
  不在本次文档编辑中提前执行。
- 不在此任务中增加新的 CLI/terminal 支持。
- 不把所有 upstream 大文件普遍重写或模块化；只处理自有增强所需的 seam。

## Notes

- 已决定以 `InteractionCenter` 深模块统一 Auto、dismiss、permission/plan/question 生命周期，并让 Hook/UI/terminal 代码成为薄 adapter；canonical types、资源所有权、effect executor、generation、projection 和迁移 matrix 已在 `design.md` 固化。
- 本任务属于复杂规划；下一步是 gate review，审阅通过后才可按 `implement.md` start。
