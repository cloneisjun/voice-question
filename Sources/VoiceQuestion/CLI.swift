import AppKit
import AVFoundation
import VQCore

/// Everything the binary does when it is not the menu-bar app: the agent hooks and the commands.
enum CLI {

    static let usage = """
    VoiceQuestion \(VQ.version) — hear an AI agent's question, answer it by voice.

    USAGE
      VoiceQuestion                      Run the menu-bar app (normally started at login).
      VoiceQuestion test                 Ask a sample question through the running app.
      VoiceQuestion ask --question TEXT [--option LABEL]... [--multi] [--header TEXT]
                        [--simulate TRANSCRIPT] [--json]
                                         Ask your own question. Exit 0 answered, 2 skipped, 1 error.
      VoiceQuestion status [--json]      What the running app sees.
      VoiceQuestion doctor               Check permissions, Wispr Flow and the installed hooks.
      VoiceQuestion miccheck             Measure the microphone level for three seconds.
      VoiceQuestion tts status           Show the selected TTS engine and neural voices.
      VoiceQuestion tts use system|edge|qwen  Select system, online or local neural TTS.
      VoiceQuestion tts preview [--language ko|en] [--voice VOICE] [--text TEXT] [--output FILE]
                                         Preview TTS only (never opens a microphone).
      VoiceQuestion hooks install [--settings FILE]... [--codex]
      VoiceQuestion hooks uninstall [--settings FILE]... [--codex]
      VoiceQuestion hooks status [--settings FILE]...
      VoiceQuestion hook claude|claude-stop|codex
                                         The hooks themselves (they read the hook JSON on stdin).

    ENVIRONMENT
      VQ_DISABLE=1                 Hooks do nothing (the agent shows its own dialog).
      VQ_SIMULATE_TRANSCRIPT=TEXT  Skip all audio and answer with TEXT ("a|b" for several questions).
      VQ_SOCKET, VQ_CONFIG, VQ_LOG Relocate the socket, settings and log (test instances).
    """

    static func run(_ arguments: [String]) -> Never {
        var rest = arguments
        let command = rest.removeFirst()
        switch command {
        case "hook": hook(rest)
        case "ask": ask(rest)
        case "test": test()
        case "status": status(json: rest.contains("--json"))
        case "doctor": doctor()
        case "miccheck": micCheck()
        case "tts": tts(rest)
        case "hooks": hooks(rest)
        case "--version", "-v", "version":
            print(VQ.version)
            exit(0)
        case "--help", "-h", "help":
            print(usage)
            exit(0)
        default:
            printError("unknown command: \(command)\n\n\(usage)")
            exit(64)
        }
    }

    // MARK: - Hooks (called by the agents)

    /// A hook must never get in the agent's way: on any problem it prints nothing and exits 0,
    /// which leaves the agent's own question dialog in place.
    private static func hook(_ arguments: [String]) -> Never {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard VQ.environment("VQ_DISABLE") != "1", IPCClient.isAppRunning() else { exit(0) }
        let simulated = VQ.environment("VQ_SIMULATE_TRANSCRIPT").map { $0.components(separatedBy: "|") }
        // Stay inside the hook timeout the installer sets, so the agent never has to kill us.
        let timeout = TimeInterval(HookSettings.timeoutSeconds - 20)

        switch arguments.first {
        case "claude":
            guard let parsed = ClaudeHook.parse(input), parsed.toolName == "AskUserQuestion",
                  let response = IPCClient.ask(ClaudeHook.request(from: parsed, simulateTranscripts: simulated), timeout: timeout),
                  response.status == .answered,
                  let output = ClaudeHook.output(for: parsed, answers: response.answers) else { exit(0) }
            print(output)
        case "claude-stop":
            guard let parsed = ClaudeNextStep.parse(input),
                  let size = (try? FileManager.default.attributesOfItem(atPath: parsed.transcriptPath))?[.size] as? UInt64,
                  let transcript = ClaudeNextStep.transcriptTail(atPath: parsed.transcriptPath),
                  let pending = ClaudeNextStep.pendingAsk(inTranscript: transcript) else { exit(0) }
            exitOnUserMessage(transcriptPath: parsed.transcriptPath, after: size)
            guard let response = IPCClient.ask(ClaudeNextStep.request(from: parsed, ask: pending, simulateTranscripts: simulated), timeout: timeout),
                  response.status == .answered,
                  let output = ClaudeNextStep.output(for: pending, answers: response.answers) else { exit(0) }
            print(output)
        case "codex":
            guard let parsed = CodexHook.parse(input), CodexHook.toolNames.contains(parsed.toolName),
                  let response = IPCClient.ask(CodexHook.request(from: parsed, simulateTranscripts: simulated), timeout: timeout),
                  response.status == .answered,
                  let output = CodexHook.output(answers: response.answers) else { exit(0) }
            print(output)
        default:
            break
        }
        exit(0)
    }

    /// Ends the hook once the user replies in the app instead (a clicked button, a typed message).
    /// The app notices the hook is gone and drops the question.
    private static func exitOnUserMessage(transcriptPath: String, after size: UInt64) {
        Thread.detachNewThread {
            var offset = size
            while true {
                Thread.sleep(forTimeInterval: 0.5)
                guard let added = ClaudeNextStep.transcriptLines(atPath: transcriptPath, after: offset) else { continue }
                if ClaudeNextStep.hasUserMessage(inTranscript: added.text) { exit(0) }
                offset = added.end
            }
        }
    }

    // MARK: - Commands

    private static func requireApp() {
        guard !IPCClient.isAppRunning() else { return }
        printError(L("VoiceQuestion 앱이 실행 중이 아닙니다. ~/Applications/VoiceQuestion.app 을 열어 주세요.",
                     "The VoiceQuestion app is not running. Open ~/Applications/VoiceQuestion.app first."))
        exit(1)
    }

    private static func value(after flag: String, in arguments: [String]) -> [String] {
        arguments.indices.filter { arguments[$0] == flag && $0 + 1 < arguments.count }.map { arguments[$0 + 1] }
    }

    private static func ask(_ arguments: [String]) -> Never {
        guard let text = value(after: "--question", in: arguments).first else {
            printError("ask: --question is required")
            exit(64)
        }
        let question = Question(question: text, header: value(after: "--header", in: arguments).first,
                                options: value(after: "--option", in: arguments).map { QuestionOption(label: $0) },
                                multiSelect: arguments.contains("--multi"))
        let simulated = value(after: "--simulate", in: arguments).first.map { [$0] }
            ?? VQ.environment("VQ_SIMULATE_TRANSCRIPT").map { $0.components(separatedBy: "|") }
        finish(AskRequest(id: "cli-\(UUID().uuidString.prefix(8))", source: .cli, questions: [question], simulateTranscripts: simulated),
               json: arguments.contains("--json"))
    }

    private static func test() -> Never {
        var request = AppDelegate.demoRequest
        request.simulateTranscripts = VQ.environment("VQ_SIMULATE_TRANSCRIPT").map { $0.components(separatedBy: "|") }
        finish(request, json: false)
    }

    private static func finish(_ request: AskRequest, json: Bool) -> Never {
        requireApp()
        guard let response = IPCClient.ask(request) else {
            printError("no response from the app")
            exit(1)
        }
        if json {
            print(String(data: (try? VQ.encoder(pretty: true).encode(response)) ?? Data(), encoding: .utf8) ?? "{}")
        } else if response.status == .answered {
            response.answers.forEach { print($0.answer) }
        } else {
            printError("\(response.status.rawValue): \(response.reason ?? "-")")
        }
        exit(response.status == .answered ? 0 : (response.status == .skipped ? 2 : 1))
    }

    private static func status(json: Bool) -> Never {
        requireApp()
        guard let report = IPCClient.status() else {
            printError("no response from the app")
            exit(1)
        }
        if json {
            print(String(data: (try? VQ.encoder(pretty: true).encode(report)) ?? Data(), encoding: .utf8) ?? "{}")
        } else {
            print("""
            VoiceQuestion \(report.version)  \(report.enabled ? "enabled" : "PAUSED")\(report.busy ? "  (asking a question now)" : "")
              microphone permission : \(report.microphonePermission)
              accessibility         : \(report.accessibilityTrusted ? "granted" : "not granted (only needed for deliver=paste)")
              Wispr Flow            : \(report.wisprInstalled ? (report.wisprRunning ? "running" : "installed, not running") : "not installed")
              ChatGPT watcher       : \(report.watchers["codex"] ?? "-")
              Aside watcher         : \(report.watchers["aside"] ?? "-")
            """)
        }
        exit(0)
    }

    private static func micCheck() -> Never {
        requireApp()
        print(L("3초 동안 마이크 레벨을 잽니다. 평소처럼 한두 마디 말해 보세요…", "Measuring the microphone for three seconds. Say a few words…"))
        guard let data = IPCClient.send(IPCRequest(cmd: "miccheck"), timeout: 12),
              let report = try? JSONDecoder().decode(MicCheckReport.self, from: data) else {
            printError("no response from the app")
            exit(1)
        }
        guard report.samples > 0 else {
            print(L("마이크를 읽지 못했습니다 (권한: \(report.permission)). 메뉴 막대 아이콘 → ‘마이크 권한 요청…’ 을 눌러 주세요.",
                    "Could not read the microphone (permission: \(report.permission)). Use the menu-bar icon → “Request microphone access…”."))
            exit(1)
        }
        func db(_ value: Double?) -> String { value.map { String(format: "%.1f dBFS", $0) } ?? "-" }
        print("""
          device            : \(report.device ?? "-")
          quietest / loudest: \(db(report.minDb)) / \(db(report.maxDb))
          average           : \(db(report.averageDb))
          speech threshold  : \(db(report.speechThresholdDb))  (louder than this counts as speech)
        """)
        exit(0)
    }

    private static func doctor() -> Never {
        var problems = 0
        func check(_ ok: Bool, _ title: String, _ detail: String = "") {
            if !ok { problems += 1 }
            print("\(ok ? "✓" : "✗") \(title)\(detail.isEmpty ? "" : " — \(detail)")")
        }
        func note(_ title: String, _ detail: String) {
            print("· \(title) — \(detail)")
        }

        let report = IPCClient.status()
        check(report != nil, L("앱 실행 중", "App running"), report == nil ? VQ.socketPath : "")
        if let report {
            check(report.enabled, L("켜져 있음", "Enabled"), report.enabled ? "" : L("메뉴 막대에서 ‘다시 켜기’", "use Resume in the menu bar"))
            check(report.microphonePermission == "granted", L("마이크 권한", "Microphone permission"),
                  report.microphonePermission == "granted" ? "" : L("\(report.microphonePermission): 없으면 말이 끝난 것을 자동으로 알 수 없어 Enter 로 마쳐야 합니다",
                                                                    "\(report.microphonePermission): without it the end of your answer is not detected; finish with Return"))
            check(report.wisprInstalled && report.wisprRunning, "Wispr Flow",
                  report.wisprInstalled ? (report.wisprRunning ? "" : L("실행 중이 아님", "not running")) : L("설치되지 않음", "not installed"))
            note(L("손쉬운 사용 권한", "Accessibility"), report.accessibilityTrusted ? "granted" : L("없음 (deliver=paste 실험 기능에만 필요)", "not granted (only for deliver=paste)"))
            note("ChatGPT / Aside", "\(report.watchers["codex"] ?? "-") / \(report.watchers["aside"] ?? "-")")
        }
        note(L("소리 출력", "Sound output"), (AudioSystem.outputName() ?? "-") + (AudioSystem.outputIsPrivate()
            ? L(" (이어폰: 질문과 동시에 마이크 켜짐)", " (headphones: microphone opens with the question)")
            : L(" (스피커: 질문이 끝난 뒤 마이크 켜짐)", " (speakers: microphone opens after the question)")))

        let claudeSettings = try? HookSettings.read(defaultClaudeSettings())
        let claude = claudeSettings.flatMap { HookSettings.installedCommand(in: $0, agent: .claude) }
        check(claude != nil, L("Claude Code 훅", "Claude Code hook"), claude ?? L("없음: VoiceQuestion hooks install", "missing: VoiceQuestion hooks install"))
        if let claude, let path = binaryPath(inCommand: claude) {
            check(FileManager.default.isExecutableFile(atPath: path), L("훅 실행 파일", "Hook binary"), path)
        }
        let nextStep = claudeSettings.flatMap { HookSettings.installedCommand(in: $0, agent: .claudeStop) }
        check(nextStep != nil, L("Claude 다음 단계 상자 훅", "Claude next-step box hook"),
              nextStep ?? L("없음: VoiceQuestion hooks install", "missing: VoiceQuestion hooks install"))
        let codex = (try? HookSettings.read(codexHooksFile())).flatMap { HookSettings.installedCommand(in: $0, agent: .codex) }
        note(L("Codex 훅 (실험)", "Codex hook (experimental)"), codex ?? L("설치 안 됨 (세션 로그 감시로 동작)", "not installed (the session-log watcher is used)"))
        note(L("설정 / 로그", "Settings / log"), "\(VQ.configURL.path) / \(VQ.logURL.path)")
        exit(problems == 0 ? 0 : 1)
    }

    // MARK: - Hook installation

    static func voicePreviewText(_ language: String) -> String {
        language.hasPrefix("ko")
            ? "안녕하세요. 어떤 음성이 더 편하게 들리시나요? 원하는 선택지를 눌러 주세요."
            : "Hello. Which voice feels more natural to you? Choose the option you prefer."
    }

    private static func tts(_ arguments: [String]) -> Never {
        var config = VQConfig.load()
        switch arguments.first {
        case "status":
            print("engine: \(config.tts.engine.rawValue)")
            print("runtime: \(config.tts.runtimeAvailable ? "ready" : "not installed")")
            let voices = config.tts.engine == .qwen ? config.tts.qwen.voices : config.tts.voices
            for language in voices.keys.sorted() { print("\(language): \(voices[language]!)") }
            exit(0)
        case "use":
            guard arguments.count == 2, let engine = VQConfig.TTS.Engine(rawValue: arguments[1]) else {
                printError("tts use: expected system, edge or qwen")
                exit(64)
            }
            config.tts.engine = engine
            guard config.tts.runtimeAvailable else {
                printError(engine == .qwen ? "Install local voices first: ./scripts/setup-qwen-tts.sh" : "Install online voices first: ./scripts/setup-neural-tts.sh")
                exit(1)
            }
            guard config.save() else { printError("could not save settings"); exit(1) }
            print(engine == .edge ? "Online neural TTS selected. Question text is sent to Microsoft for speech synthesis."
                  : "Offline \(engine.rawValue) TTS selected. Question text stays on this Mac.")
            exit(0)
        case "preview":
            guard IPCClient.status()?.busy != true else { printError("Wait for the current question to finish."); exit(1) }
            let language = value(after: "--language", in: arguments).first ?? "ko"
            let text = value(after: "--text", in: arguments).first ?? voicePreviewText(language)
            if let voice = value(after: "--voice", in: arguments).first {
                guard config.tts.engine != .system else { printError("--voice requires edge or qwen TTS."); exit(64) }
                // Preview another voice without changing the user's saved settings.
                if config.tts.engine == .qwen { config.tts.qwen.voices[language] = voice }
                else { config.tts.voices[language] = voice }
            }
            if let path = value(after: "--output", in: arguments).first {
                guard config.tts.engine != .system, let voice = config.tts.voice(for: language) else {
                    printError("Export requires edge or qwen TTS and a configured voice for \(language).")
                    exit(1)
                }
                let target = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                guard config.tts.engine != .qwen || target.pathExtension.lowercased() == "wav" else {
                    printError("Local Qwen exports WAV audio; use an output ending in .wav.")
                    exit(64)
                }
                guard !FileManager.default.fileExists(atPath: target.path) else {
                    printError("Output already exists: \(target.path)")
                    exit(1)
                }
                let renderer = NeuralSpeechRenderer()
                var done = false
                var succeeded = false
                renderer.render(text, voice: voice, rate: config.speechRate, settings: config.tts, language: language) { result in
                    defer { done = true }
                    if case .success(let url) = result {
                        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                        do {
                            let audio = try AVAudioPlayer(contentsOf: url)
                            guard audio.duration > 0 else { throw NeuralSpeechRenderer.Failure.failed }
                            try FileManager.default.copyItem(at: url, to: target)
                            print("\(target.path) (\(String(format: "%.2f", audio.duration)) seconds, \(voice)\(config.tts.engine == .qwen ? ", WAV at native speed; app uses speechRate" : ""))")
                            succeeded = true
                        } catch { printError("Could not export a valid audio file.") }
                    } else { printError("Synthesis failed or timed out. No preview exported.") }
                }
                while !done { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
                exit(succeeded ? 0 : 1)
            }
            let speaker = Speaker()
            var done = false
            speaker.speak(text, language: language, rate: config.speechRate, volume: config.speechVolume,
                          voiceIdentifier: config.voices[language], settings: config.tts) { done = true }
            while !done { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            Log.flush()
            exit(0)
        default:
            printError("tts: expected status, use system|edge|qwen, or preview [--language ko|en] [--voice VOICE] [--text TEXT] [--output FILE]")
            exit(64)
        }
    }

    private static func defaultClaudeSettings() -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
    }

    private static func codexHooksFile() -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/hooks.json")
    }

    /// `'/path/to/VoiceQuestion' hook claude` → `/path/to/VoiceQuestion`.
    private static func binaryPath(inCommand command: String) -> String? {
        guard command.hasPrefix("'"), let end = command.dropFirst().firstIndex(of: "'") else { return nil }
        return String(command[command.index(after: command.startIndex)..<end])
    }

    private static func hooks(_ arguments: [String]) -> Never {
        let explicit = value(after: "--settings", in: arguments).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        var targets: [(url: URL, agents: [HookSettings.Agent])] = (explicit.isEmpty ? [defaultClaudeSettings()] : explicit)
            .map { ($0, HookSettings.Agent.claudeHooks) }
        if arguments.contains("--codex") { targets.append((codexHooksFile(), [.codex])) }
        let binary = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath().path

        var failed = false
        switch arguments.first {
        case "install":
            for target in targets {
                do {
                    let current = try HookSettings.read(target.url)
                    let updated = target.agents.reduce(current) { HookSettings.install(into: $0, binaryPath: binary, agent: $1) }
                    try HookSettings.write(updated, to: target.url)
                    target.agents.forEach { print("installed \($0.rawValue) hook → \(target.url.path)") }
                } catch {
                    failed = true
                    printError("\(target.url.path): \(error)")
                }
            }
            if targets.contains(where: { $0.agents.contains(.codex) }) {
                print(L("Codex 훅은 ChatGPT 앱에서 ‘신뢰’를 눌러야 실행됩니다 (설정 → Hooks).",
                        "The Codex hook only runs once you trust it in the ChatGPT app (Settings → Hooks)."))
            }
        case "uninstall":
            for target in targets {
                do {
                    let current = try HookSettings.read(target.url)
                    let installed = target.agents.filter { HookSettings.isInstalled(in: current, agent: $0) }
                    target.agents.filter { !installed.contains($0) }.forEach { print("no \($0.rawValue) hook in \(target.url.path)") }
                    guard !installed.isEmpty else { continue }
                    try HookSettings.write(installed.reduce(current) { HookSettings.uninstall(from: $0, agent: $1) }, to: target.url)
                    installed.forEach { print("removed \($0.rawValue) hook ← \(target.url.path)") }
                } catch {
                    failed = true
                    printError("\(target.url.path): \(error)")
                }
            }
        case "status":
            if !arguments.contains("--codex") { targets.append((codexHooksFile(), [.codex])) }
            for target in targets {
                let settings = try? HookSettings.read(target.url)
                for agent in target.agents {
                    let command = settings.flatMap { HookSettings.installedCommand(in: $0, agent: agent) }
                    print("\(agent.rawValue)  \(target.url.path)\n    \(command ?? "not installed")")
                }
            }
        default:
            printError("hooks: expected install, uninstall or status")
            exit(64)
        }
        exit(failed ? 1 : 0)
    }
}
