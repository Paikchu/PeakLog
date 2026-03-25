import SwiftUI

struct MessageBubbleView: View {
    @Binding var message: ChatMessage
    var onDeleteExercise: (String, String) -> Void    // (recordId, exerciseId)
    var onSetChanged: (String, String, ExerciseSet) -> Void // (recordId, exerciseId, set)
    var onCompletePlannedSet: (String, PlanSetBlock) -> Void = { _, _ in }

    var body: some View {
        Group {
            if message.role == .user {
                userBubble
            } else {
                assistantContent
            }
        }
    }

    // MARK: - User Bubble
    private var userBubble: some View {
        HStack {
            Spacer(minLength: 48)
            Text(message.text)
                .font(.chatBody)
                .foregroundColor(.white.opacity(0.9))
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.userBubble)
                .cornerRadius(16, corners: [.topLeft, .topRight, .bottomLeft])
        }
    }

    // MARK: - Assistant Content
    private var assistantContent: some View {
        let blocks = message.renderableContentBlocks

        return VStack(alignment: .leading, spacing: 8) {
            if !blocks.isEmpty {
                // GenUI: render typed content blocks
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .text(let text):
                        if !text.isEmpty {
                            Text(text)
                                .font(.chatBody)
                                .foregroundColor(.textSecondary)
                                .multilineTextAlignment(.leading)
                                .padding(.horizontal, 2)
                        }

                    case .workoutRecord(let recordBlock):
                        workoutRecordCard(for: recordBlock, isEditable: true)

                    case .workoutRecordStream(let recordBlock):
                        workoutRecordCard(for: recordBlock, isEditable: false)

                    case .prSummary(let summary):
                        PRSummaryCard(summary: summary)

                    case .clarificationPrompt(let prompt):
                        VStack(alignment: .leading, spacing: 6) {
                            Text(prompt.question)
                                .font(.chatBody)
                                .foregroundColor(.textSecondary)
                                .multilineTextAlignment(.leading)

                            Text(prompt.draftSummary)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.textMuted)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color.workoutPanel.opacity(0.55))
                                .cornerRadius(12)
                        }
                        .padding(.horizontal, 2)

                    case .weeklyPlan(let plan):
                        weeklyPlanCard(plan)

                    case .todayPlan(let plan):
                        todayPlanCard(plan)

                    case .planAdjustmentSummary(let summary):
                        Text(summary.summaryText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.textMuted)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color.appSurface)
                            .cornerRadius(12)

                    case .unknown:
                        EmptyView()
                    }
                }
            } else {
                // Fallback: legacy workoutRecord field (mock data / previews)
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.chatBody)
                        .foregroundColor(.textSecondary)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 2)
                }
                if let record = message.workoutRecord {
                    WorkoutRecordCard(
                        messageId: message.id,
                        record: Binding(
                            get: { message.workoutRecord ?? record },
                            set: { message.workoutRecord = $0 }
                        ),
                        onDeleteExercise: { exerciseId in
                            onDeleteExercise(record.id, exerciseId)
                        },
                        onSetChanged: { exerciseId, updatedSet in
                            onSetChanged(record.id, exerciseId, updatedSet)
                        }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func workoutRecordCard(for recordBlock: WorkoutRecordBlock, isEditable: Bool) -> some View {
        let exercises = recordBlock.exercises.map { ex in
            Exercise(
                id: ex.exerciseId,
                name: ex.name,
                sets: ex.sets.map { s in
                    ExerciseSet(
                        id: s.setId,
                        setIndex: s.setIndex,
                        weight: s.weight,
                        weightUnit: WeightUnit(rawValue: s.weightUnit) ?? .kg,
                        reps: s.reps ?? 0
                    )
                }
            )
        }
        let record = WorkoutRecord(
            id: recordBlock.workoutSessionId,
            exercises: exercises
        )

        return WorkoutRecordCard(
            messageId: message.id,
            record: Binding(
                get: { record },
                set: { _ in }
            ),
            isEditable: isEditable,
            onDeleteExercise: { exerciseId in
                onDeleteExercise(recordBlock.workoutSessionId, exerciseId)
            },
            onSetChanged: { exerciseId, updatedSet in
                onSetChanged(recordBlock.workoutSessionId, exerciseId, updatedSet)
            }
        )
    }

    private func weeklyPlanCard(_ plan: WeeklyPlanBlock) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Current Plan")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.textMuted)
            Text("Week of \(plan.weekStartDate)")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.textPrimary)
            if let goal = plan.goalSummary, !goal.isEmpty {
                Text(goal)
                    .font(.system(size: 13))
                    .foregroundColor(.textSecondary)
            }
            ForEach(plan.days) { day in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(day.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.textPrimary)
                        Text(day.planDate)
                            .font(.system(size: 12))
                            .foregroundColor(.textMuted)
                    }
                    Spacer()
                    Text(day.status.capitalized)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.textSecondary)
                }
            }
        }
        .padding(14)
        .background(Color.appSurface)
        .cornerRadius(16)
    }

    private func todayPlanCard(_ plan: TodayPlanBlock) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Today")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.textMuted)
            Text(plan.day.title)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.textPrimary)
            if let focus = plan.day.focus, !focus.isEmpty {
                Text(focus)
                    .font(.system(size: 13))
                    .foregroundColor(.textSecondary)
            }
            ForEach(plan.day.exercises) { exercise in
                VStack(alignment: .leading, spacing: 6) {
                    Text(exercise.exerciseName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.textPrimary)
                    ForEach(exercise.sets) { set in
                        HStack {
                            Text(planSetText(set))
                                .font(.system(size: 13))
                                .foregroundColor(.textSecondary)
                            Spacer()
                            Button {
                                onCompletePlannedSet(message.id, set)
                            } label: {
                                Image(systemName: set.isCompleted ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(set.isCompleted ? .green : .textMuted)
                            }
                            .disabled(set.isCompleted)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color.appSurface)
        .cornerRadius(16)
    }

    private func planSetText(_ set: PlanSetBlock) -> String {
        if let weight = set.targetWeight {
            return "\(weight.clean) \(set.targetWeightUnit) × \(set.targetReps)"
        }
        return "Bodyweight × \(set.targetReps)"
    }
}

private extension Double {
    var clean: String {
        truncatingRemainder(dividingBy: 1) == 0 ? String(Int(self)) : String(format: "%.1f", self)
    }
}
