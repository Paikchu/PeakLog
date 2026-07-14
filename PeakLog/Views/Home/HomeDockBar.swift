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

struct DockPlanAction {
    let title: String
    let isEnabled: Bool
    let action: () -> Void
}

struct HomeDockBar: View {
    @Binding var selectedTab: HomeTab
    var planAction: DockPlanAction?

    @Namespace private var dockNamespace

    // One curve for every dock change so slot content and page transitions move together.
    static let dockSpring = Animation.spring(response: 0.35, dampingFraction: 0.82)

    // The plan slot doubles as the start-training CTA while the plan tab is
    // active and today's plan has sets to run.
    private var showsPlanAction: Bool {
        selectedTab == .plan && planAction != nil
    }

    var body: some View {
        dockContent
            .padding(HomeDockMetrics.contentPadding)
            .background(dockBackground)
            .padding(.horizontal, HomeDockMetrics.outerHorizontalPadding)
            .animation(Self.dockSpring, value: showsPlanAction)
            .accessibilityIdentifier("homeDockBar")
    }

    private var dockContent: some View {
        HStack(spacing: HomeDockMetrics.slotSpacing) {
            ForEach(HomeTab.allCases) { tab in
                dockSlot(for: tab) {
                    if tab == .plan, showsPlanAction, let planAction {
                        startTrainingButton(planAction)
                    } else {
                        tabButton(tab)
                    }
                }
            }
        }
    }

    private func dockSlot<Content: View>(for tab: HomeTab, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(width: HomeDockMetrics.slotWidth, height: HomeDockMetrics.slotHeight)
            .contentShape(Rectangle())
            .overlay(alignment: .trailing) {
                if tab != .settings && !(tab == .plan && showsPlanAction) {
                    Rectangle()
                        .fill(Color.appSeparator.opacity(0.55))
                        .frame(width: 0.5, height: HomeDockMetrics.dividerHeight)
                }
            }
            .zIndex(tab == .plan && showsPlanAction ? 1 : 0)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("homeDock.slot.\(tab.rawValue)")
    }

    private func tabButton(_ tab: HomeTab) -> some View {
        let isSelected = selectedTab == tab

        return Button {
            withAnimation(Self.dockSpring) {
                selectedTab = tab
            }
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

    private func startTrainingButton(_ planAction: DockPlanAction) -> some View {
        Button(action: planAction.action) {
            Label(planAction.title, systemImage: "play.fill")
                .font(.system(size: 15, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 16)
                .frame(width: HomeDockMetrics.actionWidth, height: HomeDockMetrics.slotHeight)
        }
        .buttonStyle(.plain)
        .foregroundColor(.white)
        .background {
            Capsule()
                .fill(Color.accentPrimary)
                .matchedGeometryEffect(id: "activeDockSlot", in: dockNamespace)
        }
        .clipShape(Capsule())
        .disabled(!planAction.isEnabled)
        .opacity(planAction.isEnabled ? 1 : 0.5)
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
        .accessibilityLabel(planAction.title)
        .accessibilityIdentifier("today.startPlan")
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

#Preview {
    ZStack {
        Color.appBackground.ignoresSafeArea()
        VStack(spacing: 16) {
            Spacer()
            HomeDockBar(selectedTab: .constant(.calendar))
            HomeDockBar(
                selectedTab: .constant(.plan),
                planAction: DockPlanAction(title: "开始训练", isEnabled: true, action: {})
            )
        }
    }
}
