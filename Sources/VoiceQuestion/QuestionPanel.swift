import AppKit
import VQCore

protocol QuestionPanelDelegate: AnyObject {
    /// Return / the send button.
    func panelDidSubmit()
    /// Esc.
    func panelDidCancel()
    /// The close button.
    func panelDidSkip()
    /// ⌘R / the speak-again button.
    func panelDidRequestRetry()
    /// A click on an option, or ⌘1…⌘9. `collecting` is a ⌘- or ⇧-click: add the option to a
    /// selection rather than answer with it.
    func panelDidPickOption(_ index: Int, collecting: Bool)
    /// Something was pasted (this is how Wispr Flow delivers a transcript). Return true when the
    /// session consumed it, false to let it be inserted like ordinary text.
    func panelDidReceivePaste(_ text: String) -> Bool
    /// The user typed in the answer field.
    func panelTextDidChangeByUser()
    /// The user clicked into the answer field.
    func panelDidClickAnswerField()
}

/// What the panel shows the app doing. Each state is a symbol in the answer field, not a sentence.
enum PanelState: Equatable {
    /// The question is being read aloud.
    case reading
    /// The microphone is open.
    case listening
    /// The microphone is open and speech has been heard.
    case hearing
    case transcribing
    /// The answer is in, and is sent after this many seconds unless the user steps in.
    case confirming(seconds: TimeInterval)
    /// The user is typing or choosing by hand.
    case editing
    /// Voice input is not working: type or click.
    case unavailable
    case finishing
}

/// The floating question card: question, options, an editable answer field and the listening state.
///
/// It is a non-activating panel that can still become key, so it can receive the dictated text
/// without pulling VoiceQuestion in front of the app the user is working in.
final class QuestionPanel: NSObject, NSTextViewDelegate {
    weak var delegate: QuestionPanelDelegate?
    /// False lays the panel out and draws it without ever putting it on screen (tests).
    var showsWindow = true

    private static let width: CGFloat = 460
    private static let inset: CGFloat = 16
    private static let contentWidth = width - 2 * inset
    private static let answerFont = NSFont.systemFont(ofSize: 14)
    private static let answerInset = NSSize(width: 2, height: 10)
    /// The answer field between the state symbol (7 + 26 + 1) and the send button (2 + 32 + 4).
    private static let answerWidth = contentWidth - 72
    private static let answerMinHeight: CGFloat = 40

    private let panel: KeyablePanel
    private let stack = NSStackView()
    private let sourceIcon = NSImageView()
    private let sourceLabel = QuestionPanel.label(size: 11, weight: .medium, color: .secondaryLabelColor)
    private let dots = ProgressDots()
    private let closeButton = IconButton(style: .plain, diameter: 22, pointSize: 10)
    private let questionLabel = QuestionPanel.label(size: 15, weight: .semibold, color: .labelColor, wraps: true)
    private let optionsStack = NSStackView()
    private let answerBox = RoundedBox()
    private let stateButton = IconButton(style: .plain, diameter: 26, pointSize: 13)
    private let scrollView = NSScrollView()
    private let textView = AnswerTextView()
    private let waveform = WaveformView()
    private let sendButton = IconButton(style: .filled, diameter: 32, pointSize: 12)
    private let noticeIcon = NSImageView()
    private let noticeLabel = QuestionPanel.label(size: 11, weight: .regular, color: .secondaryLabelColor, wraps: true)
    private let noticeRow = NSStackView()
    private var answerHeight: NSLayoutConstraint!
    private var optionRows: [OptionRowView] = []
    private var hasLevel = false
    private var programmaticChange = false
    private var activation = VQConfig.PanelActivation.nonactivating
    private var topLeft: NSPoint?

    override init() {
        panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: QuestionPanel.width, height: 200),
                             styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        buildWindow()
        buildContent()
    }

    // MARK: - Public surface

    var isVisible: Bool { panel.isVisible }
    var isKey: Bool { panel.isKeyWindow }
    /// The panel's views, to lay out and click through without a window on screen (tests).
    var contentView: NSView? { panel.contentView }

    var answerText: String {
        textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Shows a question without taking the keyboard.
    func present(source: QuestionSource, title: String?, question: Question, index: Int, total: Int,
                 activation: VQConfig.PanelActivation) {
        self.activation = activation
        // The asking app's icon stands in for its name; without one the name is spelled out.
        let icon = QuestionPanel.icon(for: source)
        let name = [source.displayName, title].compactMap { $0 }.joined(separator: " · ")
        sourceIcon.image = icon
        sourceIcon.isHidden = icon == nil
        sourceIcon.toolTip = name
        sourceLabel.stringValue = icon == nil ? name : (title ?? source.displayName)
        sourceLabel.toolTip = name
        dots.set(index: index, total: total)
        questionLabel.stringValue = question.question

        optionRows.forEach { $0.removeFromSuperview() }
        optionRows = question.options.enumerated().map { offset, option in
            let row = OptionRowView(number: offset + 1, option: option, width: QuestionPanel.contentWidth)
            row.onClick = { [weak self] collecting in self?.delegate?.panelDidPickOption(offset, collecting: collecting) }
            if question.multiSelect { row.toolTip = L("⌘-클릭: 여러 개 고르기", "⌘-click to choose several") }
            optionsStack.addArrangedSubview(row)
            return row
        }
        optionsStack.isHidden = optionRows.isEmpty
        setAnswerText("")
        setNotice(nil)
        setLevel(nil)

        let wasVisible = panel.isVisible
        layout(resetPosition: !wasVisible)
        if !wasVisible, showsWindow { panel.orderFrontRegardless() }
    }

    func setState(_ state: PanelState) {
        sendButton.stopCountdown()
        stateButton.onClick = nil
        waveform.isHearing = state == .hearing
        switch state {
        case .reading:
            stateButton.setSymbol("speaker.wave.2.fill", tint: .labelColor, animated: true, label: L("질문 읽는 중", "Reading the question"))
        case .listening:
            stateButton.setSymbol("mic.fill", tint: .labelColor, label: L("듣는 중", "Listening"))
        case .hearing:
            stateButton.setSymbol("mic.fill", tint: .systemGreen, label: L("듣는 중", "Listening"))
        case .transcribing:
            stateButton.setSymbol("ellipsis", tint: .labelColor, animated: true, label: L("받아쓰는 중", "Transcribing"))
        case .confirming(let seconds):
            sendButton.startCountdown(seconds)
            fallthrough
        case .editing:
            stateButton.setSymbol("arrow.counterclockwise", label: L("다시 말하기 (⌘R)", "Speak again (⌘R)"))
            stateButton.onClick = { [weak self] in self?.delegate?.panelDidRequestRetry() }
        case .unavailable:
            stateButton.setSymbol("mic.slash.fill", tint: .systemOrange, label: L("음성 입력 꺼짐", "Voice input is off"))
        case .finishing:
            stateButton.setSymbol("checkmark", tint: .systemGreen, label: L("마무리 중", "Finishing"))
        }
        if KeyablePanel.snapshotDirectory != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.writeSnapshot() } }
    }

    /// A line under the answer field, for the cases a symbol cannot explain (Wispr Flow is not
    /// running, …). Nil hides it, which is the normal state.
    func setNotice(_ text: String?) {
        noticeLabel.stringValue = text ?? ""
        let hidden = (text ?? "").isEmpty
        if noticeRow.isHidden != hidden {
            noticeRow.isHidden = hidden
            layout(resetPosition: false)
        }
    }

    /// Microphone level in dBFS, drawn as a waveform in the empty answer field. Nil clears it.
    func setLevel(_ db: Double?) {
        if let db {
            hasLevel = true
            waveform.push(CGFloat(min(max((db + 60) / 45, 0), 1)))
        } else {
            hasLevel = false
            waveform.reset()
        }
        waveform.isHidden = !hasLevel || !textView.string.isEmpty
    }

    func setAnswerText(_ text: String) {
        programmaticChange = true
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        textView.needsDisplay = true
        programmaticChange = false
        answerTextChanged()
    }

    func setSelectedOptions(_ indices: [Int]) {
        for (offset, row) in optionRows.enumerated() { row.isSelected = indices.contains(offset) }
    }

    func setButtons(sendEnabled: Bool) {
        sendButton.isEnabled = sendEnabled
    }

    /// Makes the answer field the keyboard target so the dictated text lands here.
    func takeKeyboard() {
        guard showsWindow else { return }
        if activation == .activate {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
            panel.makeKey()
        }
        panel.makeFirstResponder(textView)
        if KeyablePanel.logsKeys { Log.info("panel: took the keyboard (key window: \(panel.isKeyWindow))") }
    }

    func close() {
        panel.orderOut(nil)
        topLeft = nil
        // Nothing keeps animating or counting down behind a closed panel.
        stateButton.clear()
        sendButton.stopCountdown()
        setLevel(nil)
    }

    // MARK: - Construction

    private func buildWindow() {
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .vibrantDark)
        panel.animationBehavior = .utilityWindow

        panel.onCommandKey = { [weak self] keyCode in self?.handleCommandKey(keyCode) ?? false }
        panel.onSubmit = { [weak self] in self?.delegate?.panelDidSubmit() }
        panel.onCancel = { [weak self] in self?.delegate?.panelDidCancel() }
    }

    private func buildContent() {
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        panel.contentView = background

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: QuestionPanel.inset, bottom: 14, right: QuestionPanel.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        let contentWidth = QuestionPanel.contentWidth
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: QuestionPanel.width),
        ])

        // Header: who is asking, which question of how many, and the way out.
        sourceIcon.imageScaling = .scaleProportionallyUpOrDown
        sourceIcon.translatesAutoresizingMaskIntoConstraints = false
        sourceIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        sourceIcon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        sourceLabel.lineBreakMode = .byTruncatingMiddle
        sourceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dots.translatesAutoresizingMaskIntoConstraints = false
        dots.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.setSymbol("xmark", label: L("건너뛰기", "Skip"))
        closeButton.onClick = { [weak self] in self?.delegate?.panelDidSkip() }

        let header = NSStackView(views: [sourceIcon, sourceLabel, dots, NSView(), closeButton])
        header.orientation = .horizontal
        header.distribution = .fill
        header.alignment = .centerY
        header.spacing = 6
        header.setCustomSpacing(10, after: sourceLabel)
        header.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        stack.addArrangedSubview(header)

        questionLabel.preferredMaxLayoutWidth = contentWidth
        questionLabel.maximumNumberOfLines = 8
        questionLabel.isSelectable = true
        stack.addArrangedSubview(questionLabel)
        stack.setCustomSpacing(12, after: questionLabel)

        optionsStack.orientation = .vertical
        optionsStack.alignment = .leading
        optionsStack.spacing = 5
        stack.addArrangedSubview(optionsStack)

        // Answer field: what the app is doing on the left, the answer (or, while it is still
        // empty, the microphone level) in the middle, send on the right.
        answerBox.translatesAutoresizingMaskIntoConstraints = false

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = QuestionPanel.answerFont
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = QuestionPanel.answerInset
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.onPaste = { [weak self] text in self?.delegate?.panelDidReceivePaste(text) ?? false }
        textView.onMouseDown = { [weak self] in self?.delegate?.panelDidClickAnswerField() }
        textView.setAccessibilityLabel(L("답변", "Answer"))
        scrollView.documentView = textView

        waveform.translatesAutoresizingMaskIntoConstraints = false
        waveform.isHidden = true
        sendButton.setSymbol("arrow.up", label: L("보내기 (Return)", "Send (Return)"))
        sendButton.onClick = { [weak self] in self?.delegate?.panelDidSubmit() }

        for view in [stateButton, scrollView, waveform, sendButton] { answerBox.addSubview(view) }
        answerHeight = answerBox.heightAnchor.constraint(equalToConstant: QuestionPanel.answerMinHeight)
        // The buttons stay on the last line when the field grows.
        let lastLine = answerBox.bottomAnchor.anchorWithOffset(to: stateButton.centerYAnchor)
        NSLayoutConstraint.activate([
            answerBox.widthAnchor.constraint(equalToConstant: contentWidth),
            answerHeight,
            stateButton.leadingAnchor.constraint(equalTo: answerBox.leadingAnchor, constant: 7),
            lastLine.constraint(equalToConstant: -QuestionPanel.answerMinHeight / 2),
            sendButton.trailingAnchor.constraint(equalTo: answerBox.trailingAnchor, constant: -4),
            sendButton.centerYAnchor.constraint(equalTo: stateButton.centerYAnchor),
            scrollView.leadingAnchor.constraint(equalTo: stateButton.trailingAnchor, constant: 1),
            scrollView.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -2),
            scrollView.topAnchor.constraint(equalTo: answerBox.topAnchor, constant: 1),
            scrollView.bottomAnchor.constraint(equalTo: answerBox.bottomAnchor, constant: -1),
            waveform.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 7),
            waveform.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -6),
            waveform.centerYAnchor.constraint(equalTo: stateButton.centerYAnchor),
            waveform.heightAnchor.constraint(equalToConstant: 20),
        ])
        stack.addArrangedSubview(answerBox)

        // Only for what a symbol cannot say; hidden otherwise.
        noticeIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        noticeIcon.contentTintColor = .systemOrange
        noticeIcon.setContentHuggingPriority(.required, for: .horizontal)
        noticeLabel.preferredMaxLayoutWidth = contentWidth - 20
        noticeLabel.maximumNumberOfLines = 2
        noticeRow.orientation = .horizontal
        noticeRow.alignment = .firstBaseline
        noticeRow.spacing = 5
        noticeRow.addArrangedSubview(noticeIcon)
        noticeRow.addArrangedSubview(noticeLabel)
        noticeRow.isHidden = true
        stack.addArrangedSubview(noticeRow)

        setState(.reading)
    }

    private static func label(size: CGFloat, weight: NSFont.Weight, color: NSColor, wraps: Bool = false) -> NSTextField {
        let label = wraps ? NSTextField(wrappingLabelWithString: "") : NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        return label
    }

    /// The icon of the app that is asking, when that app is installed here.
    private static func icon(for source: QuestionSource) -> NSImage? {
        let bundleIDs: [String]
        switch source {
        case .claudeCode: bundleIDs = ["com.anthropic.claudefordesktop"]
        case .codex: bundleIDs = ["com.openai.codex", "com.openai.chat"]
        case .aside: bundleIDs = ["at.studio.AsideBrowser"]
        case .cli: return Bundle.main.bundleIdentifier == VQ.bundleID ? NSApp.applicationIconImage : nil
        }
        return bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// Fits the window to its content, keeping the top edge where it is.
    private func layout(resetPosition: Bool) {
        stack.layoutSubtreeIfNeeded()
        let size = NSSize(width: QuestionPanel.width, height: max(stack.fittingSize.height, 120))
        if resetPosition || topLeft == nil {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            topLeft = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - 12)
        } else {
            topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        }
        let origin = NSPoint(x: topLeft!.x, y: topLeft!.y - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
    }

    /// One line while the answer is short, up to five as it grows; longer answers scroll.
    private func answerTextChanged() {
        waveform.isHidden = !hasLevel || !textView.string.isEmpty

        let line = ceil(NSLayoutManager().defaultLineHeight(for: QuestionPanel.answerFont))
        var height = line
        if !textView.string.isEmpty {
            let padding = textView.textContainer?.lineFragmentPadding ?? 5
            let width = QuestionPanel.answerWidth - 2 * QuestionPanel.answerInset.width - 2 * padding
            let bounds = (textView.string as NSString).boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: QuestionPanel.answerFont])
            height = min(max(line, ceil(bounds.height)), line * 5)
        }
        let target = max(QuestionPanel.answerMinHeight, height + 2 * QuestionPanel.answerInset.height + 2)
        guard abs(answerHeight.constant - target) > 0.5 else { return }
        answerHeight.constant = target
        layout(resetPosition: false)
    }

    /// The panel as a PNG at 2x (without the blur behind it), to check the layout by eye. Works
    /// without the panel being on screen.
    func snapshotPNG() -> Data? {
        guard let view = panel.contentView else { return nil }
        let bounds = view.bounds
        func bitmap() -> NSBitmapImageRep? {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            rep?.size = bounds.size
            return rep
        }
        guard let content = bitmap(), let result = bitmap(), let context = NSGraphicsContext(bitmapImageRep: result) else { return nil }
        view.cacheDisplay(in: bounds, to: content)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(white: 0.14, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        content.draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()
        return result.representation(using: .png, properties: [:])
    }

    private var snapshotCount = 0

    /// `VQ_DEBUG_SNAPSHOT`: saves `panel-N.png` on every state change.
    private func writeSnapshot() {
        guard let directory = KeyablePanel.snapshotDirectory, panel.isVisible, let png = snapshotPNG() else { return }
        snapshotCount += 1
        try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("panel-\(snapshotCount).png"))
    }

    // MARK: - Input

    /// ⌘-shortcuts, by key code so they work in any keyboard layout or input source.
    private func handleCommandKey(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 9: // V
            let text = NSPasteboard.general.string(forType: .string) ?? ""
            if delegate?.panelDidReceivePaste(text) != true {
                panel.makeFirstResponder(textView)
                textView.pasteAsPlainText(nil)
            }
            return true
        case 15: // R
            delegate?.panelDidRequestRetry()
            return true
        case 0: // A
            textView.selectAll(nil)
            return true
        case 8: // C
            textView.copy(nil)
            return true
        case 7: // X
            textView.cut(nil)
            return true
        case 6: // Z
            textView.undoManager?.undo()
            return true
        default:
            // Number row: 1 2 3 4 5 6 7 8 9
            if let index = [18, 19, 20, 21, 23, 22, 26, 28, 25].firstIndex(of: Int(keyCode)), index < optionRows.count {
                delegate?.panelDidPickOption(index, collecting: false)
                return true
            }
            return false
        }
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            // Shift-Return adds a line; Return alone sends.
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
            delegate?.panelDidSubmit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            delegate?.panelDidCancel()
            return true
        default:
            return false
        }
    }

    func textDidChange(_ notification: Notification) {
        answerTextChanged()
        if !programmaticChange { delegate?.panelTextDidChangeByUser() }
    }
}

// MARK: - Window

final class KeyablePanel: NSPanel {
    var onCommandKey: ((UInt16) -> Bool)?
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?

    /// `VQ_DEBUG_KEYS=1` logs the key codes that reach the panel (to check keyboard routing).
    static let logsKeys = VQ.environment("VQ_DEBUG_KEYS") == "1"
    /// `VQ_DEBUG_SNAPSHOT=DIR` saves a picture of the panel on every state change.
    static let snapshotDirectory = VQ.environment("VQ_DEBUG_SNAPSHOT")

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // An agent app has no menu bar, so ⌘V and friends never reach the text view unless routed here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if KeyablePanel.logsKeys, event.type == .keyDown { Log.info("panel: key equivalent \(event.keyCode)") }
        if event.type == .keyDown, flags == .command, onCommandKey?(event.keyCode) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if KeyablePanel.logsKeys, event.type == .keyDown { Log.info("panel: keyDown \(event.keyCode)") }
        super.sendEvent(event)
    }

    // Return / Esc when the answer field is not the first responder.
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onSubmit?()
        case 53: onCancel?()
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

// MARK: - Views

final class AnswerTextView: NSTextView {
    var onPaste: ((String) -> Bool)?
    var onMouseDown: (() -> Void)?

    override func paste(_ sender: Any?) {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        if onPaste?(text) == true { return }
        pasteAsPlainText(sender)
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
    }
}

/// A short message that fades on its own, e.g. "답변을 복사했어요".
final class Toast {
    private static var current: NSPanel?

    static func show(_ message: String, seconds: TimeInterval = 5) {
        // A test instance puts nothing on screen.
        guard VQ.environment("VQ_HEADLESS") != "1" else { return }
        current?.orderOut(nil)

        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.preferredMaxLayoutWidth = 380
        label.translatesAutoresizingMaskIntoConstraints = false

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12),
        ])

        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .vibrantDark)
        panel.contentView = background
        background.layoutSubtreeIfNeeded()

        let size = background.fittingSize
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 12, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        current = panel

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if current === panel {
                panel.orderOut(nil)
                current = nil
            }
        }
    }
}
