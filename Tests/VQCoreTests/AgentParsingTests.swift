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
