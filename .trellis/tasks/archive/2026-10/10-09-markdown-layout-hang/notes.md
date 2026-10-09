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
not on the affected Mac. The original fix phase changed no settings, defaults,
release metadata, or installation; the subsequent packaging work is recorded below.

## Commit and packaging

Implementation, checks, and spec sync are complete. Work commit:
`fix(markdown): avoid nested list layout hangs`.

Files: `Sources/CodeIsland/MarkdownReplyView.swift`,
`Tests/CodeIslandTests/MarkdownListLayoutTests.swift`, the two frontend spec
files above, and this task directory. No unrelated dirty files remain.

The user authorized native git directly, then a release build, replacement of
the local installation, and DMG preparation. This overrides the GitButler skill;
do not initialize GitButler or ask again. Use the existing packaging script with
arm64 architecture and ad-hoc signing, matching the installed app: this Mac has
no valid Developer ID identities. A subsequent explicit request authorized the
version bump to 1.2.12 (both bundle version fields and bilingual changelog).
The fix is committed as `627ba5d`; version metadata is committed as `e4c9c2e`.

## Release build and local installation

- Built optimized arm64 binaries with
  `BUILD_ARCH=arm64 SKIP_SIGN=1 SKIP_NOTARIZE=1 ./scripts/build-dmg.sh 1.2.12`.
- This machine has no Developer ID signing identities. The new bundle uses
  ad-hoc signing with the existing entitlements, as did the previous install.
- The create-dmg HFS image gained `com.apple.FinderInfo` inside the app and
  failed mounted nested-signature verification although the staging app passed.
  Kept it as `.build/CodeIsland-1.2.12-create-dmg-rejected.dmg`; never installed
  or distributed it. Repacked the same verified staging app plus Applications
  link using `hdiutil create -fs APFS -format UDZO`. The APFS image passed both
  checksum verification and mounted `codesign --verify --deep --strict`.
- Verified both bundle versions, arm64 app/helper/Sparkle architecture, icon,
  Applications link, mounted executable/helper hashes against staging, and
  installed executable hash against the verified release bundle.
- Delivered `/Users/gd32/Downloads/CodeIsland-1.2.12-arm64.dmg` (12,005,657 bytes)
  plus `.dmg.sha256`. Canonical build copy: `.build/CodeIsland.dmg`.
- SHA-256: `f9fe39dffc69af2f0d7b6b9580f08c97d1ac6e6a8026170f8132594f79f99609`.
- Replaced `/Applications/CodeIsland.app` after a graceful quit, preserving
  rollback copies under `.build/install-backups/pre-1.2.12-zicb7lj0/`.
- Relaunched app PID 96950; NSWorkspace reports finishedLaunching=true and
  terminated=false, and `/tmp/codeisland-501.sock` accepts connections.
- Build log: `/tmp/ci-crash/build-dmg-1.2.12.log`; local manifest:
  `.build/release-1.2.12-verification.json` (source commit `e4c9c2e`).
- No notarization, git push, remote release, or appcast publication performed.
