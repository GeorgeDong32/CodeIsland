# CodeIsland 应用架构设计文档

> **文档版本**: 1.0.0
> **创建日期**: 2026-04-19
> **最后更新**: 2026-04-19

---

## 1. 项目概述

### 1.1 什么是 CodeIsland

CodeIsland 是一个 macOS 原生应用，居住在你 MacBook 的刘海（灵动岛）区域，实时展示 AI 编码 Agent 的工作状态。

它通过 Unix socket IPC 连接 **11 种 AI 编码工具**，在刘海面板中展示会话状态、工具调用、权限请求等信息——全部呈现在一个紧凑的像素风面板中。

### 1.2 核心价值

- **即时可见性**：无需切换窗口即可查看 AI 工具状态
- **权限管理**：直接在面板上审批/拒绝工具权限请求
- **多工具支持**：统一的界面管理所有主流 AI 编码工具
- **智能通知抑制**：只在你正在看该会话时抑制通知

---

## 2. 技术栈

| 组件 | 技术 |
|------|------|
| **编程语言** | Swift 5.9+ |
| **UI 框架** | AppKit (macOS 原生) |
| **目标平台** | macOS 14.0+ (Sonoma) |
| **构建系统** | Swift Package Manager |
| **IPC 通信** | Unix Domain Sockets |
| **并发模型** | Swift Concurrency (async/await) |
| **分发方式** | Homebrew Cask + DMG |
| **CI/CD** | GitHub Actions |
| **代码签名** | Apple Developer ID (公证 + Staple) |

---

## 3. 模块架构

### 3.1 模块概览

```
┌─────────────────────────────────────────────────────────────┐
│                        CodeIsland.app                       │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                   CodeIsland                        │   │
│  │  macOS UI 层 (AppKit)                               │   │
│  │  ├── NotchPanelView (刘海面板)                      │   │
│  │  ├── SettingsView (设置界面)                        │   │
│  │  ├── MascotView (吉祥物展示)                        │   │
│  │  └── HookServer (Unix socket 服务端)                │   │
│  └─────────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                   CodeIslandCore                    │   │
│  │  共享核心逻辑 (框架无关)                              │   │
│  │  ├── Models (数据模型)                               │   │
│  │  ├── SessionSnapshot (会话状态管理)                  │   │
│  │  ├── EventNormalizer (事件标准化)                    │   │
│  │  └── HookEvent (事件解析)                            │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                              ▲
                              │ Unix Socket
                              │ JSON Events
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    codeisland-bridge                         │
│  原生 Hook 转发器 (~86KB)                                   │
│  ├── 进程溯源 (Process Ancestry Resolution)                 │
│  ├── 终端环境收集 (iTerm2/tmux/Kitty/cmux)                   │
│  └── JSON 解析与规范化                                       │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 CodeIslandCore 模块

**职责**：包含所有业务逻辑，不依赖任何 UI 框架。

**导出的公共 API**：

| 类型 | 名称 | 说明 |
|------|------|------|
| `enum` | `AgentStatus` | Agent 状态枚举 (idle/processing/running/waitingApproval/waitingQuestion) |
| `struct` | `SessionSnapshot` | 单个会话的完整状态快照 |
| `struct` | `HookEvent` | 标准化后的 Hook 事件 |
| `struct` | `ToolHistoryEntry` | 工具调用历史条目 |
| `struct` | `ChatMessage` | 聊天消息 |
| `struct` | `SubagentState` | 子 Agent 状态 |
| `struct` | `QuestionPayload` | 问题负载 |
| `enum` | `SideEffect` | 副作用枚举 (播放声音、会话监控等) |
| `func` | `reduceEvent` | 纯函数：处理事件，返回副作用 |
| `func` | `deriveSessionSummary` | 从会话集合派生摘要 |
| `enum` | `CLIProcessResolver` | 进程溯源工具 |

**文件结构**：

```
Sources/CodeIslandCore/
├── Models.swift              # 所有共享类型定义
├── SessionSnapshot.swift     # 会话状态管理与事件处理
├── SocketPath.swift          # Unix socket 路径常量
├── EventNormalizer.swift     # 事件名称标准化
└── ChatMessageTextFormatter.swift  # 消息格式化
```

### 3.3 CodeIsland 模块

**职责**：macOS UI 层，包含所有 AppKit/SwiftUI 代码。

**主要组件**：

| 文件 | 职责 |
|------|------|
| `main.swift` | 应用入口 |
| `AppState.swift` | 全局应用状态 (ObservableObject) |
| `HookServer.swift` | Unix socket 服务端，接收 bridge 事件 |
| `NotchPanelView.swift` | 刘海面板主视图 |
| `IslandSurface.swift` | 面板内容表面 |
| `MascotView.swift` | 吉祥物展示组件 |
| `SettingsView.swift` | 设置界面 (7 个标签页) |
| `ScreenDetector.swift` | 刘海屏幕检测 |
| `SoundManager.swift` | 8-bit 音效管理 |
| `SessionPersistence.swift` | 会话持久化 |
| `RemoteManager.swift` | 远程会话管理 |
| `RemoteInstaller.swift` | 远程连接安装器 |

**UI 结构**：

```
App Window (刘海窗口)
├── NotchPanelController
│   ├── NotchPanelView (刘海区域展开面板)
│   │   ├── MascotView (像素风吉祥物)
│   │   ├── StatusBarView (状态栏)
│   │   └── ToolHistoryView (工具历史)
│   └── CompactBarView (紧凑状态栏)
└── SettingsWindowController
    ├── SettingsView (NSTabView)
    │   ├── GeneralView (通用设置)
    │   ├── BehaviorView (行为设置)
    │   ├── AppearanceView (外观设置)
    │   ├── MascotsView (吉祥物预览)
    │   ├── SoundsView (音效设置)
    │   ├── HooksView (Hook 管理)
    │   └── AboutView (关于)
    └── StatusItemController (菜单栏图标)
```

### 3.4 CodeIslandBridge 模块

**职责**：独立的轻量级 hook 转发器，作为独立进程运行。

**特性**：

- 体积约 86KB，无外部依赖（仅 Foundation + Darwin）
- 原生 JSON 解析（无字符串操作）
- 进程溯源：通过遍历进程树找到真正的 CLI 进程
- 终端环境检测：收集 TTY、tmux、iTerm2、Kitty、cmux 等信息
- SIGPIPE 和 SIGALRM 保护，防止进程挂起

**工作流程**：

```
1. 读取 stdin JSON (Hook 事件)
2. 验证 session_id 存在
3. 收集终端环境变量
4. 遍历进程树溯源 CLI PID
5. 推断 source (CLI 类型)
6. 通过 Unix socket 发送 enriched JSON
7. 等待服务端响应（阻塞事件需要用户交互）
8. 关闭连接，退出
```

---

## 4. 事件流架构

### 4.1 Hook 事件协议

```
AI 工具 (Claude/Codex/Gemini/Cursor/...)
  → 触发 Hook
    → codeisland-bridge (原生二进制)
      → Unix socket → /tmp/codeisland-<uid>.sock
        → CodeIsland HookServer
          → EventNormalizer (标准化事件名)
            → reduceEvent (纯函数更新状态)
              → SideEffect 执行
                → UI 更新
```

### 4.2 事件类型

| 事件名 | 说明 | 阻塞 |
|--------|------|------|
| `SessionStart` | 新会话开始 | 否 |
| `SessionEnd` | 会话结束 | 否 |
| `UserPromptSubmit` | 用户提交 prompt | 否 |
| `PreToolUse` | 工具调用前 | 否 |
| `PostToolUse` | 工具调用后 | 否 |
| `PostToolUseFailure` | 工具调用失败 | 否 |
| `PermissionRequest` | 权限请求 | **是** |
| `Notification` | 通知（含问题） | 条件 |
| `SubagentStart` | 子 Agent 启动 | 否 |
| `SubagentStop` | 子 Agent 停止 | 否 |
| `AfterAgentResponse` | AI 回复生成 | 否 |
| `Stop` | 会话停止 | 否 |
| `PreCompact` | 上下文压缩前 | 否 |

### 4.3 状态机

```
                    ┌─────────────┐
                    │    Idle    │
                    └──────┬─────┘
                           │ UserPromptSubmit
                           ▼
                    ┌─────────────┐
           ┌───────▶│  Processing │◀──────┐
           │        └──────┬─────┘        │
           │               │ PreToolUse   │ PostToolUse
           │               ▼              │
           │        ┌─────────────┐       │
           │        │   Running  │───────┘
           │        └──────┬─────┘
           │               │
    Subagent│Start         │ SubagentStop
           │               ▼
    ┌──────┴──────┐  ┌─────────────┐
    │  Running    │  │  Processing │
    │  (Subagent) │  └──────┬─────┘
    └──────┬──────┘         │
           │ Subagent│Stop │
           └────────┴──────┘
                           │
              Permission│Request   Question
                           │              │
                           ▼             ▼
                   ┌──────────────┐  ┌───────────┐
                   │WaitingApproval│  │WaitingQ  │
                   └──────┬───────┘  └─────┬─────┘
                         │                │
                         └───────┬────────┘
                                 │
                             User Response
                                 │
                                 ▼
                          (恢复原状态)
```

---

## 5. 支持的 AI 工具

### 5.1 工具矩阵

| 工具 | Source ID | 事件数 | 跳转目标 | 支持级别 |
|------|-----------|--------|----------|----------|
| Claude Code | `claude` | 13 | 终端标签页 | 完整 |
| Codex | `codex` | 3 | 终端 | 基础 |
| Gemini CLI | `gemini` | 6 | 终端 | 完整 |
| Cursor | `cursor` | 10 | IDE | 完整 |
| Trae/Traecli | `trae`/`traecli` | 10 | 终端/IDE | 完整 |
| Qoder | `qoder` | 10 | IDE | 完整 |
| GitHub Copilot | `copilot` | 6 | 终端 | 完整 |
| Factory | `droid` | 10 | IDE | 完整 |
| CodeBuddy | `codebuddy` | 10 | APP/终端 | 完整 |
| Kimi Code CLI | `kimi` | 10 | 终端 | 完整 |
| OpenCode | `opencode` | All | APP/终端 | 完整 |

### 5.2 Source 别名处理

```swift
// 支持多种别名映射到规范 source
let aliases: [String: String] = [
    "factory": "droid",
    "qwen-code": "qwen",
    "kimi-cli": "kimi",
    "traecn": "traecn",
    // ...
]
```

---

## 6. 终端兼容性

### 6.1 支持的终端

- **iTerm2**：通过 `ITERM_SESSION_ID` + AppleScript 激活
- **Apple Terminal**：通过 TTY 路径激活
- **Ghostty**：通过 bundle ID 检测
- **WezTerm**：通过 bundle ID 检测
- **kitty**：通过 `KITTY_WINDOW_ID` 检测
- **tmux**：通过 `TMUX_PANE` + `TMUX_CLIENT_TTY` 检测
- **Warp**：通过 bundle ID 检测
- **Alacritty**：通过 bundle ID 检测
- **cmux**：通过 `CMUX_SURFACE_ID` + `CMUX_WORKSPACE_ID` 检测

### 6.2 IDE 集成终端检测

- VS Code / VSCodium
- Cursor (需要区分集成终端 vs 原生 APP 模式)
- JetBrains 全家桶 (IntelliJ, PyCharm, WebStorm, etc.)
- Zed
- Xcode
- Windsurf, Codeium

### 6.3 原生 APP 模式

某些 AI 工具以独立应用形式运行（不是 CLI），需要通过 bundle ID 识别：

| 应用 | Bundle ID | Source |
|------|-----------|--------|
| Cursor | `com.todesktop.230313mzl4w4u92` | `cursor` |
| Trae | `com.trae.app` | `trae` |
| Codex APP | `com.openai.codex` | `codex` |
| Qoder | `com.qoder.ide` | `qoder` |
| Factory | `com.factory.app` | `droid` |
| CodeBuddy | `com.tencent.codebuddy` | `codebuddy` |
| StepFun | `com.stepfun.app` | `stepfun` |
| OpenCode | `ai.opencode.desktop` | `opencode` |

---

## 7. IPC 通信设计

### 7.1 Unix Socket 路径

```swift
// SocketPath.swift
public enum SocketPath {
    public static var path: String {
        "/tmp/codeisland-\(getuid()).sock"
    }
}
```

### 7.2 Socket 通信协议

**请求格式**（Bridge → App）：

```json
{
  "hook_event_name": "PreToolUse",
  "session_id": "abc123",
  "tool_name": "Bash",
  "tool_input": { "command": "ls -la" },
  "_source": "claude",
  "_ppid": 12345,
  "_tty": "/dev/ttys001",
  "_tmux_pane": "%0",
  "_cmux_surface_id": "uuid-here",
  "_term_bundle": "com.googlecode.iterm2",
  "_iterm_session": "SessionGUID"
}
```

**响应格式**（App → Bridge，用于阻塞事件）：

```json
{
  "action": "approve",      // 或 "deny"
  "message": "Optional text" // 用户输入的问题答案等
}
```

### 7.3 非阻塞 vs 阻塞事件

- **非阻塞事件**：发送后立即返回，不等待响应
- **阻塞事件**：需要等待用户交互（PermissionRequest、Question），socket 保持开放

---

## 8. 进程溯源机制

### 8.1 问题背景

某些 CLI 通过 `sh -c` 执行 hook，导致 `getppid()` 返回的是临时 shell 而非真正的 CLI 进程。

### 8.2 解决方案

遍历进程树，找到第一个匹配 CLI 二进制名称的进程：

```swift
func buildAncestry(startingAt pid: pid_t, maxDepth: Int = 6) -> [(pid: pid_t, executablePath: String?)] {
    // 递归向上遍历父进程链
}

func sourceMatchesExecutablePath(_ path: String, source: String?) -> Bool {
    // 检查路径是否匹配特定 CLI
    // 例：claude → endsWith("/claude") || contains("/claude ")
}
```

### 8.3 进程树遍历

```
hook.sh (pid=100)
  └── sh -c "codeisland-bridge ..." (pid=99)
        └── codeisland-bridge (pid=1)
              └── Claude Code (pid=0, actual CLI)

预期：bridge 检测到 Claude Code 为真正的源
实际：通过进程溯源找到正确的 CLI 进程
```

---

## 9. 通知智能抑制

### 9.1 标签页级检测

不是抑制整个终端应用的通知，而是在用户正在查看该会话的标签页时才抑制通知。

### 9.2 检测信号

| 终端 | 检测方式 |
|------|----------|
| iTerm2 | AppleScript 查询当前焦点标签页 |
| tmux | 通过 socket 查询 tmux client TTY |
| cmux | 通过 `CMUX_SURFACE_ID` + `CMUX_WORKSPACE_ID` |
| 其他 | fallback 到粗粒度抑制 |

---

## 10. 设置面板

| 标签页 | 功能 |
|--------|------|
| **通用** | 语言、登录时启动、显示器选择 |
| **行为** | 自动隐藏、智能抑制、会话清理 |
| **外观** | 面板高度、字体大小、AI 回复行数 |
| **角色** | 预览所有像素风角色及动画 |
| **声音** | 8-bit 风格音效通知 |
| **Hooks** | 查看 CLI 安装状态、重新安装或卸载 |
| **关于** | 版本信息和链接 |

---

## 11. 分发与构建

### 11.1 构建流程

```bash
# 开发模式
swift build && ./.build/debug/CodeIsland

# 发布模式 (通过 build.sh)
./build.sh
# 生成 universal binary (arm64 + x86_64)
# 自动公证 + staple
# 输出 .build/release/CodeIsland.app
```

### 11.2 分发渠道

1. **Homebrew Cask**：`brew install --cask codeisland`
2. **DMG 下载**：GitHub Releases 页面

### 11.3 CI/CD 流程 (GitHub Actions)

```
Push/PR
   │
   ▼
Swift Build (macos-latest)
   │
   ├── Unit Tests
   │
   ├── DMG Build (universal binary)
   │     └── 代码签名 + 公证 + Staple
   │
   └── Release (tag only)
         └── Create GitHub Release
               └── Upload DMG
```

---

## 12. 数据持久化

### 12.1 UserDefaults

- 设置项：`AppState` 管理的所有偏好设置
- 自定义 CLI 配置：`custom_cli_configs_v1` 键
- 语言偏好：跟随系统或手动选择

### 12.2 会话持久化

- `SessionPersistence.swift` 处理会话恢复
- 会话状态存储在内存，App 退出时清理
- 恢复会话时检查 CLI 进程是否仍在运行

---

## 13. 像素风吉祥物系统

### 13.1 吉祥物资源

每个 AI 工具对应一个像素风 GIF/Mascot：

```
Sources/CodeIsland/Resources/
├── mascots/
│   ├── claude.gif
│   ├── codex.gif
│   ├── gemini.gif
│   ├── cursor.gif
│   └── ...
└── cli-icons/
    ├── claude.png
    ├── codex.png
    └── ...
```

### 13.2 吉祥物展示规则

1. 空闲时显示最近活跃 CLI 的吉祥物
2. 活动时显示当前会话 CLI 的吉祥物
3. 动画速度可调（0% = 冻结）
4. 背景透明/白色，适配 README

---

## 14. 国际化

### 14.1 支持的语言

- **中文** (zh-Hans)
- **英文** (en)

### 14.2 实现方式

使用 `Localizable.strings` 文件：

```swift
// L10n.swift
enum L10n {
    static func string(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}

// 使用
Label(L10n.string("settings.general.title"))
```

### 14.3 语言检测

跟随系统 `Locale.current.identifier`，优先检查 `zh` 前缀。

---

## 15. 安全性

### 15.1 App Sandbox

- 网络：仅允许 Local Network（用于远程连接功能）
- 文件：无写入限制
- 自动化：允许控制终端应用

### 15.2 权限

- 辅助功能（Accessibility）：用于终端窗口激活
- 自动化（Automation）：用于 iTerm2 AppleScript

### 15.3 数据安全

- Socket 文件存储在 `/tmp/`，权限受限
- 无持久化存储敏感信息
- Hook 脚本不包含任何凭据信息

---

## 16. 性能优化

### 16.1 状态缓存

- `status`、`primarySource`、`activeSessionCount` 使用懒缓存
- 减少观察者轮询频率

### 16.2 Socket 超时

- 非阻塞事件：3s 发送超时 + 8s 整体超时
- 阻塞事件：无发送超时，但有 86400s (24h) 接收超时

### 16.3 Bridge 优化

- 使用非阻塞 connect
- 半关闭 socket (`shutdown(SHUT_WR)`) 通知服务端数据结束
- 避免管道阻塞 (`alarm()` 设置硬截止时间)

---

## 17. 错误处理

### 17.1 Bridge 错误

| 错误 | 处理 |
|------|------|
| Socket 不存在 | 静默退出 (`exit(0)`) |
| Connect 失败 | 静默退出 |
| JSON 解析失败 | 静默退出 |
| 无 session_id | 静默丢弃 |
| 发送超时 | 静默退出 |

### 17.2 App 端错误

- Socket 接受失败：记录日志，重启监听
- 事件处理异常：捕获后丢弃事件，防止 UI 卡死
- 进程监控失败：降级为粗粒度检测

---

## 18. 未来扩展方向

1. **Windows 支持**：跨平台刘海 UI（需要新架构）
2. **更多终端**：继续增加终端支持
3. **WebSocket 支持**：支持远程连接场景
4. **自定义吉祥物**：用户上传自定义像素角色
5. **Apple Watch 支持**：手腕上的通知推送
6. **多语言增强**：日语、韩语等更多语言

---

## 附录

### A. 文件速查表

| 文件 | 模块 | 职责 |
|------|------|------|
| `Package.swift` | 根 | Swift 包配置 |
| `main.swift` | CodeIsland | App 入口 |
| `AppState.swift` | CodeIsland | 全局状态管理 |
| `HookServer.swift` | CodeIsland | Unix socket 服务端 |
| `NotchPanelView.swift` | CodeIsland | 刘海面板视图 |
| `Models.swift` | CodeIslandCore | 共享类型 |
| `SessionSnapshot.swift` | CodeIslandCore | 会话状态与事件处理 |
| `main.swift` | CodeIslandBridge | Bridge 入口 |

### B. 环境变量速查

| 变量 | 来源 | 用途 |
|------|------|------|
| `TERM_PROGRAM` | 终端 | 终端类型识别 |
| `__CFBundleIdentifier` | 终端 | Bundle ID |
| `ITERM_SESSION_ID` | iTerm2 | 会话 GUID |
| `KITTY_WINDOW_ID` | Kitty | 窗口 ID |
| `TMUX` / `TMUX_PANE` | tmux | tmux 会话信息 |
| `CMUX_SURFACE_ID` | cmux | cmux surface UUID |
| `CMUX_WORKSPACE_ID` | cmux | cmux workspace UUID |
| `CODEISLAND_SKIP` | Bridge | 跳过 hook |
| `CODEISLAND_DEBUG` | Bridge | 调试日志 |

---

*本文档由 Claude Code 基于源码分析自动生成*
