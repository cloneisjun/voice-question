import AppKit
import VQCore

protocol QuestionPanelDelegate: AnyObject {
    /// Return / the Send button.
    func panelDidSubmit()
    /// Esc / the Skip button.
    func panelDidCancel()
    /// ⌘R.
    func panelDidRequestRetry()
    /// A click on an option, or ⌘1…⌘9.
    func panelDidPickOption(_ index: Int)
    /// Something was pasted (this is how Wispr Flow delivers a transcript). Return true when the
    /// session consumed it, false to let it be inserted like ordinary text.
    func panelDidReceivePaste(_ text: String) -> Bool
    /// The user typed in the answer field.
    func panelTextDidChangeByUser()
}

/// The floating question card: question, options, an editable answer field and the listening state.
///
/// It is a non-activating panel that can still become key, so it can receive the dictated text
/// without pulling VoiceQuestion in front of the app the user is working in.
final class QuestionPanel: NSObject, NSTextViewDelegate {
    weak var delegate: QuestionPanelDelegate?

    private static let width: CGFloat = 460
    private static let inset: CGFloat = 16

    private let panel: KeyablePanel
    private let stack = NSStackView()
    private let sourceLabel = QuestionPanel.label(size: 11, weight: .medium, color: .secondaryLabelColor)
    private let statusLabel = QuestionPanel.label(size: 11, weight: .medium, color: .secondaryLabelColor)
    private let questionLabel = QuestionPanel.label(size: 15, weight: .semibold, color: .labelColor, wraps: true)
    private let optionsStack = NSStackView()
    private let answerBox = NSView()
    private let scrollView = NSScrollView()
    private let textView = AnswerTextView()
    private let previewLabel = QuestionPanel.label(size: 12, weight: .medium, color: .labelColor, wraps: true)
    private let levelView = LevelView()
    private let hintLabel = QuestionPanel.label(size: 11, weight: .regular, color: .secondaryLabelColor)
    private let skipButton = NSButton(title: "", target: nil, action: nil)
    private let sendButton = NSButton(title: "", target: nil, action: nil)
    private var optionRows: [OptionRowView] = []
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

    var answerText: String {
        textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Shows a question without taking the keyboard.
    func present(source: String, question: Question, index: Int, total: Int, activation: VQConfig.PanelActivation) {
        self.activation = activation
        sourceLabel.stringValue = total > 1 ? "\(source)  ·  \(index + 1)/\(total)" : source
        questionLabel.stringValue = question.question

        optionRows.forEach { $0.removeFromSuperview() }
        optionRows = question.options.enumerated().map { offset, option in
            let row = OptionRowView(number: offset + 1, option: option, width: QuestionPanel.width - 2 * QuestionPanel.inset)
            row.onClick = { [weak self] in self?.delegate?.panelDidPickOption(offset) }
            optionsStack.addArrangedSubview(row)
            return row
        }
        optionsStack.isHidden = optionRows.isEmpty
        textView.placeholder = question.options.isEmpty
            ? L("말하거나 직접 입력하세요", "Speak or type your answer")
            : L("말하거나, 번호를 누르거나, 직접 입력하세요", "Speak, pick a number, or type")
        setAnswerText("")
        setPreview(nil)
        setLevel(nil)

        let wasVisible = panel.isVisible
        layout(resetPosition: !wasVisible)
        if !wasVisible { panel.orderFrontRegardless() }
    }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
        if KeyablePanel.snapshotDirectory != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.writeSnapshot() } }
    }

    func setHint(_ text: String) {
        hintLabel.stringValue = text
    }

    /// "→ 일반 체크카드": what is about to be sent.
    func setPreview(_ text: String?) {
        previewLabel.stringValue = text ?? ""
        let hidden = (text ?? "").isEmpty
        if previewLabel.isHidden != hidden {
            previewLabel.isHidden = hidden
            layout(resetPosition: false)
        }
    }

    /// Microphone level in dBFS, or nil to hide the meter.
    func setLevel(_ db: Double?) {
        levelView.isHidden = db == nil
        if let db { levelView.level = CGFloat(min(max((db + 60) / 45, 0), 1)) }
    }

    func setAnswerText(_ text: String) {
        programmaticChange = true
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        textView.needsDisplay = true
        programmaticChange = false
    }

    func setSelectedOptions(_ indices: [Int]) {
        for (offset, row) in optionRows.enumerated() { row.isSelected = indices.contains(offset) }
    }

    func setButtons(sendEnabled: Bool) {
        sendButton.isEnabled = sendEnabled
    }

    /// Makes the answer field the keyboard target so the dictated text lands here.
    func takeKeyboard() {
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
        stack.edgeInsets = NSEdgeInsets(top: QuestionPanel.inset, left: QuestionPanel.inset, bottom: 12, right: QuestionPanel.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        let contentWidth = QuestionPanel.width - 2 * QuestionPanel.inset
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: QuestionPanel.width),
        ])

        // Header: where the question came from, and what the app is doing right now.
        let header = NSStackView(views: [sourceLabel, NSView(), statusLabel])
        header.orientation = .horizontal
        header.distribution = .fill
        statusLabel.alignment = .right
        header.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        stack.addArrangedSubview(header)

        questionLabel.preferredMaxLayoutWidth = contentWidth
        questionLabel.maximumNumberOfLines = 8
        questionLabel.isSelectable = true
        stack.addArrangedSubview(questionLabel)

        optionsStack.orientation = .vertical
        optionsStack.alignment = .leading
        optionsStack.spacing = 4
        stack.addArrangedSubview(optionsStack)

        // Answer field.
        answerBox.wantsLayer = true
        answerBox.layer?.cornerRadius = 8
        answerBox.layer?.borderWidth = 1
        answerBox.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        answerBox.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        answerBox.translatesAutoresizingMaskIntoConstraints = false

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 7)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.onPaste = { [weak self] text in self?.delegate?.panelDidReceivePaste(text) ?? false }
        scrollView.documentView = textView

        answerBox.addSubview(scrollView)
        NSLayoutConstraint.activate([
            answerBox.widthAnchor.constraint(equalToConstant: contentWidth),
            answerBox.heightAnchor.constraint(equalToConstant: 58),
            scrollView.leadingAnchor.constraint(equalTo: answerBox.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: answerBox.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: answerBox.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: answerBox.bottomAnchor),
        ])
        stack.addArrangedSubview(answerBox)

        previewLabel.preferredMaxLayoutWidth = contentWidth
        previewLabel.maximumNumberOfLines = 3
        previewLabel.isHidden = true
        stack.addArrangedSubview(previewLabel)

        // Footer: level meter, key hints, buttons.
        skipButton.title = L("건너뛰기", "Skip")
        sendButton.title = L("보내기", "Send")
        for button in [skipButton, sendButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.target = self
            button.refusesFirstResponder = true
        }
        skipButton.action = #selector(skipClicked)
        sendButton.action = #selector(sendClicked)
        levelView.translatesAutoresizingMaskIntoConstraints = false
        levelView.widthAnchor.constraint(equalToConstant: 44).isActive = true
        levelView.heightAnchor.constraint(equalToConstant: 6).isActive = true
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hintLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let footer = NSStackView(views: [levelView, hintLabel, skipButton, sendButton])
        footer.orientation = .horizontal
        footer.distribution = .fill
        footer.alignment = .centerY
        footer.spacing = 8
        footer.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        stack.addArrangedSubview(footer)
    }

    private static func label(size: CGFloat, weight: NSFont.Weight, color: NSColor, wraps: Bool = false) -> NSTextField {
        let label = wraps ? NSTextField(wrappingLabelWithString: "") : NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        return label
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

    private var snapshotCount = 0

    /// Draws the panel into `panel-N.png` (without the blur behind it), to check the layout by eye.
    private func writeSnapshot() {
        guard let directory = KeyablePanel.snapshotDirectory, panel.isVisible, let view = panel.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size, flipped: false) { rect in
            NSColor(white: 0.14, alpha: 1).setFill()
            rect.fill()
            bitmap.draw(in: rect)
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        snapshotCount += 1
        try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("panel-\(snapshotCount).png"))
    }

    // MARK: - Input

    @objc private func skipClicked() {
        delegate?.panelDidCancel()
    }

    @objc private func sendClicked() {
        delegate?.panelDidSubmit()
    }

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
                delegate?.panelDidPickOption(index)
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
        textView.needsDisplay = true
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
    /// `VQ_DEBUG_SNAPSHOT=DIR` saves a picture of the panel on every status change.
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
    var placeholder = "" { didSet { needsDisplay = true } }

    override func paste(_ sender: Any?) {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        if onPaste?(text) == true { return }
        pasteAsPlainText(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.white.withAlphaComponent(0.38),
        ]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5), y: textContainerInset.height)
        placeholder.draw(at: origin, withAttributes: attributes)
    }
}

final class OptionRowView: NSView {
    var onClick: (() -> Void)?
    var isSelected = false { didSet { updateAppearance() } }
    private var isHovered = false { didSet { updateAppearance() } }

    init(number: Int, option: QuestionOption, width: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false

        let badge = NSTextField(labelWithString: "\(number)")
        badge.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        badge.textColor = .secondaryLabelColor
        badge.alignment = .center
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.widthAnchor.constraint(equalToConstant: 16).isActive = true

        let textWidth = width - 16 - 8 - 20
        let title = NSTextField(wrappingLabelWithString: option.label)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = .labelColor
        title.preferredMaxLayoutWidth = textWidth
        title.maximumNumberOfLines = 2

        let texts = NSStackView(views: [title])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        if let description = option.description, !description.isEmpty {
            let detail = NSTextField(wrappingLabelWithString: description)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.preferredMaxLayoutWidth = textWidth
            detail.maximumNumberOfLines = 2
            texts.addArrangedSubview(detail)
        }

        let row = NSStackView(views: [badge, texts])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func updateAppearance() {
        let color: NSColor
        if isSelected {
            color = NSColor.controlAccentColor.withAlphaComponent(0.55)
        } else {
            color = NSColor.white.withAlphaComponent(isHovered ? 0.14 : 0.07)
        }
        layer?.backgroundColor = color.cgColor
    }

    // Clickable even while another app's window is key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}

/// A small horizontal meter showing the microphone level.
final class LevelView: NSView {
    var level: CGFloat = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.white.withAlphaComponent(0.15).setFill()
        track.fill()
        guard level > 0.02 else { return }
        let filled = NSRect(x: 0, y: 0, width: max(bounds.height, bounds.width * level), height: bounds.height)
        NSColor.systemGreen.setFill()
        NSBezierPath(roundedRect: filled, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

/// A short message that fades on its own, e.g. "답변을 복사했어요".
final class Toast {
    private static var current: NSPanel?

    static func show(_ message: String, seconds: TimeInterval = 5) {
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
