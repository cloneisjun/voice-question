import AppKit
import Foundation
import VQCore

/// Drives Wispr Flow's dictation.
///
/// Wispr Flow exposes `wispr-flow://start-hands-free` and `wispr-flow://stop-hands-free`, which do
/// what holding and releasing the fn key does, without synthesising key presses. Whether it is
/// actually recording is read from Core Audio, since Wispr reports nothing back.
final class WisprController {
    static let bundleID = "com.electron.wispr-flow"

    private let trigger: String
    private var fnHeld = false

    init(trigger: String) {
        self.trigger = trigger
    }

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Wispr records in a helper process (`com.electron.wispr-flow.accessibility-mac-app`).
    static var isRecording: Bool {
        AudioSystem.recordingProcesses().contains { $0.bundleID.hasPrefix(bundleID) }
    }

    func start() {
        if trigger == "fnkey" {
            postFn(down: true)
        } else {
            open("wispr-flow://start-hands-free")
        }
    }

    func stop() {
        if trigger == "fnkey" {
            postFn(down: false)
        } else {
            open("wispr-flow://stop-hands-free")
        }
    }

    /// The microphone Wispr is set to use, e.g. "Built-in mic (recommended)".
    static func selectedMicrophoneName() -> String? {
        let path = NSHomeDirectory() + "/Library/Application Support/Wispr Flow/config.json"
        guard let data = FileManager.default.contents(atPath: path),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let user = (root["prefs"] as? [String: Any])?["user"] as? [String: Any],
              let selected = user["overrideAudioDeviceId"] as? String,
              let devices = user["rankedAudioDevices"] as? [[String: Any]] else { return nil }
        return devices.first { $0["deviceId"] as? String == selected }?["name"] as? String
    }

    private func open(_ link: String) {
        guard let url = URL(string: link) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false // never pull Wispr's window to the front
        NSWorkspace.shared.open(url, configuration: configuration) { _, error in
            if let error { Log.info("wispr: opening \(link) failed: \(error.localizedDescription)") }
        }
    }

    /// Experimental alternative (`"wispr": {"trigger": "fnkey"}`): press and hold a synthetic fn key.
    /// Needs Accessibility permission, and Wispr may ignore synthetic events.
    private func postFn(down: Bool) {
        guard down != fnHeld, let event = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: down) else { return }
        fnHeld = down
        event.type = .flagsChanged
        event.flags = down ? .maskSecondaryFn : []
        event.post(tap: .cghidEventTap)
    }
}
