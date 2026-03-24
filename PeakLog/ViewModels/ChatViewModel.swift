import Foundation
import Combine
import CoreGraphics

@MainActor
final class ChatViewModel: ObservableObject {
    // MARK: - Published State

    @Published var messageGroups: [MessageGroup] = []
    @Published var inputText: String = ""
    @Published var isSending: Bool = false
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published private(set) var voiceInputState: VoiceInputState = .idle
    @Published private(set) var hasLoadedInitialDay: Bool = false
    @Published private(set) var isLoadingOlderDays: Bool = false
    @Published private(set) var hasMoreHistory: Bool = true
    @Published private(set) var shouldScrollToBottomOnce: Bool = false
    @Published private(set) var pendingTopAnchorMessageID: String?

    // MARK: - Session (conversation ID)

    private(set) var conversationId: String

    // MARK: - Dependencies

    private let chatService: ChatServiceProtocol
    private let workoutService: WorkoutServiceProtocol
    private let speechRecognitionService: SpeechRecognitionServicing

    private var inputTextBeforeVoiceRecording = ""
    private let calendar = Calendar.current
    private let maxEmptyDaySkipsPerLoad = 30
    private var oldestLoadedDayStart: Date?

    init(
        conversationId: String,
        chatService: ChatServiceProtocol,
        workoutService: WorkoutServiceProtocol,
        speechRecognitionService: SpeechRecognitionServicing
    ) {
        self.conversationId = conversationId
        self.chatService = chatService
        self.workoutService = workoutService
        self.speechRecognitionService = speechRecognitionService
    }

    #if !TESTING
    convenience init(conversationId: String) {
        self.init(
            conversationId: conversationId,
            chatService: SupabaseChatService(),
            workoutService: SupabaseWorkoutService(),
            speechRecognitionService: SpeechRecognitionService()
        )
    }
    #endif

    var isVoiceInteractionEnabled: Bool {
        voiceInputState != .transcribing
    }

    // MARK: - Lifecycle

    func onAppear() async {
        chatService.setStreamEventHandler { [weak self] event in
            guard let self else { return }
            Task { @MainActor in
                self.handleStreamEvent(event)
            }
        }
        guard !hasLoadedInitialDay else { return }
        await loadInitialMessagesForToday()
    }

    func onDisappear() async {
        chatService.setStreamEventHandler(nil)
        await chatService.unsubscribe()
    }

    // MARK: - Load History

    func loadMessages() async {
        isLoading = true
        errorMessage = nil
        do {
            let messages = try await chatService.fetchMessages(sessionId: conversationId)
            messageGroups = groupByDate(messages)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func loadInitialMessagesForToday() async {
        isLoading = true
        errorMessage = nil
        do {
            let window = todayWindow()
            let messages = try await chatService.fetchMessages(
                sessionId: conversationId,
                start: window.start,
                end: window.end
            )
            messageGroups = groupByDate(messages)
            oldestLoadedDayStart = window.start
            hasLoadedInitialDay = true
            hasMoreHistory = true
            pendingTopAnchorMessageID = nil
            shouldScrollToBottomOnce = !messages.isEmpty
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func loadPreviousDayIfNeeded(anchorMessageID: String?) async {
        guard hasLoadedInitialDay, !isLoading, !isLoadingOlderDays, hasMoreHistory else { return }
        guard let currentOldestDayStart = oldestLoadedDayStart else { return }

        isLoadingOlderDays = true
        errorMessage = nil

        defer { isLoadingOlderDays = false }

        var searchDayEnd = currentOldestDayStart

        for _ in 0..<maxEmptyDaySkipsPerLoad {
            let previousDayStart = calendar.date(byAdding: .day, value: -1, to: searchDayEnd) ?? searchDayEnd.addingTimeInterval(-86_400)

            do {
                let messages = try await chatService.fetchMessages(
                    sessionId: conversationId,
                    start: previousDayStart,
                    end: searchDayEnd
                )

                if messages.isEmpty {
                    searchDayEnd = previousDayStart
                    oldestLoadedDayStart = previousDayStart
                    continue
                }

                prependOlderMessages(messages, anchorMessageID: anchorMessageID)
                oldestLoadedDayStart = previousDayStart
                return
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        hasMoreHistory = false
        oldestLoadedDayStart = searchDayEnd
    }

    func consumeScrollToBottomRequest() {
        shouldScrollToBottomOnce = false
    }

    func consumePendingTopAnchorMessageID() {
        pendingTopAnchorMessageID = nil
    }

    // MARK: - Send Message

    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, voiceInputState == .idle else { return }

        let optimisticMessageIDs = insertOptimisticMessages(for: text)
        inputText = ""
        errorMessage = nil
        isSending = true

        do {
            let response = try await chatService.sendMessage(text, sessionId: conversationId)
            try await refreshMessages()
            await waitForAssistantMessageToComplete(messageId: response.assistantMessageId)
        } catch {
            removeMessages(withIDs: [optimisticMessageIDs.userMessageID, optimisticMessageIDs.assistantMessageID])
            errorMessage = error.localizedDescription
            inputText = text // restore on failure
            isSending = false
        }
    }

    // MARK: - Voice Input

    func toggleVoiceInput() async {
        guard !isSending else { return }

        switch voiceInputState {
        case .idle:
            await startVoiceRecording()
        case .recording:
            await stopVoiceRecordingAndTranscribe()
        case .transcribing:
            break
        }
    }

    private func startVoiceRecording() async {
        errorMessage = nil
        inputTextBeforeVoiceRecording = inputText

        do {
            try await speechRecognitionService.startRecognition(
                onLevelUpdate: { _ in },
                onTranscriptUpdate: { [weak self] transcript in
                    Task { @MainActor in
                        self?.inputText = transcript
                    }
                }
            )
            voiceInputState = .recording
        } catch {
            handleVoiceFailure(error)
        }
    }

    private func stopVoiceRecordingAndTranscribe() async {
        voiceInputState = .transcribing

        do {
            let transcript = try await speechRecognitionService.stopRecognition()
            handleVoiceTranscriptionResult(transcript)
        } catch {
            handleVoiceFailure(error)
        }
    }

    private func handleVoiceTranscriptionResult(_ text: String) {
        inputText = text
        inputTextBeforeVoiceRecording = ""
        voiceInputState = .idle
    }

    private func handleVoiceFailure(_ error: Error) {
        inputText = inputTextBeforeVoiceRecording
        inputTextBeforeVoiceRecording = ""
        voiceInputState = .idle
        errorMessage = error.localizedDescription
    }

    // MARK: - Exercise Editing (unchanged API, now hits Supabase directly)

    func updateExerciseName(messageId: String, workoutRecordId: String, exerciseId: String, newName: String) async {
        updateExerciseInPlace(messageId: messageId, exerciseId: exerciseId) { exercise in
            exercise.name = newName
        }
        do {
            _ = try await workoutService.updateExerciseName(
                sessionId: conversationId,
                exerciseId: exerciseId,
                name: newName
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateSet(messageId: String, exerciseId: String, setId: String, weight: Double?, weightUnit: WeightUnit, reps: Int) async {
        updateSetInPlace(messageId: messageId, exerciseId: exerciseId, setId: setId) { set in
            set.weight = weight
            set.weightUnit = weightUnit
            set.reps = reps
        }
        do {
            _ = try await workoutService.updateSet(
                sessionId: conversationId,
                exerciseId: exerciseId,
                setId: setId,
                weight: weight,
                weightUnit: weightUnit,
                reps: reps
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteExercise(messageId: String, workoutRecordId: String, exerciseId: String) async {
        removeExerciseInPlace(messageId: messageId, exerciseId: exerciseId)
        do {
            try await workoutService.deleteExercise(sessionId: conversationId, exerciseId: exerciseId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Private: Message list helpers

    private func groupByDate(_ messages: [ChatMessage]) -> [MessageGroup] {
        var groups: [String: [ChatMessage]] = [:]
        var orderedKeys: [String] = []
        let calendar = Calendar.current
        let absoluteDateFormatter = DateFormatter()
        absoluteDateFormatter.dateStyle = .medium
        absoluteDateFormatter.timeStyle = .none

        for msg in messages.sorted(by: { $0.createdAt < $1.createdAt }) {
            let label = dateSeparatorLabel(
                for: msg.createdAt,
                calendar: calendar,
                absoluteDateFormatter: absoluteDateFormatter
            )
            if groups[label] == nil {
                orderedKeys.append(label)
                groups[label] = []
            }
            groups[label]!.append(msg)
        }

        return orderedKeys.map { key in
            MessageGroup(label: key, messages: groups[key]!)
        }
    }

    private func dateSeparatorLabel(
        for date: Date,
        calendar: Calendar,
        absoluteDateFormatter: DateFormatter
    ) -> String {
        if calendar.isDateInToday(date) {
            return String(localized: "common.today")
        }

        return absoluteDateFormatter.string(from: date)
    }

    private func appendMessages(_ newMessages: [ChatMessage]) {
        var all = messageGroups.flatMap(\.messages)
        all.append(contentsOf: newMessages)
        messageGroups = groupByDate(all)
    }

    private func prependOlderMessages(_ olderMessages: [ChatMessage], anchorMessageID: String?) {
        let combined = olderMessages + messageGroups.flatMap(\.messages)
        messageGroups = groupByDate(combined)
        pendingTopAnchorMessageID = anchorMessageID
    }

    private func refreshMessages() async throws {
        let window = todayWindow()
        let todayMessages = try await chatService.fetchMessages(
            sessionId: conversationId,
            start: window.start,
            end: window.end
        )
        let mergedTodayMessages = mergeServerMessagesWithOptimisticLocals(todayMessages)
        replaceTodayMessages(with: mergedTodayMessages)
        if !mergedTodayMessages.isEmpty {
            shouldScrollToBottomOnce = true
        }
        updateSendingState()
    }

    private func waitForAssistantMessageToComplete(messageId: String) async {
        for _ in 0..<6 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            do {
                try await refreshMessages()

                let allMessages = messageGroups.flatMap(\.messages)
                if let assistant = allMessages.first(where: { $0.id == messageId }),
                   assistant.status != .processing {
                    updateSendingState()
                    return
                }

                if !allMessages.contains(where: { $0.role == .assistant && $0.status == .processing }) {
                    updateSendingState()
                    return
                }
            } catch {
                // Keep polling; the Realtime path may still deliver the update.
            }
        }
    }

    /// Replace a message by ID (used when Realtime UPDATE fires with completed content)
    private func replaceMessage(_ updated: ChatMessage) {
        for gi in messageGroups.indices {
            for mi in messageGroups[gi].messages.indices {
                if messageGroups[gi].messages[mi].id == updated.id {
                    messageGroups[gi].messages[mi] = updated
                    return
                }
            }
        }
        // Not found yet (race condition) — append it
        appendMessages([updated])
    }

    private func upsertIncomingMessage(_ incoming: ChatMessage) {
        if replaceOptimisticMatch(with: incoming) {
            return
        }

        let allMessages = messageGroups.flatMap(\.messages)
        guard !allMessages.contains(where: { $0.id == incoming.id }) else {
            replaceMessage(incoming)
            return
        }

        appendMessages([incoming])
    }

    private func insertOptimisticMessages(for text: String) -> (userMessageID: String, assistantMessageID: String) {
        let requestID = UUID().uuidString
        let now = Date()
        let userMessageID = "local-user-\(requestID)"
        let assistantMessageID = "local-assistant-\(requestID)"

        let optimisticUserMessage = ChatMessage(
            id: userMessageID,
            sessionId: conversationId,
            role: .user,
            text: text,
            createdAt: now,
            status: .created,
            isLocalOnly: true
        )

        let optimisticAssistantMessage = ChatMessage(
            id: assistantMessageID,
            sessionId: conversationId,
            role: .assistant,
            text: "",
            createdAt: now.addingTimeInterval(0.001),
            status: .processing,
            isLocalOnly: true
        )

        appendMessages([optimisticUserMessage, optimisticAssistantMessage])
        shouldScrollToBottomOnce = true
        return (userMessageID, assistantMessageID)
    }

    private func reconcileOptimisticMessageID(localID: String, serverID: String) {
        for gi in messageGroups.indices {
            for mi in messageGroups[gi].messages.indices where messageGroups[gi].messages[mi].id == localID {
                let existing = messageGroups[gi].messages[mi]
                messageGroups[gi].messages[mi] = ChatMessage(
                    id: serverID,
                    sessionId: existing.sessionId,
                    role: existing.role,
                    text: existing.text,
                    createdAt: existing.createdAt,
                    contentBlocks: existing.contentBlocks,
                    status: existing.status,
                    workoutRecord: existing.workoutRecord,
                    parseStatus: existing.parseStatus,
                    isLocalOnly: existing.isLocalOnly,
                    imageURL: existing.imageURL,
                    audioURL: existing.audioURL
                )
                return
            }
        }
    }

    private func removeMessages(withIDs ids: [String]) {
        let idSet = Set(ids)
        let remainingMessages = messageGroups
            .flatMap(\.messages)
            .filter { !idSet.contains($0.id) }

        messageGroups = groupByDate(remainingMessages)
        updateSendingState()
    }

    private func updateSendingState() {
        let allMessages = messageGroups.flatMap(\.messages)
        isSending = allMessages.contains {
            $0.role == .assistant && $0.status == .processing
        }
    }

    private func mergeServerMessagesWithOptimisticLocals(_ serverMessages: [ChatMessage]) -> [ChatMessage] {
        var mergedMessages = serverMessages
        let optimisticMessages = messageGroups
            .flatMap(\.messages)
            .filter { $0.isLocalOnly && calendar.isDateInToday($0.createdAt) }

        for optimisticMessage in optimisticMessages {
            let serverMatchIndex = mergedMessages.firstIndex { serverMessage in
                messagesRepresentSameEvent(serverMessage, optimisticMessage)
            }

            if let index = serverMatchIndex {
                mergedMessages[index] = serverMessages[index]
            } else {
                mergedMessages.append(optimisticMessage)
            }
        }

        return mergedMessages.sorted(by: { $0.createdAt < $1.createdAt })
    }

    private func replaceTodayMessages(with todayMessages: [ChatMessage]) {
        let historicalMessages = messageGroups.flatMap(\.messages).filter {
            !calendar.isDateInToday($0.createdAt)
        }
        messageGroups = groupByDate(historicalMessages + todayMessages)
    }

    private func todayWindow(referenceDate: Date = Date()) -> (start: Date, end: Date) {
        let start = calendar.startOfDay(for: referenceDate)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (start, end)
    }

    private func replaceOptimisticMatch(with incoming: ChatMessage) -> Bool {
        for gi in messageGroups.indices {
            for mi in messageGroups[gi].messages.indices {
                let existing = messageGroups[gi].messages[mi]
                guard existing.isLocalOnly, messagesRepresentSameEvent(incoming, existing) else { continue }
                messageGroups[gi].messages[mi] = incoming
                return true
            }
        }

        return false
    }

    private func messagesRepresentSameEvent(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        if lhs.id == rhs.id {
            return true
        }

        guard lhs.role == rhs.role else { return false }
        guard abs(lhs.createdAt.timeIntervalSince(rhs.createdAt)) <= 10 else { return false }

        switch lhs.role {
        case .user:
            return lhs.text == rhs.text && !lhs.text.isEmpty
        case .assistant:
            return lhs.status == .processing || rhs.status == .processing
        }
    }

    private func handleStreamEvent(_ event: ChatServiceStreamEvent) {
        switch event {
        case .responseStarted(let ids):
            reconcileOptimisticMessageID(localID: latestOptimisticUserMessageID, serverID: ids.userMessageId)
            reconcileOptimisticMessageID(localID: latestOptimisticAssistantMessageID, serverID: ids.assistantMessageId)
        case .textDelta(let delta):
            appendStreamingTextDelta(delta)
        case .workoutPreview(let block):
            applyStreamingWorkoutPreview(block)
        case .error(let message):
            markStreamingAssistantFailed(message: message)
            errorMessage = message
        case .done:
            break
        }
        updateSendingState()
    }

    private var latestOptimisticUserMessageID: String {
        messageGroups
            .flatMap(\.messages)
            .last(where: { $0.role == .user && $0.isLocalOnly })?
            .id ?? ""
    }

    private var latestOptimisticAssistantMessageID: String {
        messageGroups
            .flatMap(\.messages)
            .last(where: { $0.role == .assistant && $0.isLocalOnly })?
            .id ?? ""
    }

    private func appendStreamingTextDelta(_ delta: String) {
        guard !delta.isEmpty else { return }

        updateLatestProcessingAssistant { message in
            message.text.append(delta)
            message.contentBlocks = Self.upsertTextBlock(
                text: message.text,
                into: message.contentBlocks
            )
        }
    }

    private func applyStreamingWorkoutPreview(_ block: WorkoutRecordBlock) {
        updateLatestProcessingAssistant { message in
            var blocks = message.contentBlocks ?? []
            if !message.text.isEmpty {
                blocks = Self.upsertTextBlock(text: message.text, into: blocks) ?? []
            }
            blocks.removeAll {
                switch $0 {
                case .workoutRecord, .workoutRecordStream:
                    return true
                default:
                    return false
                }
            }
            blocks.append(.workoutRecordStream(block))
            message.contentBlocks = blocks
        }
    }

    private func markStreamingAssistantFailed(message: String) {
        updateLatestProcessingAssistant { assistant in
            assistant.status = .failed
            if !message.isEmpty {
                assistant.text = message
                assistant.contentBlocks = [.text(message)]
            }
        }
    }

    private func updateLatestProcessingAssistant(_ update: (inout ChatMessage) -> Void) {
        for groupIndex in messageGroups.indices.reversed() {
            for messageIndex in messageGroups[groupIndex].messages.indices.reversed() {
                guard messageGroups[groupIndex].messages[messageIndex].role == .assistant else { continue }
                guard messageGroups[groupIndex].messages[messageIndex].status == .processing else { continue }
                update(&messageGroups[groupIndex].messages[messageIndex])
                return
            }
        }
    }

    private static func upsertTextBlock(text: String, into blocks: [ContentBlock]?) -> [ContentBlock]? {
        guard !text.isEmpty else { return blocks }

        var result = blocks ?? []
        if let index = result.firstIndex(where: {
            if case .text = $0 { return true }
            return false
        }) {
            result[index] = .text(text)
        } else {
            result.insert(.text(text), at: 0)
        }
        return result
    }

    private func updateExerciseInPlace(messageId: String, exerciseId: String, update: (inout Exercise) -> Void) {
        for gi in messageGroups.indices {
            for mi in messageGroups[gi].messages.indices {
                if messageGroups[gi].messages[mi].id == messageId,
                   var record = messageGroups[gi].messages[mi].workoutRecord {
                    for ei in record.exercises.indices where record.exercises[ei].id == exerciseId {
                        update(&record.exercises[ei])
                    }
                    messageGroups[gi].messages[mi].workoutRecord = record
                }
            }
        }
    }

    private func updateSetInPlace(messageId: String, exerciseId: String, setId: String, update: (inout ExerciseSet) -> Void) {
        for gi in messageGroups.indices {
            for mi in messageGroups[gi].messages.indices {
                if messageGroups[gi].messages[mi].id == messageId,
                   var record = messageGroups[gi].messages[mi].workoutRecord {
                    for ei in record.exercises.indices where record.exercises[ei].id == exerciseId {
                        for si in record.exercises[ei].sets.indices where record.exercises[ei].sets[si].id == setId {
                            update(&record.exercises[ei].sets[si])
                        }
                    }
                    messageGroups[gi].messages[mi].workoutRecord = record
                }
            }
        }
    }

    private func removeExerciseInPlace(messageId: String, exerciseId: String) {
        for gi in messageGroups.indices {
            for mi in messageGroups[gi].messages.indices {
                if messageGroups[gi].messages[mi].id == messageId,
                   var record = messageGroups[gi].messages[mi].workoutRecord {
                    record.exercises.removeAll { $0.id == exerciseId }
                    messageGroups[gi].messages[mi].workoutRecord = record
                }
            }
        }
    }
}
