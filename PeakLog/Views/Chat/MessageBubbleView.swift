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
            // Text portion
            if !message.text.isEmpty {
                Text(message.text)
                    .font(.chatBody)
                    .foregroundColor(.textSecondary)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 2)
            }

            // Workout record card (if present)
            if var record = message.workoutRecord {
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

            // Processing indicator
            if message.parseStatus == .processing {
                HStack(spacing: 6) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.7)
                    Text("Analyzing your workout…")
                        .font(.dateLabel)
                        .foregroundColor(.textMuted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
