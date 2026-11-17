import AVFoundation
import Foundation

/// Reads questions aloud with the system voices.
final class Speaker: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private var completion: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }

    /// `completion` runs on the main thread once, whether the text finished or was cut off.
    func speak(_ text: String, language: String, rate: Double, volume: Double = 1, voiceIdentifier: String?, completion: @escaping () -> Void) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? Speaker.bestVoice(for: language)
        let scaled = AVSpeechUtteranceDefaultSpeechRate * Float(rate)
        utterance.rate = min(max(scaled, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        utterance.volume = Float(min(max(volume, 0), 1))
        self.completion = completion
        synthesizer.speak(utterance)
    }

    func stop() {
        guard synthesizer.isSpeaking || completion != nil else { return }
        synthesizer.stopSpeaking(at: .immediate)
        finish()
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
        DispatchQueue.main.async { self.finish() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.finish() }
    }
}
