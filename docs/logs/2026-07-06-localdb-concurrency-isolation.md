# LocalAppDatabase Swift 6 Isolation Cleanup

- Worktree: `/Users/max/.config/superpowers/worktrees/PeakLog/localdb-concurrency`
- Branch: `codex/localdb-concurrency`
- Scope: remove Swift 6 MainActor isolation warnings from local database state, Live Activity shared value models, and workout date formatting.

## Changes

- Marked local persistence value models as `nonisolated` and `Sendable` so `LocalAppDatabase` can encode, decode, seed, and preview state inside its actor context.
- Marked Live Activity snapshot attributes, content state, and shared store as nonisolated shared code for app and widget targets.
- Changed `CompletePlanSetIntent` static metadata from mutable `var` to immutable `let`.
- Reworked `WorkoutDateFormatter` to avoid storing `DateFormatter`, keeping the helper sendable and nonisolated while preserving date formatting behavior.

## Validation

- `build_sim` on iOS 26.5 iPhone 17 Pro Max with `SWIFT_STRICT_CONCURRENCY=complete`: succeeded.
- `test_sim` on iOS 26.5 iPhone 17 Pro Max with `SWIFT_STRICT_CONCURRENCY=complete`: 18 passed, 0 failed.
- Confirmed the previous `LocalAppState`, `PlanLiveActivityAttributes`, `PlanLiveActivitySharedStore`, and `WorkoutDateFormatter` MainActor isolation diagnostics are gone.

## Remaining Warnings

- Existing Swift 6 warnings remain outside this scope: service protocol existential sendability, `LiveActivityManager` Activity handoff, theme default values, keyboard dismiss closure isolation, and some test helper isolation warnings.
