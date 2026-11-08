import SwiftUI
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SignatureBlockView
//
// The stamp that replaces the [Signature] placeholder once a contract is
// signed: the signer's name in a script face, a "Verified with Face ID" badge,
// the ISO timestamp, and a short fingerprint of the SHA256 hash.
//
// Deliberately says "Verified with Face ID", never "legally binding" — this is
// authentication and tamper-evidence, not certification (HANDOFF §8).
// ─────────────────────────────────────────────────────────────────────────────

struct SignatureBlockView: View {

    let stamp: SignatureStamp

    private static let purple = Color(red: 76/255, green: 0, blue: 255/255)   // #4C00FF

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            // ── Signature, script face over a ruled line ──────────────────────
            VStack(alignment: .leading, spacing: 2) {
                Text(stamp.signerName)
                    .font(.custom("SnellRoundhand-Bold", size: 30))
                    .foregroundStyle(Color(.label))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                Rectangle()
                    .fill(Color(.separator))
                    .frame(height: 1)
            }

            // ── Verified badge ────────────────────────────────────────────────
            HStack(spacing: 5) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("Verified with \(stamp.method ?? "Face ID")")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Self.purple)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Self.purple.opacity(0.10), in: Capsule())

            // ── Timestamp + fingerprint ───────────────────────────────────────
            // Local time with its zone. It used to be the ISO string in UTC
            // ("2026-11-08T21:14:03Z"), which read like a log line and was
            // hours off for everyone outside UTC. The stamp is drawn on each
            // phone that shows it, so each reader sees their own zone.
            VStack(alignment: .leading, spacing: 2) {
                Text(stamp.signedAt, format: .dateTime.year().month(.abbreviated).day()
                                                .hour().minute().timeZone(.specificName(.short)))
                Text("Fingerprint \(stamp.fingerprint)")
                    .monospaced()
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.secondaryInk)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.cardFill)   // #F4F4F5
        )
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Stamping the block into the document
//
// The document is an NSAttributedString in a UITextView, so the block is
// rendered to an image and inserted as an NSTextAttachment — the same
// mechanism the photo-insert already uses. That keeps it in the document flow
// and means it survives the RTFD round-trip into history.
// ─────────────────────────────────────────────────────────────────────────────

extension NSMutableAttributedString {

    /// Replaces the first `[Signature]` placeholder with a rendered signature
    /// block, appending it at the end if there's no placeholder.
    /// - Parameter width: layout width in points, for the rendered image.
    @MainActor
    /// - Parameter slot: which "[Signature]" to replace. nil = the first one
    ///   (single-party documents, or a box the user placed themselves).
    /// - Parameter signedDate: what goes in the date field after this slot.
    ///   The signer picks it (defaults to today), as in DocuSign's date field.
    /// - Parameter dateLimit: the date field must come before here (the next
    ///   party's block), so a box with no date of its own can't fill theirs.
    func stampSignature(_ stamp: SignatureStamp, width: CGFloat, slot: NSRange? = nil,
                        signedDate: Date? = nil, dateLimit: Int? = nil) {
        let blockWidth = max(200, min(width, 420))

        let renderer = ImageRenderer(
            content: SignatureBlockView(stamp: stamp).frame(width: blockWidth)
                .environment(\.colorScheme, .light)   // a paper card in both modes; it travels with the document
        )
        // Rendered at 3× so it's sharp on Retina. RTFD's importer sizes an
        // attachment by PIXELS and drops bounds, so on its own this would come
        // back 3× too big from history — the point size is saved next to the
        // RTFD (GeneratedContract.attachmentSizes) and restored on load.
        renderer.scale = SignatureField.renderScale

        guard let image = renderer.uiImage else { return }

        let attachment = NSTextAttachment()
        attachment.image  = image
        attachment.bounds = CGRect(origin: .zero, size: image.size)

        let block = NSMutableAttributedString(attachment: attachment)
        block.insert(NSAttributedString(string: "\n"), at: 0)
        block.append(NSAttributedString(string: "\n"))

        // The slot is a signature-field attachment (normal) or a bare
        // "[Signature]" token (older records). Either way, replace it.
        let fields = signatureFields()
        let first  = fields.first { $0.kind == .signature }?.range
                  ?? (string as NSString).range(of: "[Signature]")
        let placeholder = slot ?? first
        let isField = fields.contains { $0.kind == .signature && $0.range == placeholder }
        let isToken = placeholder.location != NSNotFound && placeholder.length == 11
                   && (string as NSString).substring(with: placeholder) == "[Signature]"
        if isField || isToken {
            replaceCharacters(in: placeholder, with: block)
            // Fill the first DATE FIELD after the signature with the signer's date.
            let afterStart = placeholder.location + block.length
            let delta = block.length - placeholder.length
            let limit = dateLimit.map { $0 == Int.max ? Int.max : $0 + delta } ?? Int.max
            let f = DateFormatter(); f.dateStyle = .long; f.timeStyle = .none
            let dateText = f.string(from: signedDate ?? stamp.signedAt)
            if let d = signatureFields().first(where: { $0.kind == .date && $0.range.location >= afterStart
                                                         && $0.range.location < limit }) {
                var attrs = attributes(at: d.range.location, effectiveRange: nil)
                attrs[.attachment] = nil; attrs[.foregroundColor] = UIColor.label
                attrs[.font] = attrs[.font] ?? UIFont.systemFont(ofSize: 17)
                replaceCharacters(in: d.range, with: NSAttributedString(string: dateText, attributes: attrs))
            } else {
                let after = NSRange(location: afterStart, length: length - afterStart)
                let tok = (string as NSString).range(of: "[Date]", options: [], range: after)
                if tok.location != NSNotFound && tok.location < limit {
                    var attrs = attributes(at: tok.location, effectiveRange: nil); attrs[.foregroundColor] = UIColor.label
                    replaceCharacters(in: tok, with: NSAttributedString(string: dateText, attributes: attrs))
                }
            }
        } else {
            append(block)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Preview
// ─────────────────────────────────────────────────────────────────────────────

#Preview {
    SignatureBlockView(stamp: SignatureStamp(
        signerName: "Dana Whitfield",
        signedAt:   .now,
        hash:       "3f9a1c04d7e5b28a6104ff93ac7712de55b0913c4f8e6a2d0b7c1e93a45f6802"
    ))
    .padding()
}
