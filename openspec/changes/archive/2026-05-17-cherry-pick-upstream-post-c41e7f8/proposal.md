## Why

Local `main` has already absorbed many upstream fixes through manual cherry-picks, but it diverged again after the last conflict-resolution commit `c41e7f8`. We need a scoped, reviewable plan to cherry-pick only the upstream fixes that landed after that boundary without replaying already-equivalent patches or pulling unrelated large features.

## What Changes

- Create a dedicated sync branch from local `main`: `sync/upstream-post-c41e7f8-picks`.
- Review upstream non-merge commits after `c41e7f8` and prioritize small bugfixes over broad feature additions.
- Cherry-pick the selected fixes individually with `-x` so each upstream source commit remains traceable.
- Preserve local post-`c41e7f8` fixes for bridge session identity, notification continuation, and node-based CLI process detection.
- Defer Cline support and other large product features to separate changes unless explicitly requested.
- Validate each batch with Swift tests and targeted resolver/session tests before continuing.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `hook-protocol`: Preserve payload, response, and remote identity semantics while syncing upstream hook/approval fixes.
- `terminal-support`: Add or preserve terminal/session routing fixes from upstream without regressing existing terminal detection behavior.

## Impact

- Affected modules: `CodeIsland`, `CodeIslandBridge`, and `CodeIslandCore`.
- High-attention files include `AppState.swift`, `HookServer.swift`, `ConfigInstaller.swift`, `TerminalActivator.swift`, `TerminalVisibilityDetector.swift`, `Sources/CodeIslandBridge/main.swift`, and `Sources/CodeIslandCore/Models.swift`.
- Affected behavior includes PermissionRequest/Question payload forwarding, Codex/opencode remote identity, hook event response completion, WezTerm-family pane routing, and CLI process/session identity resolution.
- No dependency, schema, or release artifact changes are planned in this sync.