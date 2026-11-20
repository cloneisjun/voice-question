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

    /// `status` of one session in the output of `aside session list --json`: "running", "idle", "interrupted", …
    public static func status(ofSession id: String, inSessionList data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let sessions = ((root as? [String: Any])?["sessions"] as? [[String: Any]]) ?? (root as? [[String: Any]]) ?? []
        return sessions.first { $0["id"] as? String == id }?["status"] as? String
    }

    // MARK: - Sending an answer

    public enum SendOutcome: Equatable {
        case sent
        /// The question was no longer waiting (answered in Aside itself), so nothing was sent.
        case notPending
        /// Names the step that failed.
        case failed(String)
    }

    /// The message that carries the answers into the session. It shows up in the conversation as
    /// the user's own message, so it is kept short.
    public static func answerMessage(for answers: [AnsweredQuestion]) -> String {
        let lead = answers.count == 1 ? "Here is my answer to the question you just asked."
                                      : "Here are my answers to the questions you just asked."
        return lead + "\n\n" + answers.map { "Q: \($0.question)\nA: \($0.answer)" }.joined(separator: "\n\n")
    }

    /// Hands an answer to the session that asked.
    ///
    /// The `aside` CLI has no command that answers a question card (Aside accepts that only from its
    /// own windows), so the answer goes in as a message: `session stop` closes the card and ends the
    /// waiting turn, then `session steer` starts the next turn with the answer.
    ///
    /// `run` runs the CLI with the given arguments and returns its output, or nil when it failed.
    public static func sendAnswer(_ message: String, sessionID: String, suspensionID: String,
                                  pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                                  run: ([String]) -> Data?) -> SendOutcome {
        // A session that has moved on (the question was answered in Aside a moment ago) must not be stopped.
        guard let list = run(["session", "list", "--json"]) else { return .failed("session list") }
        guard pendingQuestions(inSessionList: list).contains(where: { $0.sessionID == sessionID && $0.suspensionID == suspensionID }) else {
            return .notPending
        }
        guard run(["session", "stop", sessionID, "--json"]) != nil else { return .failed("session stop") }
        pause(0.3)
        guard run(["session", "steer", sessionID, "--json", "--", message]) != nil else { return .failed("session steer") }

        // The message starts a turn at once, which takes the session out of "interrupted".
        for _ in 0..<8 {
            guard let list = run(["session", "list", "--json"]),
                  let status = status(ofSession: sessionID, inSessionList: list) else { return .sent }
            if status != "interrupted" { return .sent }
            pause(0.5)
        }
        return .failed("no turn started")
    }

    private static func isMissing(_ value: Any?) -> Bool {
        value == nil || value is NSNull
    }
}
