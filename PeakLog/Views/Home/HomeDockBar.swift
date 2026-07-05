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
            .padding(4)
            .frame(maxWidth: 288)
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
                Capsule(style: .continuous)
                    .fill(Color.appSurface.opacity(0.05))
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
            .overlay(rimHighlight)
            .shadow(color: Color.black.opacity(0.22), radius: 18, x: 0, y: 8)
        } else {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(rimHighlight)
                .shadow(color: Color.black.opacity(0.22), radius: 18, x: 0, y: 8)
        }
    }

    private var rimHighlight: some View {
        Capsule(style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(0.32), Color.white.opacity(0.04)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
    }
}

private struct HomeDockItem: View {
    let title: String
    let symbolName: String
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: symbolName)
                .font(.system(size: 18, weight: .semibold))
                .symbolVariant(isSelected ? .fill : .none)

            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundColor(isSelected ? Color.accentPurple : Color.textPrimary)
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .background(itemBackground)
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var itemBackground: some View {
        if isSelected {
            Capsule()
                .fill(Color.appSurface.opacity(0.55))
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
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
