## Context

Local `main` and `upstream/main` have diverged, but `git cherry -v main upstream/main` shows that several upstream patches were already absorbed locally with different commit SHAs. The last known manual sync boundary is local commit `c41e7f8`, which resolved cherry-pick conflicts and restored upstream logic.

This change is a scoped upstream bugfix sync, not a broad feature merge. It must preserve local post-boundary fixes in bridge session identity, notification continuation, and node-based CLI process detection while selectively importing upstream fixes that landed later on 2026-05-10.

Relevant official hook references were reviewed before defining hook-related requirements:

- Claude Code hooks: https://docs.anthropic.com/en/docs/claude-code/hooks
- Codex hooks: https://developers.openai.com/codex/hooks
- Cursor hooks: https://cursor.com/docs/hooks

## Goals / Non-Goals

**Goals:**

- Create a dedicated branch from local `main` for a traceable cherry-pick series.
- Cherry-pick only post-`c41e7f8` upstream fixes that improve hook payload handling, response completion, remote identity, Codex/session routing, and terminal pane detection.
- Preserve local bridge/session resolver fixes from `9f84f15`, `1156178`, and `81817a5`.
- Validate after each small batch so conflicts are resolved near their source commit.

**Non-Goals:**

- Do not merge all of `upstream/main`.
- Do not replay already-equivalent upstream patches marked with `-` by `git cherry`.
- Do not include Cline support, release/appcast updates, docs-only updates, or large hardware/companion-device features in this branch.
- Do not introduce new hook formats or new external dependencies.

## Decisions

1. **Use `c41e7f8` as the sync boundary.**
   - Rationale: It is the explicit local conflict-resolution commit for the previous upstream pick cycle.
   - Alternative considered: use `merge-base main upstream/main`; rejected because it includes many older commits already absorbed locally under different SHAs.

2. **Cherry-pick individual non-merge commits with `-x`.**
   - Rationale: Each upstream source remains traceable and individual regressions can be reverted independently.
   - Alternative considered: merge `upstream/main`; rejected because it would pull unrelated features and create a large conflict surface.

3. **Prioritize hook and terminal bugfixes before larger feature work.**
   - Rationale: The highest value updates after `c41e7f8` are small fixes around `PermissionRequest`, Codex/opencode identity, hook event responses, and WezTerm-family pane routing.
   - Alternative considered: include Cline support in the same branch; rejected because Cline is a larger new CLI integration with separate UI/session lifecycle concerns.

4. **Preserve local bridge and resolver behavior during conflict resolution.**
   - Rationale: Local commits after `c41e7f8` fixed session identity fallback, notification continuation, and argv-based node CLI detection; upstream patches must not regress those paths.
   - Alternative considered: accept upstream versions wholesale during conflicts; rejected because it would risk reintroducing bugs already fixed locally.

## Risks / Trade-offs

- **Risk: `AppState.swift` conflicts hide subtle behavior regressions** → Resolve conflicts manually, then run `AppStateQuestionFlowTests` and inspect notification continuation behavior.
- **Risk: upstream hook payload changes override local bridge fallback logic** → Treat `Sources/CodeIslandBridge/main.swift` and `Sources/CodeIslandCore/Models.swift` as protected files during review.
- **Risk: Codex always-allow persistence conflicts with local auto mode changes** → Defer `d119766` if it requires broad settings or auto-approve rewrites.
- **Risk: terminal pane fixes overlap previous Ghostty/Terminal.app work** → Apply terminal-specific commits after hook fixes and run targeted terminal support tests where available.
- **Trade-off: Cline support is deferred** → This keeps the sync branch small, but delays new CLI coverage until a separate dedicated change.