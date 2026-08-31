# Phase 7 upstream sync rehearsal evidence

Date: 2026-08-31 (Asia/Singapore)

This is a read-only rehearsal. No branch, merge, index, or working-tree history was
changed. The adaptive presentation policy remains an opt-in Core seam; production
consumers remain on the legacy checkpoint because Phase 6 has not completed its
snapshot/action cutover.

## Revisions and working-tree boundary

Commands:

```text
git rev-parse HEAD
git rev-parse refs/remotes/upstream/main
git merge-base HEAD refs/remotes/upstream/main
git status --short --untracked-files=all
```

Observed revisions:

| ref | revision |
| --- | --- |
| fork `HEAD` | `1fd2bab6f617df34c33ce43046b01ed6f14d3f1b` |
| `refs/remotes/upstream/main` | `6eea9af69626953c597382ed993abdb622f66928` |
| merge base | `6eea9af69626953c597382ed993abdb622f66928` |

The worktree was already dirty before this rehearsal, with the task's Auto/Plan/UI
and InteractionCenter changes. `git merge-tree` only evaluates committed revisions,
so the working-tree delta is covered separately by the architecture guards, focused
tests, full package build, and full package test recorded below.

## Merge-tree rehearsal

Command:

```text
git merge-tree 6eea9af69626953c597382ed993abdb622f66928 1fd2bab6f617df34c33ce43046b01ed6f14d3f1b refs/remotes/upstream/main
```

Result: exit status 0, no output. The committed fork delta therefore has zero
textual merge conflicts against the current upstream tip. Because the merge base is
the upstream tip, this is a no-op rehearsal rather than evidence that future upstream
changes cannot conflict.

The committed fork delta currently touches these upstream hotspots:

* `Sources/CodeIsland/AppState.swift`
* `Sources/CodeIsland/HookServer.swift`
* `Sources/CodeIslandCore/SessionSnapshot.swift`
* `Sources/CodeIsland/NotchPanelView.swift`

The Phase 7 static guard keeps each hotspot at a one-contiguous-seam budget (and
`SessionSnapshot.swift` at zero new fork seam references). It also rejects direct
`TerminalActivator` calls and raw projection usage in `NotchPanelView.swift`, while
keeping provider JSON handling in `HookServer.swift` and upstream fact parsing in
`SessionSnapshot.swift`.

## Conflict and semantic-conflict accounting

| hotspot / scope | merge-tree conflicts | semantic conflicts requiring manual decision | disposition |
| --- | ---: | ---: | --- |
| `AppState.swift` | 0 | 0 in this no-op rehearsal | keep upstream facts; future Center ingress remains one seam |
| `HookServer.swift` | 0 | 0 in this no-op rehearsal | keep transport/protocol adapter ownership |
| `SessionSnapshot.swift` | 0 | 0 in this no-op rehearsal | keep upstream facts; no new fork-only state fields |
| `NotchPanelView.swift` | 0 | 0 in this no-op rehearsal | keep view-only projection/navigation boundary |
| fork-owned Core policy | not present in committed merge inputs | not assessed by merge-tree | covered by current-worktree guards and tests; rerun merge-tree after committing |

No fork-owned module was modified by the read-only rehearsal. The statement is about
the merge operation itself; it does not claim that the pre-existing dirty files are
ready for production cutover.

## Integrated validation status

The policy-only source subset passes syntax and type checking:

```text
swiftc -parse Sources/CodeIslandCore/InteractionTypes.swift Sources/CodeIslandCore/InteractionVisibility.swift Sources/CodeIslandCore/InteractionCenter.swift
swiftc -typecheck Sources/CodeIslandCore/InteractionTypes.swift Sources/CodeIslandCore/InteractionSupport.swift Sources/CodeIslandCore/InteractionVisibility.swift
```

After the Phase 6 consumer cutover and production owner wiring completed, the current
worktree passed:

```text
swift build
swift test
git diff --check
rg -n '^(<<<<<<<|=======|>>>>>>>)' Sources Tests
```

The final full suite executed 978 tests with 2 skipped and 0 failures. Focused gates
also cover production single-writer wiring, architecture budgets, visibility,
consumer privacy/compatibility, Hook/Codex transport, Auto, Plan, Question, and
SessionNavigator behavior. Production explicitly enables `adaptiveCLI`; the legacy
checkpoint remains available as the rollback policy.

Rollback point: phase-atomic rollback of the production runtime wiring plus the Core
visibility/presentation seam; do not restore legacy AppState writers alongside the
Center. After the task delta is committed, rerun this rehearsal against the new HEAD
so `merge-tree` includes the complete fork-owned implementation.
