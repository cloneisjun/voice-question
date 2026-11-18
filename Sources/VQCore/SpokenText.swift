import Foundation
import NaturalLanguage

/// Builds what gets read aloud for a question.
public enum SpokenText {

    /// Two-letter language code of the text ("ko", "en", "ja", ...). Falls back to the system language.
    public static func language(of text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let language = recognizer.dominantLanguage, language != .undetermined {
            return String(language.rawValue.prefix(2))
        }
        return String((Locale.preferredLanguages.first ?? "en").prefix(2))
    }

    public static func build(question: Question, index: Int, total: Int, language: String,
                             speakOptions: Bool = true, speakDescriptions: Bool = false) -> String {
        let korean = language == "ko"
        var parts: [String] = []

        if total > 1 {
            parts.append(korean ? "질문 \(index + 1)." : "Question \(index + 1).")
        }
        parts.append(terminated(clean(question.question)))

        if speakOptions, !question.options.isEmpty {
            for (offset, option) in question.options.enumerated() {
                // Digits before 번 can be read as counts (한 번, 두 번). Spell out the
                // Sino-Korean option number so both local and online engines read 일 번, 이 번.
                var line = korean ? "\(koreanNumber(offset + 1)) 번, \(clean(option.label))" : "\(offset + 1): \(clean(option.label))"
                if speakDescriptions, let description = option.description, !description.isEmpty {
                    line += ", " + clean(description)
                }
                parts.append(terminated(line))
            }
            if question.multiSelect {
                parts.append(korean ? "여러 개를 고를 수 있어요." : "You can pick more than one.")
            }
        }
        return parts.joined(separator: " ")
    }

    private static func koreanNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.numberStyle = .spellOut
        return formatter.string(from: NSNumber(value: number)) ?? String(number)
    }

    /// Markdown and URLs sound terrible when read out.
    public static func clean(_ text: String) -> String {
        var result = text
        let replacements: [(String, String)] = [
            ("```[\\s\\S]*?```", " "),                  // code fences
            ("\\[([^\\]]+)\\]\\([^)]+\\)", "$1"),      // [label](url)
            ("https?://\\S+", " "),                     // bare URLs
            ("[`*_#>]+", ""),                           // emphasis / headings / quotes
            ("\\s+", " "),
        ]
        for (pattern, template) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(location: 0, length: (result as NSString).length), withTemplate: template)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func terminated(_ sentence: String) -> String {
        guard let last = sentence.last else { return sentence }
        return ".?!。？！".contains(last) ? sentence : sentence + "."
    }
}
