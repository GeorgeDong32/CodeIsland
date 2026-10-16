# Journal - George·Dong (Part 1)

> AI development session journal
> Started: 2026-08-31

---



## Session 1: Fix Markdown layout hangs and install 1.2.12

**Date**: 2026-10-09
**Task**: Fix Markdown layout hangs and install 1.2.12
**Branch**: `main`

### Summary

Continued Devin investigation; fixed nested-list layout stall (22.429s to 0.233s), verified 2000 tests with 4 skips, bumped to 1.2.12, built arm64 release, replaced and relaunched local app, and prepared verified APFS DMG.

### Main Changes

- Use bounded Markdown list-row measurement; preserve content, formatting and panel heights.
- Bump both bundle versions and bilingual changelog to 1.2.12; native git explicitly authorized.
- Install /Applications/CodeIsland.app; retain rollback at .build/install-backups/pre-1.2.12-zicb7lj0/; deliver ~/Downloads/CodeIsland-1.2.12-arm64.dmg.

### Git Commits

| Hash | Message |
|------|---------|
| `627ba5d` | (see git log) |
| `e4c9c2e` | (see git log) |

### Testing

- [OK] Full swift test: 2000 executed, 4 optional rendering-tool skips, 0 failures; swift build and release build passed.
- [OK] DMG checksum, mounted and installed nested signatures, version/architecture and executable hashes passed; launched PID 96950 and hook socket reachable.
- [OK] Repacked verified app as APFS after create-dmg HFS FinderInfo caused mounted signature failure; local artifact is ad-hoc signed and not notarized.

### Status

[OK] **Completed**

---

## Session: 2026-10-16 — CLI zombie sessions (opencode / cursor-agent)

**Date**: 2026-10-16
**Task**: 10-16-cli-zombie-sessions（homebrew 形态 CLI 会话清理失效）
**Branch**: `main`

### Summary

MacBook 报障两连：opencode 进程退出后会话卡继续显示在跑（数分钟后自愈）、cursor-agent 假多 agent 常驻。SSH 只读侦察 MacBook（sessions.json / hooks.json / 进程树 / lsof）完成根因闭环：homebrew cask/cellar 安装路径不进 CodeIsland 的进程匹配白名单 + 清理策略对「常驻进程挂多张会话卡」全面失效（有 monitor 的卡跳过全部超时路径）。上游 opencode v2 无任何 client-exit 事件（SIGINT/SIGTERM 被截获早于插件 handler），确认不能依赖上游。

### Main Changes

- `CLIProcessResolver`：cursor-cli 匹配补 `/caskroom/cursor-cli/` keg 形状（仅 executablePath 维度，bridge ancestry 未动——用户拍板先出一版试试）。
- `findOpenCodePids`：白名单补 `/cellar/opencode` substring + npm 形态 `/opencode-ai/` argv 匹配；放宽为 internal 供 fixture 测试。
- `cleanupIdleSessions` 新增 2c（多卡挂同 pid，安静超 15min 的旧卡回收、保留组内最新卡）与 2b-2（带 currentTool 的 monitored processing 卡超 30min 无事件翻 idle）。
- opencode 插件 v8→v9：`createV2Mapper` 补订阅 `session.idle`（上游专门 quiesce 事件）作冗余 Stop；插件注释 / ConfigInstaller / 测试断言三方同步 bump。

### Git Commits

| Hash | Message |
|------|---------|
| `3723c60` | fix(sessions): reclaim zombie cards on homebrew-shaped CLI hosts |

### Testing

- [OK] TDD 红→绿：cask keg 识别、cellar/npm pid 扫描（真实 fixture 进程）、shared-pid 回收判定、session.idle→Stop 映射，修前 6 处断言红。
- [OK] swift build；swift test 全量 2012 tests 0 failures（4 既有 skip）；bun test 24/24。

### Status

[进行中] 代码已合入 main；MacBook 实机验证待用户执行（装新构建后观察 cursor-agent 假多 agent 是否按期回收、opencode TUI 退出是否秒级清卡）。发现问题时回本任务迭代。
