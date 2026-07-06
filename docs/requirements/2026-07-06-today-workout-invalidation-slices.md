# Today Workout Invalidation Slices

- `TodayWorkoutScreen` currently reads broad `TodayWorkoutViewModel` state through large computed views.
- Goal: split header, plan list, record list, and focus session UI into narrower value-driven subviews.
- Keep the existing `TodayWorkoutViewModel` as the behavior owner.
- Do not change training plan editing, daily record creation, focus mode, Live Activity sync, or error handling.
- Preserve iOS 26.5 simulator build compatibility.
- Acceptance: Today screen builds, focus flow tests still pass, and section views no longer receive the full view model.
