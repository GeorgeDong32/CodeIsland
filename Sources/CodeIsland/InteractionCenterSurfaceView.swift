import SwiftUI
import CodeIslandCore

/// SwiftUI renderer for the fork-owned interaction projection. This view is
/// intentionally independent of AppState, SessionSnapshot and provider wire
/// payloads. It becomes the panel's surface when the coordinator is attached.
struct InteractionCenterSurfaceView: View {
    let router: InteractionUIActionRouter

    private var local: LocalInteractionSnapshot { router.snapshot.local }

    var body: some View {
        Group {
            switch local.presentation.surface {
            case let .request(id):
                if let request = local.requests[id] {
                    InteractionRequestCard(request: request, router: router)
                } else {
                    EmptyView()
                }
            case .sessionList:
                InteractionSessionList(sessions: local.sessions.values.sorted { lhs, rhs in
                    if lhs.pendingCount != rhs.pendingCount { return lhs.pendingCount > rhs.pendingCount }
                    return lhs.session.key.providerSessionID < rhs.session.key.providerSessionID
                }, router: router)
            case let .completion(completion):
                VStack(alignment: .leading, spacing: 8) {
                    Text(completion.message)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                    Text(shortSessionID(completion.session))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(16)
            case .collapsed:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shortSessionID(_ session: SessionRef) -> String {
        let value = session.key.providerSessionID
        return value.count > 8 ? String(value.suffix(8)) : value
    }
}

private struct InteractionSessionList: View {
    let sessions: [InteractionSessionSnapshot]
    let router: InteractionUIActionRouter

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(sessions, id: \.session) { session in
                    Button {
                        _ = router.navigate(.session(session.session))
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.facts.title ?? session.facts.project ?? session.facts.source ?? "Session")
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                Text(session.keyLabel)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                            Spacer()
                            if session.pendingCount > 0 {
                                Text("\(session.pendingCount)")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.orange)
                            }
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .frame(maxHeight: 360)
    }
}

private extension InteractionSessionSnapshot {
    var keyLabel: String {
        let value = session.key.providerSessionID
        let suffix = value.count > 8 ? String(value.suffix(8)) : value
        return "\(session.key.provider.rawValue) · \(suffix)"
    }
}

private struct InteractionRequestCard: View {
    let request: InteractionRequestSnapshot
    let router: InteractionUIActionRouter
    @State private var answerText = ""

    private var sessionLabel: String {
        let value = request.session.key.providerSessionID
        return value.count > 8 ? String(value.suffix(8)) : value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                _ = router.navigate(.request(request.id))
            } label: {
                HStack(spacing: 6) {
                    Text(sessionLabel)
                    Text("·")
                    Text(request.session.key.provider.rawValue)
                    Spacer()
                    Text("\(request.queuePosition + 1)")
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)

            switch request.content {
            case let .permission(content):
                permissionContent(content)
            case let .question(content):
                questionContent(content)
            }

            if let error = request.error {
                Text(String(describing: error))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.red.opacity(0.85))
            }

            HStack(spacing: 6) {
                Button("Dismiss") { _ = router.dismiss(request.id) }
                    .buttonStyle(.bordered)
                Spacer()
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func permissionContent(_ content: PermissionContent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(content.variant.isPlan ? "Plan" : (content.toolName ?? "Permission"))
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(.orange)
            if let summary = content.summary {
                Text(summary)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white)
            }
            HStack(spacing: 6) {
                if request.availableActions.contains(.allowOnce) {
                    Button("Allow") { _ = router.resolve(request.id, command: .allowOnce) }
                        .buttonStyle(.borderedProminent)
                }
                if request.availableActions.contains(where: {
                    if case .allowPlan = $0 { return true }; return false
                }) {
                    Button("Allow") {
                        guard let mode = request.availableActions.compactMap({ action -> PlanMode? in
                            if case let .allowPlan(mode) = action { return mode }; return nil
                        }).first else { return }
                        _ = router.resolve(request.id, command: .allowPlan(mode: mode))
                    }
                    .buttonStyle(.borderedProminent)
                }
                if request.availableActions.contains(.allowAlways) {
                    Button("Always") { _ = router.resolve(request.id, command: .allowAlways) }
                        .buttonStyle(.bordered)
                }
                if request.availableActions.contains(.deny) {
                    Button("Deny") { _ = router.resolve(request.id, command: .deny(message: nil)) }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder
    private func questionContent(_ content: QuestionContent) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let item = content.items.first {
                Text(item.prompt.value)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(item.prompt.sensitivity == .secret ? .orange : .white)
                ForEach(item.options, id: \.key) { option in
                    Button(option.label.value) {
                        answerText = option.label.value
                        submitAnswer(key: item.key)
                    }
                    .buttonStyle(.bordered)
                }
                if content.answerSchema.allowsCustomText {
                    HStack {
                        TextField("Answer", text: $answerText)
                        Button("Send") { submitAnswer(key: item.key) }
                    }
                }
            } else {
                Text("Question")
                    .foregroundStyle(.white)
            }
        }
    }

    private func submitAnswer(key: String) {
        guard !answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        _ = router.resolve(request.id, command: .answer([
            QuestionAnswer(questionKey: key, values: [.custom(SensitiveText(answerText))])
        ]))
    }
}

private extension PermissionVariant {
    var isPlan: Bool {
        if case .plan = self { return true }
        return false
    }
}
