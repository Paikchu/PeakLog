# Today Workout Invalidation Slices Plan

- Create small value snapshots inside `TodayWorkoutScreen` for summary, plan, records, and focus state.
- Extract `TodaySummarySection`, `TodayPlanExercisesSection`, `TodayRecordsSection`, and focus header/banner views.
- Pass callbacks for mutations instead of passing `TodayWorkoutViewModel` into subviews.
- Keep bindings only where editing needs local writeback, especially `WorkoutRecordCard`.
- Validate with focused Today workout tests and an iOS 26.5 simulator build.
