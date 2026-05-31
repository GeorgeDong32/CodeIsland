## Why

AskUserQuestion Card 的 "Ignore/Dismiss" 按钮当前行为与 "Skip" 完全相同——都会向 AI 发送 deny 响应，导致用户无法在不回复 AI 的情况下关闭卡片。原始设计意图中 Ignore 应仅关闭 UI，不向 AI 端发送任何回复，类似 Plan Card 的 dismiss 行为。

## What Changes

- 修改 `AppState.dismissQuestion()` 方法：不再 resume continuation，仅关闭 question card UI 并更新 surface 状态
- 行为对齐 `dismissPermissionPrompt()` 的 dismiss 模式：记录 dismissed session ID，不向 AI 发送响应
- `skipQuestion()` 保持不变——作为显式跳过/拒绝路径
- 对 notification-style legacy question 的 dismiss 也改为仅关闭 UI（当前已经返回空 response，但语义上 dismiss 不应触发任何 response）

## Capabilities

### New Capabilities

(无新增 capability)

### Modified Capabilities

- `question-card-dismiss`: 修改 AskUserQuestion Card dismiss 的语义，从"发送 deny 响应"改为"仅关闭 UI 不回复"

## Impact

- `Sources/CodeIsland/AppState.swift`：`dismissQuestion()` 方法重写，新增 `dismissedQuestionSessionIds` 集合
- `Tests/CodeIslandCoreTests/`：需新增/更新 dismiss 相关测试用例
- 无 API 变更，无破坏性改动，纯行为修正
