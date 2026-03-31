import SwiftUI

struct WorkoutRecordCard: View {
    let messageId: String
    @Binding var record: WorkoutRecord
    var isEditable: Bool = true
    var onDeleteExercise: (String) -> Void
    var onSetChanged: (String, ExerciseSet) -> Void
    var onAddSet: ((String) -> Void)? = nil
    var onDeleteLastSet: ((String) -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(record.exercises.enumerated()), id: \.element.id) { index, _ in
                ExerciseCardView(
                    exercise: $record.exercises[index],
                    messageId: messageId,
                    isEditable: isEditable,
                    onDeleteExercise: {
                        onDeleteExercise(record.exercises[index].id)
                    },
                    onSetChanged: { updatedSet in
                        onSetChanged(record.exercises[index].id, updatedSet)
                    },
                    onAddSet: {
                        onAddSet?(record.exercises[index].id)
                    },
                    onDeleteLastSet: {
                        onDeleteLastSet?(record.exercises[index].id)
                    }
                )
            }
        }
        .padding(8)
        .background(Color.appSurface)
        .cornerRadius(AppRadius.xl)
        .shadow(color: Color.accentPurple.opacity(0.1), radius: 14, x: 0, y: 4)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(Color.accentPurple.opacity(0.14), lineWidth: 1)
        )
    }
}

#Preview {
    @Previewable @State var record = WorkoutRecord(id: "wr-1", exercises: MockData.sampleExercises)
    WorkoutRecordCard(
        messageId: "m-1",
        record: $record,
        isEditable: true,
        onDeleteExercise: { _ in },
        onSetChanged: { _, _ in }
    )
    .padding()
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}
