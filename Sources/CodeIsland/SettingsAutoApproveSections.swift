import SwiftUI

/// Behavior-page sections for Auto Mode / Plan Auto-Accept / auto-approve tools.
/// Fork patch surface — kept as one view so it can be transplanted onto upstream.
struct AutoApproveSettingsSections: View {
    @ObservedObject private var l10n = L10n.shared
    @Binding var autoApproveMode: String
    @Binding var planAutoAcceptMode: String
    @Binding var autoApproveRaw: String

    private func autoApproveBinding(for name: String) -> Binding<Bool> {
        Binding(
            get: { autoApproveRaw.split(separator: ",").contains(Substring(name)) },
            set: { isOn in
                var set = Set(autoApproveRaw.split(separator: ",").map(String.init))
                if isOn { set.insert(name) } else { set.remove(name) }
                autoApproveRaw = set.sorted().joined(separator: ",")
            }
        )
    }

    var body: some View {
        Section(l10n["auto_approve_mode"]) {
            Text(l10n["auto_approve_mode_desc"])
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker(selection: $autoApproveMode) {
                ForEach(AutoApproveMode.allCases) { mode in
                    Text(l10n["auto_approve_mode_\(mode.rawValue)"])
                        .tag(mode.rawValue)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
        }

        Section(l10n["plan_auto_accept_mode"]) {
            Text(l10n["plan_auto_accept_mode_desc"])
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker(selection: $planAutoAcceptMode) {
                ForEach(PlanAutoAcceptMode.allCases) { mode in
                    Text(l10n["plan_auto_accept_mode_\(mode.rawValue)"])
                        .tag(mode.rawValue)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
        }

        Section(l10n["auto_approve_tools"]) {
            Text(l10n["auto_approve_tools_desc"])
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(SettingsManager.allAutoApproveTools, id: \.name) { tool in
                Toggle(isOn: autoApproveBinding(for: tool.name)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tool.name)
                            .font(.system(size: 12, design: .monospaced))
                        Text(l10n["auto_approve_\(tool.name)"])
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
