# Home Dock Fixed Rail Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development and superpowers:verification-before-completion to implement this plan task-by-task.

**Goal:** Replace the shifting SwiftUI home dock with a fixed three-column rail whose plan slot can morph into “开始训练” without moving neighboring controls.

**Architecture:** Keep `HomeTab` and `DockPlanAction` as the public behavior contract. Rebuild `HomeDockBar` around three equal-width slots, with each slot owning a stable 44pt+ hit target and a fixed center. Render selection and CTA content inside the existing slot geometry; use one animation transaction for slot content, selection background, and root-screen transitions. Keep training focus behavior and action closures unchanged.

**Tech Stack:** SwiftUI, iOS 26 glass APIs with material fallback, XCTest/source-layout regression checks, Xcode Simulator iOS 26.5.

---

## Guardrails

- Preserve unrelated uncommitted history, localization, and model changes in the worktree.
- Do not alter `HomeTab`, `DockPlanAction`, `TodayWorkoutViewModel`, or training persistence.
- Do not add a fourth navigation item or a separate floating CTA.
- Keep existing color tokens and SF Symbols; add only shared geometry/animation tokens if needed.
- No commit until simulator validation is complete and the user is asked.

### Task 1: Add a failing fixed-rail contract test

**Files:**
- Create: `tests/home_dock_fixed_rail_test.swift`
- Inspect: `PeakLog/Views/Home/HomeDockBar.swift`

**Steps:**

- Write a source-layout regression test that reads `HomeDockBar.swift` and asserts the dock declares three fixed slots, uses a fixed-width slot container, and does not use an `HStack` branch that replaces a slot with an unconstrained-width CTA.
- Assert the source keeps accessibility identifiers for `homeDockBar`, all three tabs, and `today.startPlan`.
- Assert `ContentView.swift` still renders `HomeDockBar` when training focus is not visible.
- Run the test before changing production code and confirm it fails against the current width-driven implementation.

### Task 2: Define shared dock geometry and motion tokens

**Files:**
- Modify: `PeakLog/Theme/AppTheme.swift`
- Test: `tests/home_dock_fixed_rail_test.swift`

**Steps:**

- Add a small `HomeDockMetrics` namespace for outer horizontal padding, slot width, slot height, inner spacing, and minimum hit target.
- Add a single `HomeDockMotion` namespace or reuse `HomeDockBar.dockSpring` for slot transitions, page fade, and focus-bar transitions.
- Keep values centralized so light/dark, localized labels, and iOS 26/fallback rendering share identical geometry.
- Run the source contract test; geometry-token assertions should pass while the implementation assertions remain red.

### Task 3: Rebuild `HomeDockBar` as a fixed three-slot rail

**Files:**
- Modify: `PeakLog/Views/Home/HomeDockBar.swift`
- Test: `tests/home_dock_fixed_rail_test.swift`

**Steps:**

- Replace the content `HStack` branches with three explicit fixed-width slots generated from `HomeTab.allCases`.
- Give each slot the same width and height, center alignment, and a minimum 44pt content hit target.
- Render the selected tab icon/title inside its slot without using intrinsic width to size the slot.
- Keep the selection capsule inside the slot; animate its position or opacity, never the outer rail width.
- Render the plan action inside the middle slot only when `selectedTab == .plan && planAction != nil`; preserve the current action closure, enabled state, title, and `today.startPlan` identifier.
- Keep the outer glass capsule and iOS 26 fallback branches; apply the same fixed content frame to both branches.
- Remove `matchedGeometryEffect` usage that couples the CTA width to the tab's intrinsic width unless it can be constrained to the middle slot.
- Run the source test and a local Swift/Xcode compile check; expected result is a passing fixed-slot contract.

### Task 4: Add stable page transitions and Reduce Motion behavior

**Files:**
- Modify: `PeakLog/ContentView.swift`
- Modify: `PeakLog/Views/Home/HomeDockBar.swift`
- Test: `tests/home_dock_fixed_rail_test.swift`

**Steps:**

- Read `accessibilityReduceMotion` in `ContentView` or the dock and select an opacity-only transition when enabled.
- For normal motion, use a short asymmetric page transition with a small directional offset derived from tab order; keep the dock anchored in the safe-area inset.
- Ensure the dock-to-`TrainingFocusBar` transition uses the existing spring and does not animate both a height change and a second page transition for the same state.
- Run the source contract test and verify no page switch changes the safe-area inset geometry unexpectedly.

### Task 5: Add preview and accessibility state coverage

**Files:**
- Modify: `PeakLog/Views/Home/HomeDockBar.swift`
- Create or modify: `PeakLogTests/HomeDockAccessibilityTests.swift` if the target already includes SwiftUI test infrastructure

**Steps:**

- Add previews for calendar-selected, plan-selected without an action, plan-selected with “开始训练”, and settings-selected states.
- Verify every state has three stable identifiers and that the CTA remains keyboard/VoiceOver discoverable as the middle plan action.
- Add source or view-model-level assertions only if the project test target supports them without introducing a new UI test framework.

### Task 6: Verify, document, and hand off

**Files:**
- Create: `docs/logs/2026-07-10-home-dock-fixed-rail.md`

**Steps:**

- Run `git diff --check` and the focused dock tests.
- Build the `PeakLog` scheme for `iPhone 17 Pro Max` on iOS 26.5 using the project’s existing simulator workflow.
- Inspect normal, plan-ready, resume-training, dark-mode, English, and Reduce Motion states.
- Record implementation, validation results, and any known visual limitations in the log document.
- Ask the user whether to create a commit; do not commit automatically.
