import Foundation

@main
struct ConversationServiceScopeTestRunner {
    static func main() throws {
        let sourceURL = URL(fileURLWithPath: "/Users/max/Developer/IOS/PeakLog/PeakLog/Services/ConversationService.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        precondition(
            source.contains(".eq(\"user_id\", value: userId)"),
            "Expected conversation lookup to scope by current user"
        )
        precondition(
            source.contains(".eq(\"conversation_type\", value: conversationType)"),
            "Expected conversation lookup to scope by conversation type"
        )
        precondition(
            source.contains("private static let defaultConversationType = \"default\""),
            "Expected default conversation type constant to remain explicit"
        )

        print("conversation_service_scope_test passed")
    }
}
