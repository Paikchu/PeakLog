# Today Workout Invalidation Slices

- Split `TodayWorkoutScreen` into value-driven header, summary, plan list, record list, and focus-session subviews.
- Kept `TodayWorkoutViewModel` as the behavior owner; subviews receive snapshots, bindings, and callbacks instead of the full observable object.
- Reduced direct view model reads inside large UI builders, so unrelated `@Published` changes have less section-level fan-out.
- Preserved focus-session scroll behavior, Live Activity completion sync, plan editing, daily records, and running records.
- Validation: Today workout focus/live-session/date tests passed on iOS 26.5 iPhone 17 Pro Max Simulator.
