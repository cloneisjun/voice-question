import Foundation
import VQCore

/// Append-only log at `~/Library/Logs/VoiceQuestion/voicequestion.log`.
/// Transcripts and answers are logged in full only when `VQ_LOG_TRANSCRIPTS=1`.
enum Log {
    private static let queue = DispatchQueue(label: "vq.log")
    private static var handle: FileHandle?
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static let logsTranscripts = VQ.environment("VQ_LOG_TRANSCRIPTS") == "1"

    static func info(_ message: @autoclosure () -> String) {
        write(message())
    }

    /// Text the user said or was asked: shortened unless transcript logging is on.
    static func redact(_ text: String) -> String {
        logsTranscripts ? "\"\(text)\"" : "<\(text.count) chars>"
    }

    private static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            if handle == nil { handle = open() }
            if let data = line.data(using: .utf8) { try? handle?.write(contentsOf: data) }
        }
    }

    private static func open() -> FileHandle? {
        let url = VQ.logURL
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep one previous file once this one passes 2 MB.
        if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 2_000_000 {
            let previous = url.appendingPathExtension("1")
            try? manager.removeItem(at: previous)
            try? manager.moveItem(at: url, to: previous)
        }
        if !manager.fileExists(atPath: url.path) { manager.createFile(atPath: url.path, contents: nil) }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }

    /// Blocks until everything queued so far is on disk (used right before exiting).
    static func flush() {
        queue.sync { try? handle?.synchronize() }
    }
}

/// UI strings: Korean when the system language is Korean, English otherwise.
let prefersKorean = (Locale.preferredLanguages.first ?? "en").hasPrefix("ko")

func L(_ korean: String, _ english: String) -> String {
    prefersKorean ? korean : english
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Runs a command and returns its stdout, or nil on failure / timeout.
func runCommand(_ path: String, _ arguments: [String], timeout: TimeInterval = 10) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch { return nil }

    let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    killer.cancel()
    return process.terminationStatus == 0 ? data : nil
}
