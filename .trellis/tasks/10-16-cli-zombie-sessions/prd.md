# 修复 homebrew 形态 CLI 会话清理失效（opencode 卡跑 + Cursor 假多 agent）

## 背景

MacBook（macbook-air）本机 CodeIsland 监控本机 CLI，出现两类症状：

- **Bug 1（Cursor 假多 agent）**：cursor-agent CLI（homebrew cask 安装）产生多个长期存活的会话卡，
  大部分早已不活跃但 UI 永久显示「在跑」，堆积成假的多 agent 并行效果。
- **Bug 2（opencode 卡跑后自愈慢）**：opencode v2（homebrew cellar 安装）进程退出后，
  会话卡继续显示 running，约 5 分钟才靠超时翻 idle、10 分钟删卡（用户观察：会自愈但有明显延迟窗口）。

## 根因（已实测闭环，2026-10-16 MacBook 侦察）

两个 bug 同根：**CodeIsland 的进程/路径匹配规则不认识 homebrew 安装形态**，
叠加**清理策略对「常驻进程 + 多会话卡」全面失效**。

### Bug 1 证据链（Cursor）

- MacBook 实况：两个 cursor-agent TUI 常驻（`/opt/homebrew/bin/cursor-agent`，shell 脚本
  → exec 打包 node，真实 executablePath = `/opt/homebrew/Caskroom/cursor-cli/<ver>/dist-package/node`，
  argv[0] 保留 `/opt/homebrew/bin/cursor-agent`）；`~/.codeisland/sessions.json` 中
  **5 张 cursor 卡全部挂同一 cliPid**，分属 4 种 model，即同一 TUI 进程内的多个会话 UUID。
- 缺陷叠加：
  1. `cliVariantOverride`（cursor → cursor-cli 提升）匹配 `contains("/cursor-agent")`，
     node 路径不含该子串 → **提升失败，卡片被当 IDE（source=cursor）会话处理**；
  2. `resolvedTrackedPID` 走 default 分支 `contains("/cursor")`，`caskroom/cursor-cli`
     恰含 `/cursor` 子串 → 歪打正着命中，monitor 挂到 cursor-agent 常驻进程；
  3. 清理全跳过：cleanupIdleSessions Section 1 只清无 monitor、Section 2b 只清
     bare thinking（**带 currentTool 的卡跳过**）、Section 4 只清无 monitor 的 idle →
     停在 processing/tool 状态的旧会话卡永久留存。

### Bug 2 证据链（opencode）

- homebrew 真实路径 `/opt/homebrew/Cellar/opencode-v2/<ver>/bin/opencode`，
  `findOpenCodePids` 白名单只认 `/opencode.app/contents/macos/opencode(-cli)`、`/.opencode/bin/opencode` → 匹配不上；
- v2 事件经 shared background service 转发、带 `_untracked_process: true`（无 _ppid），
  `tryMonitorSession` 只能靠 CWD 扫描回找 TUI → 扫描失败 → **挂不上 monitor** →
  进程退出无感知，靠 Section 1（300s/180s）翻 idle + Section 4（10min）删卡自愈；
- 叠加：插件 v8 未订阅 `session.idle`（上游专门 quiesce 事件，clean/error/interrupt
  所有终止形态都发），上游已知 stuck-busy bug 家族丢 `session.status: idle` 边沿时
  Stop 永不触发。上游无任何 client-disconnect/process-exit 事件（SIGINT/SIGTERM 被
  opencode 在插件 handler 前截获），进程退出感知只能靠 CodeIsland 本地 monitor。

## Requirements（按优先级）

1. **会话级回收（治 Bug 1 症状）**：同一 cliPid 挂多张会话卡（many-sessions-per-PID）
   时，旧卡按 lastActivity 超时回收（建议：无事件 10–15min 翻 idle，翻 idle 后走既有
   Section 4 删除路径）。仅影响僵尸卡；正常会话由 Stop/SessionEnd 先行翻 idle。
2. **Section 2b 扩展（兜底）**：带 currentTool 的 processing 卡、有 monitor、
   超 30min 无任何 hook 事件 → 回收。30min 无事件 + 无后续 hook 基本可判僵尸
   （正常长任务每步 tool call 都有 PreToolUse/PostToolUse 刷新 lastActivity）。
3. **cursor-cli 识别补 cask 形状**：`cliVariantOverride` / `sourceMatchesExecutablePath`
   （cursor-cli 分支）补 `/caskroom/cursor-cli/`（executablePath 维度）。bridge ancestry
   只有 executablePath，argv 维度如需引入须改 bridge 收集逻辑——先评估是否必要。
   修好后卡片正确标注 Cursor CLI、终端跳转走 CLI 路径。
4. **opencode 白名单补 homebrew/npm**：`findOpenCodePids` 补 `/cellar/opencode`
   substring（覆盖 cellar/opencode-v2 与未来去 -v2 后缀）；npm 形态经
   argSubstrings 补 `/opencode-ai/`（npm 包名，node 跑 index.js 时 argv 含包路径）。
5. **插件订阅 `session.idle`**：`codeisland-opencode.js` v2 映射补
   `case "session.idle"` → 发 `Stop`（与 `session.status: idle` 同构，幂等）。
   同步 bump `ConfigInstaller.opencodePluginVersion` 与插件内 `// version:` 注释，
   并更新 `OpenCodeV2SupportTests.testBundledPluginServesBothPluginAPIs` 的断言。

## 约束

- 修复 1/2 不得误杀真活跃会话：活跃会话有事件持续刷新 lastActivity；
  权限/提问等待卡（waitingApproval/waitingQuestion）维持现有 300s 无 monitor 语义，
  有 monitor 时依赖会话级回收（10–15min）覆盖。
- 修复 3 匹配规则收紧防误报：不得让普通 `/cursor` 路径（IDE）被提升为 CLI；
  caskroom 形状专用。
- 修复 5 是插件资源文件（`Sources/CodeIsland/Resources/codeisland-opencode.js`），
  由 ConfigInstaller 安装到 `~/.opencode/`，版本号三方（插件注释 / ConfigInstaller /
  测试断言）必须同步 bump。

## Acceptance Criteria

- [ ] 回归测试：`sourceMatchesExecutablePath` / `cliVariantOverride` 对
      `/opt/homebrew/caskroom/cursor-cli/<v>/dist-package/node` 形状——
      cursor-cli 分支命中、`cliVariantOverride(declaredSource: "cursor")` 返回 "cursor-cli"。
- [ ] 回归测试：`findOpenCodePids` 路径匹配逻辑对
      `/opt/homebrew/cellar/opencode-v2/<v>/bin/opencode` 形状命中
      （经 fixture 进程或抽出纯匹配函数直测）。
- [ ] 回归测试：构造「多卡挂同一 cliPid + 有 monitor + processing（含 currentTool）+
      lastActivity 超时」的快照，断言被回收（当前代码下先红）。
- [ ] 插件测试：`session.idle` 事件映射产出 `Stop`（`CodeIslandOpenCodePluginTests`
      的 v2 映射测试补 case）。
- [ ] MacBook 实机验证（用户执行）：cursor-agent 常驻场景旧卡按期回收、不再堆积；
      opencode TUI 退出后会话卡秒级清理（monitor 触发 handleProcessExit 路径）。

## 非目标（后续任务）

- `/session/status` HTTP 对账轮询（上游 PR #39349 姿势）——修完 4/5 后评估残余窗口再定。
- 远程链路（CodeIsland 在桌面机监控 MacBook）的 processing 会话无兜底清理问题（#121
  跳过 Section 1 的副作用）——独立排查。
- 给上游提 client attach/detach 事件 feature request。

## 调查产物指针

- 上游 v2 生命周期结论：memory `opencode-v2-lifecycle-no-exit-event`
- MacBook 实测数据：本 PRD「根因」节 + 会话
  （sessions.json 快照、hooks.json、进程树 lsof/ps 输出，2026-10-16）
