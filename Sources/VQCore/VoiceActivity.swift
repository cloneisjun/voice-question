import Foundation

/// End-of-speech detection over a stream of input levels (dBFS).
///
/// Pure state machine: the app feeds it microphone levels, tests feed it synthetic ones.
/// It decides when the user has started talking, when they have been quiet long enough to be
/// done, and when nobody answered at all.
public struct VoiceActivityDetector {

    public enum Event: Equatable {
        case speechStarted
        /// The user spoke and has now been silent for `endSilenceSeconds`.
        case endOfSpeech
        /// Nobody spoke within `noSpeechTimeoutSeconds` of the question finishing.
        case noSpeechTimeout
        /// The answer ran into `maxAnswerSeconds`.
        case maxDuration
    }

    public struct Settings: Equatable {
        public var speechThresholdDb: Double?
        public var noiseMarginDb: Double
        public var minSpeechSeconds: Double
        public var endSilenceSeconds: Double
        public var noSpeechTimeoutSeconds: Double
        public var maxAnswerSeconds: Double
        /// Bounds for the adaptive threshold.
        public var minThresholdDb: Double = -50
        public var maxThresholdDb: Double = -25
        /// The first moments only measure the room; nothing in them counts as speech.
        public var calibrationSeconds: Double = 0.3

        public init(speechThresholdDb: Double? = nil, noiseMarginDb: Double = 10, minSpeechSeconds: Double = 0.25,
                    endSilenceSeconds: Double = 1.6, noSpeechTimeoutSeconds: Double = 12, maxAnswerSeconds: Double = 90) {
            self.speechThresholdDb = speechThresholdDb
            self.noiseMarginDb = noiseMarginDb
            self.minSpeechSeconds = minSpeechSeconds
            self.endSilenceSeconds = endSilenceSeconds
            self.noSpeechTimeoutSeconds = noSpeechTimeoutSeconds
            self.maxAnswerSeconds = maxAnswerSeconds
        }

        public init(_ config: VQConfig.VAD) {
            self.init(speechThresholdDb: config.speechThresholdDb, noiseMarginDb: config.noiseMarginDb,
                      minSpeechSeconds: config.minSpeechSeconds, endSilenceSeconds: config.endSilenceSeconds,
                      noSpeechTimeoutSeconds: config.noSpeechTimeoutSeconds, maxAnswerSeconds: config.maxAnswerSeconds)
        }
    }

    public let settings: Settings
    public private(set) var hasSpeech = false
    public private(set) var finished = false
    public private(set) var noiseFloorDb: Double?
    public private(set) var lastLevelDb: Double = -120

    private var firstTime: TimeInterval?
    private var lastTime: TimeInterval?
    private var speechAccumulated: TimeInterval = 0
    private var lastSpeechTime: TimeInterval?
    private var speechStartTime: TimeInterval?
    /// The no-speech clock only runs once the question has finished playing.
    private var armedAt: TimeInterval?

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    public var thresholdDb: Double {
        if let fixed = settings.speechThresholdDb { return fixed }
        let floor = noiseFloorDb ?? -55
        return min(max(floor + settings.noiseMarginDb, settings.minThresholdDb), settings.maxThresholdDb)
    }

    /// Start counting towards `noSpeechTimeout` (call when the question audio ends).
    public mutating func arm(at time: TimeInterval) {
        if armedAt == nil { armedAt = time }
    }

    public var isArmed: Bool { armedAt != nil }

    public mutating func feed(levelDb: Double, at time: TimeInterval) -> Event? {
        guard !finished else { return nil }
        let delta = min(max(time - (lastTime ?? time), 0), 0.1)
        lastTime = time
        lastLevelDb = levelDb

        let first = firstTime ?? time
        firstTime = first
        if time - first < settings.calibrationSeconds {
            updateNoiseFloor(levelDb)
            return nil
        }

        let threshold = thresholdDb
        // Once speaking, dip a little below the threshold before calling it silence.
        let isSpeech = levelDb > (hasSpeech ? threshold - 3 : threshold)

        if isSpeech {
            speechAccumulated += delta
            lastSpeechTime = time
        } else {
            speechAccumulated = max(0, speechAccumulated - delta * 2)
            updateNoiseFloor(levelDb)
        }

        if !hasSpeech, speechAccumulated >= settings.minSpeechSeconds {
            hasSpeech = true
            speechStartTime = time
            return .speechStarted
        }

        if hasSpeech {
            if let last = lastSpeechTime, time - last >= settings.endSilenceSeconds {
                finished = true
                return .endOfSpeech
            }
            if let start = speechStartTime, time - start >= settings.maxAnswerSeconds {
                finished = true
                return .maxDuration
            }
        } else if let armed = armedAt, time - armed >= settings.noSpeechTimeoutSeconds {
            finished = true
            return .noSpeechTimeout
        }
        return nil
    }

    private mutating func updateNoiseFloor(_ levelDb: Double) {
        // Never let a loud room push the floor so high that normal speech stops registering.
        let clamped = min(max(levelDb, -80), -35)
        guard let floor = noiseFloorDb else {
            noiseFloorDb = clamped
            return
        }
        // Follow drops quickly, rises slowly.
        noiseFloorDb = clamped < floor ? floor * 0.5 + clamped * 0.5 : floor * 0.98 + clamped * 0.02
    }
}
