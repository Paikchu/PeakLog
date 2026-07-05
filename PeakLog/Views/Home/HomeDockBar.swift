import SwiftUI

enum HomeTab: String, CaseIterable, Identifiable {
    case calendar
    case plan
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendar:
            return "Calendar"
        case .plan:
            return "Plan"
        case .settings:
            return "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .calendar:
            return "calendar"
        case .plan:
            return "figure.strengthtraining.traditional"
        case .settings:
            return "gearshape.fill"
        }
    }
}

struct HomeDockBar: View {
    @Binding var selectedTab: HomeTab

    var body: some View {
        dockContent
            .padding(6)
            .frame(maxWidth: 330)
            .background(dockBackground)
            .padding(.horizontal, 22)
            .accessibilityIdentifier("homeDockBar")
    }

    private var dockContent: some View {
        HStack(spacing: 4) {
            ForEach(HomeTab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        selectedTab = tab
                    }
                } label: {
                    HomeDockItem(
                        title: tab.title,
                        symbolName: tab.symbolName,
                        isSelected: selectedTab == tab
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("homeDock.\(tab.rawValue)")
            }
        }
    }

    @ViewBuilder
    private var dockBackground: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 8) {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(Color.appSurface.opacity(0.12))
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 34))
            }
        } else {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.12), radius: 20, x: 0, y: 10)
        }
    }
}

private struct HomeDockItem: View {
    let title: String
    let symbolName: String
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbolName)
                .font(.system(size: 24, weight: .semibold))
                .symbolVariant(isSelected ? .fill : .none)

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundColor(isSelected ? Color.accentPurple : Color.textPrimary)
        .frame(maxWidth: .infinity)
        .frame(height: 72)
        .background(itemBackground)
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var itemBackground: some View {
        if isSelected {
            Capsule()
                .fill(Color.appSurface.opacity(0.72))
        }
    }
}

#Preview {
    ZStack {
        Color.appBackground.ignoresSafeArea()
        VStack {
            Spacer()
            HomeDockBar(selectedTab: .constant(.plan))
        }
    }
}
