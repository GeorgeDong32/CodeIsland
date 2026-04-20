# Quickstart: Configurable Auto-Approve Tools

**Feature**: 003-configurable-auto-approve
**Date**: 2026-04-20

## For Developers

### Files to Modify

1. **`Sources/CodeIsland/Settings.swift`**
   - Add `SettingsKey.autoApproveTool(_:)` function
   - Add `SettingsDefaults.autoApproveDefaultTools` set
   - Add `SettingsManager.allAutoApproveTools` static array
   - Add `SettingsManager.isAutoApproveTool(_:)` method
   - Add `SettingsManager.setAutoApproveTool(_:enabled:)` method

2. **`Sources/CodeIsland/SettingsView.swift`**
   - Add new Section in `BehaviorPage` with ForEach toggle list

3. **`Sources/CodeIsland/HookServer.swift`**
   - Remove `autoApproveTools` static constant
   - Replace hardcoded check with `SettingsManager.shared.isAutoApproveTool()`

4. **`Sources/CodeIsland/L10n.swift`**
   - Add `auto_approve_tools` and `auto_approve_tools_desc` keys to all 5 languages

### Testing

1. Build: `swift build` or Xcode
2. Open Settings → Behavior → verify new section appears
3. Toggle OFF a tool → trigger in CLI → confirm manual approval required
4. Toggle ON → confirm auto-approve restored

### Key Behavior

- **Defaults**: All 10 tools ON (backwards compatible)
- **Precedence**: Session auto-approve (bypassPermissions) > individual toggles
- **Persistence**: UserDefaults, survives app restart
