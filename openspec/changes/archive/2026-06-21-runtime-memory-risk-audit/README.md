# runtime-memory-risk-audit — archived 2026-06-21

This change was implemented directly against `main` on 2026-06-21 without
following the standard OpenSpec experimental workflow (no `changes/<name>/`
delta specs were produced before implementation).

## What was archived

- The audit-backlog specification previously committed to
  `openspec/specs/runtime-memory-risk-audit/spec.md` is preserved here as
  `specs/spec.md`. It is the full specification document, not a delta spec,
  because the change bypassed the delta stage.

## How the implementation landed

The code changes implementing MEM-001 through MEM-007 are on `main`:

- `8ac67dc fix(memory): enforce caps and explicit ownership for MEM-001..MEM-007`
- `700b513 chore(openspec): sync runtime-memory-risk-audit spec`

The MEM-001..MEM-007 audit findings are documented in `specs/spec.md` and
the corresponding remediations are described inline in the fix commit
message and the in-source comments added to:

- `Sources/CodeIsland/PanelWindowController.swift`
- `Sources/CodeIsland/AppDelegate.swift`
- `Sources/CodeIsland/AppState.swift`
- `Sources/CodeIsland/AppState+CodexAppServer.swift`
- `Sources/CodeIslandCore/JSONLTailer.swift`
- `Sources/CodeIslandCore/CodexAppServerClient.swift`
- `Tests/CodeIslandCoreTests/CodexAppServerClientTests.swift`

## Why the standard workflow was skipped

The audit was performed and the spec was written and committed alongside the
implementation in a single working session to keep the risk register and its
remediation tightly coupled. Future audits should produce a delta spec in
`openspec/changes/<name>/specs/` first and only sync to main specs after
the implementation is reviewed.
