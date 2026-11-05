# Animation Performance (Mascots & Loops)

> How CodeIsland animates the notch/mascots without burning CPU.
> Established during the 1.2.21 power pass; baselines recorded at the bottom.

---

## Why this spec exists

A single working session's mascot cost ~7–8% CPU at idle (measured, v1.2.20),
and the always-on `TimelineView(.periodic)` redraw path was the whole story:
every tick re-evaluates the SwiftUI body, re-runs the `Canvas` draw closure,
walks the display list and commits a CA transaction. Research summary:

| Evidence | Finding |
| --- | --- |
| Punkbit benchmark | Timer-driven per-frame redraw = 50% CPU; sparse states + CA interpolation = 2% |
| WWDC23 "Explore SwiftUI animation" | Built-in animatable attributes (offset/opacity/scale) interpolate off-main-thread without calling view code |
| Codevisor (production) | "repeatForever is composited by the render server — NOT TimelineView(.animation), which re-computes body at display refresh rate" |
| OpenSwiftUI (2026) | SwiftUI animations still sample in-process (display-link, off-main) — cheaper than TimelineView by an order; true zero-per-frame = raw CAKeyframeAnimation on CALayer |
| R-Pets sprite approach | CALayer `contentsRect` + discrete keyframes = GPU-side, "preferred for many simultaneous pets" |

## The three tiers (selection rule: use the cheapest tier that can express the motion)

### T0 — schedule throttle (baseline, applies to everything)

`MascotTimeline` uses `TimelineView(.animation(minimumInterval:))`, never
`.periodic`. `.periodic` never throttles; `.animation` aligns to vsync and the
system may adapt the cadence. Floor stays 20 fps (`minInterval 0.05`).

### T1 — CA-driven loops (whole-body affine motion)

Express periodic motion as **sparse states + animatable modifiers** so Core
Animation interpolates without per-tick app work:

- Whole-body hover/breathe → static `Canvas` + `.offset(y:)` / `.opacity`
  with `.animation(.easeInOut(duration:).repeatForever(autoreverses:))`.
- Discrete cycling (blinking, shimmer) → `PhaseAnimator`, or a state toggle
  with an animated transition (`TypingIndicator` is the in-tree example —
  `withAnimation(.repeatForever)` on a gradient offset; the mascot views'
  glow circles use the same idiom).
- Moving decorations (z's, bubbles) → independent small views, each with
  its own staggered `repeatForever` offset/opacity animation.
- The `Canvas` closure must not take `t` for T1 scenes — it draws the static
  body once. No `MascotTimeline` in idle/work scenes.
- **Allowed to stay on TimelineView**: alert-style short bursts (event-driven,
  a few seconds), one-off transitions, and anything driven by external data
  (MorphText streaming).

Iron rules (unchanged): parts never detach from the body; breathing is
opacity, not dismemberment; every change is validated with the
MascotRenderHarness motion-compensated checker (see `mascot-dev-conventions`
memory: sheet layout, dy/jumpY/shake compensation formulas).

### T2 — sprite sheets (procedural cycles; the fleet-wide resolution)

**Empirical resolution (1.2.21 pass):** the fleet's scenes turned out to be
overwhelmingly procedural (asymmetric breath curves, thinking-pause quirks,
humanized typing cadence, REM blinks) — T1 modifier rewrites would have
regressed the visuals. So every supported source's idle/work scenes play
as T2 strips (28 direct sources incl. devin; 6 supported source ids are
aliases whose views match a striped sibling — `SpriteLoopPlayer.stripAliases`:
cursor-cli→cursor, qoderwork→qoder, codybuddycn→codebuddy, aiwork-cli→aiwork,
google-antigravity→gemini, dsh→claude). T1 remains the technique for NEW
simple mascots and non-mascot loops (TypingIndicator, glows). The strips
are rendered from the SAME SwiftUI views by the harness, so playback is
pixel- and cadence-identical to the live render by construction.
`testSpriteCoverageForAllSupportedSources` fails the build if any
supported source would fall back to live rendering. Power measured at 0%
for devin, google-antigravity and cursor-cli previews — the engine cost is
source-independent.

1. `scripts/gen-mascot-sprites.sh` runs `MascotRenderHarness/
testRenderSpriteStrips` (env-gated like the sheets): per source × scene a
grid-layout PNG (20 cols; idle 100 f @ 0.12 s, work 260 f @ 0.05 s — durations
cover the longest quirk cycle in the fleet) plus `manifest.json` land in
`Sources/CodeIsland/Resources/mascot-sprites/` and get committed. **Any
mascot view change must be followed by a regeneration** — stale strips keep
playing the old animation.
2. `SpriteLoopPlayer` (NSViewRepresentable) hosts a bare `CALayer` and plays
a `CAKeyframeAnimation` on `contentsRect` (`calculationMode: .discrete`,
`repeatCount: .infinity`, duration = frames × interval ÷ speed). WindowServer
composites every frame — zero per-frame app work. `MascotView` routes
idle/processing/running through the player when a strip exists and falls
back to the live view otherwise (so reverting the assets is safe).
3. Alert stays live-rendered (short event bursts, rarely on screen).

**Idle never freezes (iron rule):** the sprite player ALWAYS animates — the
idle-settled static sleeping frame (#299) existed to stop live per-frame
rendering costs, which sprite playback doesn't have (measured 0% app CPU
collapsed while playing; the CA animation advances on the presentation
layer at the strip's designed cadence). The animation gate still governs
the live-view fallback branch. Overhead guards: `stripExists` answers
routing from the manifest without decoding, and the decoded-strip cache is
LRU-capped (8 entries ≈ worst ~130MB; idle 6.5MB / work 17MB each).

Verification layers (all in `MascotRenderHarness`, run with the normal
suite): `testSpriteStripFaithfulness` asserts strip properties per source
(no empty frames, loop animates — Grok's mark is static by design —, poses
stay in-cell, and per-source envelope-occupancy baselines that a 54-in-64
geometry regression fails across the board); `testCaptureSpritePlayback`
asserts the player layer's pattern against the strip's frame-0 cell.
When regenerating strips with changed view geometry, update the baseline
table in the same commit. Bitmap reads must pin `order32Big` (ARM default
is 32Little and +3 reads BLUE), honor `bytesPerRow` padding, and zero
buffers.

## Watchers and timers (the non-animation half)

- File-arrival watchers use `DispatchSource` (filesystem / `.write` on an open
  fd), never polling timers. Precedent: `McodePermissionLogWatcher` moved from
  a 2 s poll to a directory DispatchSource in the same pass.
- Long-period housekeeping timers are fine; tight (<5 s) polls are not.

## Power benchmark (the acceptance gate)

`scripts/measure-mascot-power.sh [app-bundle]` measures 60 s × two states —
collapsed (compact bar only; hover-in then hover-out first, preview starts
expanded) and expanded (cursor parked on the notch) — with one working
session (`--preview working`). Needs the `/tmp/mousemove` CGEvent helper:

```swift
import CoreGraphics
let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: Double(CommandLine.arguments[1])!,
                                             y: Double(CommandLine.arguments[2])!),
                mouseButton: .left)!
e.post(tap: .cghidEventTap)
```

Run before and after any animation change; record both rows here:

| Build | collapsed | expanded |
| --- | --- | --- |
| v1.2.20 (baseline, `097411c`) | 7% avg / 12% peak | 8% avg / 10% peak |
| v1.2.21 T0 (schedule throttle) | 0–1% avg / 1% peak | 3% avg / 11% peak |
| v1.2.21 T2 (sprite playback) | 0% avg / 6% peak | 0% avg / 7% peak |

Peaks are transient (hover transitions); averages are the steady state.

Acceptance for the power goal: both states ≤ 2% average with animation
visually unchanged (harness-verified) — animations are never paused or
frozen; the island stays alive by design.
