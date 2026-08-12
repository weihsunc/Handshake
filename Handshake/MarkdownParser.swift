import UIKit

// ───────────────────────────────────────────────────────────────────────────
// MARK: - Markdown parser  (**bold** → UIFont.bold, no asterisks shown)
//
// Turns the AI's markdown source into the attributed string the editor and
// viewers render. Extracted from the former ContractEditorView.swift.
// ───────────────────────────────────────────────────────────────────────────

extension NSMutableAttributedString {

    static func fromHandshakeMarkdown(_ text: String) -> NSMutableAttributedString {
        let result   = NSMutableAttributedString()
        let baseFont = UIFont.systemFont(ofSize: 17)
        let boldFont = UIFont.boldSystemFont(ofSize: 17)

        let para = NSMutableParagraphStyle()
        para.lineSpacing      = 3
        para.paragraphSpacing = 0

        let base: [NSAttributedString.Key: Any] = [
            .font:            baseFont,
            .foregroundColor: UIColor.label,
            .paragraphStyle:  para
        ]

        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            result.append(parseLine(line, base: base, boldFont: boldFont))
            if i < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: base))
            }
        }
        return result
    }

    private static func parseLine(
        _ line: String,
        base: [NSAttributedString.Key: Any],
        boldFont: UIFont
    ) -> NSAttributedString {

        var boldAttrs = base
        boldAttrs[.font] = boldFont

        let out       = NSMutableAttributedString()
        var remaining = line

        while !remaining.isEmpty {
            guard let open = remaining.range(of: "**") else {
                out.append(NSAttributedString(string: remaining, attributes: base))
                break
            }
            let before = String(remaining[..<open.lowerBound])
            if !before.isEmpty {
                out.append(NSAttributedString(string: before, attributes: base))
            }
            remaining = String(remaining[open.upperBound...])

            if let close = remaining.range(of: "**") {
                let boldText = String(remaining[..<close.lowerBound])
                out.append(NSAttributedString(string: boldText, attributes: boldAttrs))
                remaining = String(remaining[close.upperBound...])
            } else {
                out.append(NSAttributedString(string: remaining, attributes: base))
                break
            }
        }
        return out
    }
}
