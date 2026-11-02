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
    }

    static let token = "[Signature]"

    static func find(in text: String) -> [Slot] {
        let ns = text as NSString
        var slots: [Slot] = []
        var search = NSRange(location: 0, length: ns.length)
        while true {
            let r = ns.range(of: token, options: [], range: search)
            if r.location == NSNotFound { break }
            let role = roleLabel(above: r.location, in: ns) ?? "Party \(slots.count + 1)"
            slots.append(Slot(role: role, range: r))
            let next = r.location + r.length
            search = NSRange(location: next, length: ns.length - next)
        }
        return slots
    }

    /// Walks up from `location`, paragraph by paragraph, for a line shaped
    /// like "LANDLORD:" / "PARTY A:" / "SERVICE PROVIDER:". Stops at the
    /// previous slot so one party's label can't bleed into the next.
    private static func roleLabel(above location: Int, in ns: NSString) -> String? {
        var loc = ns.paragraphRange(for: NSRange(location: location, length: 0)).location
        var hops = 0
        while loc > 0 && hops < 6 {
            let prev = ns.paragraphRange(for: NSRange(location: loc - 1, length: 0))
            let line = ns.substring(with: prev).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.contains(token) { return nil }                 // crossed into the slot above
            if let role = parseRole(line) { return role }
            loc = prev.location; hops += 1
        }
        return nil
    }

    /// "LANDLORD: [FULL NAME]" → "Landlord". Requires an all-caps label of
    /// 2–40 chars before the first colon; "Signature:" / "Date:" don't match
    /// because they aren't all caps.
    private static func parseRole(_ line: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let head = line[..<colon].trimmingCharacters(in: .whitespaces)
        guard (2...40).contains(head.count),
              head.first?.isLetter == true,
              head.allSatisfy({ $0.isUppercase || $0.isNumber || " /&'-".contains($0) }),
              head.contains(where: \.isLetter)
        else { return nil }
        // Title-case for display: "SERVICE PROVIDER" → "Service Provider"
        return head.lowercased().split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
