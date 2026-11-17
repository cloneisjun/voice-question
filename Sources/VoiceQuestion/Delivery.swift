import AppKit
import ApplicationServices
import VQCore

/// Hands a spoken answer to an app that offers no way to answer its question programmatically.
enum Delivery {
    static let codexBundleID = "com.openai.codex"
    static let asideBundleID = "at.studio.AsideBrowser"

    /// One answer as is; several as "question → answer" lines.
    static func text(for answers: [AnsweredQuestion]) -> String {
        if answers.count == 1 { return answers[0].answer }
        return answers.map { "\($0.question) → \($0.answer)" }.joined(separator: "\n")
    }

    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - ChatGPT (Codex)

    /// `mode`: "clipboard" (copy, open the thread), "paste" (also press the keys; experimental) or "none".
    static func deliverCodex(answers: [AnsweredQuestion], questions: [Question], threadID: String?, isDesktop: Bool, mode: String) {
        guard mode != "none", !answers.isEmpty else { return }
        let answerText = text(for: answers)
        copy(answerText)
        if isDesktop, let threadID, let url = URL(string: "codex://threads/\(threadID)") {
            NSWorkspace.shared.open(url)
        }
        Log.info("deliver codex: copied \(Log.redact(answerText)) mode=\(mode) thread=\(threadID ?? "-")")

        guard mode == "paste", isDesktop, answers.count == 1, questions.count == 1, AXIsProcessTrusted() else {
            Toast.show(L("답변을 복사했어요. ChatGPT 질문 카드에서 ⌘V 로 붙여 넣으세요.\n“\(answerText)”",
                         "Answer copied. Paste it into the ChatGPT question card with ⌘V.\n“\(answerText)”"))
            return
        }
        // Experimental: the question card takes 1–9 for an option (the one after the last option
        // is the free-form field) and Return to send.
        let answer = answers[0]
        let options = questions[0].options
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == codexBundleID else {
                Toast.show(L("답변을 복사했어요. ChatGPT에서 ⌘V 로 붙여 넣으세요.", "Answer copied. Paste it in ChatGPT with ⌘V."))
                return
            }
            if answer.kind == .option, let index = options.firstIndex(where: { $0.label == answer.answer }), index < 9 {
                Keys.press(Keys.digits[index])
            } else if options.count < 9 {
                if !options.isEmpty { Keys.press(Keys.digits[options.count]) }
                Keys.press(9, command: true) // ⌘V
            } else {
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { Keys.press(36) } // Return
        }
    }

    // MARK: - Aside

    /// `mode`: "clipboard" (copy, bring Aside forward), "resume" / "steer" (via the `aside` CLI; experimental) or "none".
    static func deliverAside(answers: [AnsweredQuestion], sessionID: String, mode: String, binary: String?) {
        guard mode != "none", !answers.isEmpty else { return }
        let answerText = text(for: answers)
        Log.info("deliver aside: \(Log.redact(answerText)) mode=\(mode) session=\(sessionID)")

        if mode == "resume" || mode == "steer", let binary {
            let message = "Answer to your question (dictated by the user): " + answerText
            DispatchQueue.global().async {
                var delivered = false
                if mode == "steer" {
                    delivered = runCommand(binary, ["session", "steer", sessionID, message], timeout: 20) != nil
                } else {
                    _ = runCommand(binary, ["session", "stop", sessionID], timeout: 10)
                    delivered = runCommand(binary, ["session", "resume", sessionID, message], timeout: 20) != nil
                }
                Log.info("deliver aside: \(mode) \(delivered ? "ok" : "failed")")
                DispatchQueue.main.async {
                    if delivered {
                        Toast.show(L("Aside에 답변을 보냈어요.\n“\(answerText)”", "Answer sent to Aside.\n“\(answerText)”"))
                    } else {
                        copyForAside(answerText)
                    }
                }
            }
            return
        }
        copyForAside(answerText)
    }

    private static func copyForAside(_ answerText: String) {
        copy(answerText)
        NSRunningApplication.runningApplications(withBundleIdentifier: asideBundleID).first?.activate()
        Toast.show(L("답변을 복사했어요. Aside 질문에 ⌘V 로 붙여 넣으세요.\n“\(answerText)”",
                     "Answer copied. Paste it into Aside's question with ⌘V.\n“\(answerText)”"))
    }
}

/// Synthetic key presses (needs the Accessibility permission). Only the experimental "paste" delivery uses them.
enum Keys {
    /// Key codes of the number row, 1…9.
    static let digits: [CGKeyCode] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    static func press(_ key: CGKeyCode, command: Bool = false) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = command ? .maskCommand : []
            event.post(tap: .cghidEventTap)
        }
    }
}
