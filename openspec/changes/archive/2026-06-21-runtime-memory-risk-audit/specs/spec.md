# Runtime Memory Risk Audit Specification

## Purpose

This specification records a repository-wide memory lifecycle audit for CodeIsland.
It is the canonical backlog of code paths that can leak resources, retain stale
runtime state, or create high memory pressure under malformed, abandoned, or
large-input conditions.

The audit was performed against the repository state on 2026-06-21. The
constitution embedded in `openspec/config.yaml` was used as the active
governance source for memory rules.

## Audit Scope

- Swift targets: `Sources/CodeIsland`, `Sources/CodeIslandCore`, and
  `Sources/CodeIslandBridge`
- Runtime integration assets: `Sources/CodeIsland/Resources/*.js` and
  `Sources/CodeIsland/Resources/*.py`
- Tests and existing specs, where they reveal intentional caps or cleanup
  contracts
- Risk classes: observer/token lifecycle, timers, DispatchSource/NWConnection
  cleanup, FileHandle/Pipe/URLSession lifecycle, unbounded `Data` buffers,
  unbounded dictionaries/maps/queues, transcript/history parsing pressure, and
  long-lived async tasks

## Requirements

### Requirement: Memory Risk Register Is Maintained

The project SHALL keep this risk register current whenever runtime ownership,
hook handling, transcript parsing, process execution, app-server integration, or
OpenCode plugin code changes.

#### Scenario: Repository-wide audit result is captured

- **GIVEN** a contributor needs the current memory-risk backlog
- **WHEN** they inspect this specification
- **THEN** every item in the risk register below MUST be considered before
  changing nearby code
- **AND** resolved items MUST either be removed from the register or moved to the
  existing-safeguards section with the new invariant documented

#### Scenario: New memory-sensitive code is added

- **GIVEN** new code owns an observer token, timer, DispatchSource, FileHandle,
  Pipe, URLSession, NWConnection, continuation, buffer, queue, or map
- **WHEN** the code is reviewed
- **THEN** the owner MUST have an explicit cleanup path
- **AND** any buffer or collection fed by external input SHOULD have a documented
  maximum size, TTL, or bounded domain

#### Scenario: Known risks are listed

- **GIVEN** the 2026-06-21 repository-wide memory audit has been completed
- **WHEN** maintainers need the actionable backlog
- **THEN** the following risk register MUST list the known leak or high-memory
  pressure anomalies and their expected remediation direction

**Risk Register**

| ID | Priority | Location | Anomaly | Memory impact | Expected remediation |
| --- | --- | --- | --- | --- | --- |
| MEM-001 | High | `Sources/CodeIsland/PanelWindowController.swift` `showPanel()` | Three notification observers are registered for screen changes, active-space changes, and frontmost-app changes, but their tokens are not stored in `settingsObservers` or any other owner. | Observer closures can remain registered for the controller lifetime or longer. Repeated panel construction or repeated `showPanel()` calls can accumulate observer tokens and callback work. | Store each observer token and remove it in `deinit`, or centralize observer setup so it is idempotent and paired with teardown. |
| MEM-002 | Medium | `Sources/CodeIsland/AppDelegate.swift` `applicationDidFinishLaunching()` | The `NSWorkspace.didActivateApplicationNotification` observer used for hook auto-recovery is not stored and is not removed in `applicationWillTerminate`. | This is app-lifetime in the current shape, but it violates the observer ownership contract and can retain notification-center bookkeeping until process exit. | Store the token and remove it during termination or delegate deinit. |
| MEM-003 | High | `Sources/CodeIsland/AppState+CodexAppServer.swift` `removeCodexAppServerSessions()` | Bulk Codex app-server session removal deletes `sessions` entries directly instead of using the unified `removeSession(_:)` cleanup path. | Attached `JSONLTailer` watches, pending queues, monitor state, completion queues, and other per-session caches can outlive removed `codexapp:` sessions. | Route bulk removal through a cleanup helper that drains pending work, detaches transcript tailers, clears queues/caches, and refreshes derived state once. |
| MEM-004 | Medium | `Sources/CodeIsland/AppState+CodexAppServer.swift` `applyCodexThreadClosedNotification()` | Thread-close handling removes the session and detaches the tailer, but bypasses the broader `removeSession(_:)` cleanup path. | If app-server sessions ever gain pending permission/question state or other per-session resources, those can be retained after close. | Reuse the same per-session cleanup path used by process-exit and reducer removal paths, or document why app-server sessions cannot own each resource type. |
| MEM-005 | High | `Sources/CodeIsland/HookServer.swift` `connectionContexts`, `monitorPeerDisconnect(connection:sessionId:)`; `Sources/CodeIsland/AppState.swift` `permissionQueue` and `questionQueue` | Blocking permission/question requests retain continuations, connection contexts, and raw event payloads. `connectionContexts` has a five-minute safety cleanup, but queues have no explicit count or age cap. | A storm of abandoned blocking requests or connections that do not transition promptly can retain `NWConnection`, continuation state, `HookEvent.rawJSON`, and tool-input dictionaries until cleanup. | Add per-session and global caps or TTLs for blocking queues, and ensure peer-disconnect cleanup drains all related continuations and context entries deterministically. |
| MEM-006 | High | `Sources/CodeIslandCore/JSONLTailer.swift` `readFromOffset(watch:)`, `handleEvents(_:watch:)`, `Watch.pendingFragment` | The tailer reads all appended bytes since the last offset into one `Data`, combines it with any pending fragment, and keeps a trailing fragment without a size cap. | A large transcript append, a writer that omits newlines, or a delayed file-system event can cause a memory spike of appended bytes plus combined copies and parsed line copies. | Enforce maximum delta bytes and maximum pending-fragment bytes; truncate, skip, or reset the watch when limits are exceeded. |
| MEM-007 | High | `Sources/CodeIslandCore/CodexAppServerClient.swift` `readBuffer`, `ingest(data:)`, `drainMessages(buffer:)` | The newline-delimited JSON buffer has no maximum size; trailing partial data remains in memory until a newline arrives. | Malformed or very large app-server output can grow `readBuffer` without bound, and parsed messages create full `AnyCodableLike` object trees. | Add maximum frame and buffer sizes, drop or stop the client on overflow, and add tests for oversized and no-newline streams. |
| MEM-008 | Medium | `Sources/CodeIslandCore/CodexAppServerClient.swift` `start()`, `stop()`, `handleProcessExit(status:)` | stdout/stderr `readabilityHandler` callbacks and the process `terminationHandler` are installed, but `stop()` and process exit do not explicitly nil them. | Weak captures avoid the main self-cycle, but FileHandle callback state can live longer than intended and can continue to schedule callbacks around process teardown. | Store pipe handles or a transport object and clear readability/termination handlers on all stop, failure, and exit paths. |
| MEM-009 | Medium | `Sources/CodeIsland/UpdateChecker.swift` `installUpdate(from:)` | A `URLSession` with delegate is invalidated on the success path, but the failure path does not use `defer` to guarantee invalidation. | A failed download can leave delegate/session resources alive longer than necessary. | Wrap session invalidation in `defer` immediately after session creation. |
| MEM-010 | Medium | `Sources/CodeIslandCore/SessionSnapshot.swift` `subagents`; `Sources/CodeIsland/AppState.swift` subagent discovery/removal paths | Per-session `subagents` are removed on explicit stop/end and some discovery closures, but there is no TTL or maximum count if stop/end is missed. | Long-running sessions that emit many subagent IDs without matching terminal events can retain stale `SubagentState` entries until parent session removal. | Add TTL/count pruning or reconcile subagents during cleanup ticks. |
| MEM-011 | Medium | `Sources/CodeIsland/Resources/codeisland-opencode.js`; `Sources/CodeIsland/Resources/codeisland-opencode-remote.js` | `sessions` and `sessionCwd` maps are unbounded and are only deleted on `session.deleted` or archived `session.updated`. | If OpenCode never emits deletion/archive for many sessions, plugin memory grows for the lifetime of the OpenCode server process. | Add a size cap or TTL for inactive sessions and CWD entries. Keep the existing `msgRoles` cap. |
| MEM-012 | Medium | `Sources/CodeIsland/ProcessRunner.swift` `run(...)`; `Sources/CodeIsland/RemoteInstaller.swift` `runSSH(...)`; `Sources/CodeIsland/DiagnosticsExporter.swift` `runCommand(...)`; `Sources/CodeIsland/UpdateChecker.swift` `runShellProcess(...)` | Several process helpers read stdout/stderr or log output with `readDataToEndOfFile()` and no maximum byte limit. `RemoteInstaller.runSSH` waits before draining pipes. | Unexpectedly noisy commands, remote SSH output, or `log show --last 2h` can allocate large buffers; waiting before pipe drain can also stall on full pipes. | Stream process output with byte caps and truncation markers, and drain pipes concurrently for long-running commands. |
| MEM-013 | Medium | `Sources/CodeIslandBridge/main.swift` `FileHandle.standardInput.readDataToEndOfFile()`, `recvAll(_:)`, helper `runCommand(...)` | The bridge reads hook stdin and server responses into memory without explicit size caps. | The bridge is short-lived and has alarms, but malformed hook payloads or unexpected server responses can still create avoidable memory spikes. | Add a maximum stdin payload and maximum response size while preserving silent-exit behavior. |
| MEM-014 | Low | `Sources/CodeIsland/NotchPanelView.swift` hover and linger timers | Several SwiftUI subviews store one-shot `Timer` instances in `@State` and invalidate them on hover changes, but they do not consistently invalidate on disappearance. | Timers can hold closures and view state until firing after the view disappears. The intervals are short, so impact is small but noisy under rapid view churn. | Add `onDisappear` invalidation or replace with cancellable `Task` state where appropriate. |
| MEM-015 | Low | `Sources/CodeIsland/DebugHarness.swift` `applyIdle(to:)` | DEBUG-only idle preview schedules a repeating timer without storing or invalidating it. | Preview/debug sessions can retain the timer and its closure indefinitely. | Store the timer in debug state or use a cancellable debug task. |
| MEM-016 | Low | `Sources/CodeIsland/Resources/codeisland-remote-hook.py` `_scan_session_jsonl(...)` | The remote hook scans an entire JSONL transcript to recover summary and recent messages. It streams one line at a time, but it has no byte/time cutoff. | Very large transcripts can create high CPU/IO pressure and per-line JSON allocation churn during hook execution. | Read from the tail where possible, or add a maximum scanned byte count. |
| MEM-017 | Low | `Sources/CodeIsland/SessionPersistence.swift` `load()` | Session persistence loads the entire `sessions.json` file into memory. | The file should be small because it is written from active persisted sessions, but corruption or unexpected growth has no hard cap. | Add a maximum file-size check before loading, or document the persistence file as bounded by session cleanup invariants. |

### Requirement: Resource Owner Cleanup Is Explicit

Long-lived resources SHALL have one clear owner and one clear teardown path.

#### Scenario: Observer tokens are paired with teardown

- **GIVEN** code calls `NotificationCenter.addObserver` or
  `NSWorkspace.shared.notificationCenter.addObserver`
- **WHEN** the observer token is returned
- **THEN** the token MUST be stored by the owning object
- **AND** the owner MUST remove the observer in a deterministic teardown path

#### Scenario: Session removal uses one cleanup path

- **GIVEN** any code removes a session from `AppState.sessions`
- **WHEN** the removal is not a test-only state reset
- **THEN** the path MUST drain pending permissions and questions
- **AND** it MUST detach transcript tailers
- **AND** it MUST clear monitor, queue, retry, completion, and derived-state data

#### Scenario: Callback-backed handles are cleared

- **GIVEN** a `FileHandle.readabilityHandler`, process
  `terminationHandler`, URLSession delegate, DispatchSource, timer, or
  NWConnection handler is installed
- **WHEN** the owner stops, exits, or fails to start
- **THEN** callbacks MUST be cleared or cancelled on every branch that releases
  the owner

### Requirement: External Input Buffers Are Bounded

External input buffers SHALL have explicit byte limits when fed by hook
payloads, app-server output, transcript files, command output, sockets, or
remote integrations.

#### Scenario: Streaming JSON input has caps

- **GIVEN** newline-delimited JSON is read from a process, transcript, or socket
- **WHEN** a complete frame or trailing partial frame exceeds its limit
- **THEN** the reader MUST drop, truncate, or reset the stream according to its
  graceful-degradation contract
- **AND** tests SHOULD cover oversized frames and never-terminated frames

#### Scenario: Process output is bounded

- **GIVEN** a helper runs a local or remote command
- **WHEN** stdout or stderr exceeds the documented maximum output size
- **THEN** the helper MUST stop accumulating additional bytes or terminate the
  command
- **AND** diagnostic paths SHOULD include a truncation marker rather than keeping
  the full output

#### Scenario: Bridge limits preserve graceful degradation

- **GIVEN** the bridge receives malformed or oversized input
- **WHEN** it rejects the input
- **THEN** it MUST preserve silent failure and exit without blocking the host AI
  tool

### Requirement: Long-Lived Runtime Maps Are Bounded

Maps and queues that grow from external runtime events SHALL be bounded by count,
age, owner lifetime, or a finite key domain.

#### Scenario: Session-scoped maps are pruned

- **GIVEN** a map is keyed by session ID, provider session ID, subagent ID, or
  message ID
- **WHEN** the owning session ends, becomes inactive, or exceeds a retention TTL
- **THEN** all dependent entries MUST be removed

#### Scenario: Blocking queues cannot grow indefinitely

- **GIVEN** a live or stuck session emits permission or question requests
- **WHEN** the queue exceeds the configured per-session or global limit
- **THEN** older or lower-priority requests MUST be drained with a safe response
  rather than retained indefinitely

## Existing Safeguards And Exclusions

These code paths were reviewed and are not current risk-register entries because
they already have an explicit cap, cleanup path, or bounded key domain:

- `Sources/CodeIsland/HookServer.swift` rejects hook payloads above 1 MB in
  `receiveAll(connection:accumulated:)`.
- `Sources/CodeIslandCore/SessionSnapshot.swift` bounds `recentMessages` and
  `toolHistory` at insertion time.
- `Sources/CodeIsland/AppState+ToolUseCache.swift` prunes `pendingToolUses`
  with a 15-minute TTL during cleanup ticks.
- `Sources/CodeIslandCore/ChatMessageTextFormatter.swift` and
  `Sources/CodeIsland/NotchPanelView.swift` bound markdown caches to 128 entries
  and clear them when full.
- `Sources/CodeIsland/SettingsWindowController.swift` stores its close observer
  token and removes it through `clearCloseObserver()`.
- `Sources/CodeIsland/AppState+CodexAppServer.swift`
  `startCodexAppServerWatcher()` stores app-activation observer tokens and
  removes them when the watcher stops.
- `Sources/CodeIsland/SSHForwarder.swift` clears its stderr readability handler
  on disconnect and process termination.
- `Sources/CodeIslandCore/JSONLTailer.swift` closes file descriptors on attach
  failure and cancels watched DispatchSources in `detach(sessionId:)` and
  `deinit`.
- `Sources/CodeIsland/AppState.swift` cancels process monitors, cleanup timers,
  save timers, rotation timers, discovery scans, FSEvent streams, and transcript
  tailers in `stopSessionDiscovery()` and `deinit`.
- `Sources/CodeIsland/AppState.swift` transcript discovery helpers that call
  `readDataToEndOfFile()` after seeking to a fixed tail window are intentionally
  bounded by the preceding `readSize` calculation.
- `Sources/CodeIsland/NotchPanelView.swift` terminal and CLI icon caches are
  keyed by small, effectively finite domains: installed terminal bundle IDs and
  known source/size pairs.
