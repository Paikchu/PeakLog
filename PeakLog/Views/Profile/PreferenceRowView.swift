import SwiftUI

struct PreferenceRowStyle {
    let contentSpacing: CGFloat
    let iconSize: CGFloat
    let titleFont: AppFont
    let valueFont: AppFont
    let verticalPadding: CGFloat
    let chevronSize: CGFloat

    static let standard = PreferenceRowStyle(
        contentSpacing: 14,
        iconSize: 16,
        titleFont: .settingTitle,
        valueFont: .settingValue,
        verticalPadding: 14,
        chevronSize: 12
    )

    static let profile = PreferenceRowStyle(
        contentSpacing: 12,
        iconSize: 20,
        titleFont: AppFont(size: 17, weight: .medium, relativeTo: .body),
        valueFont: AppFont(size: 15, relativeTo: .subheadline),
        verticalPadding: 11,
        chevronSize: 18
    )
}

// MARK: - Toggle Preference Row
struct PreferenceToggleRow: View {
    let icon: String
    let title: LocalizedStringKey
    @Binding var isOn: Bool
    var isLoading: Bool = false
    var onChange: ((Bool) -> Void)? = nil
    var style: PreferenceRowStyle = .standard

    var body: some View {
        HStack(spacing: style.contentSpacing) {
            Image(systemName: icon)
                .appFont(size: style.iconSize)
                .foregroundColor(.textSecondary)
                .frame(width: 24)

            Text(title)
                .appFont(style.titleFont)
                .foregroundColor(.textPrimary)

            Spacer()

            if isLoading {
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                Text(isOn ? "common.on" : "common.off")
                    .appFont(style.valueFont)
                    .foregroundColor(.textMuted)

                Image(systemName: "chevron.right")
                    .appFont(size: style.chevronSize, weight: .semibold)
                    .foregroundColor(.textDarkMuted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, style.verticalPadding)
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
    var style: PreferenceRowStyle = .standard
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: style.contentSpacing) {
                Image(systemName: icon)
                    .appFont(size: style.iconSize)
                    .foregroundColor(.textSecondary)
                    .frame(width: 24)

                Text(title)
                    .appFont(style.titleFont)
                    .foregroundColor(.textPrimary)

                Spacer()

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .appFont(style.valueFont)
                        .foregroundColor(.textMuted)
                }

                Image(systemName: "chevron.right")
                    .appFont(size: style.chevronSize, weight: .semibold)
                    .foregroundColor(.textDarkMuted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, style.verticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Section Container
struct SettingsSection<Content: View>: View {
    let title: LocalizedStringKey
    var horizontalPadding: CGFloat = 16
    var titleHorizontalPadding: CGFloat = 20
    var cornerRadius: CGFloat = AppRadius.xl
    var showsBorder = true
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .appFont(size: 11, weight: .semibold)
                .foregroundColor(.textMuted)
                .padding(.horizontal, titleHorizontalPadding)
                .padding(.bottom, 6)
                .textCase(.uppercase)

            VStack(spacing: 0) {
                content()
            }
            .background(Color.appSurface)
            .cornerRadius(cornerRadius)
            .overlay(
                Group {
                    if showsBorder {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(Color.appSeparator, lineWidth: 0.5)
                    }
                }
            )
            .shadow(
                color: showsBorder && colorScheme == .light ? Color.black.opacity(0.06) : .clear,
                radius: 3, x: 0, y: 1
            )
        }
        .padding(.horizontal, horizontalPadding)
    }
}
