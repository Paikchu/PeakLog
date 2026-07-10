import SwiftUI

enum RootPageHeaderMetrics {
    static let horizontalPadding: CGFloat = 20
    static let topPadding: CGFloat = 12
    static let bottomPadding: CGFloat = 8
    static let trailingControlSize: CGFloat = 44
}

extension Font {
    static let rootPageTitle = Font.system(size: 30, weight: .bold)
    static let rootPageEyebrow = Font.system(size: 12, weight: .semibold)
}

struct RootPageHeader<Trailing: View>: View {
    let eyebrow: String?
    let title: String
    let subtitle: String?
    @ViewBuilder let trailing: () -> Trailing

    init(
        eyebrow: String? = nil,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                if let eyebrow, !eyebrow.isEmpty {
                    Text(eyebrow)
                        .font(.rootPageEyebrow)
                        .kerning(0.8)
                        .foregroundColor(.textMuted)
                }
                Text(title)
                    .font(.rootPageTitle)
                    .foregroundColor(.textPrimary)
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 15))
                        .foregroundColor(.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing()
                .frame(width: RootPageHeaderMetrics.trailingControlSize, height: RootPageHeaderMetrics.trailingControlSize)
        }
        .padding(.horizontal, RootPageHeaderMetrics.horizontalPadding)
        .padding(.top, RootPageHeaderMetrics.topPadding)
        .padding(.bottom, RootPageHeaderMetrics.bottomPadding)
    }
}

extension RootPageHeader where Trailing == EmptyView {
    init(eyebrow: String? = nil, title: String, subtitle: String? = nil) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle) { EmptyView() }
    }
}
