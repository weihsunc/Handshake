import UIKit

/// A revision-only exchange format. The model edits words between markers.
/// Fonts, paragraph styles and attachment bytes stay on the device.
@MainActor
struct ContractRevision {
    private struct Style {
        let font: UIFont?
        let underline: Int?
        let paragraph: NSParagraphStyle?

        var isEmpty: Bool { font == nil && underline == nil && paragraph == nil }
    }

    private enum Marker {
        case open(Style, close: String)
        case close
        case attachment(NSAttributedString)
    }

    let markdown: String
    private let prefix: String
    private let markers: [String: Marker]

    var instructions: String {
        guard !markers.isEmpty else { return "" }
        return """
            Markers beginning with \(prefix) carry formatting and photos. Copy each marker exactly once. \
            Keep each S marker paired with its matching /S marker around the same words or their revised wording. \
            If those words are removed, return the pair with nothing between it. \
            Keep every A marker where its attachment belongs. Do not translate, explain, or put code fences around markers.
            """
    }

    init(_ body: NSAttributedString) {
        var prefix = "⟦HS:"
        while body.string.contains(prefix) { prefix.insert("X", at: prefix.index(before: prefix.endIndex)) }
        self.prefix = prefix

        var markdown = ""
        var markers: [String: Marker] = [:]
        var nextID = 0
        let baseSize = UIFont.preferredFont(forTextStyle: .body).pointSize
        let text = body.string as NSString
        var start = 0

        while start < body.length {
            var end = 0
            var contentsEnd = 0
            text.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
            body.enumerateAttributes(in: NSRange(location: start, length: contentsEnd - start)) { attrs, range, _ in
                let part = body.attributedSubstring(from: range)
                let font = attrs[.font] as? UIFont
                let customFont = font.flatMap {
                    $0.fontDescriptor.symbolicTraits.contains(.traitItalic) || $0.pointSize != baseSize ? $0 : nil
                }
                let paragraph = attrs[.paragraphStyle] as? NSParagraphStyle
                let style = Style(font: customFont, underline: attrs[.underlineStyle] as? Int,
                                  paragraph: paragraph.flatMap { $0.alignment == .natural ? nil : $0 })

                if let attachment = attrs[.attachment] as? NSTextAttachment, SignatureField.kind(of: attachment) == nil {
                    nextID += 1
                    let token = "\(prefix)A\(nextID)⟧"
                    markers[token] = .attachment(part)
                    markdown += token
                } else if style.isEmpty {
                    markdown += part.handshakeMarkdown()
                } else {
                    nextID += 1
                    let open = "\(prefix)S\(nextID)⟧"
                    let close = "\(prefix)/S\(nextID)⟧"
                    markers[open] = .open(style, close: close)
                    markers[close] = .close
                    markdown += open + part.handshakeMarkdown() + close
                }
            }
            // Keep markers on a single line so the Markdown bold parser can
            // still read styled text and blank lines are left alone.
            markdown += text.substring(with: NSRange(location: contentsEnd, length: end - contentsEnd))
            start = end
        }
        self.markdown = markdown
        self.markers = markers
    }

    /// Reject a damaged response before the workspace changes the draft.
    func restore(_ markdown: String) throws -> NSMutableAttributedString {
        guard !markers.isEmpty else { return .fromHandshakeMarkdown(markdown) }
        let parsed = NSMutableAttributedString.fromHandshakeMarkdown(markdown, renderFields: false)
        let text = parsed.string as NSString
        let pattern = NSRegularExpression.escapedPattern(for: prefix) + "[^⟧]*⟧"
        let tokens = try NSRegularExpression(pattern: pattern).matches(in: parsed.string, range: NSRange(location: 0, length: parsed.length))
        let body = NSMutableAttributedString()
        var seen: Set<String> = []
        var active: (style: Style, close: String, start: Int)?
        var paragraphs: [(NSParagraphStyle, NSRange)] = []
        var cursor = 0

        for match in tokens {
            let range = match.range
            body.append(parsed.attributedSubstring(from: NSRange(location: cursor, length: range.location - cursor)))
            cursor = NSMaxRange(range)
            let token = text.substring(with: range)
            guard seen.insert(token).inserted, let marker = markers[token] else { throw AIError.malformedContract }
            switch marker {
            case let .open(style, close):
                guard active == nil else { throw AIError.malformedContract }
                active = (style, close, body.length)
            case .close:
                guard let span = active, span.close == token else { throw AIError.malformedContract }
                let styled = NSRange(location: span.start, length: body.length - span.start)
                if styled.length > 0 {
                    if let font = span.style.font { body.addAttribute(.font, value: font, range: styled) }
                    if let underline = span.style.underline { body.addAttribute(.underlineStyle, value: underline, range: styled) }
                    if let paragraph = span.style.paragraph { paragraphs.append((paragraph, styled)) }
                }
                active = nil
            case let .attachment(attachment):
                guard active == nil else { throw AIError.malformedContract }
                if let paragraph = attachment.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle {
                    paragraphs.append((paragraph, NSRange(location: body.length, length: attachment.length)))
                }
                body.append(attachment)
            }
        }
        body.append(parsed.attributedSubstring(from: NSRange(location: cursor, length: parsed.length - cursor)))
        guard active == nil, seen.count == markers.count, !body.string.contains(prefix) else { throw AIError.malformedContract }

        let plain = body.string as NSString
        for (style, range) in paragraphs {
            body.addAttribute(.paragraphStyle, value: style, range: plain.paragraphRange(for: range))
        }
        body.renderFieldTokens(SignatureField.makeAttachment)
        return body
    }
}
