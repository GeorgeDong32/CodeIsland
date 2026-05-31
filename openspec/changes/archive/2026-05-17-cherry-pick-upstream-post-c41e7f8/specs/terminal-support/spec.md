## ADDED Requirements

### Requirement: Post-boundary terminal routing fixes are synced without broad terminal rewrites

The system SHALL selectively import upstream terminal/session routing fixes after `c41e7f8` only when they improve existing supported-terminal behavior without requiring a broad terminal subsystem rewrite.

#### Scenario: WezTerm-family panes resolve by CLI TTY
- **WHEN** a session runs inside a WezTerm-family pane and the originating CLI TTY is available
- **THEN** terminal routing MUST use the CLI TTY signal to resolve the originating pane
- **AND** the change MUST preserve existing terminal detection signals for Ghostty, Apple Terminal, iTerm2, tmux, kitty, Warp, Alacritty, and cmux

#### Scenario: Terminal fixes do not regress tab-level notification suppression
- **WHEN** a terminal routing fix is cherry-picked from upstream
- **THEN** notification suppression MUST remain scoped to the originating tab or pane
- **AND** foregrounding the same terminal app on a different tab MUST NOT suppress the originating session's notification

#### Scenario: Terminal sync remains separate from new CLI feature work
- **WHEN** a candidate upstream commit introduces a new CLI integration or broad lifecycle feature
- **THEN** it MUST be deferred from this terminal-routing sync unless it is required by a selected bugfix
- **AND** the deferred work MUST be handled in a separate change with its own specification
