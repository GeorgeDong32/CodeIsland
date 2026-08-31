import Foundation
import CodeIslandCore

/// The production effect boundary for the interaction reducer.
///
/// There is deliberately one instance of this type per AppState.  Provider
/// adapters remain independently replaceable, but no adapter is allowed to
/// consume a returned effect outside this ordered dispatcher.  This keeps the
/// Center's `send -> effects -> adapter ack -> send` contract intact in the
/// application as well as in the Core trace harness.
@MainActor
final class InteractionProductionEffectExecutor: @preconcurrency InteractionEffectExecutor {
    private let hook: HookTransportAdapter
    private let codex: CodexTransportAdapter
    private let auto: any AutoCommandAdapter
    private let navigator: SessionNavigator
    private let sessionLookup: (SessionRef) -> (sessionID: String, snapshot: SessionSnapshot)?

    init(
        hook: HookTransportAdapter,
        codex: CodexTransportAdapter,
        auto: any AutoCommandAdapter,
        navigator: SessionNavigator,
        sessionLookup: @escaping (SessionRef) -> (sessionID: String, snapshot: SessionSnapshot)?
    ) {
        self.hook = hook
        self.codex = codex
        self.auto = auto
        self.navigator = navigator
        self.sessionLookup = sessionLookup
    }

    func execute(
        _ effects: [InteractionEffect],
        report: @escaping (InteractionAdapterEvent) -> Void
    ) {
        // Do not group effects by adapter: returned order is part of the
        // reducer contract and provider commands may depend on it.
        for effect in effects {
            switch effect {
            case let .deliverResolution(resolution):
                if hook.canHandle(token: resolution.token) {
                    hook.execute([effect], report: report)
                } else {
                    codex.execute([effect], report: report)
                }
            case let .finalizeTransport(finalization):
                if hook.canHandle(token: finalization.token) {
                    hook.execute([effect], report: report)
                } else {
                    codex.execute([effect], report: report)
                }
            case let .changeAutoMode(autoEffect):
                submitAuto(autoEffect, report: report)
            case let .navigate(navigation):
                executeNavigation(navigation, report: report)
            case .cancelTransport:
                // Cancellation is a provider-specific operation.  Hook and
                // Codex responders are already token-scoped; their transport
                // adapters observe the cancellation through the same ledger.
                break
            case .feedback, .diagnostic:
                // UI/diagnostic effects have no provider side effect.  The
                // store already exposes their state through its snapshot.
                break
            }
        }
    }

    private func submitAuto(
        _ effect: AutoModeEffect,
        report: @escaping (InteractionAdapterEvent) -> Void
    ) {
        auto.submit(effect.transaction) { result in
            Task { @MainActor in
                switch result {
                case let .success(delivery):
                    report(.autoModeDelivered(delivery.effectID, session: effect.transaction.session))
                    // Delivery only means that the control adapter accepted
                    // the command.  A subsequent SessionObservation is still
                    // required before the Center can report confirmed mode.
                    report(.autoModeAwaitingConfirmation(delivery.effectID, session: effect.transaction.session))
                case let .failure(failure):
                    report(.autoModeFailed(
                        effect.effectID,
                        session: effect.transaction.session,
                        failure: .unavailable(failure.message)
                    ))
                }
            }
        }
    }

    private func executeNavigation(
        _ effect: NavigationEffect,
        report: @escaping (InteractionAdapterEvent) -> Void
    ) {
        let ref: SessionRef
        switch effect.target {
        case let .request(requestID): ref = requestID.session
        case let .session(session): ref = session
        }

        guard let target = sessionLookup(ref) else {
            report(.navigationFinished(effect.effectID, outcome: .unavailable))
            return
        }

        // Keep the physical route and the historical retry sequence inside
        // SessionNavigator.  The reducer receives only a typed outcome.
        let targetValue = SessionNavigationTarget(session: target.snapshot, sessionId: target.sessionID)
        Task { @MainActor [navigator] in
            let result = await navigator.navigate(target: targetValue, collapsePolicy: .afterSuccess)
            let outcome: NavigationOutcome
            switch result {
            case .succeeded: outcome = .succeeded
            case .failed: outcome = .failed("Navigation failed")
            case .activated: outcome = .succeeded
            case .unavailable: outcome = .unavailable
            case .cancelled: outcome = .failed("Navigation cancelled")
            }
            report(.navigationFinished(effect.effectID, outcome: outcome))
        }
    }
}

/// Auto controls are intentionally unavailable until a provider exposes an
/// independent control channel.  It is safer to surface a typed failure than
/// to reuse a pending permission continuation or claim a mode was changed.
final class UnavailableAutoCommandAdapter: AutoCommandAdapter, @unchecked Sendable {
    init() {}

    func submit(
        _ transaction: AutoCommandTransaction,
        completion: @escaping (Result<AutoDelivery, AutoAdapterFailure>) -> Void
    ) {
        completion(.failure(AutoAdapterFailure(message: "Auto control channel is unavailable")))
    }
}
