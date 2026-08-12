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
                Text("Verified with Face ID")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Self.purple)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Self.purple.opacity(0.10), in: Capsule())

            // ── Timestamp + fingerprint ───────────────────────────────────────
            VStack(alignment: .leading, spacing: 2) {
                Text(stamp.isoTimestamp)
                Text("Fingerprint \(stamp.fingerprint)")
                    .monospaced()
            }
            .font(.system(size: 11))
            .foregroundStyle(Color(red: 117/255, green: 117/255, blue: 117/255))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(red: 244/255, green: 244/255, blue: 245/255))   // #F4F4F5
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
    func stampSignature(_ stamp: SignatureStamp, width: CGFloat) {
        let blockWidth = max(200, min(width, 420))

        let renderer = ImageRenderer(
            content: SignatureBlockView(stamp: stamp).frame(width: blockWidth)
        )
        // Must render 1:1 — one pixel per point.
        //
        // The signed document is persisted as RTFD and re-read in the history
        // viewer, and RTFD's importer sizes an attachment by the image's PIXEL
        // dimensions. Rendering at UIScreen.main.scale therefore draws the block
        // 3× oversized once it round-trips, spilling far outside the text
        // column. Neither attachment.bounds nor a corrected UIImage scale
        // survives the round-trip to fix it — both are discarded on import.
        //
        // Cost of 1:1: the block is slightly soft on a Retina screen. That's the
        // trade for it being the right size everywhere it's displayed.
        renderer.scale = 1

        guard let image = renderer.uiImage else { return }

        let attachment = NSTextAttachment()
        attachment.image  = image
        attachment.bounds = CGRect(origin: .zero, size: image.size)

        let block = NSMutableAttributedString(attachment: attachment)
        block.insert(NSAttributedString(string: "\n"), at: 0)
        block.append(NSAttributedString(string: "\n"))

        let placeholder = (string as NSString).range(of: "[Signature]")
        if placeholder.location != NSNotFound {
            replaceCharacters(in: placeholder, with: block)
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
