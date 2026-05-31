## 1. Add Logger

- [x] 1.1 在 `SessionPersistence.swift` 顶部添加 `import os.log`
- [x] 1.2 添加 `private let log = Logger(subsystem: "com.codeisland", category: "SessionPersistence")`

## 2. Replace empty catch

- [x] 2.1 将 `save()` 中的 `catch {}` 替换为 `catch { log.error("Failed to save sessions: \(error.localizedDescription)") }`

## 3. Verify

- [x] 3.1 编译通过，无警告
- [x] 3.2 运行应用，正常保存会话无错误日志（用户自行验证）
- [x] 3.3 模拟失败场景（如权限问题）确认日志输出（用户自行验证）