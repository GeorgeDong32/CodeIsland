# Data Model: Configurable Auto-Approve Tools

**Feature**: 003-configurable-auto-approve
**Date**: 2026-04-20

## Entities

### AutoApproveToolSetting (implicit)

No new struct needed — each tool's preference is stored as a boolean in UserDefaults.

**Storage keys**: `autoApproveTool_{toolName}` (e.g., `autoApproveTool_ExitPlanMode`)

**Value**: Boolean — `true` = auto-approve, `false` = require manual confirmation

**Default**: If key is absent, fallback to `SettingsDefaults.autoApproveDefaultTools` set membership

### All Tools (defined at build time)

| Tool Name           | Default |
|---------------------|---------|
| TaskCreate          | ON      |
| TaskUpdate          | ON      |
| TaskGet             | ON      |
| TaskList            | ON      |
| TaskOutput          | ON      |
| TaskStop            | ON      |
| TodoRead            | ON      |
| TodoWrite           | ON      |
| EnterPlanMode       | ON      |
| ExitPlanMode        | ON      |

## State Transitions

```
User toggles tool OFF:
  UserDefaults["autoApproveTool_ExitPlanMode"] = false
  → Next PermissionRequest for "ExitPlanMode" → routed to manual approval UI

User toggles tool ON:
  UserDefaults["autoApproveTool_ExitPlanMode"] = true
  → Next PermissionRequest for "ExitPlanMode" → auto-approved

Key absent (fresh install / upgrade):
  → Fallback to default set → all tools ON → backwards compatible
```

## Validation Rules

- Tool names are defined at build time — no runtime validation needed
- Boolean values only — no invalid states possible
- Missing keys → use default (all ON)
