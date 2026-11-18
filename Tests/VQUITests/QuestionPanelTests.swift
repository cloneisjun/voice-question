import AppKit
import Testing
import VQCore
@testable import VoiceQuestion

/// The panel and a session behind it, driven by synthetic clicks. Nothing here reaches the
/// screen, the speaker, the microphone or Wispr Flow.
@MainActor
@Suite("Question panel", .serialized)
struct QuestionPanelTests {
    private final class Outcome {
        var response: AskResponse?
    }

    private static let several = Question(
        question: "Which checks should run before the release?",
        options: [
            .init(label: "Unit tests (Recommended)", description: "Fast, and they cover the parsers."),
            .init(label: "Smoke test"),
            .init(label: "Manual pass", description: "Someone walks through the panel by hand."),
        ],
        multiSelect: true)

    private func makePanel() -> QuestionPanel {
        _ = NSApplication.shared
        // Keep the session's log lines out of the installed app's log.
        setenv("VQ_LOG", NSTemporaryDirectory() + "voicequestion-tests.log", 0)
        let panel = QuestionPanel()
        panel.showsWindow = false
        return panel
    }

    private func start(_ question: Question, on panel: QuestionPanel, outcome: Outcome, autoSend: Double = 2) -> QuestionSession {
        var config = VQConfig()
        config.speakQuestions = false
        config.skipWhenMicBusy = false
        config.autoSendDelaySeconds = autoSend
        let request = AskRequest(id: "test", source: .cli, questions: [question])
        let session = QuestionSession(request: request, config: config, panel: panel,
                                      completion: { outcome.response = $0 }, onIdle: {})
        session.allowsVoiceInput = false
        session.start()
        return session
    }

    private func rows(of panel: QuestionPanel) throws -> [OptionRowView] {
        descendants(of: try #require(panel.contentView))
    }

    @Test func oneClickAnswersAQuestionThatAllowsSeveral() throws {
        let panel = makePanel()
        let outcome = Outcome()
        let session = start(QuestionPanelTests.several, on: panel, outcome: outcome)
        let rows = try rows(of: panel)
        #expect(rows.count == 3)
        #expect(outcome.response == nil)

        rows[1].mouseDown(with: try mouseDown())

        let response = try #require(outcome.response)
        #expect(response.status == .answered)
        #expect(response.answers.map(\.answer) == ["Smoke test"])
        #expect(response.answers.first?.kind == .option)
        #expect(session.phase == .finished)
        #expect(!panel.isVisible)
    }

    @Test func commandClicksCollectAndSendAnswersWithAllOfThem() throws {
        let panel = makePanel()
        let outcome = Outcome()
        let session = start(QuestionPanelTests.several, on: panel, outcome: outcome)
        let rows = try rows(of: panel)

        rows[2].mouseDown(with: try mouseDown(modifiers: .command))
        rows[0].mouseDown(with: try mouseDown(modifiers: .shift))
        #expect(outcome.response == nil)
        #expect(session.phase == .editing)
        #expect(rows.map(\.isSelected) == [true, false, true])

        // A second ⌘-click takes an option out again.
        rows[2].mouseDown(with: try mouseDown(modifiers: .command))
        #expect(rows.map(\.isSelected) == [true, false, false])
        rows[2].mouseDown(with: try mouseDown(modifiers: .command))

        session.panelDidSubmit()
        let response = try #require(outcome.response)
        #expect(response.status == .answered)
        // The agent gets the full labels, marker included, in the order of the options.
        #expect(response.answers.first?.selectedLabels == ["Unit tests (Recommended)", "Manual pass"])
        #expect(response.answers.first?.kind == .options)
        #expect(!panel.isVisible)
    }

    @Test func plainClickAfterCollectingSendsJustThatOption() throws {
        let panel = makePanel()
        let outcome = Outcome()
        let session = start(QuestionPanelTests.several, on: panel, outcome: outcome)
        let rows = try rows(of: panel)

        rows[0].mouseDown(with: try mouseDown(modifiers: .command))
        rows[1].mouseDown(with: try mouseDown())
        #expect(outcome.response?.answers.map(\.answer) == ["Smoke test"])
        #expect(session.phase == .finished)
    }

    @Test func commandClickOnASingleChoiceQuestionStillAnswers() throws {
        let panel = makePanel()
        let outcome = Outcome()
        var question = QuestionPanelTests.several
        question.multiSelect = false
        let session = start(question, on: panel, outcome: outcome)

        try rows(of: panel)[2].mouseDown(with: try mouseDown(modifiers: .command))
        #expect(outcome.response?.answers.map(\.answer) == ["Manual pass"])
        #expect(session.phase == .finished)
    }

    @Test func closeButtonSkipsAndTypedTextIsSentAsIs() throws {
        let panel = makePanel()
        let skipped = Outcome()
        let first = start(Question(question: "What should the release be called?"), on: panel, outcome: skipped)
        first.panelDidSkip()
        #expect(skipped.response?.status == .skipped)
        #expect(skipped.response?.reason == "user")

        let typed = Outcome()
        let second = start(Question(question: "What should the release be called?"), on: panel, outcome: typed)
        panel.setAnswerText("Autumn")
        second.panelTextDidChangeByUser()
        #expect(second.phase == .editing)
        second.panelDidSubmit()
        #expect(typed.response?.answers.map(\.answer) == ["Autumn"])
        #expect(typed.response?.answers.first?.kind == .freeText)
        #expect(!panel.isVisible)
    }

    @Test func chromeIsSymbolsNotSentences() throws {
        let panel = makePanel()
        let question = QuestionPanelTests.several
        panel.present(source: .cli, title: nil, question: question, index: 0, total: 3, activation: .nonactivating)
        let content = try #require(panel.contentView)

        for state in [PanelState.reading, .listening, .hearing, .transcribing, .confirming(seconds: 2), .editing, .finishing] {
            panel.setState(state)
            content.layoutSubtreeIfNeeded()
            // Everything written on the panel is the question itself: who asks, the question, the
            // options. No status line, hint, counter, placeholder or button title.
            let shown = descendants(of: content, as: NSTextField.self).filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.stringValue)
            let expected = ["VoiceQuestion", question.question]
                + question.options.flatMap { [$0.displayTitle] + ($0.description.map { [$0] } ?? []) }
            #expect(shown == expected, "state \(state)")
            #expect(descendants(of: content, as: NSButton.self).isEmpty)
        }

        // Three questions, three dots; the countdown is a ring on the send button.
        #expect(descendants(of: content, as: ProgressDots.self).first?.isHidden == false)
        let buttons = descendants(of: content, as: IconButton.self)
        panel.setState(.confirming(seconds: 2))
        #expect(buttons.filter { $0.countdownLeft() != nil }.count == 1)
        panel.setState(.editing)
        #expect(buttons.allSatisfy { $0.countdownLeft() == nil })

        // What a symbol cannot say still gets a line.
        panel.setState(.unavailable)
        panel.setNotice("Wispr Flow is not running")
        let withNotice = descendants(of: content, as: NSTextField.self).filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.stringValue)
        #expect(withNotice.last == "Wispr Flow is not running")
        #expect(!panel.isVisible)
    }

    @Test func countdownRingEmptiesOverItsDuration() {
        _ = NSApplication.shared
        let button = IconButton(style: .filled, diameter: 32, pointSize: 12)
        #expect(button.countdownLeft() == nil)
        button.startCountdown(2, from: 100)
        #expect(button.countdownLeft(at: 100) == 1)
        #expect(button.countdownLeft(at: 101) == 0.5)
        #expect(button.countdownLeft(at: 103) == 0)
        button.stopCountdown()
        #expect(button.countdownLeft() == nil)
    }

    @Test func waveformKeepsTheLoudestMomentOfEachBar() {
        _ = NSApplication.shared
        let waveform = WaveformView(frame: NSRect(x: 0, y: 0, width: 60, height: 20))
        waveform.push(0.2, at: 10.00)
        waveform.push(0.9, at: 10.02)
        waveform.push(0.1, at: 10.07)
        #expect(waveform.levels == [0.2, 0.9])
        // Ten bars fit in 60 points; older ones scroll out.
        for step in 0..<40 { waveform.push(0.5, at: 11 + Double(step) * 0.1) }
        #expect(waveform.levels.count == 11)
        waveform.reset()
        #expect(waveform.levels.isEmpty)
    }

    /// `VQ_SNAPSHOT_DIR=DIR ./scripts/test.sh` writes each state of the panel as a PNG, drawn
    /// offscreen, to look at the design without putting a window on screen.
    @Test func everyStateDrawsOffscreen() throws {
        let panel = makePanel()
        let directory = VQ.environment("VQ_SNAPSHOT_DIR").map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        func snapshot(_ name: String) throws {
            try #require(panel.contentView).layoutSubtreeIfNeeded()
            let png = try #require(panel.snapshotPNG())
            #expect(png.count > 1000)
            try directory.map { try png.write(to: $0.appendingPathComponent(name + ".png")) }
        }

        panel.present(source: .claudeCode, title: "voice-question", question: QuestionPanelTests.several, index: 1, total: 3,
                      activation: .nonactivating)
        panel.setState(.reading)
        try snapshot("1-reading")

        panel.setState(.hearing)
        for step in 0..<80 {
            let level = 0.5 + 0.45 * sin(Double(step) / 3) * cos(Double(step) / 7)
            panel.setLevel(-60 + 45 * max(level, 0.02) * (step > 20 ? 1 : 0.1))
            // One bar per 60 ms: let the clock move between levels.
            Thread.sleep(forTimeInterval: 0.012)
        }
        try snapshot("2-hearing")

        panel.setLevel(nil)
        panel.setState(.transcribing)
        try snapshot("3-transcribing")

        panel.setAnswerText("unit tests and the manual pass")
        panel.setSelectedOptions([0, 2])
        panel.setState(.confirming(seconds: 60))
        try snapshot("4-confirming")

        panel.setAnswerText("")
        panel.setSelectedOptions([])
        panel.setState(.unavailable)
        panel.setNotice("Wispr Flow is not running · click or type")
        try snapshot("5-unavailable")

        panel.present(source: .cli, title: nil, question: Question(question: "이번 릴리스 이름은 무엇으로 할까요?"), index: 0, total: 1,
                      activation: .nonactivating)
        panel.setState(.editing)
        panel.setAnswerText("가을 릴리스로 하고, 변경 내역에는 음성 패널 개편과 한 번 클릭 전송을 먼저 적어 주세요. 나머지는 지난번과 같은 순서로.")
        try snapshot("6-typing")
        #expect(!panel.isVisible)
    }
}
