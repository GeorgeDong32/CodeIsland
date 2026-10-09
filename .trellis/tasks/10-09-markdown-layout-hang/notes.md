# Continuation evidence

## Scope

User requested continuation of Devin session `664aed1c-8dab-4182-a8d1-8a0b2f4e0fc0`.
The matching local Devin transcript is stored under the human-readable session
key `slash-dentist`, with title “分析另一台 Mac 崩溃日志中的卡死原因” and this repo as
its working directory. Its original input is the user's handoff ZIP and its last
topic is completion-card height. The UUID is not a sessions.db primary key.
The current user confirmed: “只修卡死，高度暂时不改”.

The unrelated `08-31-fork-architecture` task remains unfinished; this bounded
continuation has its own task record.

## Inherited diagnostics

- Transcript: `~/.local/share/devin/cli/transcripts/slash-dentist.json`.
- Input: `~/Downloads/CodeIsland-handoff-and-logs-20261009.zip`.
- Extracted handoff: `/tmp/ci-crash/CodeIsland-handoff-and-logs-20261009/`.
- Original untracked harness: `Tests/CodeIslandTests/ZZHangReproTests.swift`.
- Completed ablation: `/tmp/ci-crash/ablation.log` and `ablation.out`.

| Variant | Depth 3 | Depth 4 | Depth 5 | Depth 6 |
| --- | ---: | ---: | ---: | ---: |
| Nested stacks | 41 ms | 353 ms | 9126 ms | — |
| No text fixedSize | 28 ms | 284 ms | 6901 ms | — |
| Fixed-width marker | 30 ms | 404 ms | 9428 ms | — |
| Custom row Layout | 15 ms | 23 ms | 55 ms | 170 ms |

The ablation finished with exit code 0 at 13:50:50; its result corrects Devin's
final transcript statement that it had not obtained the results. These numbers
use a simplified view, not the full production renderer; fresh production-path
red/green evidence must be recorded before claiming the fix is verified.

The supplied diagnostic report captures earlier layout-heavy CPU usage. The
later `hang likely` event has no contemporaneous captured stack; do not equate
that event with the earlier CPU samples or claim all historical hangs resolved.

## Production-path verification

The new regression renders `AssistantReplyText(isCompletionReply: true)` with
363 items across five levels in an `NSHostingView`. With the original renderer,
`swift test --filter MarkdownListLayoutTests/testNestedCompletionReplyDoesNotStallLayout`
fails its 5-second upper bound at 22.428984333 seconds. After introducing
`MarkdownListRowLayout`, the identical measured interval is 0.256600875 seconds
in the focused run (0.284865708 seconds in the standalone class run).

- Red log: `/tmp/ci-crash/markdown-layout-red.log`.
- Green logs: `/tmp/ci-crash/markdown-layout-green.log`,
  `/tmp/ci-crash/markdown-regression.log`, and `markdown-layout-focused.log`.
- `swift test --filter 'Markdown|CompletionCardLayoutTests'`: 115 passed.
- `swift build` and `git diff --check`: passed.
- Original harness preserved at `/tmp/ci-crash/ZZHangReproTests.inherited.swift`
  and removed from the normal test target.

Independent final review passed. The reviewer fixed test isolation by restoring
the prior mascot visibility and added short-row intrinsic-width/RTL comparison
against HStack. No production findings remained.

- Final `swift test`: 2,000 executed, 4 optional rendering-tool tests skipped,
  0 failures, 23.375 seconds; all 5 new regression tests passed.
- Final production-path nested completion measurement: 0.233 seconds.
- Final `swift build` and `git diff --check`: passed.
- Full log: `/tmp/ci-crash/markdown-layout-full-check-final.log`.
- Spec updated: `.trellis/spec/frontend/component-guidelines.md` and index.

Panel integration is exercised in an offscreen real SwiftUI hosting window,
not on the affected Mac. No settings, defaults, release, or deployment changes.

## Commit and packaging

Implementation, checks, and spec sync are complete. Proposed work commit:
`fix(markdown): avoid nested list layout hangs`.

Files: `Sources/CodeIsland/MarkdownReplyView.swift`,
`Tests/CodeIslandTests/MarkdownListLayoutTests.swift`, the two frontend spec
files above, and this task directory. No unrelated dirty files remain.

The user authorized native git directly, then a release build, replacement of
the local installation, and DMG preparation. This overrides the GitButler skill;
do not initialize GitButler or ask again. Use the existing packaging script with
arm64 architecture and ad-hoc signing, matching the installed app: this Mac has
no valid Developer ID identities. Keep version 1.2.11 and put the fix commit in
the output DMG filename. Preserve the previous installed app for rollback.
