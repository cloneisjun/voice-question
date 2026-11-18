import Foundation

/// Claude Code `PreToolUse` hook for `AskUserQuestion`.
///
/// Claude Code lets a hook answer the question: return `permissionDecision: "allow"` plus an
/// `updatedInput` that echoes the original `questions` and adds `answers` (question text → answer).
/// The dialog is then never shown. Printing nothing and exiting 0 leaves the normal dialog in place.
/// https://code.claude.com/docs/en/hooks
public enum ClaudeHook {

    public struct Input {
        public var toolName: String
        public var toolUseID: String
        public var sessionID: String?
        public var cwd: String?
        public var questions: [Question]
        /// The untouched `tool_input` object; echoed back so no field Claude sent is lost.
        public var rawToolInput: [String: Any]
    }

    public static func parse(_ data: Data) -> Input? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let toolName = root["tool_name"] as? String,
              let toolInput = root["tool_input"] as? [String: Any],
              let rawQuestions = toolInput["questions"] as? [[String: Any]] else { return nil }

        let questions = rawQuestions.compactMap(HookParsing.question)
        guard !questions.isEmpty, questions.count == rawQuestions.count else { return nil }
        return Input(toolName: toolName,
                     toolUseID: (root["tool_use_id"] as? String) ?? UUID().uuidString,
                     sessionID: root["session_id"] as? String,
                     cwd: root["cwd"] as? String,
                     questions: questions,
                     rawToolInput: toolInput)
    }

    /// The JSON to print on stdout. Nil unless every question has an answer.
    public static func output(for input: Input, answers: [AnsweredQuestion]) -> String? {
        var answerMap: [String: String] = [:]
        for question in input.questions {
            guard let answer = answers.first(where: { $0.question == question.question }) else { return nil }
            answerMap[question.question] = answer.answer
        }
        var updatedInput = input.rawToolInput
        updatedInput["answers"] = answerMap
        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "permissionDecisionReason": "Answered by voice (VoiceQuestion)",
                "updatedInput": updatedInput,
            ] as [String: Any],
        ]
        return HookParsing.jsonString(payload)
    }

    public static func request(from input: Input, simulateTranscripts: [String]? = nil) -> AskRequest {
        AskRequest(id: input.toolUseID, source: .claudeCode, title: input.cwd.map { ($0 as NSString).lastPathComponent },
                   cwd: input.cwd, questions: input.questions, simulateTranscripts: simulateTranscripts)
    }
}

/// Claude Code `Stop` hook for the Claude desktop app's next-step box (Code tab).
///
/// The box is the card at the end of a turn that holds a question and reply buttons. It is not
/// `AskUserQuestion`: the model calls `mcp__ccd_turn__wrap_up` with `ask` (the question) and `actions`
/// (the buttons), the tool returns at once, the model writes its closing message and the turn ends.
/// A click on a button arrives later as an ordinary user message holding the button's label.
/// So there is no tool call to answer. This hook runs when the turn ends, finds the box in the session
/// transcript, and returns the spoken answer as `decision: "block"` with a `reason`, which makes Claude
/// carry on with it. Printing nothing and exiting 0 ends the turn as usual, with the box untouched.
/// https://code.claude.com/docs/en/hooks
public enum ClaudeNextStep {

    public static let toolName = "mcp__ccd_turn__wrap_up"

    /// How much of the end of the transcript is read. The box is among the last few lines of a turn.
    public static let tailBytes = 2 * 1024 * 1024

    public struct Input {
        public var sessionID: String?
        public var cwd: String?
        public var transcriptPath: String
    }

    public struct Ask: Equatable {
        public var toolUseID: String
        public var question: Question
    }

    public static func parse(_ data: Data) -> Input? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["hook_event_name"] as? String == "Stop",
              let path = root["transcript_path"] as? String, !path.isEmpty else { return nil }
        return Input(sessionID: root["session_id"] as? String, cwd: root["cwd"] as? String,
                     transcriptPath: (path as NSString).expandingTildeInPath)
    }

    /// The last `tailBytes` of the transcript, starting at a line boundary.
    public static func transcriptTail(atPath path: String, maxBytes: Int = tailBytes) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, var data = try? handle.readToEnd() else { return nil }
        if start > 0 {
            // The first line is cut somewhere in the middle; drop it.
            guard let newline = data.firstIndex(of: 0x0A) else { return nil }
            data = data[data.index(after: newline)...]
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The complete lines added to the transcript after `offset`, and where the next read starts.
    public static func transcriptLines(atPath path: String, after offset: UInt64) -> (text: String, end: UInt64)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd(),
              let newline = data.lastIndex(of: 0x0A) else { return nil }
        let lines = data[...newline]
        return (String(decoding: lines, as: UTF8.self), offset + UInt64(lines.count))
    }

    /// The question in the box this turn ended with, if it is one that can be answered by voice.
    ///
    /// Walks the transcript from its end. Anything that shows the box is no longer waiting stops the search:
    /// a message the user sent or queued, or a turn end that already came after the box.
    public static func pendingAsk(inTranscript text: String) -> Ask? {
        guard text.contains(toolName) else { return nil }
        var failed: [String: Bool] = [:] // tool_use_id → is_error, from the results seen so far
        for line in text.split(separator: "\n").reversed() {
            guard let entry = mainEntry(line) else { continue }
            if isUserMessage(entry) { return nil }
            let content = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            switch entry["type"] as? String {
            case "system":
                if entry["subtype"] as? String == "stop_hook_summary" { return nil }
            case "user":
                for block in content {
                    if let id = block["tool_use_id"] as? String { failed[id] = (block["is_error"] as? Bool) ?? false }
                }
            case "assistant":
                for block in content.reversed()
                where block["type"] as? String == "tool_use" && block["name"] as? String == toolName {
                    // The last call decides what the box shows. A call that failed showed nothing.
                    guard let id = block["id"] as? String, failed[id] == false,
                          let input = block["input"] as? [String: Any],
                          let question = question(fromToolInput: input) else { return nil }
                    return Ask(toolUseID: id, question: question)
                }
            default:
                continue
            }
        }
        return nil
    }

    /// True when the lines show the user replying in the app while the question is being asked aloud.
    public static func hasUserMessage(inTranscript text: String) -> Bool {
        text.split(separator: "\n").contains { mainEntry($0).map(isUserMessage) ?? false }
    }

    /// One transcript line, unless it is unreadable or belongs to a subagent.
    private static func mainEntry(_ line: Substring) -> [String: Any]? {
        guard let entry = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              entry["isSidechain"] as? Bool != true else { return nil }
        return entry
    }

    /// A message the user sent or queued: typed, a clicked button, or an earlier answer from this hook.
    /// A `user` entry that only carries tool results is not one.
    private static func isUserMessage(_ entry: [String: Any]) -> Bool {
        switch entry["type"] as? String {
        case "queue-operation":
            return entry["operation"] as? String == "enqueue"
        case "user":
            guard let blocks = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]], !blocks.isEmpty else { return true }
            return !blocks.allSatisfy { $0["type"] as? String == "tool_result" }
        default:
            return false
        }
    }

    /// Nil unless the box asks something and every button is a reply. A button that runs an app action
    /// (commit, create a pull request, …) cannot be pressed from a hook, so that box is left to the app.
    static func question(fromToolInput input: [String: Any]) -> Question? {
        guard let ask = (input["ask"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !ask.isEmpty else { return nil }
        var options: [QuestionOption] = []
        for action in (input["actions"] as? [[String: Any]]) ?? [] {
            guard action["action"] == nil,
                  let label = (action["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return nil }
            options.append(QuestionOption(label: label))
        }
        return Question(question: ask, options: options)
    }

    /// The JSON to print on stdout. Nil unless the question has an answer.
    public static func output(for ask: Ask, answers: [AnsweredQuestion]) -> String? {
        guard let answer = answers.first(where: { $0.question == ask.question.question }),
              !answer.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let reason = """
        The user answered the question in the next-step box by voice (VoiceQuestion) instead of clicking a button. \
        Treat the answer below as the user's reply and continue from it; do not ask the same question again. \
        The answer was dictated, so allow for small speech-recognition errors. The box still shows the answered \
        question, so call wrap_up again when you finish.

        Q: \(ask.question.question)
        A: \(answer.answer)
        """
        return HookParsing.jsonString(["decision": "block", "reason": reason])
    }

    public static func request(from input: Input, ask: Ask, simulateTranscripts: [String]? = nil) -> AskRequest {
        AskRequest(id: ask.toolUseID, source: .claudeCode, title: input.cwd.map { ($0 as NSString).lastPathComponent },
                   cwd: input.cwd, questions: [ask.question], simulateTranscripts: simulateTranscripts)
    }
}

/// Codex (`ChatGPT.app`) `PreToolUse` hook for `request_user_input` / `request_user_input_async`.
///
/// Codex has no way for a hook to supply the answer, so this denies the tool call and puts the
/// spoken answer in the denial reason, which Codex returns to the model. Experimental: it relies on
/// `PreToolUse` firing for these tools and on the hook being trusted in the app.
/// https://learn.chatgpt.com/docs/hooks
public enum CodexHook {

    public struct Input {
        public var toolName: String
        public var toolUseID: String
        public var sessionID: String?
        public var cwd: String?
        public var questions: [Question]
    }

    public static let toolNames: Set<String> = ["request_user_input", "request_user_input_async"]

    public static func parse(_ data: Data) -> Input? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let toolName = root["tool_name"] as? String else { return nil }
        // `tool_input` arrives as an object; tolerate a JSON string as well.
        var toolInput = root["tool_input"] as? [String: Any]
        if toolInput == nil, let text = root["tool_input"] as? String, let data = text.data(using: .utf8) {
            toolInput = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        guard let rawQuestions = toolInput?["questions"] as? [[String: Any]] else { return nil }
        let questions = rawQuestions.compactMap(HookParsing.question)
        guard !questions.isEmpty else { return nil }
        return Input(toolName: toolName,
                     toolUseID: (root["tool_use_id"] as? String) ?? UUID().uuidString,
                     sessionID: root["session_id"] as? String,
                     cwd: root["cwd"] as? String,
                     questions: questions)
    }

    public static func output(answers: [AnsweredQuestion]) -> String? {
        guard !answers.isEmpty else { return nil }
        let lines = answers.map { "Q: \($0.question)\nA: \($0.answer)" }.joined(separator: "\n\n")
        let reason = """
        The user has already been asked these questions aloud and answered by voice (VoiceQuestion), so this tool call \
        was not shown. Do not ask again; continue with these answers. The answers were dictated, so allow for small \
        speech-recognition errors.

        \(lines)
        """
        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            ] as [String: Any],
        ]
        return HookParsing.jsonString(payload)
    }

    public static func request(from input: Input, simulateTranscripts: [String]? = nil) -> AskRequest {
        AskRequest(id: input.toolUseID, source: .codex, title: input.cwd.map { ($0 as NSString).lastPathComponent },
                   cwd: input.cwd, questions: input.questions, simulateTranscripts: simulateTranscripts)
    }
}

enum HookParsing {
    /// Accepts the shapes the different agents use for one question:
    /// Claude `{question, header, options:[{label, description}], multiSelect}`,
    /// Codex async `{title, options:["A", "B"]}`, Aside `{question, header, options, multiple}`.
    static func question(_ raw: [String: Any]) -> Question? {
        guard let text = (raw["question"] as? String) ?? (raw["title"] as? String) ?? (raw["prompt"] as? String),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var options: [QuestionOption] = []
        for item in (raw["options"] as? [Any]) ?? [] {
            if let label = item as? String {
                options.append(QuestionOption(label: label))
            } else if let object = item as? [String: Any], let label = (object["label"] as? String) ?? (object["title"] as? String) {
                options.append(QuestionOption(label: label, description: object["description"] as? String))
            }
        }
        let multi = (raw["multiSelect"] as? Bool) ?? (raw["multiple"] as? Bool) ?? (raw["multi_select"] as? Bool) ?? false
        return Question(question: text, header: raw["header"] as? String, options: options, multiSelect: multi)
    }

    static func jsonString(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
