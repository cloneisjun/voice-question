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
