import Foundation

/// Adds / removes VoiceQuestion's entry in a hooks file.
///
/// Claude Code (`settings.json`) and Codex (`hooks.json`) share the shape
/// `{"hooks": {"PreToolUse": [{"matcher": "...", "hooks": [{"type": "command", "command": "..."}]}]}}`.
/// The Claude next-step hook sits under `Stop` instead, where there is no matcher.
/// Everything that is not ours is left exactly as it was.
public enum HookSettings {

    public enum Agent: String {
        case claude, codex
        /// Claude desktop's next-step box, read when the turn ends (`ClaudeNextStep`).
        case claudeStop = "claude-stop"

        /// The hooks that go into a Claude Code `settings.json`.
        public static let claudeHooks: [Agent] = [.claude, .claudeStop]

        public var event: String {
            switch self {
            case .claude, .codex: return "PreToolUse"
            case .claudeStop: return "Stop"
            }
        }

        public var matcher: String? {
            switch self {
            case .claude: return "AskUserQuestion"
            case .codex: return "^request_user_input(_async)?$"
            case .claudeStop: return nil
            }
        }

        /// Appended to the binary path; also how our own entries are recognised later.
        public var arguments: String { "hook \(rawValue)" }
    }

    /// Voice answers can take a while (reading, thinking, speaking); keep well above that.
    public static let timeoutSeconds = 900

    public static func command(binaryPath: String, agent: Agent) -> String {
        "'\(binaryPath.replacingOccurrences(of: "'", with: "'\\''"))' \(agent.arguments)"
    }

    public static func isOurs(_ command: String, agent: Agent) -> Bool {
        command.contains("VoiceQuestion") && command.hasSuffix(agent.arguments)
    }

    public static func isInstalled(in settings: [String: Any], agent: Agent) -> Bool {
        installedCommand(in: settings, agent: agent) != nil
    }

    public static func installedCommand(in settings: [String: Any], agent: Agent) -> String? {
        let groups = ((settings["hooks"] as? [String: Any])?[agent.event] as? [[String: Any]]) ?? []
        for group in groups {
            for hook in (group["hooks"] as? [[String: Any]]) ?? [] {
                if let command = hook["command"] as? String, isOurs(command, agent: agent) { return command }
            }
        }
        return nil
    }

    public static func install(into settings: [String: Any], binaryPath: String, agent: Agent) -> [String: Any] {
        var result = uninstall(from: settings, agent: agent)
        var hooks = (result["hooks"] as? [String: Any]) ?? [:]
        var groups = (hooks[agent.event] as? [[String: Any]]) ?? []
        var group: [String: Any] = [
            "hooks": [[
                "type": "command",
                "command": command(binaryPath: binaryPath, agent: agent),
                "timeout": timeoutSeconds,
            ] as [String: Any]],
        ]
        if let matcher = agent.matcher { group["matcher"] = matcher }
        groups.append(group)
        hooks[agent.event] = groups
        result["hooks"] = hooks
        return result
    }

    public static func uninstall(from settings: [String: Any], agent: Agent) -> [String: Any] {
        var result = settings
        guard var hooks = result["hooks"] as? [String: Any], let groups = hooks[agent.event] as? [[String: Any]] else { return result }

        var kept: [[String: Any]] = []
        for var group in groups {
            guard let entries = group["hooks"] as? [[String: Any]] else {
                kept.append(group)
                continue
            }
            let remaining = entries.filter { !isOurs(($0["command"] as? String) ?? "", agent: agent) }
            if remaining.count == entries.count {
                kept.append(group)
            } else if !remaining.isEmpty {
                group["hooks"] = remaining
                kept.append(group)
            }
        }
        if kept.isEmpty {
            hooks.removeValue(forKey: agent.event)
        } else {
            hooks[agent.event] = kept
        }
        if hooks.isEmpty {
            result.removeValue(forKey: "hooks")
        } else {
            result["hooks"] = hooks
        }
        return result
    }

    // MARK: - Files

    public enum FileError: Error, CustomStringConvertible {
        case notAnObject(String)
        case unreadable(String)

        public var description: String {
            switch self {
            case .notAnObject(let path): return "\(path) is not a JSON object; left untouched"
            case .unreadable(let path): return "\(path) could not be parsed as JSON; left untouched"
            }
        }
    }

    /// A missing or empty file reads as `{}`. Anything unparseable throws, so it is never overwritten.
    public static func read(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              !(String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw FileError.unreadable(url.path) }
        guard let dictionary = object as? [String: Any] else { throw FileError.notAnObject(url.path) }
        return dictionary
    }

    /// Writes atomically, keeping the previous content next to it as `<name>.voicequestion.bak`.
    public static func write(_ settings: [String: Any], to url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("voicequestion.bak")
            try? manager.removeItem(at: backup)
            try manager.copyItem(at: url, to: backup)
        }
        var data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }
}
