import AppKit
import Foundation
import Testing
import VQCore
@testable import VoiceQuestion

/// Exercises the real subprocess boundary without making a network request or playing audio.
@MainActor
@Suite("Neural synthesis", .serialized)
struct NeuralSpeechTests {
    private func runtime(_ script: String) throws -> (URL, VQConfig.TTS) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vq-render-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("python")
        try ("#!/usr/bin/python3\n" + script).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var settings = VQConfig.TTS()
        settings.pythonPath = executable.path
        settings.timeoutSeconds = 3
        return (directory, settings)
    }

    private func pause(_ seconds: Double) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { continuation.resume() }
        }
    }

    @Test func textCrossesStdinWithoutShellExpansion() async throws {
        let (directory, settings) = try runtime("""
        import os, pathlib, sys
        text = sys.stdin.read()
        assert text == 'question; $(touch injected) `uname` 한글'
        assert text not in ' '.join(sys.argv)
        assert '--rate=-10%' in sys.argv
        output = pathlib.Path(sys.argv[sys.argv.index('--write-media') + 1])
        assert (output.parent.stat().st_mode & 0o777) == 0o700
        output.write_bytes(b'audio fixture')
        """)
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = NeuralSpeechRenderer()
        let result = await withCheckedContinuation { continuation in
            renderer.render("question; $(touch injected) `uname` 한글", voice: "ko-KR-SunHiNeural", rate: 0.9, settings: settings) {
                continuation.resume(returning: $0)
            }
        }
        let url = try result.get()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try Data(contentsOf: url) == Data("audio fixture".utf8))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("injected").path))
    }

    @Test func failedAndMissingRuntimesCompleteOnce() async throws {
        let (directory, settings) = try runtime("import sys\nsys.exit(1)\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        for python in [settings.pythonPath, directory.appendingPathComponent("missing").path] {
            var options = settings
            options.pythonPath = python
            let renderer = NeuralSpeechRenderer()
            var calls = 0
            let result = await withCheckedContinuation { continuation in
                renderer.render("hello", voice: "voice", rate: 1, settings: options) {
                    calls += 1
                    continuation.resume(returning: $0)
                }
            }
            if case .success = result { Issue.record("A failing runtime must never supply audio") }
            await pause(0.05)
            #expect(calls == 1)
        }
    }

    @Test func timeoutCompletesOnceAndDeletesPartialAudio() async throws {
        let (directory, base) = try runtime("""
        import pathlib, sys, time
        output = pathlib.Path(sys.argv[sys.argv.index('--write-media') + 1])
        pathlib.Path(__file__).with_name('output-path').write_text(str(output))
        output.write_bytes(b'partial audio')
        time.sleep(10)
        """)
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = base
        settings.timeoutSeconds = 0.5
        let renderer = NeuralSpeechRenderer()
        var calls = 0
        let result = await withCheckedContinuation { continuation in
            renderer.render("hello", voice: "voice", rate: 1, settings: settings) {
                calls += 1
                continuation.resume(returning: $0)
            }
        }
        if case .failure(.timedOut) = result {} else { Issue.record("Expected a bounded timeout") }
        let output = try String(contentsOf: directory.appendingPathComponent("output-path"), encoding: .utf8)
        #expect(!FileManager.default.fileExists(atPath: output))
        await pause(0.1)
        #expect(calls == 1)
    }

    @Test func cancellationCannotFinishOrRestartSpeech() async throws {
        let (directory, settings) = try runtime("import time\ntime.sleep(10)\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = NeuralSpeechRenderer()
        var calls = 0
        renderer.render("hello", voice: "voice", rate: 1, settings: settings) { _ in calls += 1 }
        renderer.cancel()
        await pause(0.2)
        #expect(calls == 0)
    }

    @Test func replacedSynthesisIgnoresTheOldProcessExit() async throws {
        let (directory, settings) = try runtime("""
        import pathlib, sys, time
        text = sys.stdin.read()
        if text == 'old': time.sleep(10)
        pathlib.Path(sys.argv[sys.argv.index('--write-media') + 1]).write_bytes(text.encode())
        """)
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = NeuralSpeechRenderer()
        var calls = 0
        renderer.render("old", voice: "voice", rate: 1, settings: settings) { _ in calls += 1 }
        let result = await withCheckedContinuation { continuation in
            renderer.render("new", voice: "voice", rate: 1, settings: settings) {
                calls += 1
                continuation.resume(returning: $0)
            }
        }
        let url = try result.get()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try Data(contentsOf: url) == Data("new".utf8))
        await pause(0.1)
        #expect(calls == 1)
    }

    @Test func menuOffersBothEnginesAndPreviewWithoutShowingAWindow() throws {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        let voices = try #require(menu.items.compactMap(\.submenu).first)
        #expect(voices.items.compactMap { $0.representedObject as? String } == ["system", "edge"])
        #expect(voices.items.filter { $0.state == .on }.count == 1)
        #expect(voices.items.last?.action != nil)
    }
}
