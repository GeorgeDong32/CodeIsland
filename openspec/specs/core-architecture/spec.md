# Core Architecture Specification

## Purpose

This specification defines the foundational architectural behaviors of CodeIsland: how source modules are organized, how state flows through the system, and the engineering conventions that all code MUST satisfy. It is the canonical reference for module boundaries, immutable state management, Swift coding standards, and testing discipline.

This is the "main spec" that any contributor or AI agent should read first to understand how CodeIsland is structured. Other specs (`hook-protocol`, `terminal-support`, `user-experience`) build on the architecture defined here.

## Requirements

### Requirement: Three-Module Boundary

The CodeIsland source tree SHALL be organized into exactly three Swift Package Manager modules with strict directional dependencies: `CodeIslandCore` → consumed by → `CodeIsland` and `CodeIslandBridge`.

#### Scenario: Core module remains framework-agnostic

- **GIVEN** the `CodeIslandCore` module
- **WHEN** any source file under `Sources/CodeIslandCore/` is compiled
- **THEN** it MUST NOT import `AppKit`, `SwiftUI`, or any other UI framework
- **AND** it MUST NOT import sibling modules `CodeIsland` or `CodeIslandBridge`
- **AND** it MAY import `Foundation`, `Darwin`, `Network`, and `os`

#### Scenario: UI module depends only on Core

- **GIVEN** the `CodeIsland` module
- **WHEN** a source file under `Sources/CodeIsland/` declares imports
- **THEN** it MAY import `AppKit`, `SwiftUI`, `CodeIslandCore`, and approved third-party libraries (`Sparkle`, `Yams`)
- **AND** it MUST NOT import `CodeIslandBridge`

#### Scenario: Bridge module is dependency-free

- **GIVEN** the `CodeIslandBridge` executable target
- **WHEN** the bridge binary is built for distribution
- **THEN** the resulting binary size SHALL be approximately 86 KB (no large frameworks linked)
- **AND** the bridge MUST import only `Foundation` and `Darwin`
- **AND** the bridge MUST NOT depend on `CodeIslandCore`, `CodeIsland`, or any third-party package

#### Scenario: Cross-module references use public API only

- **WHEN** the `CodeIsland` module references types defined in `CodeIslandCore`
- **THEN** those types MUST be declared `public` in Core
- **AND** consumers MUST NOT rely on `internal` or `private` implementation details

### Requirement: Domain Logic Lives in Core

All event normalization, session state mutation, transcript parsing, chat message formatting, and process resolution SHALL reside in `CodeIslandCore`, not in view layers or controllers.

#### Scenario: Event normalization is in Core

- **WHEN** an incoming hook payload from a CLI is parsed into a canonical event name
- **THEN** the parser logic (`EventNormalizer`) MUST live in `Sources/CodeIslandCore/`
- **AND** the parser MUST be callable without instantiating any UI controller

#### Scenario: Session reduction is in Core

- **WHEN** an event is applied to update session state
- **THEN** the function `reduceEvent(sessions:event:maxHistory:)` MUST be defined in Core
- **AND** it MUST be invocable by both the main app and any future headless tool

#### Scenario: View code contains no business logic

- **GIVEN** any SwiftUI view or AppKit controller in `Sources/CodeIsland/`
- **WHEN** the view needs to compute derived session state
- **THEN** the computation MUST be delegated to a Core type
- **AND** the view MUST NOT replicate event-mapping logic that already exists in Core

### Requirement: Pure Reducer State Updates

Session state mutations SHALL flow through pure reducer functions that return side effects as enum values; reducers MUST NOT perform IO, play sounds, or mutate UI directly.

#### Scenario: Reducer returns side effects

- **WHEN** `reduceEvent(sessions:event:maxHistory:)` is invoked
- **THEN** it MUST return a `[SideEffect]` array
- **AND** it MUST update `SessionSnapshot` instances via `inout` mutation
- **AND** it MUST NOT call `playSound`, `setActiveSession`, or any function with observable side effects

#### Scenario: Caller executes side effects

- **GIVEN** a reducer call that returns `[.playSound(.notification), .setActiveSession(id)]`
- **WHEN** the caller (typically `AppState`) receives the array
- **THEN** the caller MUST iterate the side effects and dispatch each to the appropriate executor
- **AND** the reducer itself MUST remain pure (deterministic, IO-free)

#### Scenario: Reducer is unit-testable without UI

- **WHEN** a unit test exercises the reducer
- **THEN** the test MUST be able to assert state transitions and side-effect outputs
- **AND** the test MUST NOT require an `NSApplication` instance, a window, or any AppKit/SwiftUI state

### Requirement: Modern Observation Framework

State containers exposed to the UI SHALL use Swift's `@Observable` macro on `final class` types; legacy `ObservableObject`/`@Published` is prohibited in new code.

#### Scenario: New state container uses @Observable

- **WHEN** a contributor introduces a new top-level state container (e.g., a settings store)
- **THEN** the type MUST be declared `@Observable final class`
- **AND** non-observable stored properties MUST be annotated `@ObservationIgnored`

#### Scenario: ObservableObject is rejected

- **WHEN** code review encounters a new type conforming to `ObservableObject` or using `@Published`
- **THEN** the change MUST be rejected
- **AND** the contributor MUST migrate to `@Observable`

### Requirement: Bounded History Buffers

Per-session history collections (tool history, chat messages) SHALL be capped to a maximum count enforced at insertion time to prevent unbounded memory growth.

#### Scenario: Tool history truncates at cap

- **GIVEN** a session with `ToolHistoryEntry` history at the configured `maxHistory` cap
- **WHEN** a new tool entry is appended via the reducer
- **THEN** the oldest entry MUST be evicted (FIFO ring-buffer semantics)
- **AND** the total count MUST equal `maxHistory`

#### Scenario: Chat history truncates at cap

- **GIVEN** a session with `ChatMessage` history at the configured cap
- **WHEN** a new message is appended
- **THEN** the oldest message MUST be evicted
- **AND** the count MUST not exceed the cap at any point

### Requirement: Concurrency Annotations

All Swift types crossing isolation boundaries SHALL declare their isolation contracts explicitly; UI-touching types MUST be `@MainActor` and value types crossing actor boundaries MUST conform to `Sendable`.

#### Scenario: UI controller is MainActor

- **GIVEN** a class instantiated by a SwiftUI view, AppKit window, or `@StateObject`-equivalent storage
- **WHEN** the class declaration is written
- **THEN** the class MUST be annotated `@MainActor` (either at class scope or via member-level annotations)

#### Scenario: Cross-actor model is Sendable

- **GIVEN** a struct or enum sent from a background task to the main actor
- **WHEN** the type is declared
- **THEN** it MUST conform to `Sendable`
- **AND** any reference-type members MUST also be `Sendable` or `@unchecked Sendable` with documented justification

#### Scenario: Main-actor hop uses Task

- **WHEN** code in a background context needs to update UI state
- **THEN** it MUST use `Task { @MainActor in ... }`
- **AND** it MUST NOT use `DispatchQueue.main.async`

### Requirement: Logging Discipline

Application diagnostic output SHALL flow through `os.Logger`; `print()` and `debugPrint()` are forbidden in shipped code paths.

#### Scenario: Logger declared at file scope

- **GIVEN** a Swift file emitting diagnostic logs
- **WHEN** the logger is declared
- **THEN** it MUST be `private let log = Logger(subsystem: "com.codeisland.app", category: "<descriptive>")` at file scope
- **AND** there MUST be at most one logger per file

#### Scenario: Errors are logged not printed

- **WHEN** a recoverable error occurs (e.g., file IO failure, JSON parse failure in a non-critical path)
- **THEN** the error MUST be logged via `Logger.error(_:)` with structured metadata
- **AND** the code MUST NOT call `print()` or `debugPrint()`

#### Scenario: Bridge path stays silent

- **GIVEN** the bridge or hook script execution path
- **WHEN** any error occurs
- **THEN** no output SHALL be written to stdout or stderr (silent failure preserved)
- **AND** see `hook-protocol` spec for the full graceful-degradation contract

### Requirement: File and Type Organization

Each Swift source file SHALL contain exactly one primary type, and files exceeding ~500 lines SHALL be split using `+Feature.swift` extensions.

#### Scenario: One primary type per file

- **GIVEN** a Swift file `Foo.swift`
- **WHEN** the file is opened
- **THEN** it SHALL contain exactly one primary `class`, `struct`, `enum`, or `actor` named `Foo`
- **AND** related private helper types MAY be nested inside or declared at file scope as `fileprivate`

#### Scenario: Large file is split with extensions

- **GIVEN** a primary type whose implementation exceeds approximately 500 lines
- **WHEN** the contributor adds a new feature
- **THEN** the new feature MUST be placed in a separate file named `Foo+Feature.swift`
- **AND** the extension file MUST contain only an extension on the primary type

#### Scenario: Imports are ordered

- **GIVEN** any Swift source file
- **WHEN** imports are declared at the top
- **THEN** the order MUST be: system frameworks (Foundation, AppKit, …), then project modules (CodeIslandCore), then third-party (Sparkle, Yams)
- **AND** each group MUST be separated by a blank line

### Requirement: Resource Lifecycle Safety

Escaping closures, network connections, and timer handlers SHALL avoid retain cycles and leaks via `[weak self]` capture and explicit close paths.

#### Scenario: Escaping closure captures weak self

- **GIVEN** a closure passed as an `@escaping` parameter that references `self`
- **WHEN** the closure is written
- **THEN** the capture list MUST include `[weak self]`
- **AND** uses of `self` inside MUST guard for nil

#### Scenario: NWConnection is released

- **GIVEN** an `NWConnection` instance owned by a controller
- **WHEN** the controller is deallocated or the connection is no longer needed
- **THEN** `cancel()` MUST be called on the connection
- **AND** the controller MUST NOT participate in a strong reference cycle with its connection's state-update handler

#### Scenario: File descriptors are closed

- **GIVEN** a code path that opens a Unix socket, file handle, or pipe
- **WHEN** the path exits (success or error)
- **THEN** the descriptor MUST be closed in all branches (use `defer` or explicit close in catch)

### Requirement: Type Design Defaults

Value semantics SHALL be the default; `class` is reserved for types that genuinely require reference semantics or framework conformance.

#### Scenario: Prefer struct over class

- **WHEN** a contributor introduces a new data-bearing type
- **THEN** it MUST be declared `struct` unless it requires reference semantics (identity, NSObject conformance, observable state container)

#### Scenario: Stateless utilities use enum namespace

- **WHEN** a contributor groups pure functions that share no state
- **THEN** the grouping SHOULD be an `enum` with no cases and `static` members
- **AND** the type MUST NOT be instantiable

#### Scenario: Public surface is minimal

- **GIVEN** a new type
- **WHEN** the access modifiers are chosen
- **THEN** the default access level MUST be `internal` (or `private` for file-local helpers)
- **AND** members MUST be promoted to `public` only when consumed by another module

### Requirement: Automated Test Coverage for Core

Every pure function in `CodeIslandCore` SHALL have at least one happy-path test and one edge-case test in the corresponding `CodeIslandCoreTests` target.

#### Scenario: New Core function ships with tests

- **GIVEN** a pull request that adds a new pure function to `CodeIslandCore`
- **WHEN** the PR is opened for review
- **THEN** the PR MUST include a test file `<TestedType>Tests.swift` under `Tests/CodeIslandCoreTests/`
- **AND** the file MUST contain at least one test exercising the happy path
- **AND** at least one test exercising an error or edge condition

#### Scenario: swift test passes without setup

- **GIVEN** a fresh checkout of the repository
- **WHEN** a developer runs `swift test`
- **THEN** the entire test suite MUST pass
- **AND** the suite MUST NOT require network access, real filesystem state outside `tmp`, or running external processes

#### Scenario: Tests are deterministic

- **GIVEN** any test in `CodeIslandCoreTests` or `CodeIslandTests`
- **WHEN** the test is run repeatedly on the same machine
- **THEN** it MUST produce the same outcome every time
- **AND** it MUST NOT depend on wall-clock time, random seeds without injection, or thread-scheduling order

### Requirement: Integration Tests for IPC and Config

Socket communication and CLI config-file mutation paths SHALL have integration tests that exercise round-trip behavior using temp directories and in-memory mocks.

#### Scenario: Hook install round-trip

- **GIVEN** a temporary directory simulating `~/.claude/`, `~/.codex/`, or another CLI config root
- **WHEN** the hook installer writes its entry and the verifier subsequently reads the same file
- **THEN** the verifier MUST report the hook as installed
- **AND** uninstalling MUST restore the file to its pre-install state byte-for-byte (modulo formatting)

#### Scenario: Existing entries are preserved

- **GIVEN** a CLI config file containing user-defined hooks unrelated to CodeIsland
- **WHEN** the installer adds CodeIsland's entry
- **THEN** the user's pre-existing entries MUST remain in the file
- **AND** uninstalling MUST remove only CodeIsland's entry

### Requirement: Coding Convention Compliance

All committed Swift source SHALL satisfy the formatting conventions documented in this spec; deviations require explicit justification in the pull request description.

#### Scenario: Indentation and line length

- **GIVEN** any Swift source file
- **WHEN** the file is committed
- **THEN** indentation MUST be 4 spaces (no tabs)
- **AND** the soft line-length limit SHALL be 100 characters; the hard limit SHALL be 120

#### Scenario: Naming conventions

- **WHEN** a contributor names a new file or type
- **THEN** the file name MUST be `TypeName.swift` for the primary type, or `TypeName+Feature.swift` for an extension
- **AND** constants MUST be `static let` inside the relevant type, never global

#### Scenario: No trailing whitespace

- **WHEN** a file is committed
- **THEN** no line MAY end with trailing whitespace characters
