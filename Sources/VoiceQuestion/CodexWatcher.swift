import CoreServices
import Foundation
import VQCore

/// Watches ChatGPT Desktop's (Codex) session logs for questions.
///
/// Codex has no hook that can answer `request_user_input`, but it writes every question to
/// `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` as it asks. This tails those files, reads the
/// question aloud through the normal session, and hands the answer over via `Delivery`.
final class CodexWatcher {
    private let directory: String
    private let coordinator: SessionCoordinator
    private let queue = DispatchQueue(label: "vq.codex")
    private var stream: FSEventStreamRef?
    private let startedAt = Date()

    // Touched on `queue` only.
    private var offsets: [String: UInt64] = [:]
    private var remainders: [String: Data] = [:]
    private var seenCallIDs: Set<String> = []
    /// Call id → request id of a question that is being asked right now.
    private var pending: [String: String] = [:]
    private var recentQuestions: [String: (requestID: String, date: Date)] = [:]
    private var metadata: [String: (isDesktop: Bool, cwd: String?)] = [:]

    private(set) var state = "off"

    static var defaultDirectory: String {
        VQ.environment("VQ_CODEX_SESSIONS_DIR") ?? NSHomeDirectory() + "/.codex/sessions"
    }

    init(coordinator: SessionCoordinator, directory: String = CodexWatcher.defaultDirectory) {
        self.coordinator = coordinator
        self.directory = directory
    }

    func start() {
        guard stream == nil else { return }
        guard FileManager.default.fileExists(atPath: directory) else {
            state = "no sessions directory"
            return
        }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info, let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            let watcher = Unmanaged<CodexWatcher>.fromOpaque(info).takeUnretainedValue()
            for path in paths.prefix(count) { watcher.fileChanged(path) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [directory] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags) else {
            state = "could not watch"
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
        state = "watching"
        Log.info("codex watcher: watching \(directory)")
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        state = "off"
    }

    // MARK: - Tailing (on `queue`)

    private func fileChanged(_ path: String) {
        let name = (path as NSString).lastPathComponent
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return }

        var offset: UInt64
        var skipPartialLine = false
        if let known = offsets[path] {
            offset = known <= size ? known : 0
        } else if let created = attributes[.creationDate] as? Date, created >= startedAt.addingTimeInterval(-2) {
            offset = 0
        } else {
            // A session that was already running: only its latest lines matter.
            offset = size > 262_144 ? size - 262_144 : 0
            skipPartialLine = offset > 0
        }
        guard size > offset, let file = FileHandle(forReadingAtPath: path) else { return }
        defer { try? file.close() }
        do { try file.seek(toOffset: offset) } catch { return }
        let chunk = file.readData(ofLength: Int(min(size - offset, 8_388_608)))
        offsets[path] = offset + UInt64(chunk.count)

        var data = (remainders[path] ?? Data()) + chunk
        if skipPartialLine, let newline = data.firstIndex(of: 0x0A) {
            data.removeSubrange(data.startIndex...newline)
        }
        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            remainders[path] = data
            return
        }
        remainders[path] = data.subdata(in: data.index(after: lastNewline)..<data.endIndex)
        let complete = data.subdata(in: data.startIndex..<lastNewline)
        guard let text = String(data: complete, encoding: .utf8) else { return }

        for line in text.split(separator: "\n") {
            guard CodexRollout.mightBeRelevant(line) || pending.keys.contains(where: line.contains),
                  let event = CodexRollout.parseLine(String(line), pendingCallIDs: Set(pending.keys)) else { continue }
            handle(event, path: path)
        }
    }

    private func handle(_ event: CodexRolloutEvent, path: String) {
        switch event {
        case .question(let threadID, let callID, let questions, let timestamp):
            guard seenCallIDs.insert(callID).inserted else { return }
            // Old questions show up when a long session is first read.
            if let timestamp, Date().timeIntervalSince(timestamp) > 60 { return }

            // The same question is logged twice under different ids (the call and the message).
            let key = path + "|" + (questions.first?.question ?? "")
            recentQuestions = recentQuestions.filter { Date().timeIntervalSince($0.value.date) < 60 }
            if let recent = recentQuestions[key] {
                pending[callID] = recent.requestID
                return
            }

            let config = VQConfig.load()
            guard config.codex.enabled else { return }
            let meta = metadata(for: path)
            let thread = threadID ?? CodexRollout.threadID(fromFilename: (path as NSString).lastPathComponent)
            let request = AskRequest(id: "codex-\(callID)", source: .codex,
                                     title: meta.cwd.map { ($0 as NSString).lastPathComponent }, cwd: meta.cwd, questions: questions,
                                     simulateTranscripts: VQ.environment("VQ_SIMULATE_TRANSCRIPT").map { [$0] })
            pending[callID] = request.id
            recentQuestions[key] = (request.id, Date())
            Log.info("codex watcher: question \(callID) thread=\(thread ?? "-") desktop=\(meta.isDesktop)")

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.coordinator.submit(request, isDelivery: true) { response in
                    Log.info("codex watcher: \(request.id) \(response.status.rawValue) \(response.reason ?? "")")
                    self.queue.async { self.pending = self.pending.filter { $0.value != request.id } }
                    guard response.status == .answered else { return }
                    Delivery.deliverCodex(answers: response.answers, questions: questions, threadID: thread,
                                          isDesktop: meta.isDesktop, mode: VQConfig.load().codex.deliver)
                }
            }

        case .answered(let callIDs):
            let requestIDs = Set(callIDs.compactMap { pending[$0] })
            guard !requestIDs.isEmpty else { return }
            pending = pending.filter { !requestIDs.contains($0.value) }
            DispatchQueue.main.async { [weak self] in
                requestIDs.forEach { self?.coordinator.cancel(id: $0, reason: "answered_in_app") }
            }
        }
    }

    /// The first line of a rollout says which client started the session and where.
    private func metadata(for path: String) -> (isDesktop: Bool, cwd: String?) {
        if let cached = metadata[path] { return cached }
        var result: (isDesktop: Bool, cwd: String?) = (false, nil)
        if let file = FileHandle(forReadingAtPath: path) {
            let head = file.readData(ofLength: 65_536)
            try? file.close()
            let firstLine = head.split(separator: 0x0A, maxSplits: 1).first.map { Data($0) } ?? head
            if let root = (try? JSONSerialization.jsonObject(with: firstLine)) as? [String: Any],
               let payload = root["payload"] as? [String: Any] {
                result = ((payload["originator"] as? String ?? "").localizedCaseInsensitiveContains("desktop"), payload["cwd"] as? String)
            } else if let text = String(data: head, encoding: .utf8) {
                // The first line can be longer than what was read; the fields near its start are enough.
                result.isDesktop = text.contains("\"originator\":\"Codex Desktop\"")
            }
        }
        metadata[path] = result
        return result
    }
}
