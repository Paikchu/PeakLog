import Foundation

struct ChatStreamIDs: Equatable {
    let userMessageId: String
    let assistantMessageId: String
}

enum ChatServiceStreamEvent: Equatable {
    case responseStarted(ChatStreamIDs)
    case textDelta(String)
    case workoutPreview(WorkoutRecordBlock)
    case error(String)
    case done
}

struct ChatSSEParser {
    private var buffer = ""

    mutating func ingest(_ data: Data) throws -> [ChatServiceStreamEvent] {
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else {
            return []
        }

        buffer.append(chunk)

        var events: [ChatServiceStreamEvent] = []
        while let range = nextEventRange(in: buffer) {
            let rawEvent = String(buffer[..<range.lowerBound])
            buffer.removeSubrange(..<range.upperBound)

            if let event = try decodeEvent(from: rawEvent) {
                events.append(event)
            }
        }

        return events
    }

    private func nextEventRange(in text: String) -> Range<String.Index>? {
        if let range = text.range(of: "\r\n\r\n") {
            return range
        }

        if let range = text.range(of: "\n\n") {
            return range
        }

        return nil
    }

    private func decodeEvent(from rawEvent: String) throws -> ChatServiceStreamEvent? {
        let payloadLines = rawEvent
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                if line.hasPrefix("data:") {
                    return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                }
                return nil
            }

        guard !payloadLines.isEmpty else {
            return nil
        }

        let payload = payloadLines.joined(separator: "\n")
        let decoder = JSONDecoder()
        let base = try decoder.decode(ChatSSEBasePayload.self, from: Data(payload.utf8))

        switch base.type {
        case "text-delta":
            let event = try decoder.decode(ChatSSETextDeltaPayload.self, from: Data(payload.utf8))
            return .textDelta(event.textDelta)
        case "workout-content-block":
            let event = try decoder.decode(ChatSSEWorkoutPreviewPayload.self, from: Data(payload.utf8))
            return .workoutPreview(event.block.asWorkoutRecordBlock())
        case "error":
            let event = try decoder.decode(ChatSSEErrorPayload.self, from: Data(payload.utf8))
            return .error(event.message)
        case "done":
            return .done
        case "workout-block-stream-start", "workout-block-delta":
            return nil
        default:
            return nil
        }
    }
}

private struct ChatSSEBasePayload: Decodable {
    let type: String
}

private struct ChatSSETextDeltaPayload: Decodable {
    let type: String
    let textDelta: String

    enum CodingKeys: String, CodingKey {
        case type
        case textDelta = "textDelta"
    }
}

private struct ChatSSEErrorPayload: Decodable {
    let type: String
    let message: String
}

private struct ChatSSEWorkoutPreviewPayload: Decodable {
    let type: String
    let block: StreamWorkoutRecordPayload
}

private struct StreamWorkoutRecordPayload: Decodable {
    let workoutSessionId: String
    let workoutDate: String
    let title: String?
    let parseStatus: String
    let exercises: [ContentBlockExercise]

    enum CodingKeys: String, CodingKey {
        case workoutSessionId = "workout_session_id"
        case workoutDate = "workout_date"
        case title
        case parseStatus = "parse_status"
        case exercises
    }

    func asWorkoutRecordBlock() -> WorkoutRecordBlock {
        WorkoutRecordBlock(
            workoutSessionId: workoutSessionId,
            workoutDate: workoutDate,
            title: title,
            parseStatus: parseStatus,
            exercises: exercises
        )
    }
}
