import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SignatureSlots
//
// Finds every "[Signature]" in a document and works out WHOSE it is, from the
// nearest "ROLE:" line above it:
//
//     LANDLORD: [FULL NAME]
//     Signature: [Signature]        ← slot 0, role "Landlord"
//     Date: [Date]
//
//     TENANT: [FULL NAME]
//     Signature: [Signature]        ← slot 1, role "Tenant"
//
// The signing screen uses this to let the signer pick their party when there
// is more than one slot. Before this, the stamp always replaced the FIRST
// token — so a tenant's signature landed in the landlord's slot.
// Pure Foundation so it can be tested outside the app.
// ─────────────────────────────────────────────────────────────────────────────

enum SignatureSlots {

    struct Slot: Equatable {
        /// Display name, e.g. "Landlord". "Party N" when no role line is found.
        let role: String
        /// Range of the "[Signature]" token in the document string.
        let range: NSRange
        /// The "LANDLORD: [FULL NAME]" line above it, when there is one. Its
        /// placeholder is the signer's to fill: the stamp writes their name in.
        var roleLine: NSRange? = nil
        /// Is there a date field between this box and the next party's?
        var hasDate: Bool = false
        /// Where this party's block ends: the next party's role line (or box).
        /// A date field is this slot's only if it comes before here.
        var end: Int = Int.max
    }

    static let token = "[Signature]"

    /// Signature fields in a document, as attachments (the normal case) or as
    /// bare "[Signature]" text (older records, or markdown that wasn't
    /// rendered). Ranges are in the attributed string.
    static func find(in doc: NSAttributedString) -> [Slot] {
        let ns = doc.string as NSString
        let fields = doc.signatureFields()
        var ranges = fields.filter { $0.kind == .signature }.map(\.range)
        if ranges.isEmpty { ranges = tokenRanges(token, in: ns) }
        let dates = fields.filter { $0.kind == .date }.map(\.range.location)
                  + tokenRanges(SignatureField.date.token, in: ns).map(\.location)

        let labels = ranges.map { roleLabel(above: $0.location, in: ns) }
        return ranges.enumerated().map { i, r in
            let nextStart = i + 1 < ranges.count
                ? (labels[i + 1]?.line.location ?? ranges[i + 1].location)
                : Int.max
            let after = r.location + r.length
            return Slot(role: labels[i]?.role ?? String(localized: "Party \(i + 1)"),
                        range: r,
                        roleLine: labels[i]?.line,
                        hasDate: dates.contains { $0 >= after && $0 < nextStart },
                        end: nextStart)
        }
    }

    /// Plain-text convenience (tests, markdown).
    static func find(in text: String) -> [Slot] { find(in: NSAttributedString(string: text)) }

    private static func tokenRanges(_ token: String, in ns: NSString) -> [NSRange] {
        var out: [NSRange] = []
        var search = NSRange(location: 0, length: ns.length)
        while true {
            let r = ns.range(of: token, options: [], range: search)
            if r.location == NSNotFound { break }
            out.append(r)
            let next = r.location + r.length
            search = NSRange(location: next, length: ns.length - next)
        }
        return out
    }

    /// Walks up from `location`, paragraph by paragraph, for a line shaped
    /// like "LANDLORD:" / "PARTY A:" / "SERVICE PROVIDER:". Stops at the
    /// previous slot so one party's label can't bleed into the next.
    private static func roleLabel(above location: Int, in ns: NSString) -> (role: String, line: NSRange)? {
        var loc = ns.paragraphRange(for: NSRange(location: location, length: 0)).location
        var hops = 0
        while loc > 0 && hops < 6 {
            let prev = ns.paragraphRange(for: NSRange(location: loc - 1, length: 0))
            let line = ns.substring(with: prev).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.contains(token) || line.contains("\u{FFFC}") { return nil }   // crossed into the slot above
            if let role = parseRole(line) { return (role, prev) }
            loc = prev.location; hops += 1
        }
        return nil
    }

    // ── Blanks ───────────────────────────────────────────────────────────────

    /// Placeholders the AI left for the sender to fill — "[ADDRESS]",
    /// "[RENT AMOUNT]" — in document order, without repeats. Not the field
    /// tokens, and not the name on a party's line: the signer fills that.
    static func blanks(in doc: NSAttributedString) -> [String] {
        let ns = doc.string as NSString
        let skip = find(in: doc).compactMap(\.roleLine)
        guard let re = try? NSRegularExpression(pattern: #"\[[^\[\]\n]{1,48}\]"#) else { return [] }
        var seen = Set<String>(), out: [String] = []
        for m in re.matches(in: doc.string, range: NSRange(location: 0, length: ns.length)) {
            let t = ns.substring(with: m.range)
            if t == token || t == SignatureField.date.token { continue }
            if skip.contains(where: { NSLocationInRange(m.range.location, $0) }) { continue }
            if seen.insert(t).inserted { out.append(t) }
        }
        return out
    }

    /// The first "[…]" on a party's line, for the signer's name.
    static func namePlaceholder(in line: NSRange, of ns: NSString) -> NSRange? {
        guard let re = try? NSRegularExpression(pattern: #"\[[^\[\]\n]{1,48}\]"#),
              let m = re.firstMatch(in: ns as String, range: line) else { return nil }
        return m.range
    }

    /// "LANDLORD: [FULL NAME]" → "Landlord". Requires an all-caps label of
    /// 2–40 chars before the first colon; "Signature:" / "Date:" don't match
    /// because they aren't all caps.
    private static func parseRole(_ line: String) -> String? {
        // ":" or the full-width "：" Chinese and Japanese contracts use.
        guard let colon = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return nil }
        let head = line[..<colon].trimmingCharacters(in: .whitespaces)
        guard (2...40).contains(head.count),
              head.first?.isLetter == true,
              // All caps — or, for scripts without case (CJK), any letters.
              head.allSatisfy({ $0.isUppercase || ($0.isLetter && !$0.isCased)
                                || $0.isNumber || " /&'-()（）".contains($0) }),
              head.contains(where: \.isLetter)
        else { return nil }
        // Title-case for display: "SERVICE PROVIDER" → "Service Provider"
        return head.lowercased().split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
