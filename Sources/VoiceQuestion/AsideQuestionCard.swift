import AppKit
import ApplicationServices

/// Operates only on the single-choice form in the open Aside chat for this session.
enum AsideQuestionCard {
    enum Result { case unavailable, submitAttempted }

    static func submit(sessionID: String, question: String, options: [String], answer: String,
                       stillPending: () -> Bool) -> Result {
        guard AXIsProcessTrusted(), options.contains(answer), Set(options).count == options.count,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: "at.studio.AsideBrowser").first,
              let window = attribute(AXUIElementCreateApplication(app.processIdentifier), "AXFocusedWindow"),
              CFGetTypeID(window) == AXUIElementGetTypeID() else { return .unavailable }
        let windowElement = window as! AXUIElement
        // Do not descend into unrelated web pages.
        let pages = find(in: windowElement, stoppingAt: "AXWebArea") { element in
            guard role(element) == "AXWebArea", let url = attribute(element, "AXURL") as? URL,
                  url.scheme == "chrome-extension", url.host == "fjdhphbdlfjogobdofoaagnlnkoibdge",
                  url.path == "/main.html", let fragment = url.fragment else { return false }
            let path = fragment.split(separator: "/")
            return path.count == 4 && path[0] == "u" && path[2] == "tasks" && path[3] == sessionID
        }
        guard pages.count == 1 else { return .unavailable }
        let headings = find(in: pages[0]) { role($0) == "AXHeading" && title($0) == "Q. " + question }
        guard headings.count == 1, let parent = attribute(headings[0], "AXParent"),
              CFGetTypeID(parent) == AXUIElementGetTypeID() else { return .unavailable }
        let form = parent as! AXUIElement
        let controls = children(form)
        let boxes = controls.filter { role($0) == "AXGroup" }.flatMap(children).filter { role($0) == "AXCheckBox" }
        guard boxes.map(title) == options else { return .unavailable }
        let fields = find(in: form) {
            role($0) == "AXTextArea" && title($0) == "Or write your answer to this question"
        }
        guard fields.count == 1, let value = attribute(fields[0], "AXValue") as? String,
              (value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value == title(fields[0]) + "\n"),
              stillPending() else { return .unavailable }

        // Aside's option toggles do not expose their checked state. Its card also accepts
        // a written answer. Verify that value and direct Return only to the owning process.
        let field = fields[0]
        guard AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
              AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, answer as CFString) == .success,
              waitForComposerSubmit(in: form) else { return .unavailable }

        // The first Return can commit an edit in Chromium. Only send the second if this
        // exact suspension and the same editor, focus and answer all still exist.
        for attempt in 0..<2 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.8) }
            guard stillPending(), let focused = attribute(AXUIElementCreateApplication(app.processIdentifier), "AXFocusedUIElement"),
                  CFEqual(focused, field), (attribute(field, "AXValue") as? String)?.trimmingCharacters(in: .newlines) == answer,
                  let down = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false) else {
                return attempt == 0 ? .unavailable : .submitAttempted
            }
            down.flags = []
            up.flags = []
            down.postToPid(app.processIdentifier)
            up.postToPid(app.processIdentifier)
        }
        return .submitAttempted
    }

    // The card has an outer Submit even before typing. Wait until its editor has
    // processed the accessibility value change and rendered its own submit control.
    private static func waitForComposerSubmit(in form: AXUIElement) -> Bool {
        let groups = children(form).filter { role($0) == "AXGroup" }
        for _ in 0..<12 {
            for group in groups {
                if !find(in: group, matching: { role($0) == "AXButton" && title($0) == "Submit" }).isEmpty {
                    return true
                }
            }
            Thread.sleep(forTimeInterval: 0.08)
        }
        return false
    }

    private static func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(e, name as CFString, &value)
        return value
    }

    private static func children(_ e: AXUIElement) -> [AXUIElement] {
        attribute(e, "AXChildren") as? [AXUIElement] ?? []
    }

    private static func role(_ e: AXUIElement) -> String { attribute(e, "AXRole") as? String ?? "" }
    private static func title(_ e: AXUIElement) -> String { attribute(e, "AXTitle") as? String ?? "" }
    private static func find(in root: AXUIElement, stoppingAt boundary: String? = nil,
                             matching: (AXUIElement) -> Bool) -> [AXUIElement] {
        var queue = [root], matches = [AXUIElement]()
        var index = 0
        while index < queue.count {
            guard queue.count <= 4000 else { return [] }
            let element = queue[index]
            index += 1
            if matching(element) { matches.append(element) }
            if let boundary, role(element) == boundary { continue }
            queue.append(contentsOf: children(element))
        }
        return matches
    }
}
