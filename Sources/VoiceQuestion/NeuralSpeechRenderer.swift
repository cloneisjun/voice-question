import Foundation
import VQCore

/// A single cancellable Edge or local Qwen synthesis. Text crosses stdin, never process arguments.
/// All lifecycle methods and callbacks run on the main thread; only the stdin write is background.
final class NeuralSpeechRenderer {
    enum Failure: Error {
        case unavailable, failed, timedOut
    }

    private var process: Process?
    private var directory: URL?
    private var timeout: DispatchWorkItem?
    private var callback: ((Result<URL, Failure>) -> Void)?
    private var generation = UUID()
    private let qwenHelperURL: URL?

    init(qwenHelperURL: URL? = Bundle.main.url(forResource: "qwen_tts", withExtension: "py")) {
        self.qwenHelperURL = qwenHelperURL
    }

    func render(_ text: String, voice: String, rate: Double, settings: VQConfig.TTS, language: String = "auto",
                completion: @escaping (Result<URL, Failure>) -> Void) {
        cancel()
        let token = generation
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vq-tts-\(UUID().uuidString)")
        let output = directory.appendingPathComponent(settings.engine == .qwen ? "speech.wav" : "speech.mp3")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        } catch {
            completion(.failure(.unavailable))
            return
        }
        self.directory = directory
        callback = completion
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: settings.resolvedPythonPath)
        // Match the playback rate to the existing multiplier. Keep volume in the audio player.
        let percent = Int((((rate.isFinite ? min(max(rate, 0.5), 2) : 1) - 1) * 100).rounded())
        if settings.engine == .qwen {
            guard let helper = qwenHelperURL else {
                finish(.failure(.unavailable))
                return
            }
            process.arguments = [helper.path, "--model", (settings.qwen.modelPath as NSString).expandingTildeInPath,
                                 "--speaker", voice, "--language", language, "--instruct", settings.qwen.instruct,
                                 "--output", output.path]
            var environment = ProcessInfo.processInfo.environment
            environment["HF_HUB_OFFLINE"] = "1"
            environment["TRANSFORMERS_OFFLINE"] = "1"
            environment["TOKENIZERS_PARALLELISM"] = "false"
            process.environment = environment
        } else {
            process.arguments = ["-m", "edge_tts", "--file", "/dev/stdin", "--voice", voice,
                                 "--rate=\(percent >= 0 ? "+" : "")\(percent)%", "--no-progress",
                                 "--write-media", output.path]
        }
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        // Service errors can include the submitted text. Only log a generic failure in the caller.
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] child in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size]) as? Int ?? 0
                self.finish(child.terminationStatus == 0 && size > 0 ? .success(output) : .failure(.failed))
            }
        }
        self.process = process
        do {
            try process.run()
        } catch {
            finish(.failure(.unavailable))
            return
        }
        // A long prompt must not block AppKit if the child's stdin buffer is full.
        DispatchQueue.global(qos: .userInitiated).async {
            try? input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
            try? input.fileHandleForWriting.close()
        }
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.finish(.failure(.timedOut))
        }
        timeout = deadline
        let requested = settings.engine == .qwen ? settings.qwen.timeoutSeconds : settings.timeoutSeconds
        let seconds = requested.isFinite ? min(max(requested, 0.1), settings.engine == .qwen ? 300 : 60) : 15
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: deadline)
    }

    /// Cancellation intentionally has no callback: it must never start a microphone or a fallback.
    func cancel() {
        generation = UUID()
        timeout?.cancel()
        timeout = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        callback = nil
        cleanUp()
    }

    private func finish(_ result: Result<URL, Failure>) {
        let callback = callback
        self.callback = nil
        generation = UUID()
        timeout?.cancel()
        timeout = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        // Success hands ownership of the temporary directory to the caller.
        if case .success = result { directory = nil } else { cleanUp() }
        callback?(result)
    }

    private func cleanUp() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    deinit { cancel() }
}
