import Foundation

public struct QuestionOption: Codable, Equatable {
    public var label: String
    public var description: String?

    public init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }
}

public struct Question: Codable, Equatable {
    public var question: String
    public var header: String?
    public var options: [QuestionOption]
    public var multiSelect: Bool

    public init(question: String, header: String? = nil, options: [QuestionOption] = [], multiSelect: Bool = false) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }
}

/// Where a question came from. The raw value is also what CLI/hook callers send.
public enum QuestionSource: String, Codable {
    case claudeCode = "claude-code"
    case codex
    case aside
    case cli

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "ChatGPT · Codex"
        case .aside: return "Aside"
        case .cli: return "VoiceQuestion"
        }
    }
}

public struct AskRequest: Codable {
    public var id: String
    public var source: QuestionSource
    /// Session / project title shown next to the source badge.
    public var title: String?
    public var cwd: String?
    public var questions: [Question]
    /// Test hook: when set, TTS / Wispr / VAD are bypassed and these strings are used as the
    /// transcripts (one per question). Lets the whole hook → app → answer path run without audio.
    public var simulateTranscripts: [String]?

    public init(id: String, source: QuestionSource, title: String? = nil, cwd: String? = nil,
                questions: [Question], simulateTranscripts: [String]? = nil) {
        self.id = id
        self.source = source
        self.title = title
        self.cwd = cwd
        self.questions = questions
        self.simulateTranscripts = simulateTranscripts
    }
}

public struct AnsweredQuestion: Codable, Equatable {
    public enum Kind: String, Codable {
        case option, options, freeText
    }

    public var question: String
    /// What gets handed to the asking app: option label(s) joined with ", " or the free text.
    public var answer: String
    /// What the speech engine heard, before matching.
    public var transcript: String
    public var kind: Kind
    public var selectedLabels: [String]

    public init(question: String, answer: String, transcript: String, kind: Kind, selectedLabels: [String]) {
        self.question = question
        self.answer = answer
        self.transcript = transcript
        self.kind = kind
        self.selectedLabels = selectedLabels
    }
}

public struct AskResponse: Codable {
    public enum Status: String, Codable {
        case answered, skipped, error
    }

    public var status: Status
    /// For `skipped` / `error`: "timeout", "user", "busy", "disabled", "no_speech", ...
    public var reason: String?
    public var answers: [AnsweredQuestion]

    public init(status: Status, reason: String? = nil, answers: [AnsweredQuestion] = []) {
        self.status = status
        self.reason = reason
        self.answers = answers
    }

    public static func skipped(_ reason: String) -> AskResponse { AskResponse(status: .skipped, reason: reason) }
}

/// One line of JSON per message over the Unix socket.
public struct IPCRequest: Codable {
    public var cmd: String
    public var request: AskRequest?

    public init(cmd: String, request: AskRequest? = nil) {
        self.cmd = cmd
        self.request = request
    }
}

public struct StatusReport: Codable {
    public var version: String
    public var enabled: Bool
    public var busy: Bool
    public var microphonePermission: String
    public var accessibilityTrusted: Bool
    public var wisprInstalled: Bool
    public var wisprRunning: Bool
    public var watchers: [String: String]

    public init(version: String, enabled: Bool, busy: Bool, microphonePermission: String, accessibilityTrusted: Bool,
                wisprInstalled: Bool, wisprRunning: Bool, watchers: [String: String]) {
        self.version = version
        self.enabled = enabled
        self.busy = busy
        self.microphonePermission = microphonePermission
        self.accessibilityTrusted = accessibilityTrusted
        self.wisprInstalled = wisprInstalled
        self.wisprRunning = wisprRunning
        self.watchers = watchers
    }
}

public enum VQ {
    public static let version = "0.1.0"
    public static let bundleID = "com.cloneisjun.VoiceQuestion"

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("VoiceQuestion", isDirectory: true)
    }

    /// `VQ_CONFIG` / `VQ_LOG` / `VQ_SOCKET` relocate the files, which is how a test instance stays
    /// out of the way of the installed one.
    public static var configURL: URL {
        if let override = environment("VQ_CONFIG") { return URL(fileURLWithPath: override) }
        return supportDirectory.appendingPathComponent("config.json")
    }

    public static var logURL: URL {
        if let override = environment("VQ_LOG") { return URL(fileURLWithPath: override) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/VoiceQuestion/voicequestion.log")
    }

    public static func environment(_ name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { return nil }
        return value
    }

    /// `sockaddr_un.sun_path` holds 104 bytes; fall back to /tmp for unusually long home paths.
    public static var socketPath: String {
        if let override = environment("VQ_SOCKET") { return override }
        let preferred = supportDirectory.appendingPathComponent("vq.sock").path
        return preferred.utf8.count < 100 ? preferred : "/tmp/voicequestion-\(getuid()).sock"
    }

    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.withoutEscapingSlashes]
        return e
    }

    public static func encodeLine<T: Encodable>(_ value: T) -> String {
        guard let data = try? encoder().encode(value), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}
