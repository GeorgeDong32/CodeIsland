import SwiftUI
import CodeIslandCore

/// Shared accent color for plan-related UI (PlanPreview, ApprovalBar ExitPlanMode, SessionCard).
let planApprovalColor = Color(red: 0.5, green: 0.75, blue: 1.0)

// MARK: - Plan Preview for ExitPlanMode

/// Expandable plan content preview for ExitPlanMode permission requests.
/// Collapsed: shows first 4 lines with fade overlay + line count.
/// Expanded: ScrollView with full content, height-capped.
struct PlanPreview: View {
    let toolInput: [String: Any]?
    @State private var isExpanded = false

    private var planText: String? {
        guard let plan = toolInput?["plan"] as? String, !plan.isEmpty else { return nil }
        return plan
    }

    private var lineCount: Int {
        guard let text = planText else { return 0 }
        return text.components(separatedBy: .newlines).count
    }

    private var allowedPromptsCount: Int {
        (toolInput?["allowedPrompts"] as? [[String: String]] ?? []).count
    }

    private let planColor = planApprovalColor

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let text = planText {
                if isExpanded {
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(text)
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(planColor.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                } else {
                    ZStack(alignment: .bottom) {
                        Text(text)
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(planColor.opacity(0.85))
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if lineCount > 4 {
                            LinearGradient(
                                colors: [
                                    Color(red: 0.08, green: 0.08, blue: 0.1).opacity(0),
                                    Color(red: 0.08, green: 0.08, blue: 0.1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 20)
                            .allowsHitTesting(false)
                        }
                    }

                    if lineCount > 4 {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 8))
                            Text(String(format: L10n.shared["plan_lines"], lineCount))
                                .font(.system(size: 8.5))
                        }
                        .foregroundStyle(.white.opacity(0.4))
                    }
                }
            } else {
                Text(L10n.shared["plan_no_content"])
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }

            if allowedPromptsCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 8))
                    Text(String(format: L10n.shared["plan_preapproved"], allowedPromptsCount))
                        .font(.system(size: 8.5))
                }
                .foregroundStyle(.white.opacity(0.4))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
    }
}

// MARK: - ExitPlanMode approval options

/// Plan approval OptionRows for ExitPlanMode (Auto Accept / Manual / Request Changes).
struct ExitPlanModeApprovalOptions: View {
    let queuePosition: Int
    let queueTotal: Int
    let appState: AppState
    let onDismiss: () -> Void

    @State private var showFeedbackInput = false
    @State private var feedbackText = ""
    @FocusState private var feedbackFocused: Bool

    private let planColor = planApprovalColor

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text("!")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(planColor)
                Text("ExitPlanMode")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(planColor)
                Spacer()
                if queueTotal > 1 {
                    Text("\(queuePosition)/\(queueTotal)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 14)

            VStack(spacing: 2) {
                OptionRow(
                    index: 1,
                    label: L10n.shared["plan_auto_accept"],
                    description: L10n.shared["plan_auto_accept_desc"],
                    isSelected: false,
                    accent: planColor,
                    action: {
                        let mode = appState.smartModeForPendingPlan() ?? "acceptEdits"
                        appState.approvePlanWithMode(mode)
                    }
                )
                OptionRow(
                    index: 2,
                    label: L10n.shared["plan_manual"],
                    description: L10n.shared["plan_manual_desc"],
                    isSelected: false,
                    accent: planColor,
                    action: { appState.approvePlanWithMode(nil) }
                )
                OptionRow(
                    index: 3,
                    label: L10n.shared["plan_request_changes"],
                    description: L10n.shared["plan_request_changes_desc"],
                    isSelected: showFeedbackInput,
                    accent: planColor,
                    action: {
                        withAnimation(NotchAnimation.micro) {
                            showFeedbackInput.toggle()
                            feedbackText = ""
                        }
                    }
                )
            }
            .padding(.horizontal, 14)

            if showFeedbackInput {
                HStack(spacing: 6) {
                    Text(">")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.3, green: 0.85, blue: 0.4))
                    TextField(L10n.shared["feedback_placeholder"], text: $feedbackText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white)
                        .focused($feedbackFocused)
                        .onSubmit {
                            appState.denyPermissionWithFeedback(feedbackText.isEmpty ? nil : feedbackText)
                        }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.05))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                )
                .padding(.horizontal, 14)
                .onAppear { feedbackFocused = true }
            }

            PixelButton(
                label: L10n.shared["dismiss"],
                fg: .white.opacity(0.6),
                bg: Color.white.opacity(0.06),
                border: Color.white.opacity(0.12),
                action: onDismiss
            )
            .padding(.horizontal, 14)
        }
    }
}

// MARK: - Permission mode indicator (AUTO badge)

struct PermissionIndicatorConfig {
    let symbol: String
    let color: Color
    let togglesAutoApprove: Bool
}

func permissionIndicatorConfig(for permissionMode: String?) -> PermissionIndicatorConfig? {
    switch permissionMode {
    case "bypassPermissions":
        return PermissionIndicatorConfig(
            symbol: "⏵⏵",
            color: Color(red: 1.0, green: 0.4, blue: 0.4),
            togglesAutoApprove: true
        )
    case "auto":
        return PermissionIndicatorConfig(
            symbol: "⏵⏵",
            color: Color(red: 1.0, green: 0.8, blue: 0.0),
            togglesAutoApprove: true
        )
    case "acceptEdits":
        return PermissionIndicatorConfig(
            symbol: "⏵⏵",
            color: Color(red: 175.0 / 255.0, green: 135.0 / 255.0, blue: 254.0 / 255.0),
            togglesAutoApprove: true
        )
    case "plan":
        return PermissionIndicatorConfig(
            symbol: "⏸",
            color: Color(red: 0.45, green: 0.7, blue: 0.69),
            togglesAutoApprove: false
        )
    default:
        return nil
    }
}

/// Inline ExitPlanMode summary row for SessionCard approval queue.
struct ExitPlanModeInlineSummary: View {
    let planLines: Int
    let queueIndex: Int
    let queueTotal: Int
    let fontSize: CGFloat
    let onViewDetails: () -> Void

    private let planColor = planApprovalColor

    var body: some View {
        HStack(spacing: 8) {
            if planLines > 0 {
                Text("Plan \(planLines) lines")
                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                    .foregroundStyle(planColor.opacity(0.7))
            } else {
                Text(String(format: L10n.shared["approval_queue_label"], queueIndex + 1, queueTotal, "ExitPlanMode"))
                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
            }
            Spacer(minLength: 8)
            Button(action: onViewDetails) {
                Text(L10n.shared["approval_details_expand"])
                    .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
                    .foregroundStyle(planColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(planColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
        }
    }
}
