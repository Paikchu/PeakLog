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

struct DockPlanAction {
    let title: String
    let isEnabled: Bool
    let action: () -> Void
}

struct HomeDockBar: View {
    @Binding var selectedTab: HomeTab
    var planAction: DockPlanAction?

    @Namespace private var dockNamespace

    // One curve for every dock change so width, slot morph, and the sliding
    // selection capsule all move together.
    static let dockSpring = Animation.spring(response: 0.35, dampingFraction: 0.82)
    private static let planSlotID = "planSlot"
    private static let selectionID = "selection"

    // The plan slot doubles as the start-training CTA while the plan tab is
    // active and today's plan has sets to run.
    private var showsPlanAction: Bool {
        selectedTab == .plan && planAction != nil
    }

    var body: some View {
        dockContent
            .padding(4)
            .background(dockBackground)
            .padding(.horizontal, 22)
            .animation(Self.dockSpring, value: showsPlanAction)
            .accessibilityIdentifier("homeDockBar")
    }

    private var dockContent: some View {
        HStack(spacing: 4) {
            ForEach(HomeTab.allCases) { tab in
                if tab == .plan, showsPlanAction, let planAction {
                    startTrainingButton(planAction)
                } else {
                    tabButton(tab)
                }
            }
        }
    }

    private func tabButton(_ tab: HomeTab) -> some View {
        Button {
            withAnimation(Self.dockSpring) {
                selectedTab = tab
            }
        } label: {
            Image(systemName: tab.symbolName)
                .font(.system(size: 18, weight: .semibold))
                .symbolVariant(selectedTab == tab ? .fill : .none)
                .foregroundColor(selectedTab == tab ? Color.accentPrimary : Color.textPrimary)
                .frame(width: 56, height: 48)
                .background {
                    if selectedTab == tab {
                        selectionBackground
                    }
                }
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .matchedGeometryEffect(
            id: tab == .plan ? Self.planSlotID : tab.rawValue,
            in: dockNamespace
        )
        .transition(.opacity)
        .accessibilityLabel(tab.title)
        .accessibilityIdentifier("homeDock.\(tab.rawValue)")
    }

    private var selectionBackground: some View {
        Capsule()
            .fill(Color.appSurface.opacity(0.55))
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            )
            .matchedGeometryEffect(id: Self.selectionID, in: dockNamespace)
    }

    private func startTrainingButton(_ planAction: DockPlanAction) -> some View {
        Button(action: planAction.action) {
            Label(planAction.title, systemImage: "play.fill")
                .font(.system(size: 14, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 22)
                .frame(height: 48)
        }
        .buttonStyle(.plain)
        .foregroundColor(.white)
        .glassActionBackground(cornerRadius: AppRadius.full, tint: Color.accentPrimary.opacity(0.42))
        .clipShape(Capsule())
        .disabled(!planAction.isEnabled)
        .matchedGeometryEffect(id: Self.planSlotID, in: dockNamespace)
        .transition(.opacity)
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
