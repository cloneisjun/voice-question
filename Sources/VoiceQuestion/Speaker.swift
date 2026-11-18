import AVFoundation
import Foundation
import VQCore

/// Reads questions with the selected offline or neural engine, falling back locally on failure.
final class Speaker: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let renderer = NeuralSpeechRenderer()
    private var player: AVAudioPlayer?
    private var renderedAudio: URL?
    private var utterance: AVSpeechUtterance?
    private var completion: (() -> Void)?
    private var generation = UUID()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { completion != nil }

    /// `completion` runs on the main thread once, whether the text finished or was cut off.
    func speak(_ text: String, language: String, rate: Double, volume: Double = 1, voiceIdentifier: String?,
               settings: VQConfig.TTS = .init(), completion: @escaping () -> Void) {
        stop()
        self.completion = completion
        let token = generation
        if settings.engine == .edge, let voice = settings.voice(for: language) {
            Log.info("tts: edge synthesis voice=\(voice)")
            renderer.render(text, voice: voice, rate: rate, settings: settings) { [weak self] result in
                guard let self, self.generation == token else {
                    if case .success(let url) = result { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                    return
                }
                switch result {
                case .success(let url):
                    self.renderedAudio = url
                    do {
                        let player = try AVAudioPlayer(contentsOf: url)
                        player.delegate = self
                        player.volume = Float(min(max(volume, 0), 1))
                        self.player = player
                        guard player.prepareToPlay(), player.play() else { throw NeuralSpeechRenderer.Failure.failed }
                        Log.info("tts: edge playback started")
                    } catch {
                        self.cleanUpAudio()
                        self.speakSystem(text, language: language, rate: rate, volume: volume, voiceIdentifier: voiceIdentifier)
                    }
                case .failure:
                    Log.info("tts: edge unavailable; falling back to offline system voice")
                    self.speakSystem(text, language: language, rate: rate, volume: volume, voiceIdentifier: voiceIdentifier)
                }
            }
        } else {
            speakSystem(text, language: language, rate: rate, volume: volume, voiceIdentifier: voiceIdentifier)
        }
    }

    private func speakSystem(_ text: String, language: String, rate: Double, volume: Double, voiceIdentifier: String?) {
        let utterance = AVSpeechUtterance(string: text)
        self.utterance = utterance
        utterance.voice = voiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? Speaker.bestVoice(for: language)
        let scaled = AVSpeechUtteranceDefaultSpeechRate * Float(rate)
        utterance.rate = min(max(scaled, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        utterance.volume = Float(min(max(volume, 0), 1))
        Log.info("tts: system playback started")
        synthesizer.speak(utterance)
    }

    func stop() {
        generation = UUID()
        renderer.cancel()
        utterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        cleanUpAudio()
        finish()
    }

    private func cleanUpAudio() {
        player?.stop()
        player = nil
        if let renderedAudio { try? FileManager.default.removeItem(at: renderedAudio.deletingLastPathComponent()) }
        renderedAudio = nil
    }

    /// The best installed voice for a language: premium over enhanced over compact, and never the
    /// novelty / Eloquence voices that macOS lists first for some languages.
    static func bestVoice(for language: String) -> AVSpeechSynthesisVoice? {
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.lowercased().hasPrefix(language.lowercased())
                && !$0.voiceTraits.contains(.isNoveltyVoice)
                && !$0.identifier.contains("eloquence")
                && !$0.identifier.contains("speech.synthesis.voice")
        }
        let preferredRegion = Locale.preferredLanguages.first { $0.lowercased().hasPrefix(language.lowercased()) }
        let best = candidates.max { lhs, rhs in
            if lhs.quality.rawValue != rhs.quality.rawValue { return lhs.quality.rawValue < rhs.quality.rawValue }
            return (lhs.language == preferredRegion ? 1 : 0) < (rhs.language == preferredRegion ? 1 : 0)
        }
        return best ?? AVSpeechSynthesisVoice(language: language)
    }

    private func finish() {
        guard let completion else { return }
        self.completion = nil
        DispatchQueue.main.async(execute: completion)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            guard self.utterance === utterance else { return }
            self.utterance = nil
            Log.info("tts: system playback finished")
            self.finish()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            guard self.utterance === utterance else { return }
            self.utterance = nil
            self.finish()
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            guard self.player === player else { return }
            Log.info("tts: edge playback finished success=\(flag)")
            self.cleanUpAudio()
            self.finish()
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        audioPlayerDidFinishPlaying(player, successfully: false)
    }
}
