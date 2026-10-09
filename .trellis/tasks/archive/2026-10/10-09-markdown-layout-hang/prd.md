# Fix nested Markdown completion-card hangs

## Goal and authorization

Continue the Devin investigation requested on 2026-10-09. The user explicitly
selected “只修卡死，高度暂时不改”: fix the hang only, without height controls or
height/default changes. This is a bounded rendering bug fix, independent of the
unfinished fork-architecture task; lightweight PRD-only execution applies.

Follow-up authorization: use native git to commit the completed fix, build a
release app, replace this Mac's installation, and prepare a DMG. No additional
confirmation or GitButler initialization is needed. The user then explicitly
requested a version bump: ship the local app and DMG as 1.2.12, with both bundle
version fields and the bilingual changelog updated.

## Evidence

- Devin's local `slash-dentist` transcript in this repository analyzed the supplied
  `CodeIsland-handoff-and-logs-20261009.zip` and left only the untracked
  `Tests/CodeIslandTests/ZZHangReproTests.swift` harness.
- The supplied CPU report points to SwiftUI recursive stack layout. It is not a
  captured stack at the later actual hang, so avoid claiming all historical hangs
  are proven to have this cause.
- `/tmp/ci-crash/ablation.log` and `ablation.out` show the ablation finished:
  depth-5 ternary lists take 9126 ms with stacks, 6901 ms without text fixedSize,
  9428 ms with fixed-width markers, and 55 ms with custom row layout (depth 6:
  170 ms). The transcript's final statement that results were missing is stale.
- The real AssistantReplyText completion path was previously measured at ~22 s
  for 363 nested list items. Reproduce and assert the real path before fixing.

## Requirements

- Eliminate multiplicative recursive list row measurement in the real Markdown
  reply renderer, preserving complete content and existing layout semantics.
- Preserve bullets, ordered markers, checkboxes, wrapping, indentation, code,
  tables, links, and existing completion card scrolling/height settings.
- Keep changes local to Markdown rendering and meaningful regression tests.
- No changes to settings, panel height, defaults, architecture migration,
  permissions, hooks, or session state. Version 1.2.12, local installation and
  DMG packaging are authorized; remote publishing is outside scope.
- Preserve the diagnostic evidence outside the test target, then remove the
  throwaway harness from the normal suite once replaced by regression coverage.

## Acceptance criteria

- A test through the production AssistantReplyText/completion rendering path
  detects the pre-fix multi-second nested-list stall and passes after the fix.
  Use generous timing bounds and/or deterministic measurement counts; document
  red and green evidence. Include realistic panel/open/update validation.
- Regression coverage exercises narrow/unspecified/zero/finite width proposals,
  ordered/task list markers, and nested wrapping where relevant to new layout.
- Existing Markdown and completion-card tests pass, `swift build` succeeds,
  and full `swift test` passes (report any independently established baseline
  failures rather than expanding scope).
- No debug probes or throwaway performance tests remain in normal test target.
- Independent Trellis check reviews rendering behavior and test effectiveness.
- Commit with native git, verify the release bundle and DMG, replace the local
  app with a rollback copy retained, and confirm it starts successfully.

## Execution

1. Load frontend guidelines and review the inherited harness/evidence.
2. Build a red regression through the real renderer; validate layout hypothesis.
3. Implement the smallest bounded row-layout fix and run focused tests/build.
4. Independent check, full suite, spec note, and local commit if supported.

Rollback: revert the Markdown renderer change and its new tests together.
