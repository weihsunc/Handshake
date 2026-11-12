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

    /// Each occurrence is its own input. Identical labels can describe
    /// different terms (for example, a notice period and a payment deadline).
    struct Blank: Hashable, Identifiable {
        let token: String
        let range: NSRange
        var id: String { "\(range.location):\(token)" }
    }

    static func blankFields(in doc: NSAttributedString) -> [Blank] {
        let ns = doc.string as NSString
        let skip = find(in: doc).compactMap(\.roleLine)
        let re = try! NSRegularExpression(pattern: #"\[[^\[\]\n]+\]"#)
        return re.matches(in: doc.string, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let token = ns.substring(with: m.range)
            guard token != Self.token, token != SignatureField.date.token,
                  !skip.contains(where: { NSLocationInRange(m.range.location, $0) }) else { return nil }
            return Blank(token: token, range: m.range)
        }
    }

    static func context(of blank: Blank, in doc: NSAttributedString) -> String? {
        context(of: blank.token, range: blank.range, in: doc)
    }

    /// Validate the form's snapshot before applying any input. If the document
    /// changed while the form was open, leave it untouched rather than fill a
    /// different occurrence at a stale offset.
    static func fillFields(_ values: [String: String], fields: [Blank],
                           in doc: NSMutableAttributedString) -> [NSRange] {
        let ns = doc.string as NSString
        guard fields.allSatisfy({ NSMaxRange($0.range) <= ns.length && ns.substring(with: $0.range) == $0.token }) else { return [] }
        let hits = fields.compactMap { field -> (range: NSRange, value: String)? in
            guard let value = values[field.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, value != field.token else { return nil }
            return (field.range, value)
        }.sorted { $0.range.location < $1.range.location }
        for hit in hits.reversed() {
            let attrs = doc.attributes(at: hit.range.location, effectiveRange: nil)
            doc.replaceCharacters(in: hit.range, with: NSAttributedString(string: hit.value, attributes: attrs))
        }
        var shift = 0
        return hits.map { hit in
            let length = (hit.value as NSString).length
            defer { shift += length - hit.range.length }
            return NSRange(location: hit.range.location + shift, length: length)
        }
    }

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

    /// A few words either side of a blank's first appearance, the blank
    /// shown as "____" — "[DATE]" alone doesn't say which date.
    static func context(of blank: String, in doc: NSAttributedString) -> String? {
        let ns = doc.string as NSString
        let r = ns.range(of: blank)
        guard r.location != NSNotFound else { return nil }
        return context(of: blank, range: r, in: doc)
    }

    private static func context(of blank: String, range r: NSRange, in doc: NSAttributedString) -> String? {
        let ns = doc.string as NSString
        let para = ns.paragraphRange(for: r)
        let start = max(para.location, r.location - 40)
        let end   = min(para.location + para.length, r.location + r.length + 40)
        var before = ns.substring(with: NSRange(location: start, length: r.location - start))
        var after  = ns.substring(with: NSRange(location: r.location + r.length,
                                                length: end - r.location - r.length))
        // Cut at word boundaries, and mark what was cut.
        if start > para.location, let sp = before.firstIndex(of: " ") { before = "…" + String(before[before.index(after: sp)...]) }
        if end < para.location + para.length, let sp = after.lastIndex(of: " ") { after = String(after[..<sp]) + "…" }
        let line = (before + "____" + after)
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return line == "____" ? nil : line
    }

    /// Writes each value over every appearance of its blank, in the blank's
    /// own font. Empty values are skipped. Returns whether anything changed.
    @discardableResult
    static func fill(_ values: [String: String], in doc: NSMutableAttributedString) -> Bool {
        var changed = false
        for (blank, value) in values {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty, v != blank else { continue }
            var r = (doc.string as NSString).range(of: blank)
            while r.location != NSNotFound {
                let attrs = doc.attributes(at: r.location, effectiveRange: nil)
                doc.replaceCharacters(in: r, with: NSAttributedString(string: v, attributes: attrs))
                changed = true
                let from = r.location + (v as NSString).length
                r = (doc.string as NSString).range(of: blank, options: [],
                                                   range: NSRange(location: from, length: doc.length - from))
            }
        }
        return changed
    }

    /// Like `fill`, but returns where each value ended up — in the finished
    /// text, document order — so the workspace can highlight what changed.
    /// Every appearance is collected first and replaced from the end, so no
    /// replacement moves one still to come.
    static func fillTracking(_ values: [String: String], in doc: NSMutableAttributedString) -> [NSRange] {
        let ns = doc.string as NSString
        var hits: [(range: NSRange, value: String)] = []
        for (blank, value) in values {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty, v != blank else { continue }
            var r = ns.range(of: blank)
            while r.location != NSNotFound {
                hits.append((r, v))
                let from = r.location + r.length
                r = ns.range(of: blank, options: [], range: NSRange(location: from, length: ns.length - from))
            }
        }
        hits.sort { $0.range.location < $1.range.location }
        for h in hits.reversed() {
            let attrs = doc.attributes(at: h.range.location, effectiveRange: nil)
            doc.replaceCharacters(in: h.range, with: NSAttributedString(string: h.value, attributes: attrs))
        }
        var shift = 0, out: [NSRange] = []
        for h in hits {
            let len = (h.value as NSString).length
            out.append(NSRange(location: h.range.location + shift, length: len))
            shift += len - h.range.length
        }
        return out
    }

    /// Which party a name blank belongs to: "[FREELANCER FULL NAME]",
    /// "[CLIENT NAME]", "[客戶姓名]" → that party's box. Only blanks asking
    /// for a person's name — not "[CLIENT ADDRESS]" or "[CLIENT COMPANY NAME]".
    static func party(forNameBlank blank: String, in slots: [Slot]) -> Int? {
        let key = blank.uppercased()
        let nameWords = ["NAME", "姓名", "名字", "氏名", "名前", "이름", "NOMBRE", "NOM ", "NOM]", "NOM DU", "NOM DE"]
        let notAPerson = ["BUSINESS", "COMPANY", "ENTITY", "公司", "會社", "会社", "회사", "EMPRESA",
                          "SOCIÉTÉ", "ENTREPRISE", "FIRMA", "UNTERNEHMEN", "PROJECT", "PRODUCT"]
        guard nameWords.contains(where: key.contains), !notAPerson.contains(where: key.contains) else { return nil }
        // The longest role named in it ("SERVICE PROVIDER" over "PROVIDER").
        let hits = slots.indices.filter { key.contains(slots[$0].role.uppercased()) }
        return hits.max { slots[$0].role.count < slots[$1].role.count }
    }

    /// The box for a party named `role`, matched loosely: "FREELANCER",
    /// "Freelancer" and "freelancer:" are the same party. nil when no box
    /// has that name, or more than one does (then the name doesn't decide).
    static func index(ofRole role: String?, in slots: [Slot]) -> Int? {
        guard let key = role.map(roleKey), !key.isEmpty else { return nil }
        let hits = slots.indices.filter { roleKey(slots[$0].role) == key }
        return hits.count == 1 ? hits[0] : nil
    }

    private static func roleKey(_ s: String) -> String {
        s.lowercased()
         .trimmingCharacters(in: CharacterSet(charactersIn: ":：").union(.whitespaces))
         .split(whereSeparator: \.isWhitespace).joined(separator: " ")
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
    /// "[RENT AMOUNT]" — one per occurrence in document order. Not the field
    /// tokens, and not the name on a party's line: the signer fills that.
    static func blanks(in doc: NSAttributedString) -> [String] {
        blankFields(in: doc).map(\.token)
    }

    /// The first "[…]" on a party's line, for the signer's name.
    static func namePlaceholder(in line: NSRange, of ns: NSString) -> NSRange? {
        guard let re = try? NSRegularExpression(pattern: #"\[[^\[\]\n]+\]"#),
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
