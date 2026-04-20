# Feature Specification: Configurable Auto-Approve Tools

**Feature Branch**: `003-configurable-auto-approve`
**Created**: 2026-04-20
**Status**: Draft
**Input**: User description: "用户可配置的自动审批工具列表 — 将硬编码的 autoApproveTools 改为通过设置界面让用户自行选择哪些工具可以跳过权限确认"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Toggle Auto-Approve for Individual Tools (Priority: P1)

As a user, I want to see a list of tools that are currently auto-approved and toggle each one on/off individually in the settings, so that I have full control over which tool permission requests are silently approved versus requiring my manual confirmation.

**Why this priority**: This is the core value proposition — without it, the auto-approve behavior remains opaque and uncontrollable. Every other story builds on top of this.

**Independent Test**: Open Settings → Behavior → scroll to "Auto-Approve Tools" section → verify each tool has a toggle → toggle one off → trigger that tool in a CLI session → confirm manual approval UI appears instead of silent auto-approve.

**Acceptance Scenarios**:

1. **Given** the settings are at defaults (all tools enabled), **When** the user opens Behavior settings, **Then** all tools in the auto-approve list show as toggled ON
2. **Given** the user toggles OFF "ExitPlanMode", **When** a CLI session triggers ExitPlanMode, **Then** a manual permission confirmation UI appears in the panel instead of being auto-approved
3. **Given** the user toggles ON "ExitPlanMode", **When** a CLI session triggers ExitPlanMode, **Then** it is auto-approved silently without UI

---

### User Story 2 - Preserve Existing Behavior by Default (Priority: P2)

As a user who upgrades to this version, I want the auto-approve behavior to remain exactly the same as before the upgrade, so that my existing workflow is not disrupted.

**Why this priority**: Backwards compatibility is essential — any upgrade should be seamless. Users should only see changes when they actively modify settings.

**Independent Test**: Fresh install or upgrade without changing any settings → trigger any tool in the previous autoApproveTools set → verify it is still auto-approved silently.

**Acceptance Scenarios**:

1. **Given** a fresh install or upgrade with no user changes, **When** any of the original tools (TaskCreate, TaskUpdate, etc.) is triggered, **Then** they are all auto-approved as before
2. **Given** the user has never visited the new settings section, **When** checking settings storage, **Then** no per-tool override keys exist (defaults are used)

---

### User Story 3 - Clear Labeling and Localization (Priority: P3)

As a non-English-speaking user, I want the auto-approve tools section to be clearly labeled and described in my language, so that I understand what each setting does before changing it.

**Why this priority**: Accessibility and usability enhancement. Not blocking for core functionality but essential for non-English users.

**Independent Test**: Switch language to Chinese/Japanese/Korean/Turkish → open Behavior settings → verify the section title and description are localized correctly.

**Acceptance Scenarios**:

1. **Given** the app language is set to Chinese, **When** the user opens Behavior settings, **Then** the section title and description appear in Chinese
2. **Given** any supported language, **When** viewing the auto-approve tools section, **Then** each tool name remains in English (technical identifier) while section headers and descriptions are localized

---

### Edge Cases

- What happens when a tool name in the auto-approve list is not recognized by the current CLI version? → It should still appear in settings as a toggle (forward compatibility)
- What happens when the user toggles all tools OFF? → No tools are auto-approved; every permission request goes through manual UI
- What happens when the user has auto-approve mode active (long-press ALWAYS) AND has individual tool toggles OFF? → Session auto-approve (bypassPermissions) takes precedence over individual toggles

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The settings UI MUST display a list of all configurable auto-approve tools in the Behavior settings page
- **FR-002**: Each tool MUST have an individual toggle to enable/disable auto-approval
- **FR-003**: The default state for all existing tools MUST be ON (enabled), preserving current behavior
- **FR-004**: When a tool's auto-approve toggle is OFF, permission requests for that tool MUST be routed to the manual approval UI
- **FR-005**: Settings MUST persist across app restarts via user defaults
- **FR-006**: The HookServer MUST read user configuration at runtime instead of using a hardcoded tool list
- **FR-007**: The section MUST be localized in all 5 supported languages (en, zh, ja, ko, tr)
- **FR-008**: The hardcoded `autoApproveTools` constant in HookServer MUST be removed and replaced with the dynamic configuration

### Key Entities

- **AutoApproveToolSetting**: Represents a single tool's auto-approve preference. Key attributes: tool name (string identifier), enabled state (boolean). Stored as individual boolean keys in user defaults prefixed with `autoApproveTool_`.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Users can locate and modify auto-approve tool settings within 30 seconds of opening the settings window
- **SC-002**: All 10 previously hardcoded tools appear as individually configurable toggles
- **SC-003**: Zero behavior change for existing users who do not modify the new settings (backwards compatibility)
- **SC-004**: Each toggle change takes effect immediately on the next permission request from any active CLI session

## Assumptions

- The set of auto-approvable tools is known and finite at build time — users toggle existing tools but do not add arbitrary new tool names
- The Behavior settings page is the appropriate location (rather than creating a new top-level settings page) since this relates to app behavior
- Session-level auto-approve (long-press ALWAYS bypass) remains a separate mechanism and is not affected by individual tool toggles
- Tool names remain stable across CLI versions — the toggle list is defined at build time in the app
