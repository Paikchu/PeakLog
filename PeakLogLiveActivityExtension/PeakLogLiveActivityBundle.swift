import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct PeakLogLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        PlanLiveActivityWidget()
    }
}

struct PlanLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PlanLiveActivityAttributes.self) { context in
            liveActivityView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.82))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    progressText(context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    completeButton(context: context, compact: true)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.state.currentExerciseName)
                            .font(.headline)
                            .lineLimit(1)
                        Text(setLine(context.state))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: context.state.isComplete ? "checkmark.circle.fill" : "figure.strengthtraining.traditional")
            } compactTrailing: {
                Text("\(context.state.completedSetsCount)/\(context.state.totalSetsCount)")
                    .font(.caption2.weight(.bold))
            } minimal: {
                Image(systemName: context.state.isComplete ? "checkmark.circle.fill" : "checkmark")
            }
        }
    }

    private func liveActivityView(context: ActivityViewContext<PlanLiveActivityAttributes>) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(context.state.isComplete ? "完成" : "进行中")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.purple)
                Text(context.state.currentExerciseName)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(setLine(context.state))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 8) {
                progressText(context.state)
                completeButton(context: context, compact: false)
            }
        }
        .padding(16)
    }

    private func completeButton(
        context: ActivityViewContext<PlanLiveActivityAttributes>,
        compact: Bool
    ) -> some View {
        Button(
            intent: CompletePlanSetIntent(
                activityID: context.attributes.sessionID,
                planSetID: context.state.currentPlanSetID ?? ""
            )
        ) {
            Label(compact ? "完成" : "完成动作", systemImage: "checkmark")
                .font(.caption.weight(.bold))
        }
        .disabled(context.state.isComplete)
        .tint(.purple)
    }

    private func progressText(_ state: PlanLiveActivityAttributes.ContentState) -> some View {
        Text("\(state.completedSetsCount)/\(state.totalSetsCount)")
            .font(.caption.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(.white)
    }

    private func setLine(_ state: PlanLiveActivityAttributes.ContentState) -> String {
        "第 \(state.currentSetIndex) 组 · \(state.targetLoadText) · \(state.targetReps) 次"
    }
}
