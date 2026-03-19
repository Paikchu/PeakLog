import SwiftUI

struct WorkoutRecordCard: View {
    let messageId: String
    @Binding var record: WorkoutRecord
    var onDeleteExercise: (String) -> Void
    var onSetChanged: (String, ExerciseSet) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header bar with gradient
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 20, height: 20)
                    Image(systemName: "dumbbell.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                }

                Text("chat.workout_record.title")
                    .font(.recordHeader)
                    .foregroundColor(.white)
                    .tracking(0.25)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(LinearGradient.accentGradient)
            .cornerRadius(AppRadius.xl, corners: [.topLeft, .topRight])

            // Exercise list
            VStack(spacing: 8) {
                ForEach(Array(record.exercises.enumerated()), id: \.element.id) { index, _ in
                    ExerciseCardView(
                        exercise: $record.exercises[index],
                        messageId: messageId,
                        onDeleteExercise: {
                            onDeleteExercise(record.exercises[index].id)
                        },
                        onSetChanged: { updatedSet in
                            onSetChanged(record.exercises[index].id, updatedSet)
                        }
                    )
                }
            }
            .padding(8)
            .background(Color.appSurface)
            .cornerRadius(AppRadius.xl, corners: [.bottomLeft, .bottomRight])
        }
        .shadow(color: Color.accentPurple.opacity(0.15), radius: 12, x: 0, y: 2)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(Color.accentPurple.opacity(0.12), lineWidth: 1)
        )
    }
}

#Preview {
    @Previewable @State var record = WorkoutRecord(id: "wr-1", exercises: MockData.sampleExercises)
    WorkoutRecordCard(
        messageId: "m-1",
        record: $record,
        onDeleteExercise: { _ in },
        onSetChanged: { _, _ in }
    )
    .padding()
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}
