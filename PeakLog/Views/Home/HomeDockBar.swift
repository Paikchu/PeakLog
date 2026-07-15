import SwiftUI

enum HomeTab: String, CaseIterable, Identifiable {
    case calendar
    case plan
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendar:
            return String(localized: "home_dock.calendar")
        case .plan:
            return String(localized: "home_dock.plan")
        case .settings:
            return String(localized: "home_dock.settings")
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

    @Namespace private var dockNamespace

    // One curve for every dock change; animation is scoped to the dock so
    // switching tabs never animates the screens themselves.
    static let dockSpring = Animation.spring(response: 0.35, dampingFraction: 0.82)

    var body: some View {
        glassDock
            .padding(.horizontal, HomeDockMetrics.outerHorizontalPadding)
            .animation(Self.dockSpring, value: selectedTab)
            .accessibilityIdentifier("homeDockBar")
    }

    // 原生 Liquid Glass：不叠底色、描边和自定义阴影，质感全部交给系统。
    @ViewBuilder
    private var glassDock: some View {
        if #available(iOS 26, *) {
            dockContent
                .padding(HomeDockMetrics.contentPadding)
                .glassEffect(
                    .regular.tint(Color.accentPrimary.opacity(0.12)).interactive(),
                    in: .capsule
                )
        } else {
            dockContent
                .padding(HomeDockMetrics.contentPadding)
                .background(legacyDockBackground)
        }
    }

    private var dockContent: some View {
        HStack(spacing: HomeDockMetrics.slotSpacing) {
            ForEach(HomeTab.allCases) { tab in
                dockSlot(for: tab) {
                    tabButton(tab)
                }
            }
        }
    }

    private func dockSlot<Content: View>(for tab: HomeTab, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(width: HomeDockMetrics.slotWidth, height: HomeDockMetrics.slotHeight)
            .contentShape(Rectangle())
            .overlay(alignment: .trailing) {
                if tab != .settings {
                    Rectangle()
                        .fill(Color.appSeparator.opacity(0.55))
                        .frame(width: 0.5, height: HomeDockMetrics.dividerHeight)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("homeDock.slot.\(tab.rawValue)")
    }

    private func tabButton(_ tab: HomeTab) -> some View {
        let isSelected = selectedTab == tab

        return Button {
            selectedTab = tab
        } label: {
            Image(systemName: tab.symbolName)
                .font(.system(size: 20, weight: .semibold))
                .symbolVariant(isSelected ? .fill : .none)
                .frame(height: 26)
                .foregroundColor(isSelected ? Color.accentPrimary : Color.textSecondary)
            .frame(width: HomeDockMetrics.slotWidth, height: HomeDockMetrics.slotHeight)
            .background {
                if isSelected {
                    selectionBackground
                }
            }
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(minWidth: HomeDockMetrics.minimumHitTarget, minHeight: HomeDockMetrics.minimumHitTarget)
        .accessibilityLabel(tab.title)
        .accessibilityIdentifier("homeDock.\(tab.rawValue)")
    }

    private var selectionBackground: some View {
        Capsule()
            .fill(Color.accentPrimary.opacity(0.16))
            .matchedGeometryEffect(id: "activeDockSlot", in: dockNamespace)
    }

    // iOS 26 以下没有 Liquid Glass，保留材质 + 描边 + 阴影模拟。
    private var legacyDockBackground: some View {
        Capsule(style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.32), Color.white.opacity(0.04)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(0.22), radius: 18, x: 0, y: 8)
    }
}

#Preview {
    ZStack {
        Color.appBackground.ignoresSafeArea()
        VStack(spacing: 16) {
            Spacer()
            HomeDockBar(selectedTab: .constant(.calendar))
            HomeDockBar(selectedTab: .constant(.plan))
        }
    }
}
