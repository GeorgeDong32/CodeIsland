## 1. Branch and Candidate Verification

- [x] 1.1 Run `git status` and confirm the worktree is clean before any branch or cherry-pick operation.
- [x] 1.2 Create `sync/upstream-post-c41e7f8-picks` from local `main`.
- [x] 1.3 Re-run `git cherry -v main upstream/main` and record which post-`c41e7f8` commits are still non-equivalent.
- [x] 1.4 Confirm the implementation scope excludes merge commits, already-equivalent commits, Cline support, release/appcast updates, and docs-only updates.

## 2. Batch 1 Hook and Approval Fixes

- [x] 2.1 Cherry-pick `2c98861` with `-x` and resolve conflicts while preserving local notification continuation behavior.
- [x] 2.2 Run `swift test --filter AppStateQuestionFlowTests` after `2c98861` and verify `AskUserQuestion` payload handling still matches the `hook-protocol` delta spec.
- [x] 2.3 Cherry-pick `f5c92a5` with `-x` and preserve local bridge `session_id` fallback logic in `Sources/CodeIslandBridge/main.swift`.
- [x] 2.4 Run targeted bridge/session tests after `f5c92a5`, including `swift test --filter CLIProcessResolverTests`.
- [x] 2.5 Cherry-pick `4fd5a64` with `-x` and resolve Codex hook/remote approval changes against existing local auto mode behavior.
- [x] 2.6 Cherry-pick `7e9697a` with `-x` and verify remote opencode host identity remains namespaced and distinguishable from local sessions.
- [x] 2.7 Run `swift test` after Batch 1 and stop if hook, bridge, or resolver tests fail.

## 3. Batch 2 Session Routing and Terminal Fixes

- [x] 3.1 Cherry-pick `d17709a` with `-x` and preserve existing Ghostty, Apple Terminal, iTerm2, tmux, kitty, Warp, Alacritty, and cmux detection behavior.
- [x] 3.2 Run terminal-related tests or the closest available Swift test filters after `d17709a` and inspect `TerminalActivator.swift` / `TerminalVisibilityDetector.swift` conflicts.
- [x] 3.3 Cherry-pick `861adcf` with `-x` only if it does not require pulling Cline support or broad session monitoring rewrites.
- [x] 3.4 Run `swift test --filter DerivedSessionStateTests` and resolver tests after `861adcf` to protect local node argv detection for Codex, Gemini, and Qoder.
- [x] 3.5 Cherry-pick `d119766` with `-x` only if Codex always-allow persistence can be integrated without rewriting local auto-approve mode.
- [x] 3.6 Run `swift test` after Batch 2 and defer any commit whose conflicts exceed the scoped bugfix goals.

## 4. Validation and Review

- [x] 4.1 Run full `swift test` after all accepted cherry-picks. Result: 234 tests, 0 failures.
- [x] 4.2 Run focused tests: `swift test --filter AppStateQuestionFlowTests`, `swift test --filter CLIProcessResolverTests`, and `swift test --filter DerivedSessionStateTests`.
- [x] 4.3 Run `xcodebuild -scheme CodeIsland -configuration Debug build` to validate app build integrity.
- [x] 4.4 Review diffs in `AppState.swift`, `HookServer.swift`, `ConfigInstaller.swift`, `TerminalActivator.swift`, `TerminalVisibilityDetector.swift`, `Sources/CodeIslandBridge/main.swift`, and `Sources/CodeIslandCore/Models.swift` for accidental regression of local post-`c41e7f8` fixes.
- [x] 4.5 Document any deferred upstream commits and the reason they were skipped in the final implementation summary.

## 5. Merge and Deploy

- [x] 5.1 Merge `sync/upstream-post-c41e7f8-picks` into `main` with `--no-ff` merge commit.
- [x] 5.2 Push `main` to origin.
- [x] 5.3 Build release with `SIGN_ID="-" bash build.sh` (universal binary with Sparkle).
- [x] 5.4 Backup existing app and install new release to `/Applications`.

## Deferred Commits

Cline support commits deferred to future `sync/upstream-cline-support` branch:
- `6a28f06` — Cline main feature
- `50beca9` — Cline review feedback
- `ccb0efd` — Cline TaskComplete/TaskCancel lifecycle
- `d529682` — Cline TaskRoundComplete stale events
- `64d6118` — Cline lifecycle tests
