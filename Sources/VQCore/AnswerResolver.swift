import Foundation

public enum ResolvedAnswer: Equatable {
    /// Indices into `question.options`.
    case options([Int])
    case freeText(String)
    /// "건너뛰기" / "skip": hand the question back to the app's own UI.
    case skip
    /// "다시" / "again": discard and listen once more.
    case retry
    case empty
}

/// Turns a dictated transcript into an answer for a question.
///
/// The matcher is deliberately conservative: it only returns an option when the utterance is
/// essentially just that option ("2번", "두 번째 걸로 할게", "신용카드요", "the second one").
/// Anything richer is passed through as free text, which every supported agent accepts and can
/// interpret itself, so a miss costs nothing while a wrong pick would silently mislead the agent.
public enum AnswerResolver {

    public static func resolve(transcript: String, question: Question) -> ResolvedAnswer {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let compactTranscript = compact(trimmed)
        guard !compactTranscript.isEmpty else { return .empty }

        let compactLabels = question.options.map { compact($0.label) }

        // An option literally called "Skip" wins over the control command.
        if let exact = compactLabels.firstIndex(of: compactTranscript) { return .options([exact]) }

        // The utterance as said, and with trailing particles / politeness removed ("신용카드요" → "신용카드").
        let trimmedForm = trimSuffixFillers(compactTranscript)
        let candidates = trimmedForm == compactTranscript ? [compactTranscript] : [compactTranscript, trimmedForm]
        if candidates.contains(where: skipPhrases.contains) { return .skip }
        if candidates.contains(where: retryPhrases.contains) { return .retry }

        guard !question.options.isEmpty else { return .freeText(trimmed) }

        let labelMatch = matchLabels(in: trimmed, labels: question.options.map(\.label))
        let spoken = spokenNumbers(in: trimmed, optionCount: compactLabels.count)

        if question.multiSelect {
            if candidates.contains(where: allPhrases.contains) { return .options(Array(compactLabels.indices)) }
            if !labelMatch.indices.isEmpty {
                // Numbers may be mixed in with labels: "리액트랑 3번".
                let extra = extractCompactNumbers(labelMatch.rest, optionCount: compactLabels.count)
                let residual = stripFillers(extra.rest)
                let allowance = max(3, labelMatch.matchedLength / 2)
                if residual.count <= allowance, extra.numbers.allSatisfy({ compactLabels.indices.contains($0) }) {
                    return .options(Array(Set(labelMatch.indices + extra.numbers)).sorted())
                }
            }
            if !spoken.numbers.isEmpty, spoken.residual.isEmpty, spoken.numbers.allSatisfy({ compactLabels.indices.contains($0) }) {
                return .options(Array(Set(spoken.numbers)).sorted())
            }
            return .freeText(trimmed)
        }

        // Single select ---------------------------------------------------------------------
        if labelMatch.indices.count == 1, let index = labelMatch.indices.first {
            let residual = stripFillers(labelMatch.rest)
            // Leftover digits are fine when they just restate the position: "2번 일반 체크카드".
            let withoutNumbers = stripFillers(extractCompactNumbers(labelMatch.rest, optionCount: compactLabels.count).rest)
            let allowance = max(3, compactLabels[index].count / 2)
            if min(residual.count, withoutNumbers.count) <= allowance { return .options([index]) }
            return .freeText(trimmed)
        }
        if labelMatch.indices.count > 1 { return .freeText(trimmed) }

        if spoken.numbers.count == 1, spoken.residual.isEmpty, let index = spoken.numbers.first, compactLabels.indices.contains(index) {
            return .options([index])
        }

        if let index = yesNoOption(candidates: candidates, question: question) { return .options([index]) }

        // Partial mention: "트래블로그" for "트래블로그 체크카드". Ambiguous fragments ("체크카드") fall through.
        for candidate in candidates where candidate.count >= 2 {
            let containing = compactLabels.indices.filter { compactLabels[$0].contains(candidate) }
            if containing.count == 1, candidate.count * 2 >= compactLabels[containing[0]].count { return .options(containing) }
        }

        for candidate in candidates {
            if let index = fuzzyMatch(candidate, labels: compactLabels) { return .options([index]) }
        }

        return .freeText(trimmed)
    }

    /// Convenience: the final answer record, or nil for `skip` / `retry` / `empty`.
    public static func answered(transcript: String, question: Question) -> AnsweredQuestion? {
        answered(resolved: resolve(transcript: transcript, question: question), transcript: transcript, question: question)
    }

    public static func answered(resolved: ResolvedAnswer, transcript: String, question: Question) -> AnsweredQuestion? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        switch resolved {
        case .options(let indices):
            let chosen = indices.filter { question.options.indices.contains($0) }.map { question.options[$0].label }
            guard !chosen.isEmpty else { return nil }
            return AnsweredQuestion(question: question.question, answer: chosen.joined(separator: ", "), transcript: trimmed,
                                    kind: chosen.count == 1 ? .option : .options, selectedLabels: chosen)
        case .freeText(let text):
            return AnsweredQuestion(question: question.question, answer: text, transcript: trimmed, kind: .freeText, selectedLabels: [])
        case .skip, .retry, .empty:
            return nil
        }
    }

    // MARK: - Normalisation

    /// Lowercased, punctuation turned into spaces, whitespace collapsed. A particle glued onto a
    /// Latin word is split off ("React랑" → "react 랑") so the word can be matched on its own.
    public static func normalize(_ s: String) -> String {
        let lowered = s.precomposedStringWithCanonicalMapping.lowercased()
        var out = String.UnicodeScalarView()
        var previous: Unicode.Scalar?
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if let previous, CharacterSet.alphanumerics.contains(previous), isEastAsian(previous) != isEastAsian(scalar),
                   previous.isASCII || scalar.isASCII {
                    out.append(" ")
                }
                out.append(scalar)
            } else if scalar == "'" || scalar == "’" {
                continue // "i'll" → "ill", "don't" → "dont"
            } else {
                out.append(" ")
            }
            previous = scalar
        }
        return String(out).split(separator: " ").joined(separator: " ")
    }

    /// Hangul, kana and CJK ideographs all live above U+1100.
    private static func isEastAsian(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x1100
    }

    /// `normalize` without any spaces. Korean STT spacing is unreliable, so matching happens here.
    public static func compact(_ s: String) -> String {
        normalize(s).replacingOccurrences(of: " ", with: "")
    }

    // MARK: - Labels

    struct LabelMatch {
        var indices: [Int]
        /// Space-free transcript with every matched label removed.
        var rest: String
        var matchedLength: Int
    }

    /// Finds option labels mentioned in the transcript, longest first, removing each hit so that
    /// "체크카드" does not also fire when the user said "일반 체크카드".
    ///
    /// Latin-script labels must match on word boundaries ("No" is not in "not now" or "know").
    /// Everything else is matched space-free, because dictation spaces Korean inconsistently.
    static func matchLabels(in transcript: String, labels: [String]) -> LabelMatch {
        var tokens = normalize(transcript).split(separator: " ").map(String.init)
        var indices: [Int] = []
        var matchedLength = 0
        let order = labels.indices.sorted { compact(labels[$0]).count > compact(labels[$1]).count }

        for index in order where isLatin(labels[index]) {
            let labelTokens = normalize(labels[index]).split(separator: " ").map(String.init)
            // One-character labels ("A") are too easy to hit by accident; they only match exactly.
            guard labelTokens.joined().count >= 2, let start = firstRun(of: labelTokens, in: tokens) else { continue }
            indices.append(index)
            matchedLength += labelTokens.joined().count
            tokens.removeSubrange(start..<(start + labelTokens.count))
        }

        var working = tokens.joined()
        for index in order where !isLatin(labels[index]) {
            let label = compact(labels[index])
            guard label.count >= 2, working.contains(label) else { continue }
            indices.append(index)
            matchedLength += label.count
            working = working.replacingOccurrences(of: label, with: "")
        }
        return LabelMatch(indices: indices.sorted(), rest: working, matchedLength: matchedLength)
    }

    private static func isLatin(_ s: String) -> Bool {
        let n = normalize(s)
        return !n.isEmpty && n.unicodeScalars.allSatisfy { $0.isASCII }
    }

    private static func firstRun(of needle: [String], in haystack: [String]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<(start + needle.count)]) == needle {
            return start
        }
        return nil
    }

    static func fuzzyMatch(_ text: String, labels: [String]) -> Int? {
        guard text.count >= 3 else { return nil }
        let scored = labels.enumerated().map { (index: $0.offset, score: similarity(text, $0.element)) }.sorted { $0.score > $1.score }
        guard let best = scored.first, best.score >= 0.8 else { return nil }
        if scored.count > 1, best.score - scored[1].score < 0.15 { return nil }
        return best.index
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }

    // MARK: - Numbers

    private static let englishOrdinals: [String: Int] = [
        "first": 1, "1st": 1, "second": 2, "2nd": 2, "third": 3, "3rd": 3, "fourth": 4, "4th": 4, "fifth": 5, "5th": 5,
        "sixth": 6, "6th": 6, "seventh": 7, "7th": 7, "eighth": 8, "8th": 8, "ninth": 9, "9th": 9,
    ]
    private static let englishCardinals: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
    private static let englishFillers: Set<String> = [
        "i", "ill", "id", "will", "would", "like", "choose", "pick", "select", "go", "going", "with", "take", "want", "to",
        "the", "a", "an", "option", "number", "please", "lets", "its", "is", "it", "my", "answer", "um", "uh", "and", "also",
        "plus", "for", "me", "think", "guess", "choice", "that", "this", "just", "only",
    ]

    /// Korean number expressions, matched on the space-free form. Zero-based index is `value - 1`.
    private static let koreanNumberPatterns: [(pattern: String, value: Int)] = [
        ("첫번째|첫째", 1), ("두번째|둘째|두번", 2), ("세번째|셋째|세번", 3), ("네번째|넷째|네번", 4), ("다섯번째", 5),
        ("여섯번째", 6), ("일곱번째", 7), ("여덟번째", 8), ("아홉번째", 9),
        ("일번", 1), ("이번", 2), ("삼번", 3), ("사번", 4), ("오번", 5), ("육번", 6), ("칠번", 7), ("팔번", 8), ("구번", 9),
    ]
    /// Only count when nothing else is left: "하나" yes, "하나 더 있어" no.
    private static let koreanBareNumbers: [String: Int] = ["하나": 1, "둘": 2, "셋": 3, "넷": 4, "다섯": 5, "처음": 1, "첫": 1]

    /// Digits and Korean ordinals found in a space-free string. Returns zero-based indices.
    static func extractCompactNumbers(_ s: String, optionCount: Int) -> (numbers: [Int], rest: String) {
        var rest = s
        var numbers: [Int] = []

        // "2", "2번", "2번째" – but not "3000원" or "12월" (those leave a counter behind as residue).
        if let regex = try? NSRegularExpression(pattern: "(?<![0-9])([0-9]{1,2})(?![0-9])(번째|번)?") {
            let ns = rest as NSString
            let range = NSRange(location: 0, length: ns.length)
            for match in regex.matches(in: rest, range: range) {
                if let value = Int(ns.substring(with: match.range(at: 1))) { numbers.append(value - 1) }
            }
            rest = regex.stringByReplacingMatches(in: rest, range: range, withTemplate: " ")
        }
        for (pattern, value) in koreanNumberPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(location: 0, length: (rest as NSString).length)
            let count = regex.numberOfMatches(in: rest, range: range)
            guard count > 0 else { continue }
            numbers.append(contentsOf: Array(repeating: value - 1, count: count))
            rest = regex.stringByReplacingMatches(in: rest, range: range, withTemplate: " ")
        }
        if rest.contains("마지막"), optionCount > 0 {
            numbers.append(optionCount - 1)
            rest = rest.replacingOccurrences(of: "마지막", with: " ")
        }
        rest = rest.replacingOccurrences(of: " ", with: "")
        if let value = koreanBareNumbers[stripFillers(rest)] {
            numbers.append(value - 1)
            rest = ""
        }
        return (numbers, rest)
    }

    /// Every position the speaker referred to, plus whatever was said besides that (fillers removed).
    static func spokenNumbers(in transcript: String, optionCount: Int) -> (numbers: [Int], residual: String) {
        var ordinals: [Int] = []
        var cardinals: [Int] = []
        var restTokens: [String] = []
        for token in normalize(transcript).split(separator: " ").map(String.init) {
            if let value = englishOrdinals[token] {
                ordinals.append(value - 1)
            } else if token == "last", optionCount > 0 {
                ordinals.append(optionCount - 1)
            } else if let value = englishCardinals[token] {
                cardinals.append(value - 1)
            } else if !englishFillers.contains(token) {
                restTokens.append(token)
            }
        }
        // "the first one": once an ordinal is present, "one" is just a pronoun.
        var numbers = ordinals
        numbers += ordinals.isEmpty ? cardinals : cardinals.filter { $0 != 0 }
        let extracted = extractCompactNumbers(restTokens.joined(), optionCount: optionCount)
        numbers += extracted.numbers
        return (numbers, stripFillers(extracted.rest))
    }

    // MARK: - Fillers & phrases

    /// Particles, politeness endings and "I'll go with…" style padding, longest alternatives first.
    private static let fillerRegex: NSRegularExpression? = {
        let korean = [
            "으로할게요", "으로하겠습니다", "로하겠습니다", "으로해주세요", "으로할게", "로할게요", "로해주세요", "으로해줘", "으로가자",
            "으로갈게", "으로하자", "선택할게요", "선택할게", "선택해줘", "고를게요", "좋겠어요", "로할게", "로해줘", "로가자", "로갈게", "로하자",
            "할게요", "할래요", "해주세요", "고를게", "골라줘", "갈게요", "좋아요", "좋겠어", "입니다", "이에요", "그리고", "인것같아요", "인것같아",
            "것같아요", "같아요", "것같아", "같아", "할게", "할래", "해줘", "하자", "선택", "갈게", "가자", "좋아", "예요", "이요", "으로", "이랑",
            "하고", "옵션", "정답", "저는", "나는", "답은", "번째", "랑", "로", "요", "을", "를", "은", "는", "이", "가", "걸", "거", "것",
            "번", "답", "음", "어", "그", "네", "응", "난", "전", "아", "인", "와", "과", "도", "만",
        ]
        let english = ["please", "choose", "select", "option", "number", "answer", "would", "with", "lets", "pick", "take",
                       "want", "like", "also", "just", "only", "the", "ill", "and", "go"]
        let pattern = (korean + english).sorted { $0.count > $1.count }.joined(separator: "|")
        return try? NSRegularExpression(pattern: pattern)
    }()

    /// Removes filler from a space-free string. Only ever used to measure "what else was said".
    static func stripFillers(_ s: String) -> String {
        guard let regex = fillerRegex else { return s }
        var current = s
        for _ in 0..<4 {
            let next = regex.stringByReplacingMatches(in: current, range: NSRange(location: 0, length: (current as NSString).length), withTemplate: "")
            if next == current { break }
            current = next
        }
        return current
    }

    /// Endings that only ever trail an answer. Used to get from "신용카드로 할게요" to "신용카드".
    private static let suffixFillerRegex: NSRegularExpression? = {
        let endings = [
            "으로할게요", "으로하겠습니다", "로하겠습니다", "으로해주세요", "으로할게", "로할게요", "로해주세요", "으로해줘", "으로가자",
            "으로갈게", "으로하자", "선택할게요", "선택할게", "선택해줘", "고를게요", "좋겠어요", "로할게", "로해줘", "로가자", "로갈게", "로하자",
            "할게요", "할래요", "해주세요", "입니다", "이에요", "인것같아요", "인것같아", "할게", "할래", "해줘", "예요", "이요", "으로", "요",
            "please",
        ]
        let pattern = "(" + endings.sorted { $0.count > $1.count }.joined(separator: "|") + ")$"
        return try? NSRegularExpression(pattern: pattern)
    }()

    /// Strips trailing politeness, never down to nothing.
    static func trimSuffixFillers(_ s: String) -> String {
        guard let regex = suffixFillerRegex else { return s }
        var current = s
        for _ in 0..<3 {
            let next = regex.stringByReplacingMatches(in: current, range: NSRange(location: 0, length: (current as NSString).length), withTemplate: "")
            if next == current || next.isEmpty { break }
            current = next
        }
        return current
    }

    private static let skipPhrases: Set<String> = [
        "건너뛰기", "건너뛰어", "건너뛰어줘", "건너뛸게", "건너뛸게요", "스킵", "스킵해", "스킵해줘", "패스", "넘어가", "넘어가줘", "취소", "취소해줘",
        "나중에", "skip", "skipthis", "skipit", "pass", "cancel", "nevermind",
    ]
    private static let retryPhrases: Set<String> = [
        "다시", "다시말할게", "다시말할게요", "다시할게", "다시할게요", "다시할래", "retry", "again", "tryagain", "startover",
    ]
    private static let allPhrases: Set<String> = ["전부", "전부다", "모두", "모두다", "다", "싹다", "all", "allofthem", "everything"]

    private static let affirmatives: Set<String> = [
        "네", "예", "응", "어", "그래", "그래요", "좋아", "좋아요", "맞아", "맞아요", "오케이", "오케", "그렇게해", "그렇게해줘", "진행해", "진행해줘",
        "yes", "yeah", "yep", "yup", "sure", "ok", "okay",
    ]
    private static let negatives: Set<String> = ["아니", "아니요", "아니오", "아뇨", "노", "안돼", "하지마", "no", "nope", "nah"]

    /// "네" / "yes" for a question whose options are literally Yes / No (in either language).
    static func yesNoOption(candidates: [String], question: Question) -> Int? {
        let isYes = candidates.contains(where: affirmatives.contains)
        let isNo = candidates.contains(where: negatives.contains)
        guard isYes || isNo else { return nil }
        let yesHeads: Set<String> = ["yes", "예", "네"]
        let noHeads: Set<String> = ["no", "아니요", "아니오", "아니"]
        let heads = question.options.map { normalize($0.label).split(separator: " ").first.map(String.init) ?? "" }
        let wanted = isYes ? yesHeads : noHeads
        let hits = heads.indices.filter { wanted.contains(heads[$0]) }
        return hits.count == 1 ? hits[0] : nil
    }
}
