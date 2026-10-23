import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ListNumbering
//
// Decides what number a new numbered-list item should get. Pure Foundation so
// it can be tested outside the app (see the commit that added it); the editor
// calls it from applyList.
// ─────────────────────────────────────────────────────────────────────────────

enum ListNumbering {

    /// The number to use for a list item whose paragraph starts at `location`.
    ///
    /// Walks upward to the nearest NON-EMPTY paragraph. If that paragraph is
    /// "N. …", returns N + 1; otherwise 1. Contract text puts a blank line
    /// between items, so the paragraph immediately above is usually empty —
    /// looking only one paragraph up (the first cut) restarted every item at 1.
    static func nextNumber(in text: NSString, forParagraphAt location: Int) -> Int {
        var loc = location
        while loc > 0 {
            let prev = text.paragraphRange(for: NSRange(location: loc - 1, length: 0))
            let line = text.substring(with: prev).trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                return (leadingNumber(of: line) ?? 0) + 1
            }
            loc = prev.location
        }
        return 1
    }

    /// "12. Something" → 12. "Section 1: …" → nil (no dot after the digits).
    private static func leadingNumber(of line: String) -> Int? {
        guard let dot = line.firstIndex(of: ".") else { return nil }
        let head = line[..<dot].trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty, head.allSatisfy(\.isNumber) else { return nil }
        return Int(head)
    }
}
