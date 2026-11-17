import Testing
@testable import VQCore

private let cards = Question(question: "어떤 카드로 결제할까요?", options: [
    QuestionOption(label: "신용카드"),
    QuestionOption(label: "일반 체크카드"),
    QuestionOption(label: "트래블로그 체크카드"),
])

private let frameworks = Question(question: "Which frameworks should I set up?", options: [
    QuestionOption(label: "React"),
    QuestionOption(label: "Vue"),
    QuestionOption(label: "Svelte"),
    QuestionOption(label: "Solid"),
], multiSelect: true)

private let yesNo = Question(question: "Deploy now?", options: [
    QuestionOption(label: "Yes, deploy"),
    QuestionOption(label: "No"),
])

private let koreanYesNo = Question(question: "지금 배포할까요?", options: [
    QuestionOption(label: "네"),
    QuestionOption(label: "아니요"),
])

private func resolve(_ transcript: String, _ question: Question) -> ResolvedAnswer {
    AnswerResolver.resolve(transcript: transcript, question: question)
}

@Test func emptyTranscripts() {
    #expect(resolve("", cards) == .empty)
    #expect(resolve("  \n", cards) == .empty)
    #expect(resolve("...", cards) == .empty)
}

@Test func exactAndPoliteLabels() {
    #expect(resolve("신용카드", cards) == .options([0]))
    #expect(resolve("신용카드요.", cards) == .options([0]))
    #expect(resolve("신용카드로 할게요", cards) == .options([0]))
    #expect(resolve("일반 체크카드로 해줘", cards) == .options([1]))
    #expect(resolve("일반체크카드", cards) == .options([1]))
    #expect(resolve("트래블로그 체크 카드", cards) == .options([2]))
}

@Test func koreanNumbers() {
    #expect(resolve("2번", cards) == .options([1]))
    #expect(resolve("2번이요", cards) == .options([1]))
    #expect(resolve("이번", cards) == .options([1]))
    #expect(resolve("두 번째", cards) == .options([1]))
    #expect(resolve("두번째 걸로 할게요", cards) == .options([1]))
    #expect(resolve("세 번째로 해줘", cards) == .options([2]))
    #expect(resolve("첫 번째", cards) == .options([0]))
    #expect(resolve("마지막", cards) == .options([2]))
    #expect(resolve("마지막 걸로", cards) == .options([2]))
    #expect(resolve("1", cards) == .options([0]))
    #expect(resolve("하나", cards) == .options([0]))
}

@Test func englishNumbers() {
    #expect(resolve("the second one", frameworks) == .options([1]))
    #expect(resolve("Option 3", frameworks) == .options([2]))
    #expect(resolve("number two please", yesNo) == .options([1]))
    #expect(resolve("I'll go with the first one", yesNo) == .options([0]))
    #expect(resolve("the last one", frameworks) == .options([3]))
}

@Test func outOfRangeNumbersStayFreeText() {
    #expect(resolve("7번", cards) == .freeText("7번"))
    #expect(resolve("3000원짜리로", cards) == .freeText("3000원짜리로"))
}

@Test func partialMentions() {
    // Unambiguous fragment of one label.
    #expect(resolve("트래블로그", cards) == .options([2]))
    #expect(resolve("트래블로그요", cards) == .options([2]))
    // "체크카드" could be either of two options: do not guess.
    #expect(resolve("체크카드", cards) == .freeText("체크카드"))
}

@Test func richAnswersStayFreeText() {
    let long = "신용카드 말고 이번에는 회사 법인카드로 결제해줘 영수증도 챙겨주고"
    #expect(resolve(long, cards) == .freeText(long))
    let other = "아무거나 상관없는데 수수료 제일 싼 걸로"
    #expect(resolve(other, cards) == .freeText(other))
}

@Test func latinLabelsMatchWholeWordsOnly() {
    // "No" must not fire inside "not now" / "know".
    #expect(resolve("not now, maybe after lunch", yesNo) == .freeText("not now, maybe after lunch"))
    #expect(resolve("I don't know yet", yesNo) == .freeText("I don't know yet"))
    #expect(resolve("No", yesNo) == .options([1]))
    #expect(resolve("no.", yesNo) == .options([1]))
}

@Test func yesAndNo() {
    #expect(resolve("yes", yesNo) == .options([0]))
    #expect(resolve("Yeah", yesNo) == .options([0]))
    #expect(resolve("nope", yesNo) == .options([1]))
    #expect(resolve("네", koreanYesNo) == .options([0]))
    #expect(resolve("응", koreanYesNo) == .options([0]))
    #expect(resolve("아니요", koreanYesNo) == .options([1]))
    #expect(resolve("아니", koreanYesNo) == .options([1]))
    // No yes/no options on the question: "네" is just text.
    #expect(resolve("네", cards) == .freeText("네"))
}

@Test func multiSelect() {
    #expect(resolve("React and Svelte", frameworks) == .options([0, 2]))
    #expect(resolve("react, vue", frameworks) == .options([0, 1]))
    #expect(resolve("1번이랑 3번", frameworks) == .options([0, 2]))
    #expect(resolve("one and three", frameworks) == .options([0, 2]))
    #expect(resolve("React랑 3번", frameworks) == .options([0, 2]))
    #expect(resolve("all of them", frameworks) == .options([0, 1, 2, 3]))
    #expect(resolve("전부 다", frameworks) == .options([0, 1, 2, 3]))
    #expect(resolve("just React", frameworks) == .options([0]))
    let custom = "none of these, use Angular with signals instead please"
    #expect(resolve(custom, frameworks) == .freeText(custom))
}

@Test func twoLabelsInSingleSelectIsNotAGuess() {
    #expect(resolve("신용카드 아니면 일반 체크카드", cards) == .freeText("신용카드 아니면 일반 체크카드"))
}

@Test func controlPhrases() {
    #expect(resolve("건너뛰기", cards) == .skip)
    #expect(resolve("스킵", cards) == .skip)
    #expect(resolve("skip", yesNo) == .skip)
    #expect(resolve("다시", cards) == .retry)
    #expect(resolve("다시 말할게요", cards) == .retry)
    #expect(resolve("try again", yesNo) == .retry)
    // An option literally called "Skip" wins.
    let withSkip = Question(question: "Run the migration?", options: [QuestionOption(label: "Run"), QuestionOption(label: "Skip")])
    #expect(resolve("skip", withSkip) == .options([1]))
}

@Test func questionsWithoutOptions() {
    let open = Question(question: "프로젝트 이름을 뭘로 할까요?")
    #expect(resolve("보이스 퀘스천으로 해줘", open) == .freeText("보이스 퀘스천으로 해줘"))
    #expect(resolve("2번", open) == .freeText("2번"))
    #expect(resolve("건너뛰기", open) == .skip)
}

@Test func fuzzyMatchForMisheardLabels() {
    let stacks = Question(question: "Which database?", options: [QuestionOption(label: "PostgreSQL"), QuestionOption(label: "MongoDB")])
    #expect(resolve("PostgresQL", stacks) == .options([0]))
    #expect(resolve("mongo db", stacks) == .options([1]))
}

@Test func answeredRecords() {
    let single = AnswerResolver.answered(transcript: "2번이요", question: cards)
    #expect(single?.answer == "일반 체크카드")
    #expect(single?.kind == .option)
    #expect(single?.transcript == "2번이요")

    let multi = AnswerResolver.answered(transcript: "React and Svelte", question: frameworks)
    #expect(multi?.answer == "React, Svelte")
    #expect(multi?.kind == .options)
    #expect(multi?.selectedLabels == ["React", "Svelte"])

    let free = AnswerResolver.answered(transcript: " 법인카드로 해줘 ", question: cards)
    #expect(free?.answer == "법인카드로 해줘")
    #expect(free?.kind == .freeText)

    #expect(AnswerResolver.answered(transcript: "건너뛰기", question: cards) == nil)
}

@Test func normalisation() {
    #expect(AnswerResolver.normalize("  Hello,   World! ") == "hello world")
    #expect(AnswerResolver.normalize("I'll") == "ill")
    #expect(AnswerResolver.compact("일반 체크카드.") == "일반체크카드")
}
