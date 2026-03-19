import SwiftUI

struct MessageBubbleView: View {
    @Binding var message: ChatMessage
    var onDeleteExercise: (String, String) -> Void    // (recordId, exerciseId)
    var onSetChanged: (String, String, ExerciseSet) -> Void // (recordId, exerciseId, set)

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
        VStack(alignment: .leading, spacing: 8) {
            if let blocks = message.contentBlocks, !blocks.isEmpty {
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
                        // Build a WorkoutRecord from content_blocks for the card
                        let exercises = recordBlock.exercises.map { ex in
                            Exercise(
                                id: ex.exerciseId,
                                name: ex.name,
                                sets: ex.sets.map { s in
                                    ExerciseSet(
                                        id: s.setId,
                                        setIndex: s.setIndex,
                                        weight: s.weight ?? 0,
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
                        WorkoutRecordCard(
                            messageId: message.id,
                            record: Binding(
                                get: { record },
                                set: { _ in }  // edits go through viewModel callbacks
                            ),
                            onDeleteExercise: { exerciseId in
                                onDeleteExercise(recordBlock.workoutSessionId, exerciseId)
                            },
                            onSetChanged: { exerciseId, updatedSet in
                                onSetChanged(recordBlock.workoutSessionId, exerciseId, updatedSet)
                            }
                        )

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
}
