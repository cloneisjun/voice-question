import AppKit
import Testing
import VQCore
@testable import VoiceQuestion

/// A mouse-down as AppKit would deliver it, without posting anything to the system.
@MainActor
func mouseDown(at point: NSPoint = .zero, in window: NSWindow? = nil, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: modifiers, timestamp: 0,
                                    windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
}

@MainActor
func descendants<View: NSView>(of view: NSView, as type: View.Type = View.self) -> [View] {
    view.subviews.flatMap { child in ((child as? View).map { [$0] } ?? []) + descendants(of: child, as: type) }
}

@MainActor
@Suite("Option row mouse routing", .serialized)
struct OptionRowTests {
    @Test func wholeCardReceivesFirstClick() throws {
        _ = NSApplication.shared
        // Never order this window front or post global mouse events.
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 160),
                             styleMask: [.nonactivatingPanel], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        let host = try #require(window.contentView)
        let row = OptionRowView(number: 1, option: .init(label: "First choice (Recommended)",
                                                       description: "Click the description too"), width: 428)
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 16),
            row.topAnchor.constraint(equalTo: host.topAnchor, constant: 16),
        ])
        host.layoutSubtreeIfNeeded()

        let fields: [NSTextField] = descendants(of: row)
        // Title and description. The number is a drawn key cap, "(Recommended)" a star.
        #expect(fields.map(\.stringValue) == ["First choice", "Click the description too"])
        let badge = try #require(descendants(of: row, as: OptionBadgeView.self).first)
        let star = try #require(descendants(of: row, as: NSImageView.self).first)
        var targets: [NSView] = fields
        targets += [badge, star]
        var points = targets.map { view in
            view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: host)
        }
        points.append(row.convert(NSPoint(x: 3, y: row.bounds.midY), to: host))
        points.append(row.convert(NSPoint(x: row.bounds.maxX - 3, y: row.bounds.midY), to: host))

        var picks = 0
        row.onClick = { collecting in
            #expect(!collecting)
            picks += 1
        }
        for point in points {
            let target = host.hitTest(point)
            #expect(target === row, "The entire card must route clicks to the option, including labels and padding")
            guard target === row else { continue }
            let event = try mouseDown(at: host.convert(point, to: nil), in: window)
            #expect(row.acceptsFirstMouse(for: event))
            target?.mouseDown(with: event)
        }
        #expect(picks == points.count)
        let outside = row.convert(NSPoint(x: -2, y: row.bounds.midY), to: host)
        #expect(host.hitTest(outside) !== row)
        #expect(!window.isVisible)
    }

    @Test func commandOrShiftClickCollects() throws {
        _ = NSApplication.shared
        let row = OptionRowView(number: 1, option: .init(label: "Choice"), width: 428)
        var clicks: [Bool] = []
        row.onClick = { clicks.append($0) }
        for modifiers in [[], .command, .shift, .option, .control] as [NSEvent.ModifierFlags] {
            row.mouseDown(with: try mouseDown(modifiers: modifiers))
        }
        #expect(clicks == [false, true, true, false, false])
    }

    @Test func optionDoesNotDragTheWindow() {
        _ = NSApplication.shared
        let row = OptionRowView(number: 1, option: .init(label: "Choice"), width: 428)
        #expect(!row.mouseDownCanMoveWindow)
    }

    @Test func selectedOptionShowsACheckMark() throws {
        _ = NSApplication.shared
        let row = OptionRowView(number: 2, option: .init(label: "Choice"), width: 428)
        let badge = try #require(descendants(of: row, as: OptionBadgeView.self).first)
        #expect(!badge.isSelected)
        row.isSelected = true
        #expect(badge.isSelected)
    }
}
