import Foundation

@main
struct ChatMessagePRSummaryTestRunner {
    static func main() throws {
        try decodesPRSummaryBlock()
        processingAssistantWithTextIsNotTypingOnly()
        sortedProfilePRsPreferHeavierWeights()
        print("chat_message_pr_summary_test passed")
    }

    private static func decodesPRSummaryBlock() throws {
        let json = """
        {
          "id": "message-1",
          "conversation_id": "conversation-1",
          "role": "assistant",
          "content": "Logged it.",
          "created_at": "2026-03-20T00:00:00Z",
          "status": "completed",
          "parse_status": "completed",
          "content_blocks": [
            {
              "type": "pr_summary",
              "summary_text": "New PR today.",
              "items": [
                {
                  "normalized_name": "bench press",
                  "display_name": "Bench Press",
                  "previous_weight": 80,
                  "current_weight": 85,
                  "weight_unit": "kg",
                  "is_new_record": true
                }
              ]
            }
          ]
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let message = try decoder.decode(ChatMessage.self, from: Data(json.utf8))

        guard let blocks = message.contentBlocks, blocks.count == 1 else {
            fatalError("Expected one content block")
        }

        guard case let .prSummary(summary) = blocks[0] else {
            fatalError("Expected prSummary block")
        }

        precondition(summary.items.count == 1, "Expected one PR item")
        precondition(summary.items[0].currentWeight == 85, "Expected current weight to decode")
    }

    private static func processingAssistantWithTextIsNotTypingOnly() {
        let processingTextMessage = ChatMessage(
            id: "message-2",
            sessionId: "conversation-1",
            role: .assistant,
            text: "Streaming partial reply",
            createdAt: Date(),
            status: .processing
        )

        let typingOnlyMessage = ChatMessage(
            id: "message-3",
            sessionId: "conversation-1",
            role: .assistant,
            text: "",
            createdAt: Date(),
            status: .processing
        )

        precondition(processingTextMessage.isTyping == false, "Expected processing assistant with visible text to render as content")
        precondition(typingOnlyMessage.isTyping, "Expected empty processing assistant to stay in typing state")
    }

    @MainActor
    private static func sortedProfilePRsPreferHeavierWeights() {
        let service = TestProfileService(
            profile: UserProfile(
                id: "user-1",
                displayName: "Max",
                avatarURL: nil,
                membershipLevel: .premium,
                stats: UserStats(workoutsCount: 10, streakDays: 4, totalVolumeKg: 1000, prCount: 2),
                preferences: UserPreferences(
                    notificationsEnabled: true,
                    darkModeEnabled: false,
                    weightUnit: .kg,
                    timezone: "Asia/Shanghai",
                    language: .english
                ),
                exercisePRs: [
                    ExercisePR(
                        normalizedName: "bench press",
                        displayName: "Bench Press",
                        maxWeight: 85,
                        weightUnit: .kg,
                        achievedAt: Date(timeIntervalSince1970: 100)
                    ),
                    ExercisePR(
                        normalizedName: "deadlift",
                        displayName: "Deadlift",
                        maxWeight: 120,
                        weightUnit: .kg,
                        achievedAt: Date(timeIntervalSince1970: 50)
                    ),
                ]
            )
        )

        let viewModel = ProfileViewModel(profileService: service)
        viewModel.profile = try? service.fetchProfileSync()

        let sortedNames = viewModel.sortedExercisePRs.map(\.displayName)
        precondition(sortedNames == ["Deadlift", "Bench Press"], "Expected heavier PRs first, got \(sortedNames)")
    }
}

private struct TestProfileService: ProfileServiceProtocol {
    let profile: UserProfile

    func fetchProfile() async throws -> UserProfile { profile }
    func updatePreferences(_ prefs: UpdatePreferencesRequest) async throws -> UserPreferences {
        _ = prefs
        return profile.preferences
    }
    func signOut() async throws {}

    func fetchProfileSync() throws -> UserProfile { profile }
}
