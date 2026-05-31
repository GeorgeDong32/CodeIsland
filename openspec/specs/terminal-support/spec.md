# Terminal Support Specification

## Purpose

This specification defines how CodeIsland identifies the terminal environment in which an AI coding session is running, distinguishes IDE-integrated terminals from native app contexts, suppresses notifications at the appropriate granularity, and tunnels remote sessions over SSH. It is the canonical reference for terminal compatibility and remote-host monitoring.

## Requirements

### Requirement: Universal Terminal Detection

CodeIsland SHALL detect the user's terminal environment without requiring manual configuration; supported terminals MUST be identified using a documented set of environment-variable signals.

#### Scenario: Supported terminal coverage

- **GIVEN** a user launches an AI coding CLI inside one of the supported terminals
- **WHEN** the bridge collects terminal context
- **THEN** the following terminals MUST be recognized:
  - iTerm2
  - Apple Terminal (`Terminal.app`)
  - Ghostty
  - WezTerm
  - kitty
  - tmux
  - Warp
  - Alacritty
  - cmux

#### Scenario: Detection uses multiple signals

- **WHEN** the bridge attempts to identify the host terminal
- **THEN** detection MUST consider all of the following signals (in combination, not exclusively):
  - `TERM_PROGRAM` environment variable
  - `__CFBundleIdentifier` environment variable
  - `ITERM_SESSION_ID` environment variable
  - `KITTY_WINDOW_ID` environment variable
  - `TMUX_PANE` environment variable
  - `CMUX_SURFACE_ID` environment variable
  - `CMUX_WORKSPACE_ID` environment variable

#### Scenario: iTerm2 GUID extraction

- **GIVEN** an `ITERM_SESSION_ID` of the form `w0t0p0:<GUID>`
- **WHEN** CodeIsland needs the session GUID for AppleScript activation
- **THEN** the `w<n>t<n>p<n>:` prefix MUST be stripped
- **AND** the remaining GUID MUST be used to target the specific iTerm2 tab

### Requirement: IDE Integrated Terminal Distinction

When an AI CLI runs inside an IDE's integrated terminal, CodeIsland SHALL distinguish that context from the IDE's native app mode using bundle-ID heuristics.

#### Scenario: Recognized IDE integrated terminals

- **WHEN** a hook event arrives with `_term_bundle` matching one of the IDE bundle identifiers
- **THEN** the session MUST be classified as "IDE integrated terminal" mode
- **AND** the recognized IDEs MUST include: VS Code, Cursor, JetBrains family, Zed, Xcode, Windsurf, Nova, Android Studio

#### Scenario: Native app mode requires both signals

- **GIVEN** an AI tool that has both a CLI mode and a native app mode (e.g., Cursor agent, Codex APP)
- **WHEN** classifying the session as "native app" rather than "CLI in terminal"
- **THEN** both the bundle ID AND the source identifier MUST match the native-app expectation
- **AND** a bundle-ID match alone MUST NOT trigger native-app classification

### Requirement: Tab-Level Notification Suppression

Notifications and sounds SHALL be suppressed only when the user is actively viewing the specific tab/pane that originated the event, not whenever the host terminal app is foregrounded.

#### Scenario: User watching the originating tab

- **GIVEN** a user has the originating terminal tab in focus
- **WHEN** an event that would normally produce a sound/notification arrives
- **THEN** the sound MUST be suppressed
- **AND** the visual notification MUST be suppressed

#### Scenario: User watching a different tab in same terminal

- **GIVEN** the user has a different tab in the same terminal app focused (not the originating tab)
- **WHEN** the event arrives
- **THEN** the notification MUST fire normally
- **AND** suppression MUST NOT operate at the terminal-app granularity

#### Scenario: Terminal app in background

- **WHEN** the host terminal app is not in the foreground
- **THEN** all notifications MUST fire normally regardless of tab focus

### Requirement: Remote Host Registration

CodeIsland SHALL allow users to register remote hosts whose AI sessions will be monitored over SSH; configuration MUST persist in `UserDefaults`.

#### Scenario: Adding a remote host

- **GIVEN** a user opens Settings and enters SSH connection details
- **WHEN** the user saves a new `RemoteHost` entry
- **THEN** the entry MUST be persisted via `RemoteManager` to `UserDefaults`
- **AND** the entry MUST contain at minimum: host alias, SSH destination, remote user, optional port

#### Scenario: Removing a remote host

- **WHEN** a user deletes a `RemoteHost` entry
- **THEN** any active SSH tunnel for that host MUST be terminated
- **AND** the entry MUST be removed from `UserDefaults`

### Requirement: SSH Tunnel Forwards Remote Socket

`SSHForwarder` SHALL establish an SSH tunnel that maps the remote machine's CodeIsland Unix socket to a local socket path, allowing the existing `HookServer` to receive events without modification.

#### Scenario: Tunnel maps remote to local socket

- **GIVEN** a registered `RemoteHost` with a known remote UID
- **WHEN** `SSHForwarder` connects
- **THEN** it MUST establish a `-L /tmp/codeisland-remote-<hostId>.sock:/tmp/codeisland-<remoteUid>.sock` (or equivalent stream-forward) tunnel
- **AND** the local socket path MUST be unique per remote host

#### Scenario: HookServer is unmodified for remote events

- **GIVEN** events arriving on a remote-tunneled socket
- **WHEN** the events flow into `HookServer`
- **THEN** the server MUST handle them using the same code path as local events
- **AND** no remote-specific branches in event parsing logic SHALL be required

### Requirement: Remote Session Namespacing

Sessions originating from remote hosts SHALL have their `session_id` namespaced with a `remote:<hostId>:` prefix to prevent collisions with local sessions sharing the same raw `session_id`.

#### Scenario: Remote session ID is prefixed

- **GIVEN** a session with raw `session_id = "abc-123"` arriving from remote host `myserver`
- **WHEN** the session is registered in the app's session map
- **THEN** the stored ID MUST be `remote:myserver:abc-123`
- **AND** local sessions MUST continue to use the raw `session_id` without prefix

#### Scenario: Collision prevention

- **GIVEN** a local session with `session_id = "xyz"` and a remote session with the same raw `session_id`
- **WHEN** both are active simultaneously
- **THEN** the two sessions MUST be tracked as distinct entries in the session map
- **AND** events MUST be routed to the correct entry based on origin

### Requirement: Remote Auto-Reconnect with Backoff

When an SSH tunnel disconnects, `SSHForwarder` SHALL automatically reconnect using exponential backoff to recover from transient network failures.

#### Scenario: Backoff schedule

- **GIVEN** an SSH tunnel that has just disconnected
- **WHEN** auto-reconnect runs
- **THEN** the first retry MUST occur after 5 seconds
- **AND** subsequent retries MUST use exponential backoff up to a maximum of 300 seconds (5 minutes) between attempts

#### Scenario: Maximum attempts is configurable

- **GIVEN** a configured maximum reconnect attempt count
- **WHEN** the count is reached
- **THEN** further reconnects MUST stop
- **AND** the host status MUST be reported as disconnected to the UI

#### Scenario: Successful reconnect resets backoff

- **WHEN** a reconnect attempt succeeds
- **THEN** the backoff interval MUST reset to its initial value (5 seconds)

### Requirement: Remote-Aware Process Monitoring

Local PID-based process monitoring SHALL NOT be applied to remote sessions, since the PID space is meaningless across hosts.

#### Scenario: Skip monitoring for remote session

- **GIVEN** a session whose ID has the `remote:<hostId>:` prefix
- **WHEN** `tryMonitorSession` is invoked for that session
- **THEN** the function MUST short-circuit and return without registering a process watcher
- **AND** the session lifecycle MUST be inferred from `Stop`/`SessionEnd` events instead

#### Scenario: Local sessions still monitored

- **GIVEN** a local session (no `remote:` prefix)
- **WHEN** `tryMonitorSession` is invoked
- **THEN** the function MUST register a normal PID-based watcher
- **AND** termination MUST be detected via process-exit signals

### Requirement: Permissions Scope for Remote

App permissions required to support remote sessions SHALL be limited to local network access; remote credentials MUST NOT be stored beyond what SSH itself requires.

#### Scenario: Local Network entitlement is sufficient

- **WHEN** the app establishes an SSH tunnel
- **THEN** the operation MUST function with only the Local Network entitlement
- **AND** no additional networking entitlements SHALL be required

#### Scenario: SSH credentials use system mechanisms

- **GIVEN** SSH authentication
- **WHEN** the user connects to a remote host
- **THEN** authentication MUST use the system's existing SSH facilities (ssh-agent, `~/.ssh/config`, key files)
- **AND** CodeIsland MUST NOT store SSH passwords or private key material in `UserDefaults` or its own keychain entries
