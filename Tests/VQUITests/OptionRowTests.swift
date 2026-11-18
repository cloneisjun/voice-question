import AppKit
import Testing
import VQCore
@testable import VoiceQuestion

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
        let row = OptionRowView(number: 1, option: .init(label: "First choice",
                                                       description: "Click the description too"), width: 428)
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 16),
            row.topAnchor.constraint(equalTo: host.topAnchor, constant: 16),
        ])
        host.layoutSubtreeIfNeeded()

        func labels(in view: NSView) -> [NSTextField] {
            view.subviews.flatMap { child in
                (child as? NSTextField).map { [$0] } ?? labels(in: child)
            }
        }
        let fields = labels(in: row)
        #expect(fields.count == 3) // Number, title, description.
        var points = fields.map { field in
            field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: host)
        }
        points.append(row.convert(NSPoint(x: 3, y: row.bounds.midY), to: host))
        points.append(row.convert(NSPoint(x: row.bounds.maxX - 3, y: row.bounds.midY), to: host))

        var picks = 0
        row.onClick = { picks += 1 }
        for point in points {
            let target = host.hitTest(point)
            #expect(target === row, "The entire card must route clicks to the option, including labels and padding")
            guard target === row else { continue }
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
                location: host.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            #expect(row.acceptsFirstMouse(for: event))
            target?.mouseDown(with: event)
        }
        #expect(picks == points.count)
        let outside = row.convert(NSPoint(x: -2, y: row.bounds.midY), to: host)
        #expect(host.hitTest(outside) !== row)
        #expect(!window.isVisible)
    }

    @Test func optionDoesNotDragTheWindow() {
        _ = NSApplication.shared
        let row = OptionRowView(number: 1, option: .init(label: "Choice"), width: 428)
        #expect(!row.mouseDownCanMoveWindow)
    }
}
