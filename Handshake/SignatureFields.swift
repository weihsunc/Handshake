import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SignatureField
//
// The fields a sender places for a recipient to fill, the way DocuSign and
// Dropbox Sign do it: the sender drops a box, the box belongs to a signer, and
// the signer fills it at signing time.
//
//   .signature   the recipient signs it (Face ID → stamp)
//   .date        the recipient picks a date (defaults to the day they sign)
//
// In the DOCUMENT a field is an NSTextAttachment drawing a box. In MARKDOWN —
// what the AI emits, what crosses to the recipient in the link — it's a token,
// "[Signature]" / "[Date]". The two convert losslessly in both directions, so
// a box the sender places reaches the recipient, and a token the AI writes
// renders as a box.
//
// A field attachment is recognised by its size (see Detection below), with
// its file name as a secondary check. Custom attributes don't survive RTFD.
// ─────────────────────────────────────────────────────────────────────────────

enum SignatureField: String, CaseIterable {
    case signature = "handshake-signature"
    case date      = "handshake-date"

    var token: String {
        switch self {
        case .signature: return "[Signature]"
        case .date:      return "[Date]"
        }
    }

    // ── Detection ────────────────────────────────────────────────────────────
    //
    // Identity is the box's SIZE. The file name was the first idea, and it
    // round-trips fine through AppKit — but UIKit regenerates the file wrapper
    // from the image when it writes RTFD, so on iOS every box came back as
    // "Attachment.png". Dimensions survive everything, and 300×64 / 170×44
    // don't collide with anything a user would insert. The boxes render at 3×
    // for a sharp Retina image, so a box read back without its point size
    // (see attachmentSizes) measures 900×192 — any 1×/2×/3× multiple counts.
    // Name is kept as a secondary check for the AppKit path.

    static let boxSize: [SignatureField: CGSize] = [
        .signature: CGSize(width: 300, height: 64),
        .date:      CGSize(width: 170, height: 44),
    ]

    static func kind(of attachment: NSTextAttachment) -> SignatureField? {
        let name = attachment.fileWrapper?.preferredFilename ?? attachment.fileWrapper?.filename ?? ""
        let byName = allCases.first(where: { name.hasPrefix($0.rawValue) })
        let size = Self.size(of: attachment)
        let bySize = size.flatMap { sz in
            allCases.first { kind in
                let box = boxSize[kind]!
                return [1, 2, 3].contains { (k: CGFloat) in
                    abs(box.width * k - sz.width) < 1 && abs(box.height * k - sz.height) < 1
                }
            }
        }
        return byName ?? bySize
    }

    private static func size(of a: NSTextAttachment) -> CGSize? {
        if a.bounds.size.width > 0 { return a.bounds.size }
        #if canImport(UIKit)
        if let img = a.image { return img.size }
        if let d = a.fileWrapper?.regularFileContents ?? a.contents, let img = UIImage(data: d) { return img.size }
        #else
        if let img = a.image { return img.size }
        if let d = a.fileWrapper?.regularFileContents ?? a.contents, let img = NSImage(data: d) { return img.size }
        #endif
        return nil
    }

    /// Wraps rendered PNG bytes so the attachment is recognisable later.
    static func attachment(_ kind: SignatureField, png: Data, size: CGSize) -> NSTextAttachment {
        let wrapper = FileWrapper(regularFileWithContents: png)
        wrapper.preferredFilename = kind.rawValue + ".png"
        // iOS has no init(fileWrapper:); the property is settable on both.
        let a = NSTextAttachment()
        a.fileWrapper = wrapper
        #if canImport(UIKit)
        a.image = UIImage(data: png, scale: renderScale)
        #endif
        a.bounds = CGRect(origin: .zero, size: boxSize[kind] ?? size)
        return a
    }

    /// Pixels per point for every image Handshake draws into a document
    /// (field boxes, the signature stamp). 3 is sharp on every iPhone; the
    /// point size that keeps it the right size is restored on load from
    /// `GeneratedContract.attachmentSizes`.
    static let renderScale: CGFloat = 3
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Attachment sizes across an RTFD round-trip
//
// RTFD keeps an attachment's image but not its bounds: on import iOS sizes it
// by PIXELS. A 3× image therefore comes back 3× too big, which is why the
// stamp used to be rendered at 1× (soft on Retina). Instead, the point size of
// every attachment is saved next to the RTFD, in document order, and put back
// when the document is read.
// ─────────────────────────────────────────────────────────────────────────────

extension NSAttributedString {
    /// Point size of every attachment, in document order.
    var attachmentSizes: [CGSize] {
        var out: [CGSize] = []
        enumerateAttribute(.attachment, in: NSRange(location: 0, length: length)) { v, _, _ in
            guard let a = v as? NSTextAttachment else { return }
            #if canImport(UIKit)
            let fallback = a.image?.size ?? .zero
            #else
            let fallback = a.image?.size ?? .zero
            #endif
            out.append(a.bounds.size.width > 0 ? a.bounds.size : fallback)
        }
        return out
    }
}

extension NSMutableAttributedString {
    /// Puts saved point sizes back. Only when the counts match — an older
    /// record (no sizes, 1× images) is left exactly as it was.
    func applyAttachmentSizes(_ sizes: [CGSize]?) {
        guard let sizes, sizes.count == attachmentSizes.count else { return }
        var i = 0
        enumerateAttribute(.attachment, in: NSRange(location: 0, length: length)) { v, _, _ in
            guard let a = v as? NSTextAttachment else { return }
            if sizes[i].width > 0 { a.bounds = CGRect(origin: .zero, size: sizes[i]) }
            i += 1
        }
    }

    /// Inserts a field box on its own line after the paragraph holding
    /// `cursor`, with one blank line before it — except straight after another
    /// field, so a signature and its date stack as a pair instead of drifting
    /// apart a blank line at a time. A blank line follows the box when text
    /// comes next. Returns the caret: just after the box, so a second insert
    /// lands right beneath it.
    @discardableResult
    func insertFieldBox(_ box: NSAttributedString, near cursor: Int,
                        attributes: [NSAttributedString.Key: Any]) -> Int {
        let ns    = string as NSString
        let para  = ns.paragraphRange(for: NSRange(location: min(max(cursor, 0), ns.length), length: 0))
        let at    = NSMaxRange(para)

        var lead = ""
        if at > 0 && ns.character(at: at - 1) != 10 { lead += "\n" }        // last line had no newline
        if !isBlankLine(para) && !isFieldLine(para) { lead += "\n" }        // blank line after text

        var trail = "\n"
        if at < ns.length {
            let next = ns.paragraphRange(for: NSRange(location: at, length: 0))
            if !isBlankLine(next) && !isFieldLine(next) { trail += "\n" }   // blank line before text
        }

        let block = NSMutableAttributedString(string: lead, attributes: attributes)
        block.append(box)
        block.append(NSAttributedString(string: trail, attributes: attributes))
        insert(block, at: at)
        return at + lead.utf16.count + box.length
    }

    private func isBlankLine(_ r: NSRange) -> Bool {
        (string as NSString).substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isFieldLine(_ r: NSRange) -> Bool {
        let s = (string as NSString).substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
        guard s == "\u{FFFC}" else { return false }
        let at = (string as NSString).range(of: "\u{FFFC}", options: [], range: r).location
        guard let a = attribute(.attachment, at: at, effectiveRange: nil) as? NSTextAttachment else { return false }
        return SignatureField.kind(of: a) != nil
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Fields in an attributed string
// ─────────────────────────────────────────────────────────────────────────────

extension NSAttributedString {

    /// Every field attachment, in document order.
    func signatureFields() -> [(kind: SignatureField, range: NSRange)] {
        var out: [(SignatureField, NSRange)] = []
        enumerateAttribute(.attachment, in: NSRange(location: 0, length: length)) { v, r, _ in
            if let a = v as? NSTextAttachment, let k = SignatureField.kind(of: a) { out.append((k, r)) }
        }
        return out
    }

    /// Back to markdown: bold runs → **…**, field attachments → their tokens,
    /// other attachments (photos, the signed stamp) dropped. This is what
    /// `persist()` writes to `content`, so the recipient sees the sender's
    /// edits — before this, `content` stayed frozen at the AI's first draft.
    func handshakeMarkdown() -> String {
        var out = ""
        enumerateAttributes(in: NSRange(location: 0, length: length)) { attrs, r, _ in
            if let a = attrs[.attachment] as? NSTextAttachment {
                if let k = SignatureField.kind(of: a) { out += k.token }
                return
            }
            let s = (string as NSString).substring(with: r)
            out += Self.isBold(attrs) && !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? Self.boldWrap(s) : s
        }
        return out
    }

    /// Wrap only the non-whitespace core so "**Title**\n" never becomes "**Title\n**".
    private static func boldWrap(_ s: String) -> String {
        let lead  = s.prefix { $0.isWhitespace }
        let trail = s.reversed().prefix { $0.isWhitespace }.reversed()
        let core  = s.dropFirst(lead.count).dropLast(trail.count)
        return String(lead) + "**" + core + "**" + String(trail)
    }

    private static func isBold(_ attrs: [NSAttributedString.Key: Any]) -> Bool {
        #if canImport(UIKit)
        guard let f = attrs[.font] as? UIFont else { return false }
        return f.fontDescriptor.symbolicTraits.contains(.traitBold)
        #else
        guard let f = attrs[.font] as? NSFont else { return false }
        return f.fontDescriptor.symbolicTraits.contains(.bold)
        #endif
    }
}

extension NSMutableAttributedString {

    /// Replace every "[Signature]" / "[Date]" token with a field attachment.
    func renderFieldTokens(_ make: (SignatureField) -> NSTextAttachment) {
        for kind in SignatureField.allCases {
            while true {
                var r = (string as NSString).range(of: kind.token)
                if r.location == NSNotFound { break }
                // A text label right before the token ("Signature: [Signature]",
                // "Date: [Date]") is redundant — the box is labelled — and the
                // 300pt signature box wraps under it. Absorb it into the range.
                let ns = string as NSString
                let lead = ns.substring(with: NSRange(location: 0, length: r.location)).lowercased()
                for label in ["signature: ", "signature:", "date: ", "date:"] where lead.hasSuffix(label) {
                    let start = r.location - label.count
                    // Only when the label begins its line — "Please add your
                    // Signature: [Signature]" mid-sentence must keep its words.
                    if start == 0 || ns.character(at: start - 1) == 10 {
                        r = NSRange(location: start, length: r.length + label.count)
                    }
                    break
                }
                let keep = attributes(at: r.location, effectiveRange: nil)
                let box  = NSMutableAttributedString(attachment: make(kind))
                // Keep paragraph style so the box sits in the paragraph's flow.
                if let p = keep[.paragraphStyle] { box.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: 1)) }
                replaceCharacters(in: r, with: box)
            }
        }
    }
}
