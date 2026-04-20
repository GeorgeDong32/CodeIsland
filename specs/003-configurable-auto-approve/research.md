# Research: Configurable Auto-Approve Tools

**Feature**: 003-configurable-auto-approve
**Date**: 2026-04-20

## R1: How to store per-tool auto-approve preferences

**Decision**: Use individual boolean keys in UserDefaults with prefix `autoApproveTool_`.

**Rationale**:
- Consistent with existing SettingsManager pattern (all settings use individual UserDefaults keys)
- No schema migration needed — missing keys fall back to defaults
- `@AppStorage` in SwiftUI can bind directly to each key
- Simple, no additional serialization complexity

**Alternatives considered**:
- Single array/set in UserDefaults → requires serialization, harder to use with `@AppStorage`
- Separate plist file → unnecessary complexity for 10 boolean values
- SQLite/CoreData → massive overkill

## R2: Where to define the list of configurable tools

**Decision**: Define as a static array in `SettingsManager` (alongside the default set).

**Rationale**:
- `SettingsManager` is already the central place for all settings definitions
- `HookServer` can call `SettingsManager.shared.isAutoApproveTool()` at runtime
- The list is small (10 items), no need for external configuration

**Alternatives considered**:
- Define in HookServer → violates separation of concerns (UI settings vs server logic)
- Define in CodeIslandCore → possible but unnecessary indirection for this feature

## R3: UI placement within Behavior settings

**Decision**: Add a new Section at the bottom of BehaviorPage, after the existing "Sessions" section.

**Rationale**:
- BehaviorPage already contains display and session behavior settings
- Auto-approve is a behavioral concern (how the app responds to tool requests)
- A new Section with the same `Form` + `Section` pattern keeps visual consistency

**Alternatives considered**:
- New top-level settings page → too heavy for a single toggle list
- HooksPage → already focused on CLI hook installation, not permission behavior

## R4: Interaction with session-level auto-approve (bypassPermissions)

**Decision**: Session auto-approve takes precedence over individual tool toggles.

**Rationale**:
- The existing bypassPermissions flow sends `setMode: bypassPermissions` which tells the CLI to skip all permission prompts entirely
- This is a CLI-side bypass, not a HookServer decision — the hook never sees the request
- Individual toggles only affect requests that reach HookServer for evaluation
- No code change needed for this behavior — it already works this way by nature of the precedence order in `processRequest`

## R5: Localization strategy

**Decision**: Add 2 new keys per language in L10n.swift (section title + description).

**Rationale**:
- Follows existing L10n.swift pattern exactly
- Tool names are technical identifiers and should NOT be translated
- Only the section header and description text need localization
