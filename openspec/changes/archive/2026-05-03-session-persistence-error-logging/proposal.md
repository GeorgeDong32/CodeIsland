## Why

`SessionPersistence.save()` 中的 `catch {}` 静默吞没了所有写入错误（文件创建、编码、磁盘写入），导致会话持久化失败时无任何日志或诊断信息。该文件也缺少 `Logger`，排查会话丢失问题时完全没有线索。

## What Changes

- 为 `SessionPersistence` 添加 `os.Logger`（复用 `com.codeisland` subsystem）
- 将 `catch {}` 替换为带日志的错误处理
- 保持现有行为不变：save 失败不 crash，只是记录错误

## Capabilities

### New Capabilities
<!-- None - this is an internal improvement, not a new user-facing capability -->

### Modified Capabilities
- `session-persistence`: save 失败时通过 os.Logger 记录错误详情

## Impact

- `Sources/CodeIsland/SessionPersistence.swift`: 添加 Logger，替换空 catch 块