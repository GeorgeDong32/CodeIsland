import Foundation
import AppKit
import CodeIslandCore

/// The result of a request to focus a session's local terminal or client.
///
/// `activated` is returned when validation is disabled.  It deliberately differs
/// from `succeeded`: activation is fire-and-forget in that configuration and we
/// must not claim that the terminal accepted the focus request.
enum SessionNavigationResult: Equatable, Sendable {
    case activated
    case succeeded
    case unavailable
    case failed
    case cancelled
}

/// The outcome of one complete focus validation sequence.
enum JumpValidationOutcome: Equatable {
    case success
    case failed
    case cancelled
}

/// Run the historical 120/320/640ms validation sequence. The injectable
/// clock/check closures keep retry policy deterministic in unit tests and
/// leave AppKit/AppleScript behind `TerminalVisibilityPort` in production.
func evaluateJumpValidation(
    delays: [UInt64],
    isCancelled: () -> Bool = { Task.isCancelled },
    sleep: (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) },
    checkSucceeded: () async -> Bool
) async -> JumpValidationOutcome {
    for delay in delays {
        await sleep(delay)
        if isCancelled() { return .cancelled }
        if await checkSucceeded() { return .success }
    }

    return isCancelled() ? .cancelled : .failed
}

/// The target is copied at the time the user clicks.  A later queue/surface
/// change therefore cannot redirect the operation to another session.
struct SessionNavigationTarget: Sendable {
    let session: SessionSnapshot
    let sessionId: String

    init(session: SessionSnapshot, sessionId: String) {
        self.session = session
        self.sessionId = sessionId
    }
}

enum SessionNavigationCollapsePolicy: Sendable, Equatable {
    case never
    case afterSuccess
}

struct SessionNavigationSettings: Sendable, Equatable {
    /// Kept as data so tests can make retry timing deterministic while the
    /// production adapter preserves the historical 120/320/640ms schedule.
    let validationDelays: [UInt64]

    static let production = SessionNavigationSettings(
        validationDelays: [120_000_000, 320_000_000, 640_000_000]
    )

    static let `default` = production
}

// Names used by the design's public vocabulary. Keep the implementation's
// explicit names as the source of truth while allowing adapters/tests to use
// the shorter contract names.
typealias NavigationSettings = SessionNavigationSettings
typealias CollapsePolicy = SessionNavigationCollapsePolicy
typealias NavigationResult = SessionNavigationResult

/// The AppKit/terminal route is intentionally behind this small port.  The
/// navigator owns lifecycle and retry policy; this port owns only physical
/// activation.
protocol TerminalActivationPort {
    func activate(session: SessionSnapshot, sessionId: String?)
}

/// Visibility checks can block on AppleScript or a terminal CLI, so the port is
/// async even though fake implementations are usually immediate.
protocol TerminalVisibilityPort {
    func isVisible(session: SessionSnapshot) async -> Bool
}

/// Failure sound belongs to the navigation adapter, while the SwiftUI caller
/// owns its local shake animation.  This keeps AppKit/SoundManager out of the
/// pure retry contract and prevents each card from duplicating failure policy.
@MainActor
protocol NavigationFeedbackPort {
    func navigationFailed(for target: SessionNavigationTarget)
}

struct ProductionTerminalActivationPort: TerminalActivationPort {
    func activate(session: SessionSnapshot, sessionId: String?) {
        TerminalActivator.activate(session: session, sessionId: sessionId)
    }
}

struct ProductionTerminalVisibilityPort: TerminalVisibilityPort {
    func isVisible(session: SessionSnapshot) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let visible = TerminalVisibilityDetector.isSessionTabVisible(session)
                    || TerminalVisibilityDetector.isTerminalFrontmostForSession(session)
                continuation.resume(returning: visible)
            }
        }
    }
}

@MainActor
struct ProductionNavigationFeedbackPort: NavigationFeedbackPort {
    func navigationFailed(for target: SessionNavigationTarget) {
        SoundManager.shared.preview("8bit_error")
    }
}

/// A production default used by the existing panel and by legacy shortcut
/// callers.  Tests can inject their own navigator into the card views through
/// their defaultable `navigator` property without touching AppState.
@MainActor
final class SessionNavigator {
    static let shared = SessionNavigator.production()

    let activator: any TerminalActivationPort
    let visibility: any TerminalVisibilityPort
    let feedback: any NavigationFeedbackPort
    let settings: SessionNavigationSettings

    private var operations: [UUID: Task<Void, Never>] = [:]

    init(
        activator: any TerminalActivationPort,
        visibility: any TerminalVisibilityPort,
        feedback: any NavigationFeedbackPort,
        settings: SessionNavigationSettings = .production
    ) {
        self.activator = activator
        self.visibility = visibility
        self.feedback = feedback
        self.settings = settings
    }

    static func production(
        settings: SessionNavigationSettings = .production
    ) -> SessionNavigator {
        SessionNavigator(
            activator: ProductionTerminalActivationPort(),
            visibility: ProductionTerminalVisibilityPort(),
            feedback: ProductionNavigationFeedbackPort(),
            settings: settings
        )
    }

    /// Synchronous entry point for SwiftUI actions.  The returned identifier is
    /// a cancellation handle, not a second state owner.  Retry state lives only
    /// in this module and is removed when the operation completes.
    @discardableResult
    func begin(
        target: SessionNavigationTarget,
        collapsePolicy: SessionNavigationCollapsePolicy,
        onResult: @escaping @MainActor (SessionNavigationResult) -> Void
    ) -> UUID {
        let operationID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.navigate(target: target, collapsePolicy: collapsePolicy)
            guard !Task.isCancelled else { return }
            onResult(result)
            self.operations[operationID] = nil
        }
        operations[operationID] = task
        return operationID
    }

    /// Async interface used by tests and by future effect executors.
    func navigate(
        target: SessionNavigationTarget,
        collapsePolicy: SessionNavigationCollapsePolicy
    ) async -> SessionNavigationResult {
        guard !target.session.isRemote else { return .unavailable }

        activator.activate(session: target.session, sessionId: target.sessionId)

        guard collapsePolicy == .afterSuccess else { return .activated }

        let outcome = await evaluateJumpValidation(
            delays: settings.validationDelays,
            checkSucceeded: { [visibility] in
                await visibility.isVisible(session: target.session)
            }
        )

        switch outcome {
        case .success:
            return .succeeded
        case .failed:
            feedback.navigationFailed(for: target)
            return .failed
        case .cancelled:
            return .cancelled
        }
    }

    /// Design-contract spelling retained for effect adapters and tests.
    func navigate(
        session: SessionNavigationTarget,
        collapsePolicy: SessionNavigationCollapsePolicy
    ) async -> SessionNavigationResult {
        await navigate(target: session, collapsePolicy: collapsePolicy)
    }

    func cancel(operationID: UUID) {
        operations[operationID]?.cancel()
        operations[operationID] = nil
    }

    func cancelAll() {
        operations.values.forEach { $0.cancel() }
        operations.removeAll()
    }
}
