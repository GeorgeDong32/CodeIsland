## Tasks

- [x] Add `PermissionIndicatorConfig` struct and `permissionIndicatorConfig(for:)` mapping helper in `NotchPanelView.swift` near `SessionIdentityLine`
- [x] Replace `appState.isAutoApproveActive(for: sessionId)` indicator condition with `permissionIndicatorConfig(for: session.permissionMode)`
- [x] Render indicator using `config.symbol` and `config.color` from the mapping
- [x] Preserve `.onTapGesture` calling `appState.toggleAutoApprove(sessionId:)` only for fast-forward modes (`auto`, `acceptEdits`, `bypassPermissions`)
- [x] Render `plan` indicator as static display (no tap gesture)
- [x] Render no indicator for `default` / unknown / nil `permissionMode`
- [x] Build Debug and manually verify each permission mode appearance and click behavior
