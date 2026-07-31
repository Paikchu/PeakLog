import SwiftUI

struct WorkoutRecordCard: View {
    @Binding var record: WorkoutRecord
    var isEditable: Bool = true
    var onSetChanged: (String, ExerciseSet) -> Void
    var onAddSet: ((String) -> Void)? = nil
    var onDeleteLastSet: ((String) -> Void)? = nil
    var onDeleteExercise: ((String) -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            ForEach($record.exercises) { $exercise in
                exerciseCard(for: $exercise)
            }
        }
        // 滑动删除动作后列表平滑收拢。
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: record.exercises.map(\.id))
        .padding(8)
        .background(Color.appSurface)
        .cornerRadius(AppRadius.xl)
        .shadow(color: Color.accentPrimary.opacity(0.1), radius: 14, x: 0, y: 4)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(Color.accentPrimary.opacity(0.14), lineWidth: 1)
        )
    }

    /// 回调里带的 id 直接取自当前元素，不再回头按下标去数组里捞：
    /// 下标是在闭包被调用时才求值的，动作被删掉后那个下标可能已经越界。
    @ViewBuilder
    private func exerciseCard(for exercise: Binding<Exercise>) -> some View {
        let exerciseId = exercise.wrappedValue.id
        let card = ExerciseCardView(
            exercise: exercise,
            isEditable: isEditable,
            onSetChanged: { updatedSet in
                onSetChanged(exerciseId, updatedSet)
            },
            onAddSet: {
                onAddSet?(exerciseId)
            },
            onDeleteLastSet: {
                onDeleteLastSet?(exerciseId)
            }
        )

        if let onDeleteExercise {
            // 由右向左滑动删除该动作的全部记录。
            SwipeToDeleteRow(onDelete: { onDeleteExercise(exerciseId) }) {
                card
            }
        } else {
            card
        }
    }
}

#Preview {
    @Previewable @State var record = WorkoutRecord(id: "wr-1", exercises: MockData.sampleExercises)
    WorkoutRecordCard(
        record: $record,
        isEditable: true,
        onSetChanged: { _, _ in }
    )
    .padding()
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}
