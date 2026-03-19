import SwiftUI

// MARK: - Toggle Preference Row
struct PreferenceToggleRow: View {
    let icon: String
    let title: LocalizedStringKey
    @Binding var isOn: Bool
    var isLoading: Bool = false
    var onChange: ((Bool) -> Void)? = nil

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.textSecondary)
                .frame(width: 24)

            Text(title)
                .font(.settingTitle)
                .foregroundColor(.textPrimary)

            Spacer()

            if isLoading {
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                Text(isOn ? "common.on" : "common.off")
                    .font(.settingValue)
                    .foregroundColor(.textMuted)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.textDarkMuted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .onTapGesture {
            isOn.toggle()
            onChange?(isOn)
        }
    }
}

// MARK: - Navigation Preference Row
struct PreferenceNavRow: View {
    let icon: String
    let title: LocalizedStringKey
    var detail: String? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(.textSecondary)
                    .frame(width: 24)

                Text(title)
                    .font(.settingTitle)
                    .foregroundColor(.textPrimary)

                Spacer()

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.settingValue)
                        .foregroundColor(.textMuted)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.textDarkMuted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Section Container
struct SettingsSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.textMuted)
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
                .textCase(.uppercase)

            VStack(spacing: 0) {
                content
            }
            .background(Color.appSurface)
            .cornerRadius(AppRadius.xl)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.xl)
                    .strokeBorder(Color.appSeparator, lineWidth: 0.5)
            )
            .shadow(
                color: colorScheme == .light ? Color.black.opacity(0.06) : .clear,
                radius: 3, x: 0, y: 1
            )
        }
        .padding(.horizontal, 16)
    }
}
