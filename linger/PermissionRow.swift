import SwiftUI

// The same row appears in onboarding and in Settings › General, so the flow is never needed twice.
struct LaunchAtLoginRow: View {
    let model: PermissionsModel

    var body: some View {
        PermissionRow(
            systemImage: "power",
            title: "Start linger when I log in",
            detail: "Runs quietly in the menu bar every time you start your Mac. macOS may show a \"Background Items Added\" notice, that is expected.",
            status: status.text,
            statusURL: status.url,
            isOn: Binding(get: { model.launchAtLoginOn }, set: { model.setLaunchAtLogin($0) })
        )
    }

    private var status: (text: String, url: URL?) {
        switch model.loginItemStatus {
        case .notEnabled: ("Not enabled", nil)
        case .enabled: ("Enabled", nil)
        case .needsApproval: ("Needs approval — open Login Items", PermissionsModel.loginItemsPane)
        }
    }
}

struct PermissionRow: View {
    let systemImage: String
    let title: String
    let detail: String
    let status: String
    var statusURL: URL? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                statusLabel
                    .font(.caption)
                    .contentTransition(.opacity)
                    .animation(Motion.easeOut(0.2), value: status)
            }

            Spacer(minLength: 8)

            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if let statusURL {
            Link(status, destination: statusURL)
        } else {
            Text(status)
                .foregroundStyle(.tertiary)
        }
    }
}
