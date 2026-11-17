import AppKit
import VQCore

/// Runs one question session at a time and queues the rest. Main thread only.
final class SessionCoordinator {
    typealias Completion = (AskResponse) -> Void

    private struct Listener {
        /// A watcher that would hand the answer over by clipboard. It stands down when a hook,
        /// which can answer the agent directly, is waiting on the same question.
        var isDelivery: Bool
        var completion: Completion
    }

    private struct Entry {
        var request: AskRequest
        var listeners: [Listener]
    }

    private var queue: [Entry] = []
    private var active: Entry?
    private var session: QuestionSession?
    private var recent: [(key: String, date: Date)] = []
    private lazy var panel = QuestionPanel()

    /// Called whenever a session starts or ends (the menu bar shows it).
    var onChange: (() -> Void)?

    var isBusy: Bool { active != nil }

    func submit(_ request: AskRequest, isDelivery: Bool = false, completion: @escaping Completion) {
        let listener = Listener(isDelivery: isDelivery, completion: completion)
        let key = dedupeKey(request)

        // The same question arriving twice: once from the hook and once from the session log.
        if active?.request.id == request.id || (key != nil && key == active.flatMap { dedupeKey($0.request) }) {
            active?.listeners.append(listener)
            return
        }
        if let index = queue.firstIndex(where: { $0.request.id == request.id || (key != nil && key == dedupeKey($0.request)) }) {
            queue[index].listeners.append(listener)
            return
        }
        recent.removeAll { Date().timeIntervalSince($0.date) > 60 }
        if let key, recent.contains(where: { $0.key == key }) {
            Log.info("coordinator: \(request.id) repeats a question answered a moment ago; ignored")
            return completion(.skipped("duplicate"))
        }

        queue.append(Entry(request: request, listeners: [listener]))
        Log.info("coordinator: queued \(request.id) from \(request.source.rawValue) (\(request.questions.count) question(s), waiting=\(queue.count))")
        startNext()
    }

    func cancel(id: String, reason: String) {
        if active?.request.id == id {
            session?.cancel(reason: reason)
        } else if let index = queue.firstIndex(where: { $0.request.id == id }) {
            let entry = queue.remove(at: index)
            entry.listeners.forEach { $0.completion(.skipped(reason)) }
        }
    }

    /// Only Codex questions are seen through two channels, so only they are matched by text.
    private func dedupeKey(_ request: AskRequest) -> String? {
        guard request.source == .codex, let first = request.questions.first else { return nil }
        return "codex|" + first.question
    }

    private func startNext() {
        guard active == nil, !queue.isEmpty else { return }
        let entry = queue.removeFirst()
        active = entry
        let session = QuestionSession(request: entry.request, config: VQConfig.load(), panel: panel,
                                      completion: { [weak self] response in self?.finished(response) },
                                      onIdle: { [weak self] in self?.sessionEnded() })
        self.session = session
        onChange?()
        session.start()
    }

    private func finished(_ response: AskResponse) {
        guard let entry = active else { return }
        if response.status == .answered, let key = dedupeKey(entry.request) { recent.append((key, Date())) }
        let hasDirect = entry.listeners.contains { !$0.isDelivery }
        for listener in entry.listeners {
            if listener.isDelivery, hasDirect, response.status == .answered {
                listener.completion(.skipped("answered_by_hook"))
            } else {
                listener.completion(response)
            }
        }
        active?.listeners = []
    }

    private func sessionEnded() {
        // Let the session finish unwinding before it is released and the next one starts.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.active = nil
            self.session = nil
            self.onChange?()
            self.startNext()
        }
    }
}
