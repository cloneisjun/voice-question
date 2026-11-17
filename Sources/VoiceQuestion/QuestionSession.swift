import AppKit
import VQCore

/// One request (one or more questions) from start to answer.
///
/// Everything runs on the main thread. A 0.1 s ticker watches Wispr Flow and the clocks; the
/// microphone level callback drives end-of-speech detection.
final class QuestionSession: QuestionPanelDelegate {

    enum Phase: String {
        case idle, speaking, listening, transcribing, confirming, editing, draining, finished
    }

    /// A dictation we stopped (or saw stop) whose pasted transcript may still be on its way.
    private struct PendingPaste {
        var attempt: Int
        var recordStart: Date
        var deadline: Date
        var rowSeenAt: Date?
    }

    let request: AskRequest
    private let config: VQConfig
    private let panel: QuestionPanel
    private let completion: (AskResponse) -> Void
    private let onIdle: () -> Void

    private let speaker = Speaker()
    private let monitor = MicLevelMonitor()
    private let wispr: WisprController
    private var vad = VoiceActivityDetector()
    private var timer: Timer?

    private(set) var phase = Phase.idle
    private var completed = false
    private var questionIndex = 0
    private var answers: [AnsweredQuestion] = []

    // Per attempt (a question, or one more try at it).
    private var attempt = 0
    private var voiceInput = false
    private var vadActive = false
    private var micImmediate = false
    private var wantsWisprStart = false
    private var wisprStarted = false
    private var wisprStopped = false
    private var sawRecording = false
    private var retriedStart = false
    private var warnedStart = false
    private var noSpeech = false
    private var wisprStartTime = Date.distantPast
    private var recordStart = Date.distantPast
    private var listenStart = Date.distantPast
    private var transcribeStart = Date.distantPast
    private var confirmDeadline = Date.distantPast
    private var drainStart = Date.distantPast
    private var lastHistoryPoll = Date.distantPast
    private var editingSince = Date.distantPast
    private var typedAt: Date?
    private var pendingAnswer: AnsweredQuestion?
    private var manualSelection: [Int] = []

    private var pendingPaste: PendingPaste?
    private var emptyRetries = 0
    private var spokenRetries = 0

    private var question: Question { request.questions[questionIndex] }

    init(request: AskRequest, config: VQConfig, panel: QuestionPanel,
         completion: @escaping (AskResponse) -> Void, onIdle: @escaping () -> Void) {
        self.request = request
        self.config = config
        self.panel = panel
        self.completion = completion
        self.onIdle = onIdle
        self.wispr = WisprController(trigger: config.wispr.trigger)
    }

    // MARK: - Lifecycle

    func start() {
        guard config.enabled else { return finishWithoutUI(.skipped("disabled")) }
        guard !request.questions.isEmpty else { return finishWithoutUI(AskResponse(status: .error, reason: "no_questions")) }
        if let transcripts = request.simulateTranscripts { return runSimulated(transcripts) }

        if config.skipWhenMicBusy {
            let busy = AudioSystem.recordingProcesses()
            if !busy.isEmpty {
                Log.info("session \(request.id): microphone in use by \(busy.map(\.bundleID).joined(separator: ", ")); leaving the question to the app")
                return finishWithoutUI(.skipped("mic_busy"))
            }
        }

        voiceInput = WisprController.isInstalled && WisprController.isRunning && VQ.environment("VQ_NO_WISPR") != "1"
        if !voiceInput { Log.info("session \(request.id): Wispr Flow is not running; question is read aloud, answer by typing") }
        panel.delegate = self

        let ticker = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
        beginQuestion(0)
    }

    /// Stop from outside: the asking app went away, or the question was answered there.
    func cancel(reason: String) {
        finish(.skipped(reason))
    }

    /// No audio at all: used by the automated tests and `VQ_SIMULATE_TRANSCRIPT`.
    private func runSimulated(_ transcripts: [String]) {
        var simulated: [AnsweredQuestion] = []
        for (index, question) in request.questions.enumerated() {
            let transcript = index < transcripts.count ? transcripts[index] : (transcripts.last ?? "")
            let resolved = AnswerResolver.resolve(transcript: transcript, question: question)
            guard let answer = AnswerResolver.answered(resolved: resolved, transcript: transcript, question: question) else {
                return finishWithoutUI(.skipped(resolved == .skip ? "user_said_skip" : "no_transcript"))
            }
            simulated.append(answer)
        }
        finishWithoutUI(AskResponse(status: .answered, answers: simulated))
    }

    private func finishWithoutUI(_ response: AskResponse) {
        completed = true
        phase = .finished
        Log.info("session \(request.id): \(response.status.rawValue) \(response.reason ?? "")")
        completion(response)
        onIdle()
    }

    private func finish(_ response: AskResponse) {
        guard !completed else { return }
        completed = true
        speaker.stop()
        monitor.stop()
        stopWispr()
        Log.info("session \(request.id): \(response.status.rawValue) \(response.reason ?? "") answers=\(response.answers.count)")
        completion(response)

        // The dictation we just stopped will still be pasted somewhere. Stay the keyboard target
        // until it arrives so it does not land in whatever the user is working in.
        if pendingPaste != nil, panel.isVisible {
            phase = .draining
            drainStart = Date()
            panel.takeKeyboard()
            panel.setLevel(nil)
            panel.setStatus(L("마무리 중…", "Finishing…"))
            panel.setHint("")
            panel.setButtons(sendEnabled: false)
        } else {
            close()
        }
    }

    private func close() {
        timer?.invalidate()
        timer = nil
        panel.close()
        panel.delegate = nil
        phase = .finished
        onIdle()
    }

    // MARK: - Asking

    private func beginQuestion(_ index: Int) {
        questionIndex = index
        emptyRetries = 0
        spokenRetries = 0
        let source = [request.source.displayName, request.title].compactMap { $0 }.joined(separator: " · ")
        panel.present(source: source, question: question, index: index, total: request.questions.count,
                      activation: config.panelActivation)
        let language = SpokenText.language(of: question.question)
        let text = SpokenText.build(question: question, index: index, total: request.questions.count, language: language,
                                    speakOptions: config.speakOptions, speakDescriptions: config.speakOptionDescriptions)
        Log.info("session \(request.id): question \(index + 1)/\(request.questions.count) \(Log.redact(question.question)) options=\(question.options.count)")
        startAttempt(speaking: text, language: language)
    }

    private func startAttempt(speaking text: String?, language: String) {
        attempt += 1
        wantsWisprStart = false
        wisprStarted = false
        wisprStopped = false
        sawRecording = false
        retriedStart = false
        warnedStart = false
        noSpeech = false
        typedAt = nil
        pendingAnswer = nil
        manualSelection = []
        vad = VoiceActivityDetector(settings: .init(config.vad))
        panel.setAnswerText("")
        panel.setSelectedOptions([])
        panel.setPreview(nil)
        panel.setButtons(sendEnabled: true)

        micImmediate = voiceInput && (config.micStart == .immediately || (config.micStart == .auto && AudioSystem.outputIsPrivate()))
        vadActive = voiceInput && config.vad.enabled
            && monitor.start(preference: config.vad.device) { [weak self] level in self?.handleLevel(level) }
        if !vadActive { panel.setLevel(nil) }
        if config.focus == .immediately { panel.takeKeyboard() }

        phase = .speaking
        panel.setStatus(L("질문 읽는 중", "Reading"))
        panel.setHint(idleHint)
        if micImmediate { wantsWisprStart = true }

        guard config.speakQuestions, let text, !text.isEmpty else { return speechFinished() }
        let current = attempt
        speaker.speak(text, language: language, rate: config.speechRate, volume: config.speechVolume,
                      voiceIdentifier: config.voices[language]) { [weak self] in
            guard let self, self.attempt == current else { return }
            self.speechFinished()
        }
    }

    /// How long the microphone stays open when the level cannot be measured (no microphone
    /// permission), so an unanswered question does not keep Wispr recording an empty room.
    private static let unheardListenSeconds = 45.0

    private func speechFinished() {
        guard phase == .speaking else { return }
        phase = .listening
        listenStart = Date()
        vad.arm(at: ProcessInfo.processInfo.systemUptime)
        guard voiceInput else {
            panel.setStatus(L("입력 대기", "Waiting"))
            panel.setHint(L("Wispr Flow가 꺼져 있어요 · 클릭해서 직접 입력", "Wispr Flow is not running · click to type"))
            return
        }
        if !wisprStarted { wantsWisprStart = true }
        panel.setStatus(L("듣는 중…", "Listening…"))
        if !vadActive {
            // Without the microphone level there is no way to hear the answer end; Return does it.
            panel.takeKeyboard()
            panel.setHint(L("말을 마치면 Enter · Esc 건너뛰기", "Press Return when done · Esc to skip"))
        }
    }

    /// Spoken prompts follow the question's language rather than the system's.
    private func spoken(_ korean: String, _ english: String) -> String {
        SpokenText.language(of: question.question) == "ko" ? korean : english
    }

    private var idleHint: String {
        question.options.isEmpty
            ? L("말로 답하세요 · 클릭해서 직접 입력", "Answer by voice · click to type")
            : L("말로 답하거나 항목을 클릭", "Answer by voice or click an option")
    }

    private func relisten(prompt: String?) {
        speaker.stop()
        monitor.stop()
        stopWispr()
        startAttempt(speaking: prompt, language: prompt == nil ? "ko" : SpokenText.language(of: prompt!))
    }

    // MARK: - Wispr Flow

    private func startWispr() {
        wantsWisprStart = false
        wisprStarted = true
        wisprStartTime = Date()
        recordStart = Date()
        wispr.start()
        Log.info("session \(request.id): wispr start")
    }

    /// Ends the current dictation, if any, and remembers that its transcript is still to come.
    private func stopWispr() {
        wantsWisprStart = false
        guard wisprStarted, !wisprStopped else { return }
        wisprStopped = true
        wispr.stop()
        let wait = sawRecording ? config.wispr.transcriptTimeoutSeconds : 2.5
        pendingPaste = PendingPaste(attempt: attempt, recordStart: recordStart, deadline: Date().addingTimeInterval(wait))
        Log.info("session \(request.id): wispr stop (recorded=\(sawRecording))")
    }

    private func enterTranscribing() {
        guard phase == .speaking || phase == .listening else { return }
        speaker.stop()
        monitor.stop()
        phase = .transcribing
        transcribeStart = Date()
        typedAt = nil
        panel.setLevel(nil)
        panel.setStatus(L("받아쓰는 중…", "Transcribing…"))
        panel.setHint("")
        // Wispr pastes into whatever has the keyboard, so take it before the dictation ends.
        panel.takeKeyboard()
    }

    private func endListening(reason: String) {
        guard phase == .speaking || phase == .listening else { return }
        Log.info("session \(request.id): end of answer (\(reason))")
        enterTranscribing()
        guard wisprStarted else {
            let typed = panel.answerText
            return typed.isEmpty ? handleEmpty() : gotTranscript(typed, via: "typed")
        }
        stopWispr()
    }

    // MARK: - Ticker

    private func tick() {
        let now = Date()
        switch phase {
        case .speaking, .listening:
            watchWispr(now)
            guard phase == .listening else { break }
            let waited = now.timeIntervalSince(listenStart)
            if !voiceInput {
                if waited > 45 { finish(.skipped("wispr_unavailable")) }
            } else if !vadActive, waited > min(config.vad.maxAnswerSeconds, QuestionSession.unheardListenSeconds) {
                // Nobody pressed Return. Use whatever was dictated, but do not ask again.
                noSpeech = true
                endListening(reason: "max_duration")
            } else if vadActive, waited > config.vad.maxAnswerSeconds + config.vad.noSpeechTimeoutSeconds + 5 {
                endListening(reason: "watchdog") // the level callback went quiet
            }
        case .transcribing:
            if let typedAt, now.timeIntervalSince(typedAt) > 0.4, !panel.answerText.isEmpty {
                return gotTranscript(panel.answerText, via: "typed")
            }
            pollPendingPaste(now)
        case .confirming:
            pollPendingPaste(now)
            guard phase == .confirming else { break }
            let remaining = confirmDeadline.timeIntervalSince(now)
            if remaining <= 0 {
                commitPending()
            } else {
                panel.setHint(L("\(Int(remaining.rounded(.up)))초 뒤 전송 · Enter 바로 · Esc 수정 · ⌘R 다시",
                                "Sending in \(Int(remaining.rounded(.up)))s · Return now · Esc edit · ⌘R redo"))
            }
        case .editing:
            pollPendingPaste(now)
            // Nobody is coming back to this one; hand it to the app's own dialog.
            if phase == .editing, now.timeIntervalSince(editingSince) > 600 { finish(.skipped("timeout")) }
        case .draining:
            pollPendingPaste(now)
            if pendingPaste == nil || now.timeIntervalSince(drainStart) > 6 { close() }
        case .idle, .finished:
            break
        }
    }

    private func watchWispr(_ now: Date) {
        // A previous dictation is still being transcribed; Wispr will not start another one yet.
        if wantsWisprStart {
            if pendingPaste == nil { startWispr() } else { pollPendingPaste(now) }
            return
        }
        guard wisprStarted, !wisprStopped else { return }
        let recording = WisprController.isRecording
        if recording {
            sawRecording = true
        } else if sawRecording {
            // Stopped by the user (fn key, Esc) or by Wispr itself.
            wisprStopped = true
            pendingPaste = PendingPaste(attempt: attempt, recordStart: recordStart,
                                        deadline: now.addingTimeInterval(config.wispr.transcriptTimeoutSeconds))
            Log.info("session \(request.id): wispr stopped outside VoiceQuestion")
            enterTranscribing()
        } else {
            let waited = now.timeIntervalSince(wisprStartTime)
            if waited > 1.2, !retriedStart {
                retriedStart = true
                wispr.start()
            } else if waited > 3.5, !warnedStart {
                warnedStart = true
                Log.info("session \(request.id): wispr did not start recording")
                panel.setHint(L("Wispr Flow가 녹음을 시작하지 못했어요 · 직접 입력하거나 클릭하세요",
                                "Wispr Flow did not start recording · type or click instead"))
            }
        }
    }

    /// Looks for the transcript in Wispr's history: the fallback when the paste does not reach the
    /// panel, and the way to learn that nothing will be pasted at all.
    private func pollPendingPaste(_ now: Date) {
        guard var pending = pendingPaste else {
            if phase == .transcribing, now.timeIntervalSince(transcribeStart) > 2.5 { handleEmpty() }
            return
        }
        let current = pending.attempt == attempt && phase == .transcribing
        if now >= pending.deadline {
            pendingPaste = nil
            if current { handleEmpty() }
            return
        }
        guard now.timeIntervalSince(lastHistoryPoll) >= 0.3 else { return }
        lastHistoryPoll = now
        guard let row = WisprHistory.rows(since: pending.recordStart.addingTimeInterval(-0.5), limit: 1).first, row.isFinal else { return }

        if row.text.isEmpty {
            pendingPaste = nil // nothing was recognised, so nothing will be pasted
            guard current else { return }
            if row.status == "dismissed" { finish(.skipped("dismissed")) } else { handleEmpty() }
        } else if current, now.timeIntervalSince(transcribeStart) > 0.8 {
            // The paste had its chance; keep expecting it a little longer so a late one is dropped.
            pending.rowSeenAt = pending.rowSeenAt ?? now
            pendingPaste = pending
            gotTranscript(row.text, via: "history")
        } else if let seen = pending.rowSeenAt {
            if !current, now.timeIntervalSince(seen) > 1.5 { pendingPaste = nil } // the paste went elsewhere
        } else {
            pending.rowSeenAt = now
            pendingPaste = pending
        }
    }

    // MARK: - Microphone level

    private func handleLevel(_ level: Double) {
        guard phase == .speaking || phase == .listening else { return }
        panel.setLevel(level)
        // On speakers the question itself would count as speech, so only listen once it is over.
        if phase == .speaking, !micImmediate { return }
        guard let event = vad.feed(levelDb: level, at: ProcessInfo.processInfo.systemUptime) else { return }
        switch event {
        case .speechStarted:
            if phase == .speaking { speaker.stop() } // barge-in
            panel.setStatus(L("듣는 중… 말씀하세요", "Listening… go on"))
        case .endOfSpeech:
            endListening(reason: "silence")
        case .maxDuration:
            endListening(reason: "max_duration")
        case .noSpeechTimeout:
            guard manualSelection.isEmpty else { return }
            noSpeech = true
            endListening(reason: "no_speech")
        }
    }

    // MARK: - Transcript → answer

    private func gotTranscript(_ text: String, via: String) {
        guard phase == .speaking || phase == .listening || phase == .transcribing else { return }
        if phase != .transcribing { enterTranscribing() }
        let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Log.info("session \(request.id): transcript via \(via) \(Log.redact(transcript))")
        panel.setAnswerText(transcript)

        let resolved = AnswerResolver.resolve(transcript: transcript, question: question)
        switch resolved {
        case .empty:
            handleEmpty()
        case .skip:
            finish(.skipped("user_said_skip"))
        case .retry where spokenRetries < 3:
            spokenRetries += 1
            relisten(prompt: spoken("네, 다시 말씀해 주세요.", "Okay, go ahead."))
        case .options(let indices):
            panel.setSelectedOptions(indices)
            confirm(AnswerResolver.answered(resolved: resolved, transcript: transcript, question: question))
        case .freeText, .retry:
            confirm(AnswerResolver.answered(resolved: .freeText(transcript), transcript: transcript, question: question))
        }
    }

    private func handleEmpty() {
        if noSpeech { return finish(.skipped("no_speech")) }
        guard emptyRetries < config.retriesOnEmpty else { return finish(.skipped("no_transcript")) }
        emptyRetries += 1
        relisten(prompt: spoken("잘 못 들었어요. 다시 말씀해 주세요.", "Sorry, I didn't catch that. Please say it again."))
    }

    private func confirm(_ answer: AnsweredQuestion?) {
        guard let answer else { return handleEmpty() }
        pendingAnswer = answer
        panel.setPreview(answer.kind == .freeText ? nil : "→ " + answer.answer)
        panel.setStatus(L("확인", "Confirm"))
        panel.takeKeyboard()
        guard config.autoSendDelaySeconds > 0 else { return commit(answer) }
        phase = .confirming
        confirmDeadline = Date().addingTimeInterval(config.autoSendDelaySeconds)
    }

    private func commitPending() {
        if let pendingAnswer { commit(pendingAnswer) }
    }

    private func commit(_ answer: AnsweredQuestion) {
        Log.info("session \(request.id): answer \(answer.kind.rawValue) \(Log.redact(answer.answer))")
        answers.append(answer)
        speaker.stop()
        monitor.stop()
        stopWispr()
        if questionIndex + 1 < request.questions.count {
            beginQuestion(questionIndex + 1)
        } else {
            finish(AskResponse(status: .answered, answers: answers))
        }
    }

    private func enterEditing() {
        speaker.stop()
        monitor.stop()
        stopWispr()
        phase = .editing
        editingSince = Date()
        panel.setLevel(nil)
        panel.setStatus(L("직접 입력", "Typing"))
        panel.setHint(L("Enter 전송 · ⌘R 다시 말하기 · Esc 건너뛰기", "Return to send · ⌘R to speak again · Esc to skip"))
    }

    /// The answer as it stands in the panel: typed text first, clicked options otherwise.
    private func manualAnswer() -> AnsweredQuestion? {
        let text = panel.answerText
        if text.isEmpty {
            guard !manualSelection.isEmpty else { return nil }
            return AnswerResolver.answered(resolved: .options(manualSelection.sorted()), transcript: "", question: question)
        }
        let resolved = AnswerResolver.resolve(transcript: text, question: question)
        if case .options = resolved { return AnswerResolver.answered(resolved: resolved, transcript: text, question: question) }
        return AnswerResolver.answered(resolved: .freeText(text), transcript: text, question: question)
    }

    // MARK: - QuestionPanelDelegate

    func panelDidSubmit() {
        switch phase {
        case .speaking, .listening:
            if let answer = manualAnswer() {
                commit(answer)
            } else if wisprStarted {
                endListening(reason: "return")
            }
        case .confirming:
            commitPending()
        case .editing:
            if let answer = manualAnswer() { commit(answer) } else { NSSound.beep() }
        case .transcribing, .draining, .idle, .finished:
            break
        }
    }

    func panelDidCancel() {
        switch phase {
        case .confirming:
            enterEditing() // stop the countdown and let the user fix the text
        case .speaking, .listening, .transcribing, .editing:
            finish(.skipped("user"))
        case .draining, .idle, .finished:
            break
        }
    }

    func panelDidRequestRetry() {
        guard phase == .confirming || phase == .editing || phase == .transcribing else { return }
        relisten(prompt: nil)
    }

    func panelDidPickOption(_ index: Int) {
        guard question.options.indices.contains(index),
              [.speaking, .listening, .transcribing, .confirming, .editing].contains(phase) else { return }
        guard question.multiSelect else {
            if let answer = AnswerResolver.answered(resolved: .options([index]), transcript: "", question: question) { commit(answer) }
            return
        }
        if let position = manualSelection.firstIndex(of: index) {
            manualSelection.remove(at: position)
        } else {
            manualSelection.append(index)
        }
        panel.setSelectedOptions(manualSelection)
        panel.setAnswerText("")
        let labels = manualSelection.sorted().map { question.options[$0].label }
        panel.setPreview(labels.isEmpty ? nil : "→ " + labels.joined(separator: ", "))
        enterEditing()
        panel.takeKeyboard()
    }

    func panelDidReceivePaste(_ text: String) -> Bool {
        let now = Date()
        if let pending = pendingPaste, now < pending.deadline {
            pendingPaste = nil
            // The transcript of the answer being waited for; anything else is a leftover to drop.
            if pending.attempt == attempt, phase == .transcribing { gotTranscript(text, via: "paste") }
            return true
        }
        switch phase {
        case .speaking, .listening:
            // Wispr was stopped by hand and its paste beat the ticker.
            guard wisprStarted, sawRecording, !WisprController.isRecording else { return false }
            wisprStopped = true
            gotTranscript(text, via: "paste")
            return true
        case .transcribing:
            gotTranscript(text, via: "paste")
            return true
        case .confirming, .editing:
            return false
        case .draining, .idle, .finished:
            return true
        }
    }

    func panelTextDidChangeByUser() {
        switch phase {
        case .speaking, .listening, .confirming:
            enterEditing()
        case .transcribing:
            typedAt = Date() // some setups deliver the dictation as keystrokes rather than a paste
        case .editing:
            editingSince = Date()
        case .draining, .idle, .finished:
            break
        }
    }
}
