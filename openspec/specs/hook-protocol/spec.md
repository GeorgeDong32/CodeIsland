# Hook Protocol Specification

## Purpose

This specification defines how CodeIsland integrates with AI coding CLIs through a unified hook event protocol. It covers the native bridge binary (`codeisland-bridge`), the canonical event schema, the six hook installation formats, the data-driven CLI registry, and the graceful-degradation contract that prevents CodeIsland from interfering with the user's AI tool.

This spec governs the IPC boundary between AI tools and CodeIsland. Any change to event names, payload fields, hook formats, or installation logic MUST be reflected here.

## Requirements

### Requirement: Native Swift Bridge Binary

Hook events from AI tools SHALL be forwarded by a compiled Swift binary (`codeisland-bridge`), not by shell scripts performing string manipulation.

#### Scenario: Bridge is dependency-minimal

- **GIVEN** the `codeisland-bridge` executable
- **WHEN** the binary is built and inspected
- **THEN** it MUST link only against `Foundation` and `Darwin` system libraries
- **AND** the resulting binary SHALL be approximately 86 KB

#### Scenario: Bridge uses Unix Domain Socket transport

- **WHEN** the bridge forwards an event to the main app
- **THEN** it MUST connect to the Unix socket at `/tmp/codeisland-<uid>.sock` (where `<uid>` is the current user's numeric UID)
- **AND** it MUST send a single JSON object terminated by a newline
- **AND** it MUST NOT use TCP, named pipes, files, or any other transport

#### Scenario: Bridge parses JSON natively

- **WHEN** the bridge receives a payload from the AI tool's hook script
- **THEN** parsing MUST use `JSONDecoder` or `JSONSerialization` (no string regex/awk parsing)
- **AND** invalid JSON MUST cause silent exit (see graceful-degradation requirement)

#### Scenario: Bridge validates session_id before forwarding

- **GIVEN** an inbound payload from a hook script
- **WHEN** the bridge inspects the JSON
- **THEN** if `session_id` is missing, empty, or not a string, the bridge MUST exit silently with code 0
- **AND** the event MUST NOT be forwarded to the socket

#### Scenario: Bridge protects against signals

- **GIVEN** the bridge is connected to a socket whose peer disappears mid-write
- **WHEN** a `SIGPIPE` signal would be raised
- **THEN** the bridge MUST have installed a `SIGPIPE` handler (or `SO_NOSIGPIPE` on the socket) to prevent process termination

#### Scenario: Bridge enforces hard deadline

- **WHEN** the bridge starts execution
- **THEN** it MUST arm a `SIGALRM` watchdog with a default of 8 seconds (non-blocking events) or 24 hours (blocking events)
- **AND** if the watchdog fires, the bridge MUST exit silently

#### Scenario: Source can be supplied or inferred

- **WHEN** the bridge is invoked with `--source <name>`
- **THEN** the supplied source name MUST be used in the enriched event
- **AND** when `--source` is absent, the bridge MUST infer the source by walking the process ancestry (`getppid` chain) until a known CLI executable name is identified

### Requirement: Canonical Event Envelope

All hook events forwarded by the bridge SHALL conform to a shared JSON envelope with at minimum `hook_event_name` and `session_id`, plus enrichment fields prefixed with underscore.

#### Scenario: Required envelope fields

- **GIVEN** a forwarded event
- **WHEN** the main app's `HookServer` reads the JSON
- **THEN** the payload MUST contain a string field `hook_event_name`
- **AND** the payload MUST contain a non-empty string field `session_id`

#### Scenario: Bridge enriches with context fields

- **WHEN** the bridge forwards an event
- **THEN** it MUST add the following fields if available:
  - `_source` — CLI source identifier (claude, codex, gemini, …)
  - `_ppid` — parent process ID at hook invocation
  - `_tty` — TTY device path
  - `_tmux` — tmux pane identifier when `TMUX_PANE` is set
  - `_term_bundle` — `__CFBundleIdentifier` of the host terminal app
  - `_cmux_surface_id` — value of `CMUX_SURFACE_ID` environment variable
  - `_cmux_workspace_id` — value of `CMUX_WORKSPACE_ID` environment variable

#### Scenario: Event names normalize to PascalCase

- **WHEN** `EventNormalizer` in `CodeIslandCore` receives a raw payload
- **THEN** it MUST map vendor-specific event names to canonical PascalCase names: `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, `Notification`, `PermissionRequest`, etc.
- **AND** unknown event names SHOULD be passed through unchanged with a debug log entry

### Requirement: Six Hook Installation Formats

The hook installer SHALL handle exactly the six format families enumerated below; adding a seventh format requires updating this requirement and `CLIConfig`.

#### Scenario: Claude format (matcher-based array)

- **GIVEN** a Claude Code config at `~/.claude/settings.json`
- **WHEN** the installer writes a CodeIsland hook
- **THEN** the hook MUST be inserted as `[{"matcher": "<pattern>", "hooks": [...]}]` under the appropriate event key
- **AND** existing matcher entries unrelated to CodeIsland MUST be preserved

#### Scenario: Nested format (Codex/Gemini)

- **GIVEN** a Codex (`~/.codex/config.toml` rendered as JSON-equivalent) or Gemini (`~/.gemini/settings.json`) config
- **WHEN** the installer writes a hook
- **THEN** the hook MUST be inserted as `[{"hooks": [{"type": "<type>", "command": "<cmd>"}]}]`

#### Scenario: Flat format (Cursor/Trae)

- **GIVEN** a Cursor or Trae config
- **WHEN** the installer writes a hook
- **THEN** the hook MUST be inserted as `[{"command": "<cmd>"}]` (no nesting)

#### Scenario: TraeCLI YAML managed block

- **GIVEN** the file `~/.trae/traecli.yaml`
- **WHEN** the installer writes hooks
- **THEN** the entries MUST be inserted between `# >>> codeisland-managed >>>` and `# <<< codeisland-managed <<<` markers
- **AND** content outside the markers MUST be preserved verbatim

#### Scenario: Copilot format

- **GIVEN** a GitHub Copilot CLI config
- **WHEN** the installer writes a hook
- **THEN** the hook MUST be inserted as `[{"type": "<type>", "bash": "<cmd>", "timeoutSec": <n>}]`

#### Scenario: Kimi TOML array of tables

- **GIVEN** the file `~/.kimi/config.toml`
- **WHEN** the installer writes hooks
- **THEN** entries MUST use the `[[hooks]]` array-of-tables syntax
- **AND** TOML structure (sections, comments) outside `[[hooks]]` MUST be preserved

### Requirement: Blocking vs Non-Blocking Event Semantics

Permission/question events SHALL block until the user responds (or a 24-hour ceiling fires); all other events SHALL be fire-and-forget with a 3-second send timeout.

#### Scenario: PermissionRequest blocks for response

- **GIVEN** a `PermissionRequest` event sent by the bridge
- **WHEN** the bridge writes the JSON to the socket
- **THEN** the bridge MUST keep the connection open and read a JSON response from the main app
- **AND** the response MUST be written to stdout in the format expected by the host CLI
- **AND** the bridge MUST exit only after the response is delivered, or after the 24-hour `SIGALRM` ceiling fires

#### Scenario: Non-blocking event respects send timeout

- **GIVEN** a non-blocking event such as `PostToolUse`
- **WHEN** the bridge sends the JSON
- **THEN** the write MUST complete within 3 seconds (default)
- **AND** if the write does not complete, the bridge MUST close the connection and exit silently

#### Scenario: Question event behaves like PermissionRequest

- **GIVEN** a `Question` event from a CLI that supports interactive prompts
- **WHEN** the bridge forwards it
- **THEN** the same blocking response semantics as `PermissionRequest` MUST apply

### Requirement: Graceful Degradation

The bridge and hook script SHALL fail silently in every error path; a broken CodeIsland installation MUST NOT degrade the host AI tool's workflow.

#### Scenario: Missing socket exits silently

- **GIVEN** the file `/tmp/codeisland-<uid>.sock` does not exist
- **WHEN** the bridge starts
- **THEN** it MUST exit with code 0 immediately
- **AND** it MUST NOT print anything to stdout or stderr

#### Scenario: Connection failure is silent

- **WHEN** `connect(2)` to the socket fails for any reason (refused, timeout, permission denied)
- **THEN** the bridge MUST exit with code 0
- **AND** no output SHALL be produced

#### Scenario: Hook script fallback chain

- **GIVEN** the installed hook shell script invoked by the AI tool
- **WHEN** the script runs
- **THEN** it MUST first attempt to invoke the native `codeisland-bridge` binary
- **AND** if the binary is missing or fails to execute, it MUST attempt a `nc` (netcat) fallback to the Unix socket
- **AND** if `nc` is also unavailable or fails, the script MUST exit silently with code 0

#### Scenario: No directory creation for absent CLI

- **GIVEN** a CLI (e.g., Kimi) that is not installed on the user's machine
- **WHEN** the hook installer runs
- **THEN** it MUST NOT create the CLI's config directory (e.g., `~/.kimi/`) if no other evidence of that CLI exists
- **AND** it MUST detect installation by checking for the CLI's binary or pre-existing config directory

### Requirement: Data-Driven CLI Registry

Adding support for a new AI coding CLI SHALL require only adding a `CLIConfig` entry; no event-processing or hook-installation code may be modified to add a new CLI (with the narrow exception of new format families which require a sixth-format-amendment).

#### Scenario: CLIConfig describes one CLI

- **GIVEN** the source enum/array enumerating built-in CLIs
- **WHEN** the registry is consulted
- **THEN** each entry MUST be a `CLIConfig` struct containing:
  - `displayName: String`
  - `source: String` (canonical identifier)
  - `configPath: String` (absolute or `~/`-prefixed)
  - `configKey: String` (key under which hooks are written)
  - `hookFormat: HookFormat` (one of the six format enum cases)
  - `events: [String]` (list of event names to register)

#### Scenario: Custom CLI is loaded at runtime

- **GIVEN** a user has defined a `CustomCLIConfig` in `UserDefaults`
- **WHEN** the app launches
- **THEN** the custom config MUST be merged with built-in `CLIConfig` entries via `allCLIs`
- **AND** subsequent install/uninstall/verify operations MUST iterate `allCLIs` without special-casing

#### Scenario: Source aliases are normalized centrally

- **GIVEN** a session arrives with `_source = "factory"`
- **WHEN** any consumer queries the canonical source
- **THEN** `SessionSnapshot.normalizedSupportedSource` MUST resolve `factory` to `droid`
- **AND** consumers MUST NOT maintain their own alias maps

#### Scenario: Auto-repair runs at launch

- **WHEN** the app starts
- **THEN** `verifyAndRepair` MUST iterate `allCLIs` and reinstall any missing or outdated hook entries
- **AND** the hook script template version MUST be embedded in the installed script so version drift can be detected

#### Scenario: Versioned events gated by CLI version

- **GIVEN** a CLI feature requires a minimum CLI version (e.g., Claude Code 1.5.0+ for `Notification`)
- **WHEN** the installer registers events for that CLI
- **THEN** it MUST first detect the installed version (e.g., via `claude --version`)
- **AND** events that require an unmet minimum version MUST NOT be installed

### Requirement: Authoritative Documentation Consultation

Before modifying hook integration code, event normalization, or CLI config installation, contributors and AI agents SHALL consult the relevant CLI's official documentation; pull requests touching these areas MUST cite the consulted URLs.

#### Scenario: Adding a new CLI

- **GIVEN** a contributor proposes adding a new AI coding CLI to the registry
- **WHEN** the PR is opened
- **THEN** the proposal MUST include a link to the CLI's official hooks documentation
- **AND** the link MUST be added to the registry table below if not already present

#### Scenario: Modifying event handling

- **WHEN** a PR modifies `EventNormalizer` or hook payload parsing for an existing CLI
- **THEN** the PR description MUST cite the official documentation URL consulted
- **AND** if the documentation contradicts current behavior, the PR MUST flag the discrepancy and propose alignment

#### Scenario: Documented CLI registry

- **GIVEN** the official documentation registry maintained in this spec
- **WHEN** any contributor seeks the canonical hooks reference for a supported CLI
- **THEN** the following URLs SHALL be the authoritative source:

| CLI Tool | Documentation URL |
|----------|-------------------|
| Claude Code | https://docs.anthropic.com/en/docs/claude-code/hooks |
| Codex (OpenAI) | https://developers.openai.com/codex/hooks |
| Gemini CLI | https://geminicli.com/docs/hooks/ |
| GitHub Copilot CLI | https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-hooks |
| Cursor | https://cursor.com/docs/hooks |
| Kimi Code CLI | https://moonshotai.github.io/kimi-cli/en/customization/hooks.html |
| Qwen Code | https://qwenlm.github.io/qwen-code-docs/en/users/features/hooks/ |
| Trae Agent | https://github.com/bytedance/trae-agent (Issue #397) |

### Requirement: Socket Security and Privacy

The Unix socket SHALL be user-scoped and MUST NOT carry sensitive credentials.

#### Scenario: Socket path includes UID

- **WHEN** the main app creates the listening socket
- **THEN** the path MUST be `/tmp/codeisland-<uid>.sock` where `<uid>` is the current user's numeric UID
- **AND** the path MUST NOT be predictable across users

#### Scenario: No credentials in payload

- **GIVEN** any hook event forwarded through the bridge
- **WHEN** the payload is inspected
- **THEN** it MUST NOT contain API keys, OAuth tokens, password material, or other authentication credentials
- **AND** payload contents are limited to event metadata: tool name, file paths, prompt text excerpts, status codes
