import Foundation
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Parties and their signatures
//
// A contract has one signature box per party ("LANDLORD:", "TENANT:"). The
// sender says who signs which box when sending (SendFlowView), signs their
// own box first if they have one, and each recipient's link names the box
// that recipient signs, the way DocuSign assigns fields to a recipient.
//
// Signatures are records (PartySignature), not pixels in the document. The
// document stays unsigned (baseBody) and the stamps are drawn on top when it
// is shown (displayBody). That's what lets copies merge: the sender's
// signature, one recipient's and another's arrive separately and all three
// end up in their own boxes, where before the last copy back overwrote the
// record. Older records, whose RTFD has a stamp baked in, have no records
// and show exactly as they did.
// ─────────────────────────────────────────────────────────────────────────────

extension GeneratedContract {

    /// The document with no signatures drawn: the sender's rich edits (RTFD)
    /// when there are any, otherwise the markdown.
    func baseBody() -> NSMutableAttributedString {
        if let data = bodyRTFD,
           let attr = try? NSMutableAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.rtfd],
               documentAttributes: nil
           ) {
            attr.applyAttachmentSizes(attachmentSizes)
            attr.adaptTextColorsToAppearance()
            attr.redrawSignatureFieldBoxes()
            return attr
        }
        return .fromHandshakeMarkdown(content)
    }

    /// Saves an edited document: RTFD (formatting, images) plus the markdown
    /// that travels in links. Signatures are on the words they were given —
    /// if the words change, they're dropped.
    mutating func setBody(_ body: NSAttributedString) {
        guard body.length > 0 else { return }
        bodyRTFD = try? body.data(
            from: NSRange(location: 0, length: body.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
        attachmentSizes = body.attachmentSizes
        let markdown = body.handshakeMarkdown()
        if markdown != content { signatures = [] }
        content = markdown
    }

    /// The document as everyone sees it: each party's stamp in its box.
    func displayBody() -> NSMutableAttributedString {
        let body = baseBody()
        if !signatures.isEmpty { body.applySignatures(signatures) }
        return body
    }

    /// Signature boxes and whose they are, on the unsigned document.
    func signatureSlots() -> [SignatureSlots.Slot] { SignatureSlots.find(in: baseBody()) }

    func signature(forSlot i: Int) -> PartySignature? { signatures.first { $0.slot == i } }

    /// Adds another copy's signatures: one per box, and a box that's already
    /// signed keeps the signature it has. Returns whether anything changed.
    @discardableResult
    mutating func merge(signatures incoming: [PartySignature]) -> Bool {
        var changed = false
        for s in incoming where signature(forSlot: s.slot) == nil {
            signatures.append(s); changed = true
        }
        signatures.sort { $0.slot < $1.slot }
        return changed
    }

    /// On the sender's copy: Signed once every party has signed.
    mutating func refreshCompletion() {
        guard !isIncoming, status == .sent || status == .signed else { return }
        if !signatures.isEmpty && signaturesNeeded == 0 {
            status = .signed
            signedAt = signatures.map(\.signedAt).max()
        }
    }

    /// "1 of 2 signed", for a contract that's partway there.
    var progressLabel: String? {
        guard let n = partyCount, n > 1, status == .sent, !isIncoming else { return nil }
        return String(localized: "\(signatures.count) of \(n) signed")
    }
}

extension PartySignature {
    var stamp: SignatureStamp {
        SignatureStamp(signerName: name, signedAt: signedAt, hash: hash, method: method)
    }
}

extension NSMutableAttributedString {

    /// Draws each signature into its box, fills the date after it, and writes
    /// the signer's name over the placeholder on their party's line
    /// ("TENANT: [FULL NAME]" → "TENANT: Dana Whitfield").
    func applySignatures(_ sigs: [PartySignature]) {
        let slots = SignatureSlots.find(in: self)
        // Last box first, so filling one never moves a box still to come.
        for sig in sigs.filter({ slots.indices.contains($0.slot) }).sorted(by: { $0.slot > $1.slot }) {
            let s = slots[sig.slot]
            stampSignature(sig.stamp, width: 360, slot: s.range, signedDate: sig.date, dateLimit: s.end)
            if let line = s.roleLine,
               let ph = SignatureSlots.namePlaceholder(in: line, of: string as NSString) {
                var attrs = attributes(at: ph.location, effectiveRange: nil)
                attrs[.foregroundColor] = UIColor.label
                replaceCharacters(in: ph, with: NSAttributedString(string: sig.name, attributes: attrs))
            }
        }
        // A document with no boxes: each signature at the end, in order.
        for sig in sigs.filter({ !slots.indices.contains($0.slot) }).sorted(by: { $0.slot < $1.slot }) {
            stampSignature(sig.stamp, width: 360, slot: NSRange(location: NSNotFound, length: 0))
        }
    }
}
