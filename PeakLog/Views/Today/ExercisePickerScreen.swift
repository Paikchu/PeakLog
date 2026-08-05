import SwiftUI

// MARK: - Exercise Picker
// First screen of the add-exercise flow: multi-select from the library,
// funneled by recents → muscle/equipment chips → search. Deliberately flat —
// no card containers; hierarchy comes from type scale and hairline separators.

struct ExercisePickerScreen: View {
    @EnvironmentObject private var localizationManager: LocalizationManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale

    /// Items already turned into form cards; shown as added and not re-selectable.
    var alreadyAddedItemIDs: Set<String> = []
    let onConfirm: ([ExercisePickerItem]) -> Void
    var supportsCardio = false

    private enum ExercisePickerCategory: Hashable {
        case all
        case muscle(MuscleGroup)
        case cardio
    }

    private static let suggestionLimit = 8

    @State private var library: [ExerciseDefinition] = []
    @State private var recommendations: [ExerciseDefinition] = []
    /// Which picking pass `recommendations` was ranked for; see `pickingPassKey`.
    @State private var rankedPassKey: String?
    @State private var summariesById: [String: RecentExerciseEntry] = [:]
    @State private var query = ""
    @State private var equipmentFilter: Equipment?
    @State private var selection: [ExercisePickerItem] = []
    @State private var showsCreateSheet = false
    @State private var category: ExercisePickerCategory = .all
    @State private var detailDefinition: ExerciseDefinition?

    private var pickerSpring: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.3, dampingFraction: 0.85)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredExercises: [ExerciseDefinition] {
        guard category != .cardio else { return [] }
        return ExerciseLibraryEngine.filter(
            library,
            query: trimmedQuery,
            muscleGroup: selectedMuscleGroup,
            equipment: equipmentFilter
        )
    }

    private var selectedMuscleGroup: MuscleGroup? {
        guard case .muscle(let group) = category else { return nil }
        return group
    }

    private var filteredCardio: [CardioActivityType] {
        guard supportsCardio, (category == .all || category == .cardio) else { return [] }
        return CardioActivityType.allCases.filter { matchesCardio($0, query: trimmedQuery) }
    }

    private var groupedExercises: [(group: MuscleGroup, exercises: [ExerciseDefinition])] {
        ExerciseLibraryEngine.groupedByMuscle(filteredExercises)
    }

    private var showsSuggestions: Bool {
        category == .all && trimmedQuery.isEmpty && equipmentFilter == nil && !recommendations.isEmpty
    }

    /// One "picking pass" is everything between two trips to the form: the
    /// suggested section is ranked once per pass and then holds still, so rows
    /// never move under a finger mid-multi-select. Deliberately keyed on the
    /// form cards only — folding `selection` in here is what used to re-rank
    /// (and re-order) the section on every single tap.
    private var pickingPassKey: String {
        alreadyAddedItemIDs.sorted().joined(separator: "|")
    }

    private var navigationTitle: LocalizedStringKey {
        supportsCardio ? "exercise_picker.activity_title" : "exercise_picker.title"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                searchField
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                muscleChips
                    .padding(.top, 12)

                if selectedMuscleGroup != nil {
                    equipmentChips
                        .padding(.top, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if category != .cardio {
                    if showsSuggestions {
                        sectionLabel("exercise_picker.suggested_section")
                        ForEach(recommendations, id: \.suggestedRowId) { definition in
                            pickerRow(for: .strength(definition), recentEntry: summariesById[definition.id])
                        }
                    }

                    if filteredExercises.isEmpty && filteredCardio.isEmpty {
                        noResults
                    } else {
                        ForEach(groupedExercises, id: \.group) { group in
                            sectionLabel(LocalizedStringKey(stringLiteral: "muscle_group.\(group.group.rawValue)"))
                            ForEach(group.exercises) { definition in
                                pickerRow(for: .strength(definition), recentEntry: nil)
                            }
                        }
                    }

                }

                if supportsCardio, (category == .all || category == .cardio) {
                    sectionLabel("daily_record.type.cardio")
                    ForEach(filteredCardio, id: \.self) { activity in
                        pickerRow(for: .cardio(activity), recentEntry: nil)
                    }
                }

                if category != .cardio {
                    createCustomRow
                        .padding(.horizontal, 16)
                        .padding(.top, 20)
                        .padding(.bottom, 24)
                }
            }
            .animation(pickerSpring, value: filteredExercises.map(\.id))
            .animation(pickerSpring, value: recommendations.map(\.id))
            .animation(pickerSpring, value: category)
        }
        .background(Color.appBackground.ignoresSafeArea())
        .dismissKeyboardOnTap()
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { confirmBar }
        .sensoryFeedback(.selection, trigger: selection.count)
        .task { await loadLibrary() }
        .task(id: pickingPassKey) { await refreshRecommendations() }
        .sheet(isPresented: $showsCreateSheet) {
            CreateCustomExerciseSheet(initialName: trimmedQuery) { name, muscleGroup, loadType in
                await createCustomExercise(name: name, muscleGroup: muscleGroup, loadType: loadType)
            }
            .presentationDetents([.height(280)])
        }
        .sheet(item: $detailDefinition) { definition in
            ExerciseDetailSheet(definition: definition)
                .environmentObject(localizationManager)
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .appFont(size: 14, weight: .medium)
                .foregroundColor(.textMuted)

            TextField(String(localized: "exercise_picker.search_placeholder"), text: $query)
                .appFont(.chatBodyMedium)
                .foregroundColor(.textPrimary)
                .autocorrectionDisabled()

            if !query.isEmpty {
                Button {
                    withAnimation(pickerSpring) { query = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .appFont(size: 14)
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
                    isSelected: category == .all
                ) {
                    category = .all
                    equipmentFilter = nil
                }
                if supportsCardio {
                    filterChip(
                        label: Text("daily_record.type.cardio"),
                        isSelected: category == .cardio
                    ) {
                        category = .cardio
                        equipmentFilter = nil
                    }
                }
                ForEach(MuscleGroup.allCases) { group in
                    filterChip(
                        label: Text(group.displayLabel),
                        isSelected: category == .muscle(group)
                    ) {
                        category = .muscle(group)
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
                .appFont(size: compact ? 11 : 12, weight: .medium)
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
            .appFont(size: 11, weight: .medium)
            .kerning(1.1)
            .foregroundColor(.textMuted)
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 6)
    }

    private func pickerRow(for item: ExercisePickerItem, recentEntry: RecentExerciseEntry?) -> some View {
        let isAdded = alreadyAddedItemIDs.contains(item.id)
        let isSelected = selection.contains { $0.id == item.id }

        return HStack(spacing: 0) {
            Button {
                guard !isAdded else { return }
                withAnimation(pickerSpring) { toggle(item) }
            } label: {
                HStack(spacing: 12) {
                    leadingThumbnail(for: item)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.displayName(for: localizationManager.appLanguage))
                            .appFont(size: 15, weight: .semibold)
                            .foregroundColor(isAdded ? .textMuted : (isSelected ? .accentValue : .textPrimary))
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                            .multilineTextAlignment(.leading)

                        metaLine(for: item, recentEntry: recentEntry)
                    }

                    Spacer(minLength: 8)

                    trailingIndicator(isAdded: isAdded, isSelected: isSelected)
                }
                .padding(.leading, 16)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isAdded)

            infoButton(for: item)
        }
        .padding(.trailing, 16)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.appSeparator)
                .frame(height: 0.5)
                .padding(.leading, 16)
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private func leadingThumbnail(for item: ExercisePickerItem) -> some View {
        switch item {
        case .strength(let definition):
            ExerciseThumbnailView(
                mediaId: definition.mediaId,
                muscleGroup: definition.muscleGroup
            )
        case .cardio:
            ExerciseThumbnailView(mediaId: nil, muscleGroup: .fullBody)
        }
    }

    /// Separate hit target from the row itself: tapping the row selects the
    /// exercise, tapping the glyph explains it.
    @ViewBuilder
    private func infoButton(for item: ExercisePickerItem) -> some View {
        if case .strength(let definition) = item {
            Button {
                detailDefinition = definition
            } label: {
                Image(systemName: "info.circle")
                    .appFont(size: 16, weight: .regular)
                    .foregroundColor(.textDarkMuted)
                    .padding(.leading, 10)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("exercise_detail.open_accessibility"))
        }
    }

    @ViewBuilder
    private func metaLine(for item: ExercisePickerItem, recentEntry: RecentExerciseEntry?) -> some View {
        switch item {
        case .cardio:
            Text("daily_record.type.cardio")
                .appFont(.exerciseUnit)
                .foregroundColor(.textMuted)
        case .strength(let definition):
            HStack(spacing: 4) {
                Text("\(definition.equipment.displayLabel) · \(definition.muscleGroup.displayLabel)")
                    .appFont(.exerciseUnit)
                    .foregroundColor(.textMuted)

                if let recentEntry, let summary = lastSummary(recentEntry) {
                    Text("·")
                        .appFont(.exerciseUnit)
                        .foregroundColor(.textMuted)
                    Text(summary)
                        .appFont(.exerciseUnit)
                        .foregroundColor(.accentValue)
                }
            }
        }
    }

    @ViewBuilder
    private func trailingIndicator(isAdded: Bool, isSelected: Bool) -> some View {
        if isAdded {
            Text("exercise_picker.already_added")
                .appFont(size: 11, weight: .medium)
                .foregroundColor(.textMuted)
        } else if isSelected {
            Image(systemName: "checkmark.circle.fill")
                .appFont(size: 20, weight: .semibold)
                .foregroundColor(.accentPrimary)
                .transition(.scale.combined(with: .opacity))
        } else {
            Image(systemName: "circle")
                .appFont(size: 20, weight: .regular)
                .foregroundColor(.textDarkMuted)
        }
    }

    // MARK: - Empty & Custom Creation

    private var noResults: some View {
        Text("exercise_picker.no_results")
            .appFont(.chatBody)
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
            .appFont(size: 14, weight: .semibold)
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
                    Text(LocalizedPlanText.formatted(
                        "exercise_picker.add_count",
                        locale: locale,
                        Int64(selection.count)
                    ))
                        .appFont(size: 15, weight: .semibold)
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
            .padding(.bottom, BottomActionBarMetrics.bottomPadding)
            .background(alignment: .top) {
                // Opaque, not a 0.94 wash: the rows scrolling underneath used
                // to ghost through the bar and read as a rendering glitch. The
                // hairline gives the bar an edge so it reads as chrome rather
                // than as content floating over the last rows.
                Color.appBackground
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(Color.appSeparator)
                            .frame(height: 0.5)
                    }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Horizontally scrolling chips of the current selection, so the user can
    /// see (and undo) what they've picked without scanning the list above.
    private var selectionPreview: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(selection) { item in
                        selectionChip(item)
                            .id(item.id)
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

    private func selectionChip(_ item: ExercisePickerItem) -> some View {
        Button {
            withAnimation(pickerSpring) { toggle(item) }
        } label: {
            HStack(spacing: 5) {
                Text(item.displayName(for: localizationManager.appLanguage))
                    .appFont(size: 12, weight: .medium)
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)

                Image(systemName: "xmark")
                    .appFont(size: 9, weight: .bold)
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

    private func toggle(_ item: ExercisePickerItem) {
        if let index = selection.firstIndex(where: { $0.id == item.id }) {
            selection.remove(at: index)
        } else {
            selection.append(item)
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
        // The pass this run belongs to, read before any await. A superseded
        // `.task(id:)` is cancelled but still resumes — the library service is
        // non-throwing and doesn't check cancellation — so a late result must
        // never be stamped with a pass it wasn't ranked for.
        let passKey = pickingPassKey

        // Reuse the cached library instead of re-fetching the whole catalog.
        // `loadLibrary()` populates `library` on first appear; only fall back
        // to a fetch here if it hasn't landed yet.
        if library.isEmpty {
            library = await AppServices.exerciseLibraryService.fetchLibrary()
        }
        let selectedDefinitions = selection.compactMap { item -> ExerciseDefinition? in
            guard case .strength(let definition) = item else { return nil }
            return definition
        }
        let addedDefinitions = library.filter {
            alreadyAddedItemIDs.contains(ExercisePickerItem.strength($0).id)
        }
        let result = await AppServices.exerciseLibraryService.fetchRecommendations(
            todaysSelections: selectedDefinitions + addedDefinitions,
            limit: Self.suggestionLimit
        )

        // Drop a superseded run outright rather than let it publish last
        // pass's ranking: confirming a selection while the first fetch is
        // still in flight would otherwise pin rows that have since become
        // form cards, leaving disabled "already added" rows in SUGGESTED for
        // the rest of the pass. Checked on the task rather than by re-reading
        // `pickingPassKey`, which resolves against this run's captured view.
        guard !Task.isCancelled else { return }

        // Within a pass the rows already on screen keep their slots; a re-run
        // (a late library load, say) may only top up slots that are still
        // empty. Crossing into a new pass drops the pins and re-ranks.
        let pinned = rankedPassKey == passKey ? recommendations : []
        rankedPassKey = passKey
        let merged = ExerciseRecommendationEngine.stableMerge(
            pinned: pinned,
            incoming: result,
            limit: Self.suggestionLimit
        )
        guard merged.map(\.id) != recommendations.map(\.id) else { return }
        withAnimation(pickerSpring) { recommendations = merged }
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
            let item = ExercisePickerItem.strength(definition)
            if !selection.contains(where: { $0.id == item.id }),
               !alreadyAddedItemIDs.contains(item.id) {
                selection.append(item)
            }
        }
    }

    private func matchesCardio(_ activity: CardioActivityType, query: String) -> Bool {
        let normalizedQuery = ExerciseDefinition.normalize(query)
        guard !normalizedQuery.isEmpty else { return true }
        let terms: [String]
        switch activity {
        case .running: terms = [activity.localizedTitle, activity.rawValue, "跑步", "running"]
        case .cycling: terms = [activity.localizedTitle, activity.rawValue, "骑行", "cycling"]
        case .elliptical: terms = [activity.localizedTitle, activity.rawValue, "椭圆机", "elliptical"]
        case .stairClimber: terms = [activity.localizedTitle, activity.rawValue, "爬楼机", "stair climber"]
        }
        return terms.contains { ExerciseDefinition.normalize($0).contains(normalizedQuery) }
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
                .appFont(.headerTitle)
                .foregroundColor(.textPrimary)
                .padding(.top, 20)

            TextField(String(localized: "exercise_picker.custom_name_placeholder"), text: $name)
                .appFont(.chatBodyMedium)
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
                            .appFont(size: 10, weight: .semibold)
                            .foregroundColor(.textMuted)
                    }
                    .appFont(size: 13, weight: .medium)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(Capsule().fill(Color.workoutPanel))
                }

                Button {
                    isBodyweight.toggle()
                } label: {
                    Text(isBodyweight ? "daily_record.load.bodyweight" : "daily_record.load.weighted")
                        .appFont(size: 13, weight: .medium)
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
        ExercisePickerScreen(onConfirm: { _ in })
    }
    .environmentObject(LocalizationManager())
}
