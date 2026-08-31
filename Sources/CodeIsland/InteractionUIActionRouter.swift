import CodeIslandCore
import Observation

/// The UI/shortcut consumer seam for the fork-owned interaction model.
/// SwiftUI and AppKit do not call provider-specific response helpers; they
/// submit typed Center inputs through this coordinator.
@MainActor
@Observable
final class InteractionUIActionRouter {
    let coordinator: InteractionCoordinator
    private let shortcutAdapter = InteractionShortcutAdapter()

    init(coordinator: InteractionCoordinator) {
        self.coordinator = coordinator
    }

    var snapshot: InteractionSnapshot { coordinator.snapshot }

    @discardableResult
    func send(_ input: InteractionInput) -> [InteractionEffect] {
        return coordinator.send(input)
    }

    /// Returns true whenever the Center seam was installed. An ignored action
    /// is still considered handled, preventing a stale shortcut from falling
    /// through to a legacy queue-head method.
    @discardableResult
    func perform(_ shortcut: InteractionShortcut) -> Bool {
        let decision = shortcutAdapter.decision(shortcut, snapshot: snapshot.local)
        switch decision {
        case let .action(input): _ = send(input)
        case .ignored: break
        }
        return true
    }

    @discardableResult
    func resolve(_ requestID: RequestID, command: ResolutionCommand) -> [InteractionEffect] {
        send(.user(.resolve(requestID, command)))
    }

    @discardableResult
    func dismiss(_ requestID: RequestID) -> [InteractionEffect] {
        send(.user(.dismiss(requestID)))
    }

    @discardableResult
    func reveal(_ requestID: RequestID) -> [InteractionEffect] {
        send(.user(.reveal(requestID)))
    }

    @discardableResult
    func navigate(_ target: NavigationTarget) -> [InteractionEffect] {
        send(.user(.navigate(target)))
    }
}
