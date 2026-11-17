import AppKit
import ApplicationServices
import VQCore

/// What `VoiceQuestion miccheck` reports: a few seconds of microphone levels as the app hears them.
struct MicCheckReport: Codable {
    var permission: String
    var device: String?
    var samples: Int
    var minDb: Double?
    var maxDb: Double?
    var averageDb: Double?
    /// The level above which sound would count as speech in this room.
    var speechThresholdDb: Double?
}

/// The menu-bar agent: listens on the socket for hooks and the CLI, and runs the watchers.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let coordinator = SessionCoordinator()
    private var server: SocketServer?
    private var codexWatcher: CodexWatcher?
    private var asideWatcher: AsideWatcher?
    private var statusItem: NSStatusItem?
    private var micCheck: MicLevelMonitor?
    /// A test instance (`VQ_HEADLESS=1`) shows no menu-bar item and never prompts for permissions.
    private let headless = VQ.environment("VQ_HEADLESS") == "1"

    static var demoRequest: AskRequest {
        // In Korean for anyone who lists Korean at all, even with the system in another language:
        // the sample should be answered in the language you actually speak to your agents.
        let korean = Locale.preferredLanguages.contains { $0.hasPrefix("ko") }
        func text(_ ko: String, _ en: String) -> String { korean ? ko : en }
        let question = Question(question: text("테스트 질문입니다. 오늘 점심으로 무엇을 드시겠어요?", "This is a test. What would you like for lunch?"),
                                header: text("테스트", "Test"),
                                options: [QuestionOption(label: text("김치찌개", "Sushi")), QuestionOption(label: text("파스타", "Pasta")),
                                          QuestionOption(label: text("샐러드", "Salad"))])
        return AskRequest(id: "demo-\(UUID().uuidString.prefix(8))", source: .cli, title: text("테스트", "Test"), questions: [question])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        VQConfig.writeDefaultsIfMissing()
        Log.info("app: VoiceQuestion \(VQ.version) started (pid \(getpid()), socket \(VQ.socketPath))")

        let server = SocketServer(path: VQ.socketPath) { [weak self] connection in self?.serve(connection) }
        do {
            try server.start()
            self.server = server
        } catch SocketServer.ServerError.alreadyRunning {
            Log.info("app: another instance is already running; exiting")
            Log.flush()
            exit(0)
        } catch {
            Log.info("app: could not listen on \(VQ.socketPath): \(error)")
            Log.flush()
            exit(1)
        }

        let config = VQConfig.load()
        if config.codex.enabled {
            codexWatcher = CodexWatcher(coordinator: coordinator)
            codexWatcher?.start()
        }
        if config.aside.enabled {
            asideWatcher = AsideWatcher(coordinator: coordinator)
            asideWatcher?.start()
        }

        guard !headless else { return }
        setUpStatusItem()
        coordinator.onChange = { [weak self] in self?.updateIcon() }
        if MicLevelMonitor.permission == .notDetermined {
            MicLevelMonitor.requestPermission { granted in Log.info("app: microphone permission \(granted ? "granted" : "denied")") }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        Log.info("app: quit")
        Log.flush()
    }

    // MARK: - Socket

    private final class ResponseBox {
        private let lock = NSLock()
        private var stored: AskResponse?
        var value: AskResponse? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    /// Runs on a thread of its own per connection.
    private func serve(_ connection: SocketConnection) {
        defer { connection.close() }
        guard let line = connection.readLine(timeout: 5), let data = line.data(using: .utf8),
              let message = try? JSONDecoder().decode(IPCRequest.self, from: data) else { return }

        switch message.cmd {
        case "status":
            let report = DispatchQueue.main.sync { self.statusReport() }
            connection.writeLine(VQ.encodeLine(report))

        case "miccheck":
            let semaphore = DispatchSemaphore(value: 0)
            var report = MicCheckReport(permission: MicLevelMonitor.permissionName, samples: 0)
            DispatchQueue.main.async {
                self.runMicCheck { result in
                    report = result
                    semaphore.signal()
                }
            }
            _ = semaphore.wait(timeout: .now() + 10)
            connection.writeLine(VQ.encodeLine(report))

        case "ask":
            guard let request = message.request else {
                connection.writeLine(VQ.encodeLine(AskResponse(status: .error, reason: "missing_request")))
                return
            }
            let box = ResponseBox()
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                self.coordinator.submit(request) { response in
                    box.value = response
                    semaphore.signal()
                }
            }
            while semaphore.wait(timeout: .now() + 0.25) == .timedOut {
                // The hook was killed or timed out: stop asking a question nobody is waiting on.
                guard AppDelegate.peerIsGone(connection.fd) else { continue }
                Log.info("app: client for \(request.id) went away")
                DispatchQueue.main.async { self.coordinator.cancel(id: request.id, reason: "client_gone") }
                _ = semaphore.wait(timeout: .now() + 2)
                break
            }
            connection.writeLine(VQ.encodeLine(box.value ?? .skipped("client_gone")))

        default:
            connection.writeLine(VQ.encodeLine(AskResponse(status: .error, reason: "unknown_command")))
        }
    }

    private static func peerIsGone(_ fd: Int32) -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 0) > 0 else { return false }
        if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return true }
        var byte: UInt8 = 0
        return recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0
    }

    private func statusReport() -> StatusReport {
        StatusReport(version: VQ.version, enabled: VQConfig.load().enabled, busy: coordinator.isBusy,
                     microphonePermission: MicLevelMonitor.permissionName, accessibilityTrusted: AXIsProcessTrusted(),
                     wisprInstalled: WisprController.isInstalled, wisprRunning: WisprController.isRunning,
                     watchers: ["codex": codexWatcher?.state ?? "disabled", "aside": asideWatcher?.state ?? "disabled"])
    }

    /// Listens for three seconds and reports the levels, to tune the end-of-speech detection.
    private func runMicCheck(_ completion: @escaping (MicCheckReport) -> Void) {
        let monitor = MicLevelMonitor()
        var levels: [Double] = []
        var detector = VoiceActivityDetector(settings: .init(VQConfig.load().vad))
        let started = monitor.start(preference: VQConfig.load().vad.device) { level in
            levels.append(level)
            _ = detector.feed(levelDb: level, at: ProcessInfo.processInfo.systemUptime)
        }
        guard started else { return completion(MicCheckReport(permission: MicLevelMonitor.permissionName, samples: 0)) }
        micCheck = monitor
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            monitor.stop()
            self.micCheck = nil
            completion(MicCheckReport(permission: MicLevelMonitor.permissionName, device: monitor.deviceName, samples: levels.count,
                                      minDb: levels.min(), maxDb: levels.max(),
                                      averageDb: levels.isEmpty ? nil : levels.reduce(0, +) / Double(levels.count),
                                      speechThresholdDb: levels.isEmpty ? nil : detector.thresholdDb))
        }
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateIcon()
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let name = !VQConfig.load().enabled ? "mic.slash" : (coordinator.isBusy ? "waveform.circle.fill" : "waveform.circle")
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: "VoiceQuestion") {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.title = "VQ"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let config = VQConfig.load()

        func info(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        func action(_ title: String, _ selector: Selector) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        info("VoiceQuestion \(VQ.version)" + (config.enabled ? "" : L(" · 일시 중지됨", " · paused")))
        let permission: String
        switch MicLevelMonitor.permission {
        case .authorized: permission = L("허용됨", "granted")
        case .notDetermined: permission = L("아직 묻지 않음", "not asked yet")
        default: permission = L("거부됨 (말 끝 자동 감지 불가)", "denied (no automatic end of speech)")
        }
        info(L("마이크 권한: ", "Microphone: ") + permission)
        let wispr = !WisprController.isInstalled ? L("설치되지 않음", "not installed")
            : (WisprController.isRunning ? L("실행 중", "running") : L("꺼져 있음", "not running"))
        info("Wispr Flow: " + wispr)
        info("ChatGPT: \(codexWatcher?.state ?? "disabled") · Aside: \(asideWatcher?.state ?? "disabled")")
        menu.addItem(.separator())

        action(L("테스트 질문 실행", "Ask a test question"), #selector(askTestQuestion))
        action(config.enabled ? L("일시 중지", "Pause") : L("다시 켜기", "Resume"), #selector(toggleEnabled))
        if MicLevelMonitor.permission == .notDetermined {
            action(L("마이크 권한 요청…", "Request microphone access…"), #selector(requestMicrophone))
        } else if MicLevelMonitor.permission != .authorized {
            action(L("마이크 설정 열기…", "Open microphone settings…"), #selector(openMicrophoneSettings))
        }
        menu.addItem(.separator())
        action(L("설정 파일 열기", "Open settings file"), #selector(openConfig))
        action(L("로그 열기", "Open log"), #selector(openLog))
        menu.addItem(.separator())
        action(L("VoiceQuestion 종료", "Quit VoiceQuestion"), #selector(quit))
    }

    @objc private func askTestQuestion() {
        coordinator.submit(AppDelegate.demoRequest) { response in
            let answer = response.answers.first?.answer
            Toast.show(answer.map { L("답변: \($0)", "Answer: \($0)") }
                ?? L("건너뜀 (\(response.reason ?? "-"))", "Skipped (\(response.reason ?? "-"))"))
        }
    }

    @objc private func toggleEnabled() {
        var config = VQConfig.load()
        config.enabled.toggle()
        config.save()
        Log.info("app: \(config.enabled ? "resumed" : "paused")")
        updateIcon()
    }

    @objc private func requestMicrophone() {
        MicLevelMonitor.requestPermission { granted in Log.info("app: microphone permission \(granted ? "granted" : "denied")") }
    }

    @objc private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openConfig() {
        VQConfig.writeDefaultsIfMissing()
        NSWorkspace.shared.open(VQ.configURL)
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(VQ.logURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
