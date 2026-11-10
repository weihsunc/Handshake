import Foundation
import NaturalLanguage

enum SignatureTypeface: String {
    case latin = "MrsSaintDelafield-Regular"
    case traditionalChinese = "LXGWWenKaiTC-Regular"
    case simplifiedChinese = "LXGWWenKai-Regular"
    case japanese = "KleeOne-Regular"

    static func forName(_ name: String, appLanguage: String? = Bundle.main.preferredLocalizations.first) -> Self {
        if name.range(of: #"\p{Hiragana}|\p{Katakana}"#, options: .regularExpression) != nil { return .japanese }
        guard name.range(of: #"\p{Han}"#, options: .regularExpression) != nil else { return .latin }

        // A Han-only name may be written identically in several languages.
        // Use clear evidence from the name, then the app language for ties.
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.traditionalChinese, .simplifiedChinese, .japanese]
        recognizer.processString(name)
        let hypothesis = recognizer.languageHypotheses(withMaximum: 1).first
        let inferred = hypothesis.flatMap { typeface(for: $0.key) }
        if let inferred, let hypothesis, hypothesis.value >= 0.8 { return inferred }
        return appLanguage.flatMap { typeface(for: NLLanguage(rawValue: $0)) }
            ?? inferred ?? .traditionalChinese
    }

    private static func typeface(for language: NLLanguage) -> Self? {
        switch language {
        case .traditionalChinese: .traditionalChinese
        case .simplifiedChinese: .simplifiedChinese
        case .japanese: .japanese
        default: nil
        }
    }
}
