import AppKit
import Symbols
import VQCore

// The small views the question panel is built from. They say with a picture what used to be a
// line of text: who is asking, what the app is doing, how loud the microphone is, when it sends.

/// A round symbol button that works on the first click, also while another app is active.
final class IconButton: NSView {
    enum Style {
        /// Just the symbol, with a highlight under the pointer.
        case plain
        /// A filled accent circle: the primary action.
        case filled
    }

    /// Nil makes it a plain indicator: no highlight, no click.
    var onClick: (() -> Void)? { didSet { needsDisplay = true } }
    var isEnabled = true { didSet { refresh() } }

    private let style: Style
    private let pointSize: CGFloat
    private let imageView = NSImageView()
    private var symbolName = ""
    private var tint = NSColor.secondaryLabelColor
    private var animated = false
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }
    private var countdown: (start: TimeInterval, duration: TimeInterval)?
    private var countdownTimer: Timer?

    init(style: Style, diameter: CGFloat, pointSize: CGFloat) {
        self.style = style
        self.pointSize = pointSize
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleNone
        addSubview(imageView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter),
            heightAnchor.constraint(equalToConstant: diameter),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        countdownTimer?.invalidate()
    }

    /// `animated` runs the symbol's variable-colour animation: "this is going on right now".
    func setSymbol(_ name: String, tint: NSColor = .secondaryLabelColor, animated: Bool = false, label: String) {
        setAccessibilityLabel(label)
        toolTip = label
        guard name != symbolName || tint != self.tint || animated != self.animated else { return }
        symbolName = name
        self.tint = tint
        self.animated = animated
        refresh()
    }

    private func refresh() {
        let weight: NSFont.Weight = style == .filled ? .bold : .semibold
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
        imageView.contentTintColor = style == .filled ? .white : (isEnabled ? tint : .tertiaryLabelColor)
        imageView.removeAllSymbolEffects()
        if animated { imageView.addSymbolEffect(.variableColor.iterative, options: .repeating) }
        needsDisplay = true
    }

    /// A ring around the button that empties over `seconds`: the answer is sent when it is gone.
    func startCountdown(_ seconds: TimeInterval, from start: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        stopCountdown()
        guard seconds > 0 else { return }
        countdown = (start, seconds)
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            self.needsDisplay = true
            // Nothing left to draw: stop redrawing.
            if self.countdownLeft() == 0 { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    func stopCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdown = nil
        needsDisplay = true
    }

    /// Back to an empty, still button (the panel is closing).
    func clear() {
        stopCountdown()
        symbolName = ""
        animated = false
        imageView.removeAllSymbolEffects()
        imageView.image = nil
    }

    /// How much of the countdown is left, from 1 down to 0. Nil when none is running.
    func countdownLeft(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double? {
        countdown.map { min(max(1 - (time - $0.start) / $0.duration, 0), 1) }
    }

    override func draw(_ dirtyRect: NSRect) {
        switch style {
        case .filled:
            let color = !isEnabled ? NSColor.white.withAlphaComponent(0.16)
                : NSColor.controlAccentColor.withAlphaComponent(isPressed ? 0.7 : (isHovered ? 0.9 : 1))
            color.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4)).fill()
        case .plain:
            if onClick != nil, isEnabled, isHovered || isPressed {
                NSColor.white.withAlphaComponent(isPressed ? 0.24 : 0.14).setFill()
                NSBezierPath(ovalIn: bounds).fill()
            }
        }

        guard let left = countdownLeft(), left > 0 else { return }
        // From twelve o'clock, clockwise.
        let ring = NSBezierPath()
        ring.appendArc(withCenter: NSPoint(x: bounds.midX, y: bounds.midY), radius: bounds.width / 2 - 1,
                       startAngle: 90, endAngle: 90 - 360 * left, clockwise: true)
        ring.lineWidth = 2
        ring.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.9).setStroke()
        ring.stroke()
    }

    // The symbol is decoration, not a click target of its own. As a plain indicator the button
    // is no target either: a drag there moves the panel like anywhere else on its background.
    override func hitTest(_ point: NSPoint) -> NSView? {
        onClick == nil || super.hitTest(point) == nil ? nil : self
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        isPressed = onClick != nil && isEnabled
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick, isEnabled else { return false }
        onClick()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}

/// The microphone level as scrolling bars, newest on the right: "I can hear you" without words.
final class WaveformView: NSView {
    /// Speech has been recognised as speech (not just room noise): the bars turn green.
    var isHearing = false { didSet { needsDisplay = true } }

    private static let barWidth: CGFloat = 3
    private static let pitch: CGFloat = 6
    private static let interval = 0.06

    /// The bars, oldest first.
    private(set) var levels: [CGFloat] = []
    private var pending: CGFloat = 0
    private var lastPush = 0.0

    /// `level` from 0 (silence) to 1. Levels arrive faster than a bar is worth, so each bar is the
    /// loudest moment of its 60 ms.
    func push(_ level: CGFloat, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        pending = max(pending, level)
        guard time - lastPush >= WaveformView.interval else { return }
        lastPush = time
        levels.append(pending)
        pending = 0
        let capacity = Int(bounds.width / WaveformView.pitch) + 1
        if levels.count > capacity { levels.removeFirst(levels.count - capacity) }
        needsDisplay = true
    }

    func reset() {
        levels = []
        pending = 0
        lastPush = 0
        isHearing = false
    }

    override func draw(_ dirtyRect: NSRect) {
        let count = Int(bounds.width / WaveformView.pitch)
        guard count > 0 else { return }
        let quiet = NSColor.white.withAlphaComponent(0.22)
        let loud = isHearing ? NSColor.systemGreen : NSColor.white.withAlphaComponent(0.7)
        for slot in 0..<count {
            // Slot 0 is the newest bar, at the right edge. Slots with no sample yet draw as dots.
            let level = slot < levels.count ? levels[levels.count - 1 - slot] : 0
            let height = max(WaveformView.barWidth, level * bounds.height)
            let x = bounds.maxX - CGFloat(slot + 1) * WaveformView.pitch + (WaveformView.pitch - WaveformView.barWidth) / 2
            let bar = NSRect(x: x, y: bounds.midY - height / 2, width: WaveformView.barWidth, height: height)
            (level > 0.08 ? loud : quiet).setFill()
            NSBezierPath(roundedRect: bar, xRadius: WaveformView.barWidth / 2, yRadius: WaveformView.barWidth / 2).fill()
        }
    }

    // It lies over the answer field; clicks belong to the field.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One dot per question of a request, the current one bright.
final class ProgressDots: NSView {
    private static let diameter: CGFloat = 5
    private static let gap: CGFloat = 4

    private var index = 0
    private var total = 0

    func set(index: Int, total: Int) {
        self.index = index
        self.total = total
        isHidden = total < 2
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(total) * ProgressDots.diameter + CGFloat(max(total - 1, 0)) * ProgressDots.gap, height: ProgressDots.diameter)
    }

    override func draw(_ dirtyRect: NSRect) {
        for dot in 0..<total {
            NSColor.white.withAlphaComponent(dot == index ? 0.9 : (dot < index ? 0.5 : 0.2)).setFill()
            let x = CGFloat(dot) * (ProgressDots.diameter + ProgressDots.gap)
            NSBezierPath(ovalIn: NSRect(x: x, y: bounds.midY - ProgressDots.diameter / 2,
                                        width: ProgressDots.diameter, height: ProgressDots.diameter)).fill()
        }
    }
}

/// A rounded box with a hairline border: the answer field's frame.
final class RoundedBox: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor.black.withAlphaComponent(0.25).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        path.stroke()
    }
}

/// The key cap in front of an option: its number, or a check mark once it is chosen.
final class OptionBadgeView: NSView {
    static let side: CGFloat = 20

    var isSelected = false { didSet { needsDisplay = true } }
    private let number: Int

    init(number: Int) {
        self.number = number
        super.init(frame: NSRect(x: 0, y: 0, width: OptionBadgeView.side, height: OptionBadgeView.side))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: OptionBadgeView.side).isActive = true
        heightAnchor.constraint(equalToConstant: OptionBadgeView.side).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func draw(_ dirtyRect: NSRect) {
        (isSelected ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.14)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()

        if isSelected {
            let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            guard let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else { return }
            check.draw(in: NSRect(x: bounds.midX - check.size.width / 2, y: bounds.midY - check.size.height / 2,
                                  width: check.size.width, height: check.size.height))
        } else {
            let text = NSAttributedString(string: "\(number)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.8),
            ])
            let size = text.size()
            text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
        }
    }
}

/// One option: a card that answers with it on a click.
final class OptionRowView: NSView {
    /// `collecting` is true for a ⌘- or ⇧-click: add this option to a selection rather than
    /// answer with it right away.
    var onClick: ((_ collecting: Bool) -> Void)?
    var isSelected = false {
        didSet {
            badge.isSelected = isSelected
            needsDisplay = true
        }
    }
    private var isHovered = false { didSet { needsDisplay = true } }
    private let badge: OptionBadgeView

    init(number: Int, option: QuestionOption, width: CGFloat) {
        badge = OptionBadgeView(number: number)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(option.label)
        addSubview(badge)

        // "Label (Recommended)" becomes "Label" and a star.
        var star: NSImageView?
        if option.isRecommended, let image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: L("추천", "Recommended")) {
            let view = NSImageView(image: image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)) ?? image)
            view.contentTintColor = .systemYellow
            view.toolTip = L("추천", "Recommended")
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            star = view
        }

        let textWidth = width - 10 - OptionBadgeView.side - 10 - 12 - (star == nil ? 0 : 20)
        let title = NSTextField(wrappingLabelWithString: option.displayTitle)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = .labelColor
        title.preferredMaxLayoutWidth = textWidth
        title.maximumNumberOfLines = 2

        let texts = NSStackView(views: [title])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        if let description = option.description, !description.isEmpty {
            let detail = NSTextField(wrappingLabelWithString: description)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.preferredMaxLayoutWidth = textWidth
            detail.maximumNumberOfLines = 2
            detail.toolTip = description
            texts.addArrangedSubview(detail)
        }
        texts.translatesAutoresizingMaskIntoConstraints = false
        addSubview(texts)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            bottomAnchor.constraint(greaterThanOrEqualTo: badge.bottomAnchor, constant: 8),
            texts.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            texts.widthAnchor.constraint(equalToConstant: textWidth),
            // The title's first line sits level with the number.
            texts.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            bottomAnchor.constraint(equalTo: texts.bottomAnchor, constant: 10),
        ])
        if let star {
            NSLayoutConstraint.activate([
                star.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                star.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            ])
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.32).setFill()
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
            path.stroke()
        } else {
            NSColor.white.withAlphaComponent(isHovered ? 0.14 : 0.07).setFill()
            path.fill()
        }
    }

    // Labels and stack views are decoration, not separate click targets. In this
    // draggable nonactivating panel they otherwise swallow clicks or start a drag.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override var mouseDownCanMoveWindow: Bool { false }

    // Clickable even while another app's window is key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?(!event.modifierFlags.intersection([.command, .shift]).isEmpty)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick(false)
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}
