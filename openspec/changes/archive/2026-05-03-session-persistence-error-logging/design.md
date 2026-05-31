## Context

`SessionPersistence` 是一个简单的枚举类型，负责将活跃会话快照持久化到 `~/.codeisland/sessions.json`。当前 `save()` 方法使用空 `catch {}` 块吞没所有错误，没有任何日志输出。

项目中已有统一的日志模式：使用 `os.log` 模块的 `Logger`，subsystem 为 `com.codeisland`，category 按模块命名（如 `AppState`、`HookServer`）。

## Goals / Non-Goals

**Goals:**
- 为 `SessionPersistence` 添加 `Logger`，复用现有模式
- 记录 save 失败时的错误详情（文件路径、错误类型、描述）

**Non-Goals:**
- 不改变 save 失败时的行为（仍然不 crash，只是静默失败）
- 不添加 load/clear 的日志（它们已用 `try?` 合理处理）
- 不引入新依赖或复杂错误处理机制

## Decisions

### Decision 1: 使用 os.Logger 而非 print

`os.Logger` 是项目标准做法，输出到系统日志（可通过 Console.app 或 `log show` 查看），便于生产环境诊断。`print` 只输出到终端，发布版不可见。

### Decision 2: 只在 save() 添加日志

`save()` 是唯一用 `catch {}` 吞错的地方。`load()` 和 `clear()` 用 `try?` 返回默认值或静默跳过——这是合理的设计（文件不存在不是错误）。

## Risks / Trade-offs

无显著风险。改动极小，仅添加日志不影响运行时行为。