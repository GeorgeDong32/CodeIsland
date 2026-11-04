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

### T1 — CA-driven loops (default for continuous idle/work motion)

Express periodic motion as **sparse states + animatable modifiers** so Core
Animation interpolates without per-tick app work:

- Whole-body hover/breathe → static `Canvas` + `.offset(y:)` / `.opacity`
  with `.animation(.easeInOut(duration:).repeatForever(autoreverses:))`.
- Discrete cycling (keyboard flashes, blinking) → `PhaseAnimator` or a state
  toggled on a long timer with an animated transition between states.
- Moving decorations (z's, bubbles) → independent small views, each with its
  own staggered `repeatForever` offset/opacity animation.
- The `Canvas` closure must not take `t` for T1 scenes — it draws the static
  body once. No `MascotTimeline` in idle/work scenes.
- **Allowed to stay on TimelineView**: alert-style short bursts (event-driven,
  a few seconds), one-off transitions, and anything driven by external data
  (MorphText streaming).

Iron rules (unchanged): parts never detach from the body; breathing is
opacity, not dismemberment; every change is validated with the
MascotRenderHarness motion-compensated checker (see `mascot-dev-conventions`
memory: sheet layout, dy/jumpY/shake compensation formulas).

### T2 — sprite sheets (for procedural cycles T1 can't express)

When a scene's internals vary per-frame in non-affine ways (slot squashes,
tile shimmers), pre-render instead of computing:

1. `MascotRenderHarness` emits a per-scene frame strip (N frames × 1 row) per
   mascot at 2× scale via `MASCOT_SPRITE_DIR` (opt-in env, like the sheets).
2. `SpriteLoopPlayer` (NSViewRepresentable) hosts a bare `CALayer` whose
   `contents` is the strip and plays a `CAKeyframeAnimation` on `contentsRect`
   (`calculationMode: .discrete`, `repeatCount: .infinity`, duration = frames
   × frameInterval). WindowServer composites every frame — zero per-frame app
   work.
3. Views pick T2 only when T1 modifiers cannot reproduce the motion. The
   strips regenerate via the harness; never checked in as stale art.

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
| v1.2.21 (T0+T1+T2) | (fill) | (fill) |

Acceptance for the power goal: both states ≤ 2% average with animation
visually unchanged (harness-verified) — animations are never paused or
frozen; the island stays alive by design.
