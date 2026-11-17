import Foundation

/// Aside (the AI browser) parks a session in a `suspension` of kind `ask-user-question` when its
/// agent calls `ask_user_question`. The daemon logs the moment, and `aside session list --json`
/// exposes the questions.
public enum AsideSessions {

    public struct PendingQuestion: Equatable {
        public var sessionID: String
        public var title: String?
        public var suspensionID: String
        public var questions: [Question]
    }

    /// `{"t":…,"msg":"[SessionSuspensionNotification] session=<id> kind=ask-user-question sending"}` → `<id>`.
    public static func askSessionID(fromLogLine line: String) -> String? {
        guard line.contains("SessionSuspensionNotification"), line.contains("kind=ask-user-question"),
              let regex = try? NSRegularExpression(pattern: "session=([A-Za-z0-9_\\-]+)"),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return nil }
        return (line as NSString).substring(with: match.range(at: 1))
    }

    /// Unanswered `ask-user-question` suspensions in the output of `aside session list --json`.
    public static func pendingQuestions(inSessionList data: Data) -> [PendingQuestion] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let sessions = ((root as? [String: Any])?["sessions"] as? [[String: Any]]) ?? (root as? [[String: Any]]) ?? []
        var pending: [PendingQuestion] = []
        for session in sessions {
            guard let id = session["id"] as? String,
                  let suspension = session["suspension"] as? [String: Any],
                  suspension["kind"] as? String == "ask-user-question",
                  isMissing(suspension["response"]), isMissing(suspension["error"]), isMissing(suspension["resolvedAt"]),
                  let request = suspension["request"] as? [String: Any],
                  let rawQuestions = request["questions"] as? [[String: Any]] else { continue }
            let questions = rawQuestions.compactMap(HookParsing.question)
            guard !questions.isEmpty else { continue }
            pending.append(PendingQuestion(sessionID: id, title: session["title"] as? String,
                                           suspensionID: (suspension["id"] as? String) ?? id, questions: questions))
        }
        return pending
    }

    private static func isMissing(_ value: Any?) -> Bool {
        value == nil || value is NSNull
    }
}
