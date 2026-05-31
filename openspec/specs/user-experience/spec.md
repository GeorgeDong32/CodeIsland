# User Experience Specification

## Purpose

This specification defines the user-facing presentation layer of CodeIsland: how strings are localized, how each AI tool is identified visually through pixel-art mascots, and the rules that ensure these systems stay coherent as new tools and languages are added. It is the canonical reference for internationalization (i18n) and the mascot system.

## Requirements

### Requirement: Bilingual String Externalization

All user-facing strings SHALL be externalized into a single localization layer (`L10n.swift`) supporting Chinese (Simplified) and English; raw natural-language strings MUST NOT appear in view code.

#### Scenario: New string is added through L10n

- **GIVEN** a contributor adds a new label, button title, alert message, or tooltip
- **WHEN** the string is referenced in a SwiftUI view or AppKit controller
- **THEN** the string MUST be looked up via `L10n.<key>` (or the equivalent localized accessor)
- **AND** the raw text MUST NOT be hardcoded in the view file

#### Scenario: Bundle ships both locales

- **WHEN** the app bundle is inspected after build
- **THEN** the bundle MUST contain a `zh-Hans.lproj/` directory with the Simplified Chinese strings
- **AND** the bundle MUST contain an `en.lproj/` directory with the English strings
- **AND** every key referenced via `L10n` MUST have an entry in BOTH locale bundles

#### Scenario: System locale drives display language

- **GIVEN** the user's macOS preferred languages list places `zh-Hans` first
- **WHEN** the app launches
- **THEN** all strings MUST display in Simplified Chinese
- **AND** the app MUST NOT expose a separate language toggle for users to manually override the system locale, unless explicitly required

#### Scenario: English fallback for unsupported locale

- **GIVEN** the user's preferred languages list contains no supported language
- **WHEN** the app launches
- **THEN** strings MUST fall back to English (`en.lproj/`)
- **AND** the app MUST NOT crash, display empty strings, or display raw key names

### Requirement: Localization Coverage Audit

Pull requests adding user-facing UI SHALL include corresponding entries in both locale bundles; review MUST verify both locales are updated.

#### Scenario: Adding UI requires both translations

- **GIVEN** a PR introduces a new key `L10n.settingsRemoteHostsTitle`
- **WHEN** the PR is opened
- **THEN** the diff MUST include both the Chinese (`zh-Hans.lproj/Localizable.strings`) and English (`en.lproj/Localizable.strings`) entries for the key
- **AND** missing translations in either locale MUST block the merge

### Requirement: Per-Source Mascot Identification

Each supported AI coding tool SHALL have a distinct pixel-art mascot animation; the mascot MUST be selected based on the active session's `source` identifier.

#### Scenario: Mascot keyed by source

- **GIVEN** a session with `source = "claude"`
- **WHEN** the notch panel renders the mascot view
- **THEN** `MascotView` MUST load the mascot resource keyed `claude` from `Resources/mascots/`
- **AND** the rendered animation MUST be visually distinct from mascots for other sources

#### Scenario: Resource location

- **WHEN** a contributor adds a new mascot
- **THEN** the resource file MUST be placed in `Sources/CodeIsland/Resources/mascots/<source>.<ext>` (where `<ext>` is `gif`, `png`, or another supported animated format)
- **AND** the file name (minus extension) MUST exactly match the canonical source identifier

#### Scenario: Aliased sources resolve to canonical mascot

- **GIVEN** a session with raw source `factory` (alias of `droid`)
- **WHEN** the mascot view consults `SessionSnapshot.normalizedSupportedSource`
- **THEN** it MUST receive the canonical name `droid`
- **AND** it MUST load the mascot resource for `droid`, not for `factory`

### Requirement: Pauseable Mascot Animation

Mascot animations SHALL be pauseable via the user-controlled animation speed setting; setting speed to 0% MUST freeze the animation.

#### Scenario: Speed slider freezes animation

- **GIVEN** the user opens Settings and drags the animation speed slider to 0%
- **WHEN** the change is applied
- **THEN** the active mascot MUST stop on its current frame
- **AND** the mascot MUST NOT consume CPU for animation timer ticks while frozen

#### Scenario: Restoring speed resumes animation

- **GIVEN** an animation frozen at 0%
- **WHEN** the user moves the slider to any non-zero value
- **THEN** the animation MUST resume playback at the requested rate
- **AND** the resumed animation MUST start from the current frame, not from frame 0

### Requirement: Recently-Active Idle Mascot

When no AI session is active, the notch panel SHALL display the mascot of the most-recently active CLI rather than an arbitrary default.

#### Scenario: Last-used mascot persists

- **GIVEN** the user has just finished a session with `source = "codex"`
- **WHEN** the session terminates and no other sessions are active
- **THEN** the idle notch SHALL display the `codex` mascot
- **AND** the displayed mascot MUST persist until a new session of a different source becomes active

#### Scenario: First-launch idle state

- **GIVEN** a fresh install with no prior session history
- **WHEN** the user opens the panel for the first time before any AI tool runs
- **THEN** the idle mascot MAY display a documented default
- **AND** once any session runs, the most-recently-active rule applies thereafter

### Requirement: Mascot Background Compatibility

Mascot resources SHALL use white or transparent backgrounds to remain readable on both the dark notch chrome and project documentation contexts (README screenshots).

#### Scenario: New mascot has transparent or white background

- **WHEN** a contributor adds a new mascot resource
- **THEN** the file MUST have either a transparent background (preferred) or a solid white background
- **AND** non-white opaque backgrounds (e.g., grey, colored) MUST NOT be used

#### Scenario: Visual consistency check

- **GIVEN** a PR adds a mascot
- **WHEN** the reviewer inspects the resource
- **THEN** the mascot MUST be visually coherent with existing mascots in pixel scale and proportion
- **AND** the resource MUST display correctly on both the notch panel chrome and a white documentation background

### Requirement: Mascot Coverage for Supported CLIs

Every CLI in the built-in `CLIConfig` registry SHALL have a corresponding mascot resource; adding a CLI without a mascot is permitted only with documented justification.

#### Scenario: Built-in CLI has mascot

- **GIVEN** a CLI is present in the built-in registry described by the `hook-protocol` spec
- **WHEN** the app inventories mascot resources at build time
- **THEN** a mascot file matching the canonical source identifier MUST exist under `Resources/mascots/`

#### Scenario: Custom CLI without mascot falls back

- **GIVEN** a user-defined `CustomCLIConfig` with no mascot resource
- **WHEN** a session for that custom CLI becomes active
- **THEN** `MascotView` MUST display a documented generic fallback mascot
- **AND** the app MUST NOT crash or render an empty space

### Requirement: Session Card Permission Indicator

The session card SHALL display a permission-mode indicator driven by the hook-reported `permissionMode` field, with icon and color varying by CLI permission mode.

#### Scenario: Permission mode indicator rendering

- **GIVEN** a session with a hook-reported `permissionMode`
- **WHEN** the session card renders its identity line
- **THEN** the indicator SHALL render as follows:
  - `bypassPermissions` → `⏵⏵` in `#ff6666` (red)
  - `auto` → `⏵⏵` in `#ffcc00` (yellow)
  - `acceptEdits` → `⏵⏵` in `#af87fe` (purple)
  - `plan` → `⏸` in `#73b3b0` (teal)
  - `default` → no indicator

#### Scenario: Fast-forward modes are tappable

- **GIVEN** a session with `permissionMode` in {`auto`, `acceptEdits`, `bypassPermissions`}
- **WHEN** the user taps the `⏵⏵` indicator
- **THEN** the app SHALL call `toggleAutoApprove(sessionId:)` for that session

#### Scenario: Plan indicator is static

- **GIVEN** a session with `permissionMode = "plan"`
- **WHEN** the session card renders
- **THEN** the `⏸` indicator SHALL NOT have a tap gesture attached
- **AND** taps within its bounds SHALL fall through to the parent card
