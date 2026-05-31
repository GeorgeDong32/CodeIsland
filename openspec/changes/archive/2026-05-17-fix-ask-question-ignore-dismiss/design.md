## Context

AskUserQuestion Card 有两个按钮："Skip" 和 "Dismiss"（即 Ignore），但两者当前行为完全相同——都通过 `CheckedContinuation.resume()` 向 AI 工具发送 deny 或空响应。这意味着用户无法在不回复 AI 的情况下关闭卡片。

相比之下，Plan Card 的 dismiss (`dismissPermissionPrompt()`) 仅关闭 UI、记录 dismissed session ID，不 resume continuation。Question Card 应采用相同模式。

**当前代码路径：**
- `dismissQuestion()` (AppState.swift:1860) — resume continuation + deny/empty response
- `skipQuestion()` (AppState.swift:1842) — resume continuation + deny/empty response
- `dismissPermissionPrompt()` (AppState.swift:1539) — 不 resume，仅关闭 UI（参考实现）

## Goals / Non-Goals

**Goals:**
- `dismissQuestion()` 改为仅关闭 UI，不向 AI 发送任何响应
- 维持与 `dismissPermissionPrompt()` 一致的行为模式
- 保留 `skipQuestion()` 作为显式跳过/拒绝路径不变

**Non-Goals:**
- 不修改 `skipQuestion()` 的行为
- 不修改 `drainQuestions()` 的行为（断连清理仍需 deny）
- 不修改 UI 布局或按钮标签
- 不处理 dismissed question 的后续恢复逻辑

## Decisions

### D1: dismissQuestion 不 resume continuation

**选择**: `dismissQuestion()` 不再调用 `continuation.resume()`，仅从 `questionQueue` 移除、关闭 surface、更新 derived state。

**替代方案**: 添加超时后自动 deny dismissed question — 但这增加了复杂度且 Plan Card 也不这样做，保持一致性。

**原因**: 与 `dismissPermissionPrompt()` 模式完全对齐。Continuation 不被 resume 意味着 AI 工具的 hook 进程会继续等待，直到用户在终端中直接回复或超时。这是预期行为——用户选择 Ignore 就是想暂时忽略这个提示。

### D2: 使用 dismissedQuestionSessionIds 集合追踪

**选择**: 新增 `private var dismissedQuestionSessionIds: Set<String>` 来记录被 dismiss 的 question 对应的 session，与 `dismissedPermissionSessionIds` 模式一致。

**原因**: 如果同一个 session 有后续事件（如 peer disconnect），可以通过此集合知道该 session 的 question 已被用户主动 dismiss，避免误操作。

### D3: 仅修改 UI 模块中的 dismissQuestion

**选择**: 只改 `AppState`（UI 模块），不涉及 `CodeIslandCore` 中的纯逻辑。

**原因**: question 的 dequeue/dismiss 是 UI 层行为，不涉及 event reducer 或纯函数。

## Risks / Trade-offs

- **Continuation 泄漏风险**: 不 resume continuation 意味着 `CheckedContinuation` 会一直挂起直到被 ARC 回收。但 Swift 的 `CheckedContinuation` 在 deinit 时会打印 warning。如果用户 dismiss 后 AI 工具端也超时退出，continuation 引用的 hook 进程已经结束，不会产生实际问题。→ **缓解**: dismissed 后如果同一 session 收到新事件或 peer disconnect，`drainQuestions` 仍会处理残留的 continuation。
- **遗留 question 残留**: 如果 queue 中有多个 question，dismiss 第一个后后续的仍保留在 queue 中。→ **缓解**: 这是当前已有的行为，`showNextPending()` 会展示下一个。
