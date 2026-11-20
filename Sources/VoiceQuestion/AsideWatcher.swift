import Foundation
import VQCore

/// Watches Aside (the AI browser) for `ask_user_question` suspensions.
///
/// The daemon log announces the moment a session starts waiting for the user; the questions
/// themselves come from `aside session list --json`.
final class AsideWatcher {
    private let logDirectory: String
    private let binary: String?
    private let coordinator: SessionCoordinator
    private let queue = DispatchQueue(label: "vq.aside")
    private var timer: DispatchSourceTimer?
    private let startedAt = Date()

    // Touched on `queue` only.
    private var offsets: [String: UInt64] = [:]
    private var seenSuspensions: Set<String> = []
    /// Request id → Aside session id of the questions being asked right now.
    private var pending: [String: String] = [:]
    private var lastRecheck = Date.distantPast

    private(set) var state = "off"

    static var defaultLogDirectory: String {
        VQ.environment("VQ_ASIDE_LOG_DIR") ?? NSHomeDirectory() + "/.aside/logs"
    }

    static var binaryPath: String? {
        let candidates = [VQ.environment("VQ_ASIDE_BIN"), "/opt/homebrew/bin/aside", "/usr/local/bin/aside",
                          NSHomeDirectory() + "/.local/bin/aside"].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    init(coordinator: SessionCoordinator, logDirectory: String = AsideWatcher.defaultLogDirectory, binary: String? = AsideWatcher.binaryPath) {
        self.coordinator = coordinator
        self.logDirectory = logDirectory
        self.binary = binary
    }

    func start() {
        guard timer == nil else { return }
        guard binary != nil else {
            state = "aside CLI not found"
            return
        }
        guard FileManager.default.fileExists(atPath: logDirectory) else {
            state = "no log directory"
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1.0, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
        state = "watching"
        Log.info("aside watcher: watching \(logDirectory)")
    }

    func stop() {
        timer?.cancel()
        timer = nil
        state = "off"
    }

    // MARK: - Polling (on `queue`)

    private func poll() {
        if let log = newestLog() { readNewLines(of: log) }
        if !pending.isEmpty, Date().timeIntervalSince(lastRecheck) > 3 {
            lastRecheck = Date()
            cancelAnsweredElsewhere()
        }
    }

    private func newestLog() -> String? {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: logDirectory) else { return nil }
        var newest: (path: String, date: Date)?
        for name in names where name.hasPrefix("daemon-") && name.hasSuffix(".log") {
            let path = logDirectory + "/" + name
            guard let date = (try? manager.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { continue }
            if newest == nil || date > newest!.date { newest = (path, date) }
        }
        return newest?.path
    }

    private func readNewLines(of path: String) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return }
        guard let known = offsets[path] else {
            // First sight: a file that predates us is read from its end, a new one from the top.
            let created = attributes[.creationDate] as? Date ?? .distantPast
            offsets[path] = created >= startedAt.addingTimeInterval(-2) ? 0 : size
            if offsets[path] == size { return }
            return readNewLines(of: path)
        }
        let offset = known <= size ? known : 0
        guard size > offset, let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: offset) } catch { return }
        let chunk = handle.readData(ofLength: Int(min(size - offset, 4_194_304)))
        // Only whole lines; the rest is read next time.
        guard let lastNewline = chunk.lastIndex(of: 0x0A) else { return }
        offsets[path] = offset + UInt64(lastNewline - chunk.startIndex + 1)
        guard let text = String(data: chunk.subdata(in: chunk.startIndex..<lastNewline), encoding: .utf8) else { return }

        let sessionIDs = Set(text.split(separator: "\n").compactMap { AsideSessions.askSessionID(fromLogLine: String($0)) })
        for sessionID in sessionIDs { questionAppeared(in: sessionID) }
    }

    private func listPending() -> [AsideSessions.PendingQuestion]? {
        guard let binary, let data = runCommand(binary, ["session", "list", "--json"], timeout: 8) else { return nil }
        return AsideSessions.pendingQuestions(inSessionList: data)
    }

    private func questionAppeared(in sessionID: String) {
        // The suspension is written right around the log line; give it a moment if it is not there yet.
        var found: AsideSessions.PendingQuestion?
        for attempt in 0..<3 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.7) }
            found = listPending()?.first { $0.sessionID == sessionID }
            if found != nil { break }
        }
        guard let question = found else {
            Log.info("aside watcher: session \(sessionID) announced a question but none is pending")
            return
        }
        guard seenSuspensions.insert(question.suspensionID).inserted else { return }
        let config = VQConfig.load()
        guard config.aside.enabled else { return }

        let request = AskRequest(id: "aside-\(question.suspensionID)", source: .aside, title: question.title, questions: question.questions,
                                 simulateTranscripts: VQ.environment("VQ_SIMULATE_TRANSCRIPT").map { [$0] })
        pending[request.id] = sessionID
        Log.info("aside watcher: question in session \(sessionID) (\(question.questions.count) question(s))")

        let binary = self.binary
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.coordinator.submit(request, isDelivery: true) { response in
                Log.info("aside watcher: \(request.id) \(response.status.rawValue) \(response.reason ?? "")")
                self.queue.async { self.pending.removeValue(forKey: request.id) }
                guard response.status == .answered else { return }
                Delivery.deliverAside(answers: response.answers, sessionID: sessionID, suspensionID: question.suspensionID,
                                      mode: VQConfig.load().aside.deliver, binary: binary)
            }
        }
    }

    /// The user answered in Aside itself while the question was still being read out.
    private func cancelAnsweredElsewhere() {
        guard let stillPending = listPending() else { return }
        let waiting = Set(stillPending.map { "aside-\($0.suspensionID)" })
        let answered = pending.keys.filter { !waiting.contains($0) }
        guard !answered.isEmpty else { return }
        answered.forEach { pending.removeValue(forKey: $0) }
        DispatchQueue.main.async { [weak self] in
            answered.forEach { self?.coordinator.cancel(id: $0, reason: "answered_in_app") }
        }
    }
}
