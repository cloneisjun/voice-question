import Foundation

/// What a click on an option card (or ⌘1…⌘9) does.
public enum OptionPick: Equatable {
    /// Answer right away with these options.
    case send([Int])
    /// Keep collecting; Send or Return answers with this selection.
    case collect([Int])

    /// A plain click always answers with the clicked option, also when the question allows
    /// several. Only a ⌘- or ⇧-click on such a question (`collecting`) adds the option to the
    /// selection, or takes it out again, instead of answering.
    public static func resolve(index: Int, collecting: Bool, multiSelect: Bool, selection: [Int]) -> OptionPick {
        guard collecting, multiSelect else { return .send([index]) }
        var selection = selection
        if let position = selection.firstIndex(of: index) {
            selection.remove(at: position)
        } else {
            selection.append(index)
        }
        return .collect(selection)
    }
}

extension QuestionOption {
    private static let recommendedSuffix = try? NSRegularExpression(
        pattern: "\\s*[(\\[（]\\s*(recommended|추천|권장)\\s*[)\\]）]\\s*$", options: [.caseInsensitive])

    private var recommendedRange: NSRange? {
        let range = QuestionOption.recommendedSuffix?.firstMatch(in: label, range: NSRange(location: 0, length: (label as NSString).length))?.range
        // A label that is nothing but the marker stays as it is.
        return range.flatMap { $0.location > 0 ? $0 : nil }
    }

    /// Agents mark their suggestion as "Label (Recommended)". The panel shows that as a star.
    public var isRecommended: Bool { recommendedRange != nil }

    /// The label as shown on the card, without the "(Recommended)" marker. The answer handed
    /// back to the agent is always the full `label`.
    public var displayTitle: String {
        recommendedRange.map { (label as NSString).substring(to: $0.location) } ?? label
    }
}
