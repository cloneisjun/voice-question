import Foundation
import Testing
@testable import VQCore

// MARK: - Claude Code hook

private let claudeHookInput = """
{"session_id":"s-1","transcript_path":"/tmp/t.jsonl","cwd":"/Users/me/dev/shop","hook_event_name":"PreToolUse",
 "tool_name":"AskUserQuestion","tool_use_id":"toolu_01ABC",
 "tool_input":{"questions":[
   {"question":"어떤 카드로 결제할까요?","header":"결제","multiSelect":false,
    "options":[{"label":"신용카드","description":"할부 가능"},{"label":"체크카드","description":"즉시 출금"}]},
   {"question":"Which extras?","header":"Extras","multiSelect":true,
    "options":[{"label":"Gift wrap","description":"+$2"},{"label":"Receipt","description":"Paper receipt"}]}
 ]}}
"""

@Test func claudeHookParsesQuestions() throws {
    let input = try #require(ClaudeHook.parse(Data(claudeHookInput.utf8)))
    #expect(input.toolName == "AskUserQuestion")
    #expect(input.toolUseID == "toolu_01ABC")
    #expect(input.cwd == "/Users/me/dev/shop")
    #expect(input.questions.count == 2)
    #expect(input.questions[0].options.map(\.label) == ["신용카드", "체크카드"])
    #expect(input.questions[0].options[0].description == "할부 가능")
    #expect(input.questions[1].multiSelect)

    let request = ClaudeHook.request(from: input)
    #expect(request.id == "toolu_01ABC")
    #expect(request.source == .claudeCode)
    #expect(request.title == "shop")
}

@Test func claudeHookOutputEchoesQuestionsAndAddsAnswers() throws {
    let input = try #require(ClaudeHook.parse(Data(claudeHookInput.utf8)))
    let answers = [
        AnsweredQuestion(question: "어떤 카드로 결제할까요?", answer: "체크카드", transcript: "2번", kind: .option, selectedLabels: ["체크카드"]),
        AnsweredQuestion(question: "Which extras?", answer: "Gift wrap, Receipt", transcript: "both", kind: .options, selectedLabels: ["Gift wrap", "Receipt"]),
    ]
    let output = try #require(ClaudeHook.output(for: input, answers: answers))
    let root = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    let specific = try #require(root["hookSpecificOutput"] as? [String: Any])
    #expect(specific["hookEventName"] as? String == "PreToolUse")
    #expect(specific["permissionDecision"] as? String == "allow")
    let updated = try #require(specific["updatedInput"] as? [String: Any])
    #expect((updated["questions"] as? [[String: Any]])?.count == 2)
    #expect(updated["answers"] as? [String: String] == ["어떤 카드로 결제할까요?": "체크카드", "Which extras?": "Gift wrap, Receipt"])
    // Single line: Claude Code reads the hook's stdout as one JSON document.
    #expect(!output.contains("\n"))
}

@Test func claudeHookOutputNeedsEveryAnswer() throws {
    let input = try #require(ClaudeHook.parse(Data(claudeHookInput.utf8)))
    let partial = [AnsweredQuestion(question: "어떤 카드로 결제할까요?", answer: "체크카드", transcript: "2번", kind: .option, selectedLabels: ["체크카드"])]
    #expect(ClaudeHook.output(for: input, answers: partial) == nil)
}

@Test func claudeHookIgnoresOtherPayloads() {
    #expect(ClaudeHook.parse(Data("not json".utf8)) == nil)
    #expect(ClaudeHook.parse(Data(#"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#.utf8)) == nil)
    #expect(ClaudeHook.parse(Data(#"{"tool_name":"AskUserQuestion","tool_input":{"questions":[]}}"#.utf8)) == nil)
}

// MARK: - Claude desktop next-step box

/// Transcript lines in the shape Claude Code 2.1.326 writes them, trimmed to the fields that matter.
private enum NextStepLine {
    static func wrapUp(_ id: String, _ input: String) -> String {
        #"{"parentUuid":"p","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":""# + id
            + #"","name":"mcp__ccd_turn__wrap_up","input":"# + input + #","caller":{"type":"direct"}}],"stop_reason":"tool_use"}}"#
    }
    static func result(_ id: String, isError: Bool = false) -> String {
        #"{"parentUuid":"p","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":""# + id
            + #"","type":"tool_result","# + (isError ? #""is_error":true,"# : "")
            + #""content":[{"type":"text","text":"Shown in the next-step box."}]}]}}"#
    }
    static let ask = #"{"recap":"Both PRs are approved.","ask":"How should we handle #3549's release-record binding?","actions":[{"label":"Ask the owner"},{"label":"I'll prepare it"}],"blocked":true}"#
    static let blob = #"{"type":"api-request-blob","message":{"content":[{"type":"tool_result","tool_use_id":"x"}]}}"#
    static let closing = #"{"isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Both PRs are approved; one decision is left."}]}}"#
    static let summary = #"{"isSidechain":false,"type":"system","subtype":"stop_hook_summary","hookCount":3,"preventedContinuation":false}"#
    static let human = #"{"isSidechain":false,"type":"user","message":{"role":"user","content":"Ask the owner"},"origin":{"kind":"human"}}"#
    static let humanWithImage = #"{"isSidechain":false,"type":"user","message":{"role":"user","content":[{"type":"image"},{"type":"text","text":"look"}]}}"#
    static let enqueue = #"{"type":"queue-operation","operation":"enqueue","content":"Ask the owner"}"#
    static let dequeue = #"{"type":"queue-operation","operation":"dequeue"}"#

    static func transcript(_ lines: String...) -> String { lines.joined(separator: "\n") + "\n" }
}

@Test func nextStepHookReadsTheStopInput() throws {
    let payload = #"{"session_id":"s-1","transcript_path":"/tmp/vq/s-1.jsonl","cwd":"/Users/me/dev/shop","permission_mode":"auto","hook_event_name":"Stop","stop_hook_active":false}"#
    let input = try #require(ClaudeNextStep.parse(Data(payload.utf8)))
    #expect(input.transcriptPath == "/tmp/vq/s-1.jsonl")
    #expect(input.cwd == "/Users/me/dev/shop")
    // Any other event, the AskUserQuestion hook's input for one, is not ours.
    #expect(ClaudeNextStep.parse(Data(claudeHookInput.utf8)) == nil)
    #expect(ClaudeNextStep.parse(Data("{}".utf8)) == nil)
}

@Test func nextStepBoxBecomesAQuestion() throws {
    let text = NextStepLine.transcript(NextStepLine.human, NextStepLine.wrapUp("toolu_01H5", NextStepLine.ask), NextStepLine.result("toolu_01H5"),
                                       NextStepLine.blob, NextStepLine.closing)
    let ask = try #require(ClaudeNextStep.pendingAsk(inTranscript: text))
    #expect(ask.toolUseID == "toolu_01H5")
    #expect(ask.question == Question(question: "How should we handle #3549's release-record binding?",
                                     options: [QuestionOption(label: "Ask the owner"), QuestionOption(label: "I'll prepare it")]))

    let payload = #"{"session_id":"s-1","transcript_path":"/tmp/t.jsonl","cwd":"/Users/me/dev/clone-poc","hook_event_name":"Stop"}"#
    let request = ClaudeNextStep.request(from: try #require(ClaudeNextStep.parse(Data(payload.utf8))), ask: ask)
    #expect(request.id == "toolu_01H5")
    #expect(request.source == .claudeCode)
    #expect(request.title == "clone-poc")
    #expect(request.questions == [ask.question])

    // A question with no buttons is answered freely.
    let open = NextStepLine.transcript(NextStepLine.wrapUp("toolu_02", #"{"recap":"Done.","ask":"Which branch next?"}"#), NextStepLine.result("toolu_02"))
    #expect(ClaudeNextStep.pendingAsk(inTranscript: open)?.question == Question(question: "Which branch next?"))
}

@Test func nextStepBoxesThatCannotBeAnsweredByVoiceAreLeftAlone() {
    func pending(_ input: String, isError: Bool = false) -> ClaudeNextStep.Ask? {
        ClaudeNextStep.pendingAsk(inTranscript: NextStepLine.transcript(NextStepLine.wrapUp("toolu_1", input), NextStepLine.result("toolu_1", isError: isError),
                                                                        NextStepLine.closing))
    }
    #expect(pending(NextStepLine.ask) != nil)
    #expect(pending(NextStepLine.ask, isError: true) == nil) // the box was never shown
    #expect(pending(#"{"recap":"All done."}"#) == nil) // nothing is asked
    #expect(pending(#"{"recap":"All done.","ask":"  ","actions":[{"label":"OK"}]}"#) == nil)
    // A button that makes the app do something (commit, create a pull request, …) cannot be pressed from here.
    #expect(pending(#"{"recap":"Ready.","ask":"Commit now?","actions":[{"action":"commit"},{"label":"Not yet"}]}"#) == nil)
    #expect(pending(#"{"recap":"Ready.","ask":"Commit now?","actions":[{"action":"commit","label":"Commit"}]}"#) == nil)

    // No result recorded for the call, and a transcript that never mentions the box.
    #expect(ClaudeNextStep.pendingAsk(inTranscript: NextStepLine.transcript(NextStepLine.wrapUp("toolu_1", NextStepLine.ask), NextStepLine.closing)) == nil)
    #expect(ClaudeNextStep.pendingAsk(inTranscript: NextStepLine.transcript(NextStepLine.human, NextStepLine.closing)) == nil)
    #expect(ClaudeNextStep.pendingAsk(inTranscript: "") == nil)
}

@Test func nextStepBoxIsAskedOnlyWhileItIsWaiting() {
    let box = [NextStepLine.wrapUp("toolu_1", NextStepLine.ask), NextStepLine.result("toolu_1"), NextStepLine.closing]
    func pending(after later: String...) -> ClaudeNextStep.Ask? {
        ClaudeNextStep.pendingAsk(inTranscript: (box + later).joined(separator: "\n"))
    }
    #expect(pending() != nil)
    #expect(pending(after: NextStepLine.dequeue, "not json", #"{"type":"custom-title"}"#) != nil)
    // The user already replied: a clicked button, a typed message, one still in the queue.
    #expect(pending(after: NextStepLine.human, NextStepLine.closing) == nil)
    #expect(pending(after: NextStepLine.humanWithImage) == nil)
    #expect(pending(after: NextStepLine.enqueue) == nil)
    // The turn already ended once with this box, so it has been offered before.
    #expect(pending(after: NextStepLine.summary, NextStepLine.closing) == nil)

    // Only the last box of the turn counts, and a subagent's lines are not part of the turn.
    let second = #"{"recap":"Next.","ask":"Ship it?","actions":[{"label":"Yes"},{"label":"No"}]}"#
    #expect(pending(after: NextStepLine.wrapUp("toolu_2", second), NextStepLine.result("toolu_2"))?.question.question == "Ship it?")
    #expect(pending(after: NextStepLine.wrapUp("toolu_2", #"{"recap":"Next."}"#), NextStepLine.result("toolu_2")) == nil)
    let sidechain = NextStepLine.human.replacingOccurrences(of: #""isSidechain":false"#, with: #""isSidechain":true"#)
    #expect(pending(after: sidechain) != nil)

    #expect(!ClaudeNextStep.hasUserMessage(inTranscript: (box + [NextStepLine.dequeue, NextStepLine.summary, sidechain]).joined(separator: "\n")))
    #expect(ClaudeNextStep.hasUserMessage(inTranscript: NextStepLine.enqueue + "\n"))
    #expect(ClaudeNextStep.hasUserMessage(inTranscript: NextStepLine.closing + "\n" + NextStepLine.human))
}

@Test func nextStepAnswerMakesClaudeContinue() throws {
    let ask = ClaudeNextStep.Ask(toolUseID: "toolu_1", question: Question(question: "Ship it?", options: [QuestionOption(label: "Yes"), QuestionOption(label: "No")]))
    let answers = [AnsweredQuestion(question: "Ship it?", answer: "Yes", transcript: "첫 번째", kind: .option, selectedLabels: ["Yes"])]
    let output = try #require(ClaudeNextStep.output(for: ask, answers: answers))
    #expect(!output.contains("\n")) // one line of JSON
    let root = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    #expect(root["decision"] as? String == "block")
    let reason = try #require(root["reason"] as? String)
    #expect(reason.contains("Q: Ship it?\nA: Yes"))

    #expect(ClaudeNextStep.output(for: ask, answers: []) == nil)
    #expect(ClaudeNextStep.output(for: ask, answers: [AnsweredQuestion(question: "Ship it?", answer: " ", transcript: "", kind: .freeText, selectedLabels: [])]) == nil)
}

@Test func nextStepTranscriptIsReadFromItsEnd() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vq-next-step-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("session.jsonl").path

    let old = (0..<200).map { #"{"type":"assistant","message":{"content":[{"type":"text","text":"한글 줄 \#($0)"}]}}"# }.joined(separator: "\n") + "\n"
    let turn = NextStepLine.transcript(NextStepLine.human, NextStepLine.wrapUp("toolu_9", NextStepLine.ask), NextStepLine.result("toolu_9"), NextStepLine.closing)
    try Data((old + turn).utf8).write(to: URL(fileURLWithPath: path))

    #expect(ClaudeNextStep.transcriptTail(atPath: path) == old + turn)
    // A short tail starts on a whole line, even when the cut lands inside a character.
    for extra in 0..<4 {
        let tail = try #require(ClaudeNextStep.transcriptTail(atPath: path, maxBytes: turn.utf8.count + 30 + extra))
        #expect(tail == turn)
        #expect(ClaudeNextStep.pendingAsk(inTranscript: tail)?.toolUseID == "toolu_9")
    }
    #expect(ClaudeNextStep.transcriptTail(atPath: directory.appendingPathComponent("missing.jsonl").path) == nil)

    // While the question is asked, only whole new lines are looked at.
    let size = UInt64((old + turn).utf8.count)
    #expect(ClaudeNextStep.transcriptLines(atPath: path, after: size) == nil)
    let handle = try #require(FileHandle(forWritingAtPath: path))
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((NextStepLine.dequeue + "\n" + NextStepLine.enqueue.prefix(20)).utf8))
    let first = try #require(ClaudeNextStep.transcriptLines(atPath: path, after: size))
    #expect(first.text == NextStepLine.dequeue + "\n")
    #expect(!ClaudeNextStep.hasUserMessage(inTranscript: first.text))
    try handle.write(contentsOf: Data((NextStepLine.enqueue.dropFirst(20) + "\n").utf8))
    let second = try #require(ClaudeNextStep.transcriptLines(atPath: path, after: first.end))
    #expect(second.text == NextStepLine.enqueue + "\n")
    #expect(ClaudeNextStep.hasUserMessage(inTranscript: second.text))
}

// MARK: - Codex hook

@Test func codexHookParsesAsyncQuestionShape() throws {
    let payload = #"{"session_id":"t-1","cwd":"/Users/me/dev/api","hook_event_name":"PreToolUse","tool_name":"request_user_input_async","tool_use_id":"call_9","tool_input":{"questions":[{"title":"Which region?","options":["us-east-1","ap-northeast-2"]}]}}"#
    let input = try #require(CodexHook.parse(Data(payload.utf8)))
    #expect(CodexHook.toolNames.contains(input.toolName))
    #expect(input.questions == [Question(question: "Which region?", options: [QuestionOption(label: "us-east-1"), QuestionOption(label: "ap-northeast-2")])])

    let answers = [AnsweredQuestion(question: "Which region?", answer: "ap-northeast-2", transcript: "두 번째", kind: .option, selectedLabels: ["ap-northeast-2"])]
    let output = try #require(CodexHook.output(answers: answers))
    let root = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    let specific = try #require(root["hookSpecificOutput"] as? [String: Any])
    #expect(specific["permissionDecision"] as? String == "deny")
    let reason = try #require(specific["permissionDecisionReason"] as? String)
    #expect(reason.contains("Q: Which region?"))
    #expect(reason.contains("A: ap-northeast-2"))
    #expect(CodexHook.output(answers: []) == nil)
}

// MARK: - Codex rollout

// Shapes copied from a real ChatGPT Desktop (Codex 0.169) rollout, with made-up ids.
private let rolloutFunctionCall = #"{"timestamp":"2026-11-17T07:03:21.684Z","ordinal":48,"type":"response_item","payload":{"type":"function_call","status":"completed","id":"fc_1","name":"request_user_input_async","arguments":"{\"questions\":[{\"title\":\"어느 브랜치에 올릴까요?\",\"options\":[\"main\",\"develop\",\"새 브랜치\"]}]}","call_id":"call_AbC123"}}"#
private let rolloutItemCompleted = #"{"timestamp":"2026-11-17T07:03:21.685Z","ordinal":49,"type":"event_msg","payload":{"type":"item_completed","thread_id":"01900000-aaaa-7bbb-8ccc-ddddeeeeffff","turn_id":"turn_1","item":{"type":"AgentMessage","id":"call_AbC123","content":[{"type":"Text","text":"어느 브랜치에 올릴까요?"}],"phase":"final_answer","delivery":"async","questions":[{"title":"어느 브랜치에 올릴까요?","options":["main","develop","새 브랜치"]}]}}}"#
private let rolloutAccepted = #"{"timestamp":"2026-11-17T07:03:21.690Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_AbC123","output":"{\"accepted\":true}"}}"#
private let rolloutUserReply = #"{"timestamp":"2026-11-17T07:04:02.100Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<send_user_message_question_reply>\n[{\"questionItemId\":\"[\\\"request_user_input_async\\\",\\\"call_AbC123\\\",0]\",\"question\":\"어느 브랜치에 올릴까요?\",\"answer\":\"develop\"}]\n</send_user_message_question_reply>"}]}}"#
private let rolloutBlockingAnswer = #"{"timestamp":"2026-11-17T07:04:02.100Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_Zz9","output":"{\"answers\":{\"q1\":{\"answers\":[\"main\"]}}}"}}"#

@Test func rolloutFunctionCallIsAQuestion() throws {
    let event = try #require(CodexRollout.parseLine(rolloutFunctionCall))
    guard case .question(let threadID, let callID, let questions, let timestamp) = event else {
        Issue.record("expected a question, got \(event)")
        return
    }
    #expect(threadID == nil)
    #expect(callID == "call_AbC123")
    #expect(questions.first?.question == "어느 브랜치에 올릴까요?")
    #expect(questions.first?.options.map(\.label) == ["main", "develop", "새 브랜치"])
    #expect(timestamp != nil)
}

@Test func rolloutItemCompletedCarriesTheThread() throws {
    let event = try #require(CodexRollout.parseLine(rolloutItemCompleted))
    guard case .question(let threadID, let callID, let questions, _) = event else {
        Issue.record("expected a question, got \(event)")
        return
    }
    #expect(threadID == "01900000-aaaa-7bbb-8ccc-ddddeeeeffff")
    #expect(callID == "call_AbC123")
    #expect(questions.count == 1)
}

@Test func rolloutAnswers() {
    // `{"accepted":true}` only acknowledges the async tool call.
    #expect(CodexRollout.parseLine(rolloutAccepted) == nil)
    #expect(CodexRollout.parseLine(rolloutUserReply) == .answered(callIDs: ["call_AbC123"]))
    // The blocking tool's output only counts for a question we are actually waiting on.
    #expect(CodexRollout.parseLine(rolloutBlockingAnswer) == nil)
    #expect(CodexRollout.parseLine(rolloutBlockingAnswer, pendingCallIDs: ["call_Zz9"]) == .answered(callIDs: ["call_Zz9"]))
    #expect(CodexRollout.parseLine(rolloutAccepted, pendingCallIDs: ["call_AbC123"]) == nil)
}

@Test func rolloutIgnoresEverythingElse() {
    #expect(CodexRollout.parseLine(#"{"timestamp":"2026-11-17T07:03:21.684Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}"#) == nil)
    #expect(CodexRollout.parseLine(#"{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":\"echo request_user_input\"}","call_id":"call_1"}}"#) == nil)
    #expect(CodexRollout.parseLine("") == nil)
    #expect(CodexRollout.parseLine("{not json request_user_input") == nil)
}

@Test func rolloutThreadIDFromFilename() {
    #expect(CodexRollout.threadID(fromFilename: "rollout-2026-11-17T16-00-00-01900000-aaaa-7bbb-8ccc-ddddeeeeffff.jsonl") == "01900000-aaaa-7bbb-8ccc-ddddeeeeffff")
    #expect(CodexRollout.threadID(fromFilename: "notes.jsonl") == nil)
}

// MARK: - Aside

@Test func asideLogLine() {
    let line = #"{"t":"2026-11-16T06:28:49.602Z","lvl":"info","pid":12345,"msg":"[SessionSuspensionNotification] session=AbCdEfGh12345678 kind=ask-user-question sending"}"#
    #expect(AsideSessions.askSessionID(fromLogLine: line) == "AbCdEfGh12345678")
    #expect(AsideSessions.askSessionID(fromLogLine: #"{"msg":"[SessionSuspensionNotification] session=abc kind=permission sending"}"#) == nil)
    #expect(AsideSessions.askSessionID(fromLogLine: #"{"msg":"something else"}"#) == nil)
}

@Test func asidePendingQuestions() {
    let list = """
    {"sessions":[
      {"id":"pending1","title":"휴가 일정","status":"idle","suspension":{"id":"sus_1","kind":"ask-user-question","toolCallId":"tc_1",
        "request":{"questions":[{"question":"언제 출발할까요?","header":"출발","options":[{"label":"금요일","description":"저녁"},{"label":"토요일","description":"아침"}],"multiple":false}]},
        "createdAt":"2026-11-16T06:28:49.000Z"}},
      {"id":"answered1","title":"done","suspension":{"id":"sus_2","kind":"ask-user-question",
        "request":{"questions":[{"question":"Q?","options":[{"label":"A"},{"label":"B"}]}]},"response":{"answers":{"Q?":"A"}},"resolvedAt":"2026-11-16T06:30:00.000Z"}},
      {"id":"other1","suspension":{"id":"sus_3","kind":"permission","request":{}}},
      {"id":"plain1","title":"no suspension","status":"idle"}
    ]}
    """
    let pending = AsideSessions.pendingQuestions(inSessionList: Data(list.utf8))
    #expect(pending.count == 1)
    #expect(pending.first?.sessionID == "pending1")
    #expect(pending.first?.title == "휴가 일정")
    #expect(pending.first?.suspensionID == "sus_1")
    #expect(pending.first?.questions.first?.options.map(\.label) == ["금요일", "토요일"])
    #expect(AsideSessions.pendingQuestions(inSessionList: Data("oops".utf8)).isEmpty)
}

@Test func asideSessionStatus() {
    let list = Data(#"{"sessions":[{"id":"a1","status":"interrupted"},{"id":"b2","status":"running"},{"id":"c3"}]}"#.utf8)
    #expect(AsideSessions.status(ofSession: "a1", inSessionList: list) == "interrupted")
    #expect(AsideSessions.status(ofSession: "b2", inSessionList: list) == "running")
    #expect(AsideSessions.status(ofSession: "c3", inSessionList: list) == nil)
    #expect(AsideSessions.status(ofSession: "zz", inSessionList: list) == nil)
    #expect(AsideSessions.status(ofSession: "a1", inSessionList: Data("oops".utf8)) == nil)
}

@Test func asideAnswerMessage() {
    let one = AnsweredQuestion(question: "언제 출발할까요?", answer: "금요일", transcript: "금요일", kind: .option, selectedLabels: ["금요일"])
    let two = AnsweredQuestion(question: "Seats?", answer: "Aisle, Front", transcript: "", kind: .options, selectedLabels: ["Aisle", "Front"])
    #expect(AsideSessions.answerMessage(for: [one]) == "Here is my answer to the question you just asked.\n\nQ: 언제 출발할까요?\nA: 금요일")
    #expect(AsideSessions.answerMessage(for: [one, two])
            == "Here are my answers to the questions you just asked.\n\nQ: 언제 출발할까요?\nA: 금요일\n\nQ: Seats?\nA: Aisle, Front")
}

/// Stands in for the `aside` CLI: one session that waits on a question until it is stopped.
private final class FakeAsideCLI {
    var calls: [[String]] = []
    var waiting = true
    var status = "idle"
    /// "list", "stop" or "steer": that command fails.
    var failing: String?
    var steerStartsTurn = true
    var pauses: [TimeInterval] = []

    func run(_ arguments: [String]) -> Data? {
        calls.append(arguments)
        let command = arguments.dropFirst().first ?? ""
        guard command != failing else { return nil }
        switch command {
        case "list":
            let suspension = waiting
                ? #","suspension":{"id":"sus_1","kind":"ask-user-question","request":{"questions":[{"question":"Q?","options":[{"label":"A"},{"label":"B"}]}]}}"#
                : ""
            return Data(#"{"sessions":[{"id":"ses1","status":"\#(status)"\#(suspension)},{"id":"other","status":"idle"}]}"#.utf8)
        case "stop":
            waiting = false
            status = "interrupted"
            return Data(#"{"session":{"id":"ses1","status":"interrupted"},"outcome":"stopped"}"#.utf8)
        case "steer":
            if steerStartsTurn { status = "running" }
            return Data(#"{"session":{"id":"ses1","status":"interrupted"},"outcome":"steered"}"#.utf8)
        default:
            return nil
        }
    }

    func send(_ message: String = "the answer", suspensionID: String = "sus_1") -> AsideSessions.SendOutcome {
        AsideSessions.sendAnswer(message, sessionID: "ses1", suspensionID: suspensionID, pause: { self.pauses.append($0) }, run: run)
    }
}

@Test func asideSendAnswerStopsTheSessionThenSteersIt() {
    let cli = FakeAsideCLI()
    #expect(cli.send("-- a message that starts with dashes") == .sent)
    #expect(cli.calls == [
        ["session", "list", "--json"],
        ["session", "stop", "ses1", "--json"],
        ["session", "steer", "ses1", "--json", "--", "-- a message that starts with dashes"],
        ["session", "list", "--json"],
    ])
    #expect(cli.pauses == [0.3])
}

@Test func asideSendAnswerLeavesAQuestionAnsweredInAsideAlone() {
    // Answered in Aside a moment ago: the session is working again and must not be stopped.
    let answered = FakeAsideCLI()
    answered.waiting = false
    answered.status = "running"
    #expect(answered.send() == .notPending)
    #expect(answered.calls == [["session", "list", "--json"]])

    // The session has moved on to another question.
    let next = FakeAsideCLI()
    #expect(next.send(suspensionID: "sus_0") == .notPending)
    #expect(next.calls.count == 1)
}

@Test func asideSendAnswerNamesTheStepThatFailed() {
    let noList = FakeAsideCLI()
    noList.failing = "list"
    #expect(noList.send() == .failed("session list"))
    #expect(noList.calls.count == 1)

    let noStop = FakeAsideCLI()
    noStop.failing = "stop"
    #expect(noStop.send() == .failed("session stop"))
    #expect(!noStop.calls.contains { $0.contains("steer") })

    let noSteer = FakeAsideCLI()
    noSteer.failing = "steer"
    #expect(noSteer.send() == .failed("session steer"))

    // The message was accepted, but the session never left "interrupted".
    let stuck = FakeAsideCLI()
    stuck.steerStartsTurn = false
    #expect(stuck.send() == .failed("no turn started"))
    #expect(stuck.calls.filter { $0 == ["session", "list", "--json"] }.count == 9)
}
