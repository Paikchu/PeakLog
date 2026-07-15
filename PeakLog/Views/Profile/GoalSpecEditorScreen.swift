import SwiftUI

// MARK: - Goal Spec Editor
// Structured training-goal form (ADR-001 Phase 1). Deliberately a flat set of
// pickers, not a wizard — saving never rebuilds the current plan (G4), so
// there's no multi-step "generate" flow to walk through here.

struct GoalSpecEditorScreen: View {
    @Environment(\.dismiss) private var dismiss

    @State private var spec: GoalSpec
    @State private var isSaving = false
    @State private var saveError: String?

    let onSave: (GoalSpec) async throws -> Void

    init(initial: GoalSpec?, legacyGoalSummary: String?, onSave: @escaping (GoalSpec) async throws -> Void) {
        var seed = initial ?? .default
        // G1: a first-ever open with no structured goal yet inherits the old
        // free-text summary as a starting note, rather than discarding it.
        if initial == nil, let legacyGoalSummary {
            let trimmed = legacyGoalSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { seed.note = trimmed }
        }
        _spec = State(initialValue: seed)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    objectiveSection
                    scheduleSection
                    equipmentSection
                    focusAreasSection
                    experienceSection
                    noteSection
                }
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .background(Color.appBackground.ignoresSafeArea())
            .dismissKeyboardOnTap()
            .navigationTitle("goal_spec.title")
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .bottom) {
                if let saveError {
                    Text(saveError)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                        .foregroundColor(.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("goal_spec.save", action: save)
                        .fontWeight(.semibold)
                        .foregroundColor(spec.isValid ? .accentPrimary : .textMuted)
                        .disabled(!spec.isValid || isSaving)
                }
            }
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        saveError = nil
        Task {
            do {
                try await onSave(spec)
                isSaving = false
                dismiss()
            } catch {
                isSaving = false
                saveError = error.localizedDescription
            }
        }
    }

    // MARK: - Sections

    private var objectiveSection: some View {
        SettingsSection(title: "goal_spec.section.objective") {
            chipRow(GoalObjective.allCases) { objective in
                chip(label: Text(objective.displayLabel), isSelected: spec.objective == objective) {
                    spec.objective = objective
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var scheduleSection: some View {
        SettingsSection(title: "goal_spec.section.schedule") {
            stepperRow(
                title: "goal_spec.days_per_week",
                value: "\(spec.daysPerWeek)",
                onDecrement: { spec.daysPerWeek = max(1, spec.daysPerWeek - 1) },
                onIncrement: { spec.daysPerWeek = min(7, spec.daysPerWeek + 1) }
            )
            Divider().background(Color.appSeparator).padding(.horizontal, 16)
            stepperRow(
                title: "goal_spec.session_minutes",
                value: "\(spec.sessionMinutes)",
                onDecrement: { spec.sessionMinutes = max(15, spec.sessionMinutes - 15) },
                onIncrement: { spec.sessionMinutes = min(240, spec.sessionMinutes + 15) }
            )
        }
        .padding(.horizontal, 16)
    }

    private var equipmentSection: some View {
        SettingsSection(title: "goal_spec.section.equipment") {
            chipRow(Equipment.allCases) { equipment in
                chip(label: Text(equipment.displayLabel), isSelected: spec.equipment.contains(equipment)) {
                    toggle(equipment, in: &spec.equipment)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var focusAreasSection: some View {
        SettingsSection(title: "goal_spec.section.focus_areas") {
            chipRow(MuscleGroup.allCases) { group in
                chip(label: Text(group.displayLabel), isSelected: spec.focusAreas.contains(group)) {
                    toggle(group, in: &spec.focusAreas)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var experienceSection: some View {
        SettingsSection(title: "goal_spec.section.experience") {
            chipRow(ExperienceLevel.allCases) { level in
                chip(label: Text(level.displayLabel), isSelected: spec.experience == level) {
                    spec.experience = level
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var noteSection: some View {
        SettingsSection(title: "goal_spec.section.note") {
            TextEditor(text: Binding(
                get: { spec.note ?? "" },
                set: { spec.note = $0.isEmpty ? nil : $0 }
            ))
            .frame(minHeight: 90)
            .scrollContentBackground(.hidden)
            .appFont(size: 14)
            .foregroundColor(.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Building blocks

    private func toggle<T: Hashable>(_ value: T, in collection: inout [T]) {
        if let index = collection.firstIndex(of: value) {
            collection.remove(at: index)
        } else {
            collection.append(value)
        }
    }

    private func stepperRow(title: LocalizedStringKey, value: String, onDecrement: @escaping () -> Void, onIncrement: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .appFont(.settingTitle)
                .foregroundColor(.textPrimary)
            Spacer()
            Button(action: onDecrement) {
                Image(systemName: "minus.circle")
            }
            Text(value)
                .appFont(size: 15, weight: .semibold)
                .foregroundColor(.textPrimary)
                .frame(minWidth: 28)
            Button(action: onIncrement) {
                Image(systemName: "plus.circle")
            }
        }
        .foregroundColor(.accentPrimary)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func chipRow<T: Identifiable>(_ items: [T], @ViewBuilder content: @escaping (T) -> some View) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    content(item)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func chip(label: Text, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label
                .appFont(size: 12, weight: .medium)
                .foregroundColor(isSelected ? .accentValue : .textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(Color.workoutPanel)
                        .overlay(
                            Capsule().strokeBorder(isSelected ? Color.accentPrimary.opacity(0.5) : .clear, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
    }
}
