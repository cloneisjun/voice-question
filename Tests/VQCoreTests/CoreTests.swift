import Foundation
import SQLite3
import Testing
@testable import VQCore

// MARK: - Voice activity

/// Feeds a constant level for `seconds` at 50 Hz and returns every event raised.
private func feed(_ detector: inout VoiceActivityDetector, level: Double, seconds: Double, from start: inout Double) -> [VoiceActivityDetector.Event] {
    var events: [VoiceActivityDetector.Event] = []
    let end = start + seconds
    while start < end {
        if let event = detector.feed(levelDb: level, at: start) { events.append(event) }
        start += 0.02
    }
    return events
}

@Test func speechThenSilenceEndsTheAnswer() {
    var detector = VoiceActivityDetector(settings: .init(endSilenceSeconds: 1.5))
    var clock = 0.0
    #expect(feed(&detector, level: -62, seconds: 1.0, from: &clock).isEmpty)
    detector.arm(at: clock)
    #expect(feed(&detector, level: -20, seconds: 1.2, from: &clock) == [.speechStarted])
    // A short pause between sentences is not the end.
    #expect(feed(&detector, level: -62, seconds: 0.8, from: &clock).isEmpty)
    #expect(feed(&detector, level: -22, seconds: 0.6, from: &clock).isEmpty)
    let tail = feed(&detector, level: -62, seconds: 2.0, from: &clock)
    #expect(tail == [.endOfSpeech])
    #expect(detector.finished)
    // Nothing more after it has finished.
    #expect(feed(&detector, level: -20, seconds: 1.0, from: &clock).isEmpty)
}

@Test func noSpeechTimesOutOnlyOnceArmed() {
    var detector = VoiceActivityDetector(settings: .init(noSpeechTimeoutSeconds: 3))
    var clock = 0.0
    // While the question is still being read out the clock does not run.
    #expect(feed(&detector, level: -60, seconds: 5.0, from: &clock).isEmpty)
    detector.arm(at: clock)
    #expect(feed(&detector, level: -60, seconds: 2.5, from: &clock).isEmpty)
    #expect(feed(&detector, level: -60, seconds: 1.0, from: &clock) == [.noSpeechTimeout])
}

@Test func shortNoisesAreNotSpeech() {
    var detector = VoiceActivityDetector(settings: .init(minSpeechSeconds: 0.25))
    var clock = 0.0
    _ = feed(&detector, level: -60, seconds: 0.5, from: &clock)
    // A key click: 100 ms of loud input.
    #expect(feed(&detector, level: -15, seconds: 0.1, from: &clock).isEmpty)
    #expect(feed(&detector, level: -60, seconds: 0.5, from: &clock).isEmpty)
    #expect(!detector.hasSpeech)
}

@Test func thresholdAdaptsToTheRoom() {
    var quiet = VoiceActivityDetector()
    var clock = 0.0
    _ = feed(&quiet, level: -70, seconds: 1.0, from: &clock)
    #expect(quiet.thresholdDb == -50) // clamped to the lower bound

    var noisy = VoiceActivityDetector()
    clock = 0.0
    _ = feed(&noisy, level: -42, seconds: 1.0, from: &clock)
    #expect(abs(noisy.thresholdDb - -32) < 0.5) // floor + 10 dB margin
    // Speech has to clear the raised threshold.
    #expect(feed(&noisy, level: -36, seconds: 1.0, from: &clock).isEmpty)
    #expect(feed(&noisy, level: -20, seconds: 1.0, from: &clock) == [.speechStarted])

    var fixed = VoiceActivityDetector(settings: .init(speechThresholdDb: -30))
    clock = 0.0
    _ = feed(&fixed, level: -70, seconds: 1.0, from: &clock)
    #expect(fixed.thresholdDb == -30)
}

@Test func longAnswersHitTheCap() {
    var detector = VoiceActivityDetector(settings: .init(maxAnswerSeconds: 5))
    var clock = 0.0
    _ = feed(&detector, level: -60, seconds: 0.5, from: &clock)
    let events = feed(&detector, level: -18, seconds: 7.0, from: &clock)
    #expect(events == [.speechStarted, .maxDuration])
}

// MARK: - Config

@Test func configDefaultsAndPartialFiles() throws {
    let defaults = VQConfig()
    #expect(defaults.enabled)
    #expect(defaults.micStart == .auto)
    #expect(defaults.codex.deliver == "clipboard")

    let partial = #"{"micStart":"afterSpeech","autoSendDelaySeconds":0,"vad":{"endSilenceSeconds":2.5},"codex":{"deliver":"paste"},"unknownKey":1}"#
    let config = try JSONDecoder().decode(VQConfig.self, from: Data(partial.utf8))
    #expect(config.micStart == .afterSpeech)
    #expect(config.autoSendDelaySeconds == 0)
    #expect(config.vad.endSilenceSeconds == 2.5)
    #expect(config.vad.noSpeechTimeoutSeconds == 12) // untouched default
    #expect(config.codex.deliver == "paste")
    #expect(config.codex.enabled)
    #expect(config.aside.deliver == "clipboard")

    // A wrong type falls back to the default instead of discarding the whole file.
    let wrong = try JSONDecoder().decode(VQConfig.self, from: Data(#"{"micStart":"sometimes","speechRate":"fast","enabled":false}"#.utf8))
    #expect(wrong.micStart == .auto)
    #expect(wrong.speechRate == 1.0)
    #expect(!wrong.enabled)
}

@Test func configRoundTripsThroughDisk() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vq-config-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.json")

    #expect(VQConfig.load(from: url) == VQConfig()) // missing file
    #expect(VQConfig.writeDefaultsIfMissing(to: url))
    #expect(!VQConfig.writeDefaultsIfMissing(to: url))

    var changed = VQConfig()
    changed.enabled = false
    changed.vad.speechThresholdDb = -33
    changed.voices = ["ko": "com.apple.voice.compact.ko-KR.Yuna"]
    #expect(changed.save(to: url))
    #expect(VQConfig.load(from: url) == changed)
}

@Test func ttsDefaultsStayOfflineAndOldSettingsRemainValid() throws {
    let old = try JSONDecoder().decode(VQConfig.self, from: Data(#"{"speechRate":0.9,"voices":{"ko":"mac-voice"}}"#.utf8))
    #expect(old.tts.engine == .system)
    #expect(old.voices["ko"] == "mac-voice")
    #expect(old.tts.voice(for: "ko-KR") == "ko-KR-SunHiNeural")
    #expect(old.tts.voice(for: "fr") == nil) // unsupported online languages stay local
    let partial = try JSONDecoder().decode(VQConfig.self, from: Data(#"{"tts":{"engine":"edge"}}"#.utf8))
    #expect(partial.tts.engine == .edge)
    #expect(partial.tts.timeoutSeconds == 15)
    #expect(partial.tts.voice(for: "en") == "en-US-EmmaMultilingualNeural")
    let malformed = try JSONDecoder().decode(VQConfig.self, from: Data(#"{"tts":{"engine":"missing","timeoutSeconds":"forever"}}"#.utf8))
    #expect(malformed.tts.engine == .system)
    #expect(malformed.tts.timeoutSeconds == 15)
    #expect(try JSONDecoder().decode(VQConfig.self, from: JSONEncoder().encode(partial)) == partial)
}

@Test func qwenSettingsStaySeparateFromOnlineVoices() throws {
    let config = try JSONDecoder().decode(VQConfig.self, from: Data(#"{"tts":{"engine":"qwen","pythonPath":"/edge/python","qwen":{"pythonPath":"/local/python","voices":{"ko":"Sohee"}}}}"#.utf8))
    #expect(config.tts.engine == .qwen)
    #expect(config.tts.resolvedPythonPath == "/local/python")
    #expect(config.tts.voice(for: "ko-KR") == "Sohee")
    #expect(config.tts.voice(for: "fr") == nil)
    #expect(config.tts.qwen.timeoutSeconds == 120)
    let saved = try JSONEncoder().encode(config)
    #expect(try JSONDecoder().decode(VQConfig.self, from: saved) == config)
}

// MARK: - Hook settings

@Test func installKeepsExistingSettings() throws {
    let existing: [String: Any] = [
        "skipWorkflowUsageWarning": true,
        "hooks": [
            "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "/usr/local/bin/audit"]]]],
            "SessionEnd": [["hooks": [["type": "command", "command": "/usr/local/bin/archive", "timeout": 10]]]],
        ],
    ]
    let binary = "/Users/me/Applications/VoiceQuestion.app/Contents/MacOS/VoiceQuestion"
    let installed = HookSettings.install(into: existing, binaryPath: binary, agent: .claude)

    #expect(installed["skipWorkflowUsageWarning"] as? Bool == true)
    let hooks = try #require(installed["hooks"] as? [String: Any])
    #expect((hooks["SessionEnd"] as? [[String: Any]])?.count == 1)
    let groups = try #require(hooks["PreToolUse"] as? [[String: Any]])
    #expect(groups.count == 2)
    #expect(groups[0]["matcher"] as? String == "Bash")
    #expect(groups[1]["matcher"] as? String == "AskUserQuestion")
    let entry = try #require((groups[1]["hooks"] as? [[String: Any]])?.first)
    #expect(entry["command"] as? String == "'\(binary)' hook claude")
    #expect(entry["timeout"] as? Int == 900)
    #expect(HookSettings.isInstalled(in: installed, agent: .claude))
    #expect(!HookSettings.isInstalled(in: installed, agent: .codex))

    // Installing again (say, from a new location) replaces instead of duplicating.
    let moved = HookSettings.install(into: installed, binaryPath: "/Applications/VoiceQuestion.app/Contents/MacOS/VoiceQuestion", agent: .claude)
    let movedGroups = try #require((moved["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
    #expect(movedGroups.count == 2)
    #expect(HookSettings.installedCommand(in: moved, agent: .claude) == "'/Applications/VoiceQuestion.app/Contents/MacOS/VoiceQuestion' hook claude")

    let removed = HookSettings.uninstall(from: moved, agent: .claude)
    let removedHooks = try #require(removed["hooks"] as? [String: Any])
    #expect((removedHooks["PreToolUse"] as? [[String: Any]])?.count == 1)
    #expect((removedHooks["SessionEnd"] as? [[String: Any]])?.count == 1)
    #expect(!HookSettings.isInstalled(in: removed, agent: .claude))
}

@Test func nextStepHookGoesUnderStopWithoutAMatcher() throws {
    let existing: [String: Any] = [
        "hooks": [
            "Stop": [["hooks": [["type": "command", "command": "/usr/local/bin/notify"]]]],
        ],
    ]
    let binary = "/Users/me/Applications/VoiceQuestion.app/Contents/MacOS/VoiceQuestion"
    let installed = HookSettings.Agent.claudeHooks.reduce(existing) { HookSettings.install(into: $0, binaryPath: binary, agent: $1) }

    let hooks = try #require(installed["hooks"] as? [String: Any])
    #expect((hooks["PreToolUse"] as? [[String: Any]])?.count == 1)
    let groups = try #require(hooks["Stop"] as? [[String: Any]])
    #expect(groups.count == 2)
    #expect(groups[1]["matcher"] == nil)
    let entry = try #require((groups[1]["hooks"] as? [[String: Any]])?.first)
    #expect(entry["command"] as? String == "'\(binary)' hook claude-stop")
    #expect(entry["timeout"] as? Int == 900)
    // The two Claude hooks are told apart, so one can be read or removed without the other.
    #expect(HookSettings.installedCommand(in: installed, agent: .claude) == "'\(binary)' hook claude")
    #expect(HookSettings.installedCommand(in: installed, agent: .claudeStop) == "'\(binary)' hook claude-stop")

    let again = HookSettings.install(into: installed, binaryPath: binary, agent: .claudeStop)
    #expect(((again["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.count == 2)

    let withoutStop = HookSettings.uninstall(from: installed, agent: .claudeStop)
    #expect(((withoutStop["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.count == 1)
    #expect(HookSettings.isInstalled(in: withoutStop, agent: .claude))
    #expect(!HookSettings.isInstalled(in: withoutStop, agent: .claudeStop))

    let removed = HookSettings.Agent.claudeHooks.reduce(installed) { HookSettings.uninstall(from: $0, agent: $1) }
    let removedHooks = try #require(removed["hooks"] as? [String: Any])
    #expect(removedHooks["PreToolUse"] == nil)
    #expect((removedHooks["Stop"] as? [[String: Any]])?.count == 1)
}

@Test func uninstallLeavesNoEmptyShells() {
    let installed = HookSettings.install(into: ["skipWorkflowUsageWarning": true], binaryPath: "/x/VoiceQuestion", agent: .claude)
    let removed = HookSettings.uninstall(from: installed, agent: .claude)
    #expect(removed.count == 1)
    #expect(removed["hooks"] == nil)
    #expect(removed["skipWorkflowUsageWarning"] as? Bool == true)
}

@Test func hookFilesAreBackedUpAndNeverClobberedWhenBroken() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vq-hooks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("settings.json")
    #expect(try HookSettings.read(url).isEmpty) // missing file is an empty object
    try Data(#"{"model":"opus"}"#.utf8).write(to: url)
    let updated = HookSettings.install(into: try HookSettings.read(url), binaryPath: "/x/VoiceQuestion", agent: .codex)
    try HookSettings.write(updated, to: url)
    #expect(try HookSettings.read(url)["model"] as? String == "opus")
    #expect(HookSettings.isInstalled(in: try HookSettings.read(url), agent: .codex))
    let backup = try String(contentsOf: url.appendingPathExtension("voicequestion.bak"), encoding: .utf8)
    #expect(backup == #"{"model":"opus"}"#)

    let broken = directory.appendingPathComponent("broken.json")
    try Data("{ this is not json".utf8).write(to: broken)
    #expect(throws: HookSettings.FileError.self) { try HookSettings.read(broken) }
}

// MARK: - Spoken text

@Test func spokenTextReadsQuestionAndOptions() {
    let question = Question(question: "어떤 카드로 결제할까요", options: [QuestionOption(label: "신용카드", description: "할부 가능"), QuestionOption(label: "체크카드")])
    #expect(SpokenText.build(question: question, index: 0, total: 1, language: "ko") == "어떤 카드로 결제할까요. 일 번, 신용카드. 이 번, 체크카드.")
    #expect(SpokenText.build(question: question, index: 0, total: 1, language: "ko", speakOptions: false) == "어떤 카드로 결제할까요.")
    #expect(SpokenText.build(question: question, index: 1, total: 2, language: "ko", speakDescriptions: true)
        == "질문 2. 어떤 카드로 결제할까요. 일 번, 신용카드, 할부 가능. 이 번, 체크카드.")

    let english = Question(question: "Which frameworks?", options: [QuestionOption(label: "React"), QuestionOption(label: "Vue")], multiSelect: true)
    #expect(SpokenText.build(question: english, index: 0, total: 1, language: "en") == "Which frameworks? 1: React. 2: Vue. You can pick more than one.")
}

@Test func koreanOptionNumbersArePositionsRatherThanCounts() {
    let options = (1...12).map { QuestionOption(label: "항목 \($0)") }
    let question = Question(question: "어느 항목인가요?", options: options)
    let text = SpokenText.build(question: question, index: 0, total: 1, language: "ko")
    #expect(text.contains("일 번, 항목 1. 이 번, 항목 2. 삼 번, 항목 3."))
    #expect(text.contains("구 번, 항목 9. 십 번, 항목 10. 십일 번, 항목 11. 십이 번, 항목 12."))
    // Only generated numbering changes. The question, answer labels and matching stay intact.
    #expect(question.options[0].label == "항목 1")
    #expect(!text.contains("1번"))
}

@Test func spokenTextDropsMarkdownAndLinks() {
    #expect(SpokenText.clean("**Deploy** `main` to [production](https://example.com/deploy)?") == "Deploy main to production?")
    #expect(SpokenText.clean("See https://example.com/a/b for details") == "See for details")
    #expect(SpokenText.clean("## Title\n\n> quoted") == "Title quoted")
}

@Test func languageDetection() {
    #expect(SpokenText.language(of: "어떤 카드로 결제할까요? 신용카드와 체크카드 중에서 골라 주세요.") == "ko")
    #expect(SpokenText.language(of: "Which database should the new service use for its primary storage?") == "en")
}

// MARK: - Wispr history

@Test func wisprTimestampFormat() {
    // 2026-11-15 15:39:10.099 UTC
    let date = Date(timeIntervalSince1970: 1_794_757_150.099)
    #expect(WisprHistory.timestampString(date) == "2026-11-15 15:39:10.099 +00:00")
    #expect(WisprHistory.rows(since: date, path: "/nonexistent/flow.sqlite").isEmpty)
}

@Test func wisprHistoryRows() throws {
    let path = NSTemporaryDirectory() + "vq-test-\(UUID().uuidString.prefix(8)).sqlite"
    defer { try? FileManager.default.removeItem(atPath: path) }
    var database: OpaquePointer?
    #expect(sqlite3_open(path, &database) == SQLITE_OK)
    let setup = """
    CREATE TABLE History (transcriptEntityId TEXT, timestamp TEXT, status TEXT, asrText TEXT, formattedText TEXT, pastedText TEXT);
    INSERT INTO History VALUES ('old', '2026-11-15 15:39:00.000 +00:00', 'formatted', 'before', 'Before.', 'Before. ');
    INSERT INTO History VALUES ('a', '2026-11-15 15:39:11.000 +00:00', 'formatted', 'blue please', 'Blue, please.', 'Blue, please. ');
    INSERT INTO History VALUES ('b', '2026-11-15 15:39:12.000 +00:00', 'raw_transcript', 'raw words', '', '');
    INSERT INTO History VALUES ('c', '2026-11-15 15:39:13.000 +00:00', 'raw_transcript', '', '', '');
    INSERT INTO History VALUES ('d', '2026-11-15 15:39:14.000 +00:00', 'processing', 'half', NULL, NULL);
    INSERT INTO History VALUES ('e', '2026-11-15 15:39:15.000 +00:00', NULL, NULL, NULL, NULL);
    """
    #expect(sqlite3_exec(database, setup, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(database)

    let rows = WisprHistory.rows(since: Date(timeIntervalSince1970: 1_794_757_150.099), path: path, limit: 10)
    #expect(rows.map(\.id) == ["e", "d", "c", "b", "a"]) // newest first, nothing from before the dictation
    #expect(rows.map(\.isFinal) == [false, false, true, true, true])
    #expect(rows.map(\.text) == ["", "half", "", "raw words", "Blue, please."])
}

// MARK: - IPC

@Test func socketRoundTrip() throws {
    let path = "/tmp/vq-test-\(UUID().uuidString.prefix(8)).sock"
    let server = SocketServer(path: path) { connection in
        defer { connection.close() }
        guard let line = connection.readLine(timeout: 5), let data = line.data(using: .utf8),
              let request = try? JSONDecoder().decode(IPCRequest.self, from: data) else { return }
        if request.cmd == "ask", let ask = request.request {
            let answers = ask.questions.map {
                AnsweredQuestion(question: $0.question, answer: ask.simulateTranscripts?.first ?? "", transcript: "t", kind: .freeText, selectedLabels: [])
            }
            connection.writeLine(VQ.encodeLine(AskResponse(status: .answered, answers: answers)))
        } else {
            connection.writeLine(VQ.encodeLine(AskResponse.skipped("unknown")))
        }
    }
    try server.start()
    defer { server.stop() }

    #expect(IPCClient.isAppRunning(path: path))
    let request = AskRequest(id: "r1", source: .cli, questions: [Question(question: "이름이 뭐예요?")], simulateTranscripts: ["보이스 퀘스천"])
    let response = try #require(IPCClient.ask(request, path: path, timeout: 5))
    #expect(response.status == .answered)
    #expect(response.answers.first?.answer == "보이스 퀘스천")

    // A second server on the same path must refuse to start.
    let second = SocketServer(path: path) { $0.close() }
    #expect(throws: SocketServer.ServerError.self) { try second.start() }

    server.stop()
    #expect(!IPCClient.isAppRunning(path: path))
    #expect(IPCClient.ask(request, path: path, timeout: 1) == nil)
}
