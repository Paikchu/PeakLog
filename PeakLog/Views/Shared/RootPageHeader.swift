import SwiftUI

enum RootPageHeaderMetrics {
    static let horizontalPadding: CGFloat = 20
    static let topPadding: CGFloat = 12
    static let bottomPadding: CGFloat = 8
    static let trailingControlSize: CGFloat = 44
}

extension AppFont {
    static let rootPageTitle = AppFont(size: 30, weight: .bold, relativeTo: .largeTitle)
}

struct RootPageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let trailing: () -> Trailing

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .appFont(.rootPageTitle)
                    .foregroundColor(.textPrimary)
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .appFont(size: 15)
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
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}
