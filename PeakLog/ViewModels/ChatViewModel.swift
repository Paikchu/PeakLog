import Foundation
import Combine

@MainActor
final class ChatViewModel: ObservableObject {
    // MARK: - Published State
    @Published var messageGroups: [MessageGroup] = []
    @Published var inputText: String = ""
    @Published var isSending: Bool = false
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    // MARK: - Session (one per day / per user)
    private(set) var sessionId: String = "session-default"

    // MARK: - Dependencies
    private let chatService: ChatServiceProtocol
    private let workoutService: WorkoutServiceProtocol

    init(chatService: ChatServiceProtocol = MockChatService(),
         workoutService: WorkoutServiceProtocol = MockWorkoutService()) {
        self.chatService = chatService
        self.workoutService = workoutService
    }

    // MARK: - Load History
    func loadMessages() async {
        isLoading = true
        errorMessage = nil
        do {
            let messages = try await chatService.fetchMessages(sessionId: sessionId)
            messageGroups = groupByDate(messages)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Send Message
    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }

        inputText = ""
        isSending = true
        errorMessage = nil

        do {
            let response = try await chatService.sendMessage(text, sessionId: sessionId)
            appendMessages([response.userMessage, response.assistantMessage])
        } catch {
            errorMessage = error.localizedDescription
            inputText = text // restore on failure
        }

        isSending = false
    }

    // MARK: - Exercise Editing

    func updateExerciseName(messageId: String, workoutRecordId: String, exerciseId: String, newName: String) async {
        updateExerciseInPlace(messageId: messageId, exerciseId: exerciseId) { exercise in
            exercise.name = newName
        }
        do {
            _ = try await workoutService.updateExerciseName(sessionId: sessionId, exerciseId: exerciseId, name: newName)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateSet(messageId: String, exerciseId: String, setId: String, weight: Double, weightUnit: WeightUnit, reps: Int) async {
        updateSetInPlace(messageId: messageId, exerciseId: exerciseId, setId: setId) { set in
            set.weight = weight
            set.weightUnit = weightUnit
            set.reps = reps
        }
        do {
            _ = try await workoutService.updateSet(sessionId: sessionId, exerciseId: exerciseId, setId: setId, weight: weight, weightUnit: weightUnit, reps: reps)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteExercise(messageId: String, workoutRecordId: String, exerciseId: String) async {
        removeExerciseInPlace(messageId: messageId, exerciseId: exerciseId)
        do {
            try await workoutService.deleteExercise(sessionId: sessionId, exerciseId: exerciseId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Private Helpers

    private func groupByDate(_ messages: [ChatMessage]) -> [MessageGroup] {
        var groups: [String: [ChatMessage]] = [:]
        var orderedKeys: [String] = []
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        for msg in messages.sorted(by: { $0.createdAt < $1.createdAt }) {
            let msgDay = calendar.startOfDay(for: msg.createdAt)
            let label: String
            if msgDay == today {
                label = "Today"
            } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), msgDay == yesterday {
                label = "Yesterday"
            } else {
                let fmt = DateFormatter()
                fmt.dateFormat = "MMM d"
                label = fmt.string(from: msg.createdAt)
            }
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

    private func appendMessages(_ newMessages: [ChatMessage]) {
        var all = messageGroups.flatMap(\.messages)
        all.append(contentsOf: newMessages)
        messageGroups = groupByDate(all)
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
