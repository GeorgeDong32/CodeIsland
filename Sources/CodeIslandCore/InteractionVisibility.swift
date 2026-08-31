import Foundation

/// The result of applying a presentation policy to one visibility fact.
///
/// This is intentionally independent of SwiftUI surface types: an adapter may
/// turn `.badgeOnly` into a notification, while the local panel may choose a
/// badge style.  The policy itself only decides whether a new request should
/// be prominent.
public enum VisibilityPresentation: Sendable, Equatable, Codable {
    case prominent
    case badgeOnly
}

public extension VisibilityObservation {
    /// Returns the state that is safe to use at `now`.
    ///
    /// A missing observation, stale measurement, future timestamp, or invalid
    /// max-age is treated as unknown by callers.  Unknown is deliberately
    /// conservative for CLI-first behavior: it causes a pending request to be
    /// shown instead of silently suppressing it.
    func state(at now: Date, policyMaximumAge: Duration? = nil) -> CLIVisibility {
        let age = now.timeIntervalSince(measuredAt)
        guard age >= 0, maxAge.timeInterval >= 0,
              age <= maxAge.timeInterval else { return .unknown }
        if let policyMaximumAge {
            guard policyMaximumAge.timeInterval >= 0,
                  age <= policyMaximumAge.timeInterval else { return .unknown }
        }
        return state
    }

    func isExpired(at now: Date, policyMaximumAge: Duration? = nil) -> Bool {
        state(at: now, policyMaximumAge: policyMaximumAge) == .unknown
    }
}

public extension PresentationPolicy {
    /// The first migration checkpoint.  Keep this explicit at call sites so a
    /// rollout cannot accidentally change UX while the owner is migrating.
    static let legacyCheckpoint = PresentationPolicy(mode: .legacyProminent)

    /// The opt-in policy used after behavior-equivalence evidence is recorded.
    static func adaptiveCLI(
        visibilityMaxAge: Duration = .seconds(5)
    ) -> PresentationPolicy {
        PresentationPolicy(mode: .adaptiveCLIFirst, visibilityMaxAge: visibilityMaxAge)
    }

    /// Decides the automatic presentation for a newly waiting request.  An
    /// explicit reveal is a separate request-owned override and is therefore
    /// applied by InteractionCenter after this method returns.
    func automaticPresentation(
        for observation: VisibilityObservation?,
        now: Date
    ) -> VisibilityPresentation {
        switch mode {
        case .legacyProminent:
            return .prominent
        case .adaptiveCLIFirst:
            guard let observation,
                  observation.state(at: now, policyMaximumAge: visibilityMaxAge) == .visible else {
                return .prominent
            }
            return .badgeOnly
        }
    }
}
