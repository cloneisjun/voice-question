import Foundation

/// What the Codex session log (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`) says about questions.
public enum CodexRolloutEvent: Equatable {
    /// The agent asked. `callID` identifies the pending question.
    case question(threadID: String?, callID: String, questions: [Question], timestamp: Date?)
    /// The user answered (in the app) the questions with these call ids.
    case answered(callIDs: [String])
}

/// Parser for single rollout lines.
///
/// ChatGPT Desktop asks through `request_user_input_async`: the tool returns `{"accepted":true}`
/// straight away, an `item_completed` event carries the questions, and the answer shows up later as
/// a user message wrapped in `<send_user_message_question_reply>`.
public enum CodexRollout {

    /// Cheap pre-check so multi-megabyte lines are not parsed for nothing.
    public static func mightBeRelevant(_ line: Substring) -> Bool {
        line.contains("request_user_input") || line.contains("\"delivery\"") || line.contains("send_user_message_question_reply")
    }

    /// `pendingCallIDs`: questions still waiting for an answer. The blocking `request_user_input`
    /// tool reports its answer in a plain `function_call_output`, recognisable only by its call id.
    public static func parseLine(_ line: String, pendingCallIDs: Set<String> = []) -> CodexRolloutEvent? {
        guard mightBeRelevant(line[...]) || pendingCallIDs.contains(where: line.contains), let data = line.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let payload = root["payload"] as? [String: Any] else { return nil }
        let type = root["type"] as? String
        let payloadType = payload["type"] as? String
        let timestamp = (root["timestamp"] as? String).flatMap(parseTimestamp)

        if type == "event_msg", payloadType == "item_completed", let item = payload["item"] as? [String: Any] {
            if item["type"] as? String == "AgentMessage", let callID = item["id"] as? String,
               let rawQuestions = item["questions"] as? [[String: Any]] {
                let questions = rawQuestions.compactMap(HookParsing.question)
                guard !questions.isEmpty else { return nil }
                return .question(threadID: payload["thread_id"] as? String, callID: callID, questions: questions, timestamp: timestamp)
            }
            if item["type"] as? String == "UserMessage" {
                let ids = replyCallIDs(in: line)
                return ids.isEmpty ? nil : .answered(callIDs: ids)
            }
            return nil
        }

        guard type == "response_item" else { return nil }
        switch payloadType {
        case "function_call":
            guard let name = payload["name"] as? String, name == "request_user_input" || name == "request_user_input_async",
                  let callID = payload["call_id"] as? String,
                  let arguments = (payload["arguments"] as? String)?.data(using: .utf8),
                  let parsed = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any],
                  let rawQuestions = parsed["questions"] as? [[String: Any]] else { return nil }
            let questions = rawQuestions.compactMap(HookParsing.question)
            guard !questions.isEmpty else { return nil }
            return .question(threadID: nil, callID: callID, questions: questions, timestamp: timestamp)
        case "function_call_output":
            // The async tool answers `{"accepted":true}` immediately; that is not the user's answer.
            guard let callID = payload["call_id"] as? String, pendingCallIDs.contains(callID) else { return nil }
            let output = (payload["output"] as? String) ?? ""
            if output.contains("\"accepted\"") { return nil }
            return .answered(callIDs: [callID])
        case "message":
            guard payload["role"] as? String == "user" else { return nil }
            let ids = replyCallIDs(in: line)
            return ids.isEmpty ? nil : .answered(callIDs: ids)
        default:
            return nil
        }
    }

    /// `rollout-2026-11-17T16-02-52-01a1e850-ce8d-7602-ab1e-152591e46153.jsonl` → the trailing UUID.
    public static func threadID(fromFilename name: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\\.jsonl$"),
              let match = regex.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)) else { return nil }
        return (name as NSString).substring(with: match.range(at: 1))
    }

    static func replyCallIDs(in line: String) -> [String] {
        guard line.contains("send_user_message_question_reply"),
              let regex = try? NSRegularExpression(pattern: "call_[A-Za-z0-9]+") else { return [] }
        let ns = line as NSString
        var seen: [String] = []
        for match in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: match.range)
            if !seen.contains(id) { seen.append(id) }
        }
        return seen
    }

    static func parseTimestamp(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}
