# Native Tab Bar Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace PeakLog's custom bottom dock with a text-labeled native SwiftUI Tab Bar that follows the iPhone bottom safe area.

**Architecture:** `ContentView` owns `selectedTab` and renders three stable `Tab` values inside `TabView(selection:)`. The system owns the iOS 26 Liquid Glass surface and safe-area placement. iOS 26.1+ dynamically enables `tabViewBottomAccessory`; iOS 26.0 falls back to a tab-content safe-area inset. Focus mode disables the accessory, hides the system tab bar, and substitutes a solid-action `TrainingFocusBar`.

**Tech Stack:** SwiftUI, iOS 26, source-contract Swift regression tests, Xcode build tooling.

---

### Task 1: Lock the native navigation contract

**Files:**
- Modify: `tests/home_dock_navigation_test.swift`
- Modify: `tests/home_dock_fixed_rail_test.swift`
- Modify: `tests/today_workout_screen_overlay_layout_test.swift`

**Steps:**

- Replace custom-dock assertions with requirements for `TabView(selection:)`, three native `Tab` declarations, localized labels, and `.tabBar` visibility control.
- Assert that `ContentView` no longer renders `HomeDockBar` or adds the old bottom padding.
- Run each Swift test and confirm it fails because the production shell still uses the custom dock.

### Task 2: Replace the custom dock with native TabView

**Files:**
- Modify: `PeakLog/ContentView.swift`
- Create: `PeakLog/Views/Home/HomeTab.swift`
- Delete: `PeakLog/Views/Home/HomeDockBar.swift`
- Modify: `PeakLog/Theme/AppTheme.swift`

**Steps:**

- Move `HomeTab` identity, localized title, and SF Symbol mapping into `HomeTab.swift`.
- Replace the manual root-screen switch with three native `Tab` values in `TabView(selection:)`.
- Hide the system Tab Bar only while training focus is active.
- Keep `TrainingActionLayer` above the native bar and `TrainingFocusBar` in the bottom inset while focus mode is active.
- Use solid capsules for complete-set and finish actions so no Liquid Glass rim appears below the primary CTA.
- Remove custom dock geometry tokens that no longer have consumers, preserving the horizontal action-layer inset as a narrowly named token.

### Task 3: Verify behavior and document delivery

**Files:**
- Create: `docs/logs/2026-07-15-native-tab-bar.md`
- Modify: `docs/testing/regression-matrix.md`

**Steps:**

- Run the three focused Swift regression tests and confirm they pass.
- Run an iOS Simulator build for the project and confirm zero compiler errors.
- Inspect the final diff for custom dock remnants, unintended business changes, and whitespace errors.
- Record exact verification evidence and residual manual visual checks.
- Do not commit or open a PR until the user authorizes that delivery step.
