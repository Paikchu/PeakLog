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

/// 信息层级（见 `docs/requirements/2026-08-12-live-activity-information-hierarchy.md`）：
///
/// - P1 当前动作还剩几组 —— 最大字号，训练时唯一需要「读数字」的信息。
/// - P2 今日总进度 —— 进度环，只需要「大概过了多少」的体感，用形状而不是数字承载。
/// - P3 当前动作 —— 2–4 字简称，确认性信息，空间不足时第一个被牺牲。
///
/// P1 和 P2 做成同一个复合件（环 + 环内数字），所以最小态整体缩小仍然同时保留两者，
/// 被丢掉的恰好是优先级最低的 P3。空间够的展开态和锁屏则把复合件拆开——环只是紧凑态
/// 的空间妥协，不必带到大尺寸里去。
struct PlanLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PlanLiveActivityAttributes.self) { context in
            lockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.82))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.currentExerciseName)
                            .font(.headline)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                        Text(setPositionLine(context.state))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    remainingBadge(context.state)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        targetLine(context.state)
                        progressBar(context.state)
                        completeButton(context: context)
                    }
                }
            } compactLeading: {
                compactLeadingLabel(context.state)
            } compactTrailing: {
                remainingRing(
                    context.state,
                    diameter: 26,
                    lineWidth: 2.5,
                    numberSize: 15,
                    glyphSize: 13
                )
            } minimal: {
                remainingRing(
                    context.state,
                    diameter: 22,
                    lineWidth: 2,
                    numberSize: 12,
                    glyphSize: 11
                )
            }
        }
    }

    // MARK: - 紧凑态

    /// P3。简称由 `PlanLiveActivityShortName` 保证在 2–4 字之间；4 字时降一档字号，
    /// 再配 `minimumScaleFactor` 兜住「上斜卧推」这种满宽的情况。
    @ViewBuilder
    private func compactLeadingLabel(_ state: PlanLiveActivityAttributes.ContentState) -> some View {
        if state.isComplete {
            Text("完成")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(islandAccent)
        } else if state.currentExerciseShortName.isEmpty {
            Image(systemName: "figure.strengthtraining.traditional")
                .foregroundStyle(.white)
        } else {
            Text(state.currentExerciseShortName)
                .font(.system(
                    size: state.currentExerciseShortName.count >= 4 ? 11 : 12.5,
                    weight: .semibold
                ))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(.white)
        }
    }

    /// P1 + P2 的复合件：环是总进度，环内数字是当前动作还剩几组。
    private func remainingRing(
        _ state: PlanLiveActivityAttributes.ContentState,
        diameter: CGFloat,
        lineWidth: CGFloat,
        numberSize: CGFloat,
        glyphSize: CGFloat
    ) -> some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progressFraction(state))
                .stroke(
                    islandAccent,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                // 起点转到 12 点方向，顺时针增长。
                .rotationEffect(.degrees(-90))

            if state.isComplete {
                Image(systemName: "checkmark")
                    .font(.system(size: glyphSize, weight: .bold))
                    .foregroundStyle(islandAccent)
            } else {
                Text("\(state.currentExerciseRemainingSets)")
                    .font(.system(size: numberSize, weight: .heavy, design: .rounded))
                    // 两位数掉到一位数时数字宽度不跳动。
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(.white)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(state))
    }

    // MARK: - 展开态 / 锁屏

    private func lockScreenView(
        context: ActivityViewContext<PlanLiveActivityAttributes>
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.state.currentExerciseName)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(detailLine(context.state))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                }

                Spacer(minLength: 8)

                remainingBadge(context.state)
            }

            progressBar(context.state)
            completeButton(context: context)
        }
        .padding(16)
    }

    /// 空间够了就把复合件拆开：剩余组数独立成大字，总进度回落成一条进度条。
    @ViewBuilder
    private func remainingBadge(_ state: PlanLiveActivityAttributes.ContentState) -> some View {
        if state.isComplete {
            VStack(alignment: .trailing, spacing: 2) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(islandAccent)
                Text("已完成")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.72))
            }
        } else {
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(state.currentExerciseRemainingSets)")
                    .font(.system(size: 29, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(islandAccent)
                Text("组待做")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
    }

    /// 展开态字号最大的是目标重量×次数：组间休息瞄一眼手机，要的是「这组上多少」。
    private func targetLine(_ state: PlanLiveActivityAttributes.ContentState) -> some View {
        Text("\(state.targetLoadText) × \(state.targetReps) 次")
            .font(.system(size: 20, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private func progressBar(_ state: PlanLiveActivityAttributes.ContentState) -> some View {
        HStack(spacing: 10) {
            ProgressView(value: progressFraction(state))
                .progressViewStyle(.linear)
                .tint(islandAccent)
            Text("\(state.completedSetsCount)/\(state.totalSetsCount)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.72))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "今日进度，\(state.totalSetsCount) 组中的 \(state.completedSetsCount) 组"
        )
    }

    private func completeButton(
        context: ActivityViewContext<PlanLiveActivityAttributes>
    ) -> some View {
        Button(
            intent: CompletePlanSetIntent(
                activityID: context.attributes.sessionID,
                planSetID: context.state.currentPlanSetID ?? ""
            )
        ) {
            Label("完成本组", systemImage: "checkmark")
                .font(.caption.weight(.bold))
                .frame(maxWidth: .infinity)
        }
        .disabled(context.state.isComplete)
        .tint(islandAccent)
    }

    // MARK: - 文案与取值

    /// 与 App 主题 accent（`#F59E0B`）同源，在纯黑灵动岛上提亮到 `#FFB020` 保住对比度。
    /// 写成计算属性而不是 `Color` 上的 `static let`：静态存储属性在这个模块的默认
    /// MainActor 隔离下会引出跨隔离读取的告警，而每个调用点本来就在 view body 里。
    private var islandAccent: Color {
        Color(red: 1.0, green: 0.69, blue: 0.13)
    }

    private func progressFraction(_ state: PlanLiveActivityAttributes.ContentState) -> Double {
        guard state.totalSetsCount > 0 else { return 0 }
        let fraction = Double(state.completedSetsCount) / Double(state.totalSetsCount)
        return min(max(fraction, 0), 1)
    }

    private func setPositionLine(_ state: PlanLiveActivityAttributes.ContentState) -> String {
        guard !state.isComplete, state.currentExerciseTotalSets > 0 else {
            return "\(state.completedSetsCount)/\(state.totalSetsCount) 组已完成"
        }
        return "第 \(state.currentSetIndex) 组 / 共 \(state.currentExerciseTotalSets) 组"
    }

    private func detailLine(_ state: PlanLiveActivityAttributes.ContentState) -> String {
        guard !state.isComplete else {
            return "今日训练已完成"
        }
        return "\(setPositionLine(state)) · \(state.targetLoadText) × \(state.targetReps) 次"
    }

    private func accessibilityLabel(_ state: PlanLiveActivityAttributes.ContentState) -> String {
        guard !state.isComplete else {
            return "今日训练已完成，共 \(state.totalSetsCount) 组"
        }
        return """
        当前\(state.currentExerciseName)，本动作还剩 \(state.currentExerciseRemainingSets) 组，\
        今日进度 \(state.totalSetsCount) 组中的 \(state.completedSetsCount) 组
        """
    }
}
