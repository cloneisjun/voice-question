import Foundation

/// User settings, stored as JSON at `~/Library/Application Support/VoiceQuestion/config.json`.
/// Every key is optional in the file; missing keys take the defaults below.
public struct VQConfig: Codable, Equatable {

    public enum MicStart: String, Codable {
        /// Headphones: mic on as soon as the question starts playing (you can interrupt it).
        /// Speakers: mic on the moment the question finishes, so the dictation does not pick up the TTS.
        case auto
        case immediately
        case afterSpeech
    }

    public enum Focus: String, Codable {
        /// Keep typing where you are; the panel takes the keyboard only when your answer is about to arrive.
        case onAnswer
        /// The panel takes the keyboard as soon as the question appears (Enter / Esc work right away).
        case immediately
    }

    public enum PanelActivation: String, Codable {
        /// Take keyboard focus without bringing VoiceQuestion to the front.
        case nonactivating
        /// Activate the app (use if dictation does not land in the panel on your setup).
        case activate
    }

    public struct Wispr: Codable, Equatable {
        /// "deeplink" (wispr-flow://start-hands-free) or "fnkey" (synthetic fn press, experimental).
        public var trigger = "deeplink"
        /// Seconds to wait for the pasted transcript after dictation stops.
        public var transcriptTimeoutSeconds = 12.0

        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            trigger = c.value(.trigger, default: trigger)
            transcriptTimeoutSeconds = c.value(.transcriptTimeoutSeconds, default: transcriptTimeoutSeconds)
        }
    }

    public struct VAD: Codable, Equatable {
        public var enabled = true
        /// Input device to watch: "auto" follows Wispr Flow's microphone, otherwise a name fragment.
        public var device = "auto"
        /// Fixed speech threshold in dBFS. `nil` adapts to the room's noise floor.
        public var speechThresholdDb: Double?
        public var noiseMarginDb = 10.0
        public var minSpeechSeconds = 0.25
        /// Silence after speech that counts as "finished answering".
        public var endSilenceSeconds = 1.6
        /// Give up (and fall back to the app's own UI) when nobody speaks for this long.
        public var noSpeechTimeoutSeconds = 12.0
        public var maxAnswerSeconds = 90.0

        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = c.value(.enabled, default: enabled)
            device = c.value(.device, default: device)
            speechThresholdDb = try? c.decodeIfPresent(Double.self, forKey: .speechThresholdDb)
            noiseMarginDb = c.value(.noiseMarginDb, default: noiseMarginDb)
            minSpeechSeconds = c.value(.minSpeechSeconds, default: minSpeechSeconds)
            endSilenceSeconds = c.value(.endSilenceSeconds, default: endSilenceSeconds)
            noSpeechTimeoutSeconds = c.value(.noSpeechTimeoutSeconds, default: noSpeechTimeoutSeconds)
            maxAnswerSeconds = c.value(.maxAnswerSeconds, default: maxAnswerSeconds)
        }
    }

    public struct Watcher: Codable, Equatable {
        public var enabled = true
        /// How a captured answer reaches an app that has no answer API:
        /// "clipboard" – copy it and bring the app's question to the front (paste with ⌘V);
        /// "paste" – additionally press ⌘V and Return for you (experimental);
        /// "none" – read the question aloud only.
        public var deliver = "clipboard"

        public init() {}
        public init(enabled: Bool, deliver: String) {
            self.enabled = enabled
            self.deliver = deliver
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = c.value(.enabled, default: enabled)
            deliver = c.value(.deliver, default: deliver)
        }
    }

    public var enabled = true
    public var micStart = MicStart.auto
    /// Read questions aloud. Off shows the panel and opens the microphone without a sound.
    public var speakQuestions = true
    /// Read the options after the question.
    public var speakOptions = true
    public var speakOptionDescriptions = false
    /// Multiplier on the system default speaking rate.
    public var speechRate = 1.0
    /// 0…1, relative to the system output volume.
    public var speechVolume = 1.0
    /// Language code ("ko", "en", ...) → voice identifier. Empty picks the best installed voice.
    public var voices: [String: String] = [:]
    /// After the answer is recognised, wait this long before sending so it can be cancelled or edited.
    public var autoSendDelaySeconds = 2.0
    /// How many times to re-listen when nothing was recognised.
    public var retriesOnEmpty = 1
    /// Skip the voice flow while another app (a call, a recorder) is using the microphone.
    public var skipWhenMicBusy = true
    public var focus = Focus.onAnswer
    public var panelActivation = PanelActivation.nonactivating
    public var wispr = Wispr()
    public var vad = VAD()
    public var codex = Watcher()
    public var aside = Watcher()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.value(.enabled, default: enabled)
        micStart = c.value(.micStart, default: micStart)
        speakQuestions = c.value(.speakQuestions, default: speakQuestions)
        speakOptions = c.value(.speakOptions, default: speakOptions)
        speakOptionDescriptions = c.value(.speakOptionDescriptions, default: speakOptionDescriptions)
        speechRate = c.value(.speechRate, default: speechRate)
        speechVolume = c.value(.speechVolume, default: speechVolume)
        voices = c.value(.voices, default: voices)
        autoSendDelaySeconds = c.value(.autoSendDelaySeconds, default: autoSendDelaySeconds)
        retriesOnEmpty = c.value(.retriesOnEmpty, default: retriesOnEmpty)
        skipWhenMicBusy = c.value(.skipWhenMicBusy, default: skipWhenMicBusy)
        focus = c.value(.focus, default: focus)
        panelActivation = c.value(.panelActivation, default: panelActivation)
        wispr = c.value(.wispr, default: wispr)
        vad = c.value(.vad, default: vad)
        codex = c.value(.codex, default: codex)
        aside = c.value(.aside, default: aside)
    }

    // MARK: - Persistence

    public static func load(from url: URL = VQ.configURL) -> VQConfig {
        guard let data = try? Data(contentsOf: url), let config = try? JSONDecoder().decode(VQConfig.self, from: data) else {
            return VQConfig()
        }
        return config
    }

    /// Writes the file only when it does not exist yet, so the defaults are visible and editable.
    @discardableResult
    public static func writeDefaultsIfMissing(to url: URL = VQ.configURL) -> Bool {
        guard !FileManager.default.fileExists(atPath: url.path) else { return false }
        return VQConfig().save(to: url)
    }

    @discardableResult
    public func save(to url: URL = VQ.configURL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try VQ.encoder(pretty: true).encode(self).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

extension KeyedDecodingContainer {
    /// Missing or malformed keys fall back to the default instead of failing the whole file.
    func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}
