import Testing
@testable import VQCore

@Test func plainClickAnswersAlsoWhenSeveralAreAllowed() {
    #expect(OptionPick.resolve(index: 1, collecting: false, multiSelect: false, selection: []) == .send([1]))
    #expect(OptionPick.resolve(index: 1, collecting: false, multiSelect: true, selection: []) == .send([1]))
    // A plain click is that option and nothing else, whatever was collected before.
    #expect(OptionPick.resolve(index: 1, collecting: false, multiSelect: true, selection: [0, 2]) == .send([1]))
}

@Test func modifierClickCollectsOnlyWhenSeveralAreAllowed() {
    #expect(OptionPick.resolve(index: 2, collecting: true, multiSelect: true, selection: []) == .collect([2]))
    #expect(OptionPick.resolve(index: 0, collecting: true, multiSelect: true, selection: [2]) == .collect([2, 0]))
    #expect(OptionPick.resolve(index: 2, collecting: true, multiSelect: true, selection: [2, 0]) == .collect([0]))
    #expect(OptionPick.resolve(index: 2, collecting: true, multiSelect: false, selection: []) == .send([2]))
}

@Test func recommendedMarkerIsShownAsAStarNotAsText() {
    let english = QuestionOption(label: "Leave it out (Recommended)")
    #expect(english.isRecommended)
    #expect(english.displayTitle == "Leave it out")

    let korean = QuestionOption(label: "이번엔 빼기 (추천)")
    #expect(korean.isRecommended)
    #expect(korean.displayTitle == "이번엔 빼기")

    #expect(QuestionOption(label: "Keep [recommended] ").displayTitle == "Keep")

    let plain = QuestionOption(label: "Recommended settings")
    #expect(!plain.isRecommended)
    #expect(plain.displayTitle == "Recommended settings")

    // Only at the end of the label, and never the whole label.
    #expect(!QuestionOption(label: "(Recommended) first").isRecommended)
    let bare = QuestionOption(label: "(Recommended)")
    #expect(!bare.isRecommended)
    #expect(bare.displayTitle == "(Recommended)")
}
