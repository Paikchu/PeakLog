# History Empty State and Header Consistency Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development and superpowers:verification-before-completion to implement this plan task-by-task.

**Goal:** Remove the duplicate history date affordance, provide a useful zero-record state, and align the three root-screen hero headers.

**Architecture:** Add a reusable root-page hero header that owns the 30-point title geometry and optional trailing action. Keep date selection in `HistoryScreen`, reuse `DailyRecordSheet` for manual entry, and put persistence plus refresh in `HistoryViewModel` so the empty state never writes data directly.

**Tech Stack:** SwiftUI, Swift Concurrency, XCTest, Swift localization catalogs, Xcode iOS Simulator.

---

## Guardrails

- Preserve the current uncommitted changes in history, localization, completed-record, and dock files.
- Do not alter calendar aggregation, cross-month selection, or week-refresh behavior.
- Do not create commits until the user explicitly approves a commit after acceptance.
- Use prompt-driven agent behavior only where AI is involved; this UI change adds no rules engine or expression matching.

### Task 1: Lock the header and empty-state contracts with failing tests

**Files:**
- Create: `tests/root_page_header_layout_test.swift`
- Create: `PeakLogTests/HistoryEmptyStateTests.swift`
- Modify: `PeakLogTests/PeakLogSmokeTests.swift`

**Steps:**

- Add a source-layout regression test that reads `HistoryScreen.swift`, `TodayWorkoutScreen.swift`, and `ProfileScreen.swift` and requires all three to use `RootPageHeader`.
- Assert `HistoryScreen` does not contain `chevron.down` and does contain a dedicated calendar button with `history.calendar.open` accessibility text.
- Add unit coverage for an extracted `HistoryEmptyStateContent.resolve(selectedDate:today:locale:)` value:

```swift
let today = formatter.date(from: "2026-07-10")!
XCTAssertEqual(
    HistoryEmptyStateContent.resolve(selectedDate: today, today: today, locale: zh).title,
    "今天还没有记录"
)

let past = formatter.date(from: "2026-07-08")!
XCTAssertFalse(
    HistoryEmptyStateContent.resolve(selectedDate: past, today: today, locale: zh).title.contains("今天")
)
```

- Add smoke assertions for the empty-state CTA accessibility identifier `history.empty.addRecord`.
- Run the new tests before implementation and confirm failures reference missing `RootPageHeader` and `HistoryEmptyStateContent`.
- Do not modify production code in this task.

### Task 2: Introduce one root-page hero header

**Files:**
- Create: `PeakLog/Views/Shared/RootPageHeader.swift`
- Modify: `PeakLog/Theme/AppTheme.swift:116-144`
- Modify: `PeakLog.xcodeproj/project.pbxproj`

**Steps:**

- Add shared title geometry tokens rather than repeating numeric values:

```swift
enum RootPageHeaderMetrics {
    static let horizontalPadding: CGFloat = 20
    static let topPadding: CGFloat = 12
    static let bottomPadding: CGFloat = 8
    static let trailingControlSize: CGFloat = 44
}

extension Font {
    static let rootPageTitle = Font.system(size: 30, weight: .bold)
    static let rootPageEyebrow = Font.system(size: 12, weight: .semibold)
}
```

- Implement `RootPageHeader` with leading eyebrow, title, optional subtitle, and an optional 44×44 trailing control slot.
- Keep title leading alignment and vertical geometry identical whether the trailing slot is empty or populated.
- Add accessibility grouping without merging the calendar action into the title element.
- Add the file to the PeakLog app target if the Xcode project does not use synchronized groups.
- Run `root_page_header_layout_test` and confirm the component contract passes while screen-usage assertions still fail.

### Task 3: Make the calendar icon the only date-selection entry

**Files:**
- Modify: `PeakLog/Views/History/HistoryScreen.swift:31-85`
- Modify: `PeakLog/Localizable.xcstrings`
- Test: `tests/root_page_header_layout_test.swift`

**Steps:**

- Replace the whole-row `Button` with `RootPageHeader`.
- Render `selectedDateLabel` as the header title with `muscleFocusLine` as the optional subtitle.
- Remove `chevron.down` and make the right calendar icon its own `Button`.
- Use a 44×44 hit target, circular surface, `history.calendar.open` accessibility label, and `history.calendar.button` identifier.
- Keep `showsCalendarPopup`, `CalendarPopupSheet`, and date-refresh behavior unchanged.
- Run the source-layout regression test and existing cross-month calendar test.
- Expected: date text has no button action; calendar button opens the existing sheet; calendar refresh tests pass.

### Task 4: Add date-aware empty-state content

**Files:**
- Create: `PeakLog/Support/HistoryEmptyStateContent.swift`
- Modify: `PeakLog/Views/History/HistoryScreen.swift:87-105`
- Modify: `PeakLog/Localizable.xcstrings`
- Modify: `PeakLog.xcodeproj/project.pbxproj`
- Test: `PeakLogTests/HistoryEmptyStateTests.swift`

**Steps:**

- Add a pure content resolver that compares calendar days, not timestamps.
- Return today-specific and selected-date-specific localized title and subtitle keys.
- Add localized strings for Chinese and English:

```text
history.empty.today.title = 今天还没有记录 / No workout logged today
history.empty.date.title = 这天还没有记录 / No workout logged for this day
history.empty.subtitle = 记录力量或有氧训练，完成后会显示在这里 / Log strength or cardio and it will appear here
history.empty.add_record = 添加训练记录 / Add workout
```

- Replace the single `Text("history.empty")` with a leading-aligned empty-state block using the resolver.
- Show the selected-date eyebrow, 30-point title, supporting text, and CTA; do not render statistics or placeholder cards.
- Render an explicit localized error state when `viewModel.errorMessage` exists instead of showing the empty state after a failed load.
- Run `HistoryEmptyStateTests` in Chinese and English and confirm today/past-date semantics pass.

### Task 5: Reuse manual record persistence from history

**Files:**
- Modify: `PeakLog/ViewModels/HistoryViewModel.swift:1-220`
- Modify: `PeakLog/Views/History/HistoryScreen.swift:3-29`
- Modify: `PeakLog/Views/Today/DailyRecordSheet.swift:24-45`
- Modify: `tests/history_calendar_cross_month_selection_test.swift`

**Steps:**

- Extend `DailyRecordSheet` with an `initialDate` input; seed strength and cardio drafts with that date rather than hard-coding `Date()`.
- Add `HistoryViewModel.addDailyRecord(_:) async` using the injected `WorkoutServiceProtocol`:

```swift
switch draft {
case .strength(let strength):
    _ = try await workoutService.createStrengthSession(strength)
case .cardio(let minutes, let distance):
    _ = try await workoutService.createRunningRecord(
        workoutDate: selectedDate,
        durationMinutes: minutes,
        distanceKm: distance,
        source: .manual
    )
}
await loadSessionsForSelectedDate()
await loadCalendar()
```

- Present `DailyRecordSheet(initialDate: viewModel.selectedDate)` from the empty-state CTA.
- Dismiss only after the save finishes; surface persistence errors through `errorMessage`.
- Add fake-service tests for strength and cardio drafts, selected-date propagation, record refresh, and calendar marker refresh.
- Run `history_calendar_cross_month_selection_test`; expected output: `history_calendar_cross_month_selection_test passed`.

### Task 6: Apply the shared header to plan and settings

**Files:**
- Modify: `PeakLog/Views/Today/TodayWorkoutScreen.swift:514-680`
- Modify: `PeakLog/Views/Profile/ProfileScreen.swift:18-115`
- Test: `tests/root_page_header_layout_test.swift`
- Test: `PeakLogTests/TodayPlanHeaderTests.swift`

**Steps:**

- Make `TodaySummarySection` delegate its eyebrow, resolved plan title, subtitle, and completion chip slot to `RootPageHeader`.
- Preserve plan progress and running summary below the shared header; do not change training-focus layout.
- Replace the centered 17-point profile header with a leading `RootPageHeader(title: String(localized: "profile.title"))`.
- Remove redundant page-specific top padding so all three headers use only shared metrics.
- Run header layout, TodayPlanHeader, and smoke tests.
- Expected: calendar, plan, and settings titles share 30-point bold type, leading edge, top inset, and title baseline.

### Task 7: Verify behavior, visuals, and documentation

**Files:**
- Create: `docs/logs/2026-07-10-history-empty-state-and-header-consistency.md`
- Modify only if defects are found: files listed above

**Steps:**

- Run `git diff --check`; expected: no whitespace errors.
- Run the focused Swift test runners, including calendar cross-month selection and root-page layout checks.
- Run the PeakLog XCTest suite on `platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5`.
- Build the `PeakLog` scheme for the same simulator with code signing disabled; expected: `BUILD SUCCEEDED`.
- Launch on iPhone 17 Pro Max and verify calendar-button-only interaction, today empty state, past-date empty state, saved-record refresh, and existing-record display.
- Capture calendar, plan, and settings screens in light/dark and Chinese/English; compare title leading edge, top offset, font size, and baseline.
- Confirm VoiceOver labels for the calendar button and add-record CTA.
- Record changed files, test commands, simulator evidence, and known limitations in `docs/logs/2026-07-10-history-empty-state-and-header-consistency.md`.
- Ask the user whether to create a commit only after acceptance passes.
