import SwiftUI

// MARK: - Exercise Picker
// First screen of the add-exercise flow: multi-select from the library,
// funneled by recents → muscle/equipment chips → search. Deliberately flat —
// no card containers; hierarchy comes from type scale and hairline separators.

struct ExercisePickerScreen: View {
    @EnvironmentObject private var localizationManager: LocalizationManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Exercises already turned into form cards; shown as added and not re-selectable.
    var alreadyAddedIds: Set<String> = []
    let onConfirm: ([ExerciseDefinition]) -> Void

    @State private var library: [ExerciseDefinition] = []
    @State private var recommendations: [ExerciseDefinition] = []
    @State private var summariesById: [String: RecentExerciseEntry] = [:]
    @State private var query = ""
    @State private var muscleFilter: MuscleGroup?
    @State private var equipmentFilter: Equipment?
    @State private var selection: [ExerciseDefinition] = []
    @State private var showsCreateSheet = false

    private var pickerSpring: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.3, dampingFraction: 0.85)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredExercises: [ExerciseDefinition] {
        ExerciseLibraryEngine.filter(
            library,
            query: trimmedQuery,
            muscleGroup: muscleFilter,
            equipment: equipmentFilter
        )
    }

    private var groupedExercises: [(group: MuscleGroup, exercises: [ExerciseDefinition])] {
        ExerciseLibraryEngine.groupedByMuscle(filteredExercises)
    }

    private var showsSuggestions: Bool {
        trimmedQuery.isEmpty && muscleFilter == nil && equipmentFilter == nil && !recommendations.isEmpty
    }

    /// Selection and form-card changes re-key the recommendation task.
    private var recommendationKey: String {
        (selection.map(\.id) + alreadyAddedIds.sorted()).joined(separator: "|")
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                searchField
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                muscleChips
                    .padding(.top, 12)

                if muscleFilter != nil {
                    equipmentChips
                        .padding(.top, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if showsSuggestions {
                    sectionLabel("exercise_picker.suggested_section")
                    // Prefixed row identity: the same exercise also appears in
                    // its muscle-group section below.
                    ForEach(recommendations, id: \.suggestedRowId) { definition in
                        pickerRow(for: definition, recentEntry: summariesById[definition.id])
                    }
                }

                if filteredExercises.isEmpty {
                    noResults
                } else {
                    ForEach(groupedExercises, id: \.group) { group in
                        sectionLabel(LocalizedStringKey(stringLiteral: "muscle_group.\(group.group.rawValue)"))
                        ForEach(group.exercises) { definition in
                            pickerRow(for: definition, recentEntry: nil)
                        }
                    }
                }

                createCustomRow
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 24)
            }
            .animation(pickerSpring, value: filteredExercises.map(\.id))
            .animation(pickerSpring, value: recommendations.map(\.id))
            .animation(pickerSpring, value: muscleFilter)
        }
        .background(Color.appBackground.ignoresSafeArea())
        .dismissKeyboardOnTap()
        .navigationTitle("exercise_picker.title")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { confirmBar }
        .sensoryFeedback(.selection, trigger: selection.count)
        .task { await loadLibrary() }
        .task(id: recommendationKey) { await refreshRecommendations() }
        .sheet(isPresented: $showsCreateSheet) {
            CreateCustomExerciseSheet(initialName: trimmedQuery) { name, muscleGroup, loadType in
                await createCustomExercise(name: name, muscleGroup: muscleGroup, loadType: loadType)
            }
            .presentationDetents([.height(280)])
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.textMuted)

            TextField(String(localized: "exercise_picker.search_placeholder"), text: $query)
                .font(.chatBodyMedium)
                .foregroundColor(.textPrimary)
                .autocorrectionDisabled()

            if !query.isEmpty {
                Button {
                    withAnimation(pickerSpring) { query = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .fill(Color.workoutShell)
        )
        .accessibilityIdentifier("exercisePicker.search")
    }

    // MARK: - Filter Chips

    private var muscleChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(
                    label: Text("exercise_picker.filter_all"),
                    isSelected: muscleFilter == nil
                ) {
                    muscleFilter = nil
                    equipmentFilter = nil
                }
                ForEach(MuscleGroup.allCases) { group in
                    filterChip(
                        label: Text(group.displayLabel),
                        isSelected: muscleFilter == group
                    ) {
                        muscleFilter = muscleFilter == group ? nil : group
                        equipmentFilter = nil
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var equipmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Equipment.allCases) { equipment in
                    filterChip(
                        label: Text(equipment.displayLabel),
                        isSelected: equipmentFilter == equipment,
                        compact: true
                    ) {
                        equipmentFilter = equipmentFilter == equipment ? nil : equipment
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func filterChip(
        label: Text,
        isSelected: Bool,
        compact: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(pickerSpring) { action() }
        } label: {
            label
                .font(.system(size: compact ? 11 : 12, weight: .medium))
                .foregroundColor(isSelected ? .accentValue : .textSecondary)
                .padding(.horizontal, compact ? 10 : 12)
                .padding(.vertical, compact ? 5 : 7)
                .background(
                    Capsule()
                        .fill(Color.workoutPanel)
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    isSelected ? Color.accentPrimary.opacity(0.5) : .clear,
                                    lineWidth: 1
                                )
                        )
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sections & Rows

    private func sectionLabel(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.system(size: 11, weight: .medium))
            .kerning(1.1)
            .foregroundColor(.textMuted)
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 6)
    }

    private func pickerRow(for definition: ExerciseDefinition, recentEntry: RecentExerciseEntry?) -> some View {
        let isAdded = alreadyAddedIds.contains(definition.id)
        let isSelected = selection.contains { $0.id == definition.id }

        return Button {
            guard !isAdded else { return }
            withAnimation(pickerSpring) { toggle(definition) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(definition.displayName(for: localizationManager.appLanguage))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(isAdded ? .textMuted : (isSelected ? .accentValue : .textPrimary))

                    metaLine(for: definition, recentEntry: recentEntry)
                }

                Spacer(minLength: 8)

                trailingIndicator(isAdded: isAdded, isSelected: isSelected)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.appSeparator)
                    .frame(height: 0.5)
                    .padding(.leading, 16)
            }
        }
        .buttonStyle(.plain)
        .disabled(isAdded)
        .transition(.opacity)
    }

    private func metaLine(for definition: ExerciseDefinition, recentEntry: RecentExerciseEntry?) -> some View {
        HStack(spacing: 4) {
            Text("\(definition.equipment.displayLabel) · \(definition.muscleGroup.displayLabel)")
                .font(.exerciseUnit)
                .foregroundColor(.textMuted)

            if let recentEntry, let summary = lastSummary(recentEntry) {
                Text("·")
                    .font(.exerciseUnit)
                    .foregroundColor(.textMuted)
                Text(summary)
                    .font(.exerciseUnit)
                    .foregroundColor(.accentValue)
            }
        }
    }

    @ViewBuilder
    private func trailingIndicator(isAdded: Bool, isSelected: Bool) -> some View {
        if isAdded {
            Text("exercise_picker.already_added")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.textMuted)
        } else if isSelected {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.accentPrimary)
                .transition(.scale.combined(with: .opacity))
        } else {
            Image(systemName: "circle")
                .font(.system(size: 20, weight: .regular))
                .foregroundColor(.textDarkMuted)
        }
    }

    // MARK: - Empty & Custom Creation

    private var noResults: some View {
        Text("exercise_picker.no_results")
            .font(.chatBody)
            .foregroundColor(.textMuted)
            .frame(maxWidth: .infinity)
            .padding(.top, 28)
            .padding(.bottom, 4)
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    private var createCustomRow: some View {
        Button {
            showsCreateSheet = true
        } label: {
            Label {
                if trimmedQuery.isEmpty || !filteredExercises.isEmpty {
                    Text("exercise_picker.create_custom")
                } else {
                    Text(String(format: String(localized: "exercise_picker.create_custom_named"), trimmedQuery))
                }
            } icon: {
                Image(systemName: "plus")
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.accentPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.xl)
                    .strokeBorder(
                        Color.accentPrimary.opacity(0.4),
                        style: StrokeStyle(lineWidth: 1.2, dash: [6, 4])
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("exercisePicker.createCustom")
    }

    // MARK: - Confirm Bar

    @ViewBuilder
    private var confirmBar: some View {
        if !selection.isEmpty {
            VStack(spacing: 10) {
                selectionPreview

                Button {
                    let picked = selection
                    withAnimation(pickerSpring) { selection.removeAll() }
                    onConfirm(picked)
                } label: {
                    Text(String(format: String(localized: "exercise_picker.add_count"), selection.count))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .contentTransition(.numericText())
                        .animation(pickerSpring, value: selection.count)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Capsule().fill(LinearGradient.accentGradient))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .accessibilityIdentifier("exercisePicker.confirm")
            }
            .padding(.top, 10)
            .padding(.bottom, 4)
            .background(
                Color.appBackground
                    .opacity(0.94)
                    .ignoresSafeArea(edges: .bottom)
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Horizontally scrolling chips of the current selection, so the user can
    /// see (and undo) what they've picked without scanning the list above.
    private var selectionPreview: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(selection) { definition in
                        selectionChip(definition)
                            .id(definition.id)
                    }
                }
                .padding(.horizontal, 16)
                .animation(pickerSpring, value: selection.map(\.id))
            }
            .onChange(of: selection.count) {
                guard let lastId = selection.last?.id else { return }
                withAnimation(pickerSpring) { proxy.scrollTo(lastId, anchor: .trailing) }
            }
        }
        .accessibilityIdentifier("exercisePicker.selectionPreview")
    }

    private func selectionChip(_ definition: ExerciseDefinition) -> some View {
        Button {
            withAnimation(pickerSpring) { toggle(definition) }
        } label: {
            HStack(spacing: 5) {
                Text(definition.displayName(for: localizationManager.appLanguage))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)

                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.textMuted)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(Color.workoutPanel)
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.accentPrimary.opacity(0.35), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .transition(.scale(scale: 0.8).combined(with: .opacity))
        .accessibilityHint(Text("exercise_picker.remove_selected_hint"))
    }

    // MARK: - Actions

    private func toggle(_ definition: ExerciseDefinition) {
        if let index = selection.firstIndex(where: { $0.id == definition.id }) {
            selection.remove(at: index)
        } else {
            selection.append(definition)
        }
    }

    private func loadLibrary() async {
        library = await AppServices.exerciseLibraryService.fetchLibrary()
        let entries = await AppServices.exerciseLibraryService.fetchRecentEntries(limit: 100)
        summariesById = Dictionary(
            entries.map { ($0.definition.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func refreshRecommendations() async {
        let currentLibrary = await AppServices.exerciseLibraryService.fetchLibrary()
        let addedDefinitions = alreadyAddedIds.compactMap { id in
            currentLibrary.first { $0.id == id }
        }
        let result = await AppServices.exerciseLibraryService.fetchRecommendations(
            todaysSelections: selection + addedDefinitions,
            limit: 8
        )
        withAnimation(pickerSpring) { recommendations = result }
    }

    private func createCustomExercise(
        name: String,
        muscleGroup: MuscleGroup,
        loadType: ExerciseLoadType
    ) async {
        guard let definition = try? await AppServices.exerciseLibraryService.addCustomExercise(
            name: name,
            muscleGroup: muscleGroup,
            loadType: loadType
        ) else { return }

        library = await AppServices.exerciseLibraryService.fetchLibrary()
        withAnimation(pickerSpring) {
            query = ""
            if !selection.contains(where: { $0.id == definition.id }),
               !alreadyAddedIds.contains(definition.id) {
                selection.append(definition)
            }
        }
    }

    private func lastSummary(_ entry: RecentExerciseEntry) -> String? {
        guard let reps = entry.lastReps else { return nil }
        // Legacy bodyweight sets stored weight 0 instead of nil, so only a
        // positive weight counts as an explicitly logged weight.
        let weight = (entry.lastWeight ?? 0) > 0 ? entry.lastWeight : nil
        let loadText = LoadDisplayFormat.plainText(
            weight: weight,
            unit: entry.lastWeightUnit,
            isBodyweight: entry.definition.loadType == .bodyweight
        )
        return String(format: String(localized: "exercise_picker.last_summary"), loadText, reps)
    }
}

// MARK: - Custom Exercise Creation Sheet
// Compact 280pt sheet, same grammar as ValueEditSheet: three fields only.

struct CreateCustomExerciseSheet: View {
    @Environment(\.dismiss) private var dismiss

    let initialName: String
    let onCreate: (String, MuscleGroup, ExerciseLoadType) async -> Void

    @State private var name: String
    @State private var muscleGroup: MuscleGroup = .chest
    @State private var isBodyweight = false

    init(initialName: String, onCreate: @escaping (String, MuscleGroup, ExerciseLoadType) async -> Void) {
        self.initialName = initialName
        self.onCreate = onCreate
        _name = State(initialValue: initialName)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 14) {
            Text("exercise_picker.create_custom")
                .font(.headerTitle)
                .foregroundColor(.textPrimary)
                .padding(.top, 20)

            TextField(String(localized: "exercise_picker.custom_name_placeholder"), text: $name)
                .font(.chatBodyMedium)
                .foregroundColor(.textPrimary)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.xl)
                        .fill(Color.workoutPanel)
                )
                .padding(.horizontal, 24)

            HStack(spacing: 12) {
                Menu {
                    ForEach(MuscleGroup.allCases) { group in
                        Button(group.displayLabel) { muscleGroup = group }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("exercise_picker.custom_muscle")
                            .foregroundColor(.textSecondary)
                        Text(muscleGroup.displayLabel)
                            .foregroundColor(.accentValue)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.textMuted)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(Capsule().fill(Color.workoutPanel))
                }

                Button {
                    isBodyweight.toggle()
                } label: {
                    Text(isBodyweight ? "daily_record.load.bodyweight" : "daily_record.load.weighted")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isBodyweight ? .accentValue : .textSecondary)
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .background(Capsule().fill(Color.workoutPanel))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 16) {
                Button(String(localized: "common.cancel")) { dismiss() }
                    .foregroundColor(.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.appSurface)
                    .cornerRadius(AppRadius.lg)

                Button(String(localized: "common.done")) {
                    let finalName = trimmedName
                    let group = muscleGroup
                    let loadType: ExerciseLoadType = isBodyweight ? .bodyweight : .weighted
                    Task {
                        await onCreate(finalName, group, loadType)
                        dismiss()
                    }
                }
                .foregroundColor(trimmedName.isEmpty ? .textMuted : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    Group {
                        if trimmedName.isEmpty {
                            Color.appSurface
                        } else {
                            LinearGradient.accentGradient
                        }
                    }
                )
                .cornerRadius(AppRadius.lg)
                .disabled(trimmedName.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.appCard)
        .dismissKeyboardOnTap()
    }
}

private extension ExerciseDefinition {
    var suggestedRowId: String { "suggested-\(id)" }
}

#Preview {
    NavigationStack {
        ExercisePickerScreen { _ in }
    }
    .environmentObject(LocalizationManager())
}
