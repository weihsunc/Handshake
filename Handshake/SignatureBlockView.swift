import SwiftUI
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SignatureBlockView
//
// The stamp that replaces the [Signature] placeholder once a contract is
// signed, in the app's doodle style: an ink ✕, the signer's name in a script
// face over a hand-drawn line, the local time and a short fingerprint of the
// SHA256 hash, and a small tilted seal ("SIGNED · FACE ID · date" around the
// owner's check doodle).
//
// Says what confirmed it (Face ID), never "legally binding" — this is
// authentication and tamper-evidence, not certification (HANDOFF §8).
// ─────────────────────────────────────────────────────────────────────────────

struct SignatureBlockView: View {

    let stamp: SignatureStamp

    /// Always ink on paper: the stamp is an image inside the document and
    /// reads the same in both appearances (rendered light, see below).
    private let ink = Color(red: 0x1F / 255, green: 0x1E / 255, blue: 0x1C / 255)

    var body: some View {
        // "Signed on the line" (owner's pick, Nov 9): pen on paper, no box —
        // an ink ✕, the name over a hand-drawn line, the date and fingerprint
        // underneath — with a small doodled seal stamped beside it.
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    InkCross()
                        .stroke(ink, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                        .frame(width: 11, height: 11)
                    Text(stamp.signerName)
                        .font(.custom("SnellRoundhand-Bold", size: 30))
                        .foregroundStyle(ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                InkLine()
                    .stroke(ink.opacity(0.85), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                    .frame(height: 6)

                // Local time with its zone, drawn on each phone that shows it.
                Text(stamp.signedAt, format: .dateTime.year().month(.abbreviated).day()
                                            .hour().minute().timeZone(.specificName(.short)))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondaryInk)
                    .padding(.top, 3)
                Text("Fingerprint \(stamp.fingerprint)")
                    .font(.system(size: 10.5))
                    .monospaced()
                    .foregroundStyle(Color.secondaryInk)
            }
            DoodleSeal(method: stamp.method ?? "Face ID", date: stamp.signedAt)
                .frame(width: 64, height: 64)
                .rotationEffect(.degrees(-10))
                .accessibilityHidden(true)
        }
        .padding(.vertical, 8)
        .padding(.trailing, 6)
    }
}

// ── The hand-drawn bits ─────────────────────────────────────────────────────

/// The "sign here" ✕, two quick pen strokes.
private struct InkCross: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.08))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.move(to: CGPoint(x: r.maxX - r.width * 0.05, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.05, y: r.maxY - r.height * 0.04))
        return p
    }
}

/// A signature line that isn't ruler-straight.
private struct InkLine: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, y = r.midY
        p.move(to: CGPoint(x: r.minX + 1, y: y + 1))
        p.addCurve(to: CGPoint(x: r.minX + w * 0.48, y: y),
                   control1: CGPoint(x: r.minX + w * 0.18, y: y - 2),
                   control2: CGPoint(x: r.minX + w * 0.32, y: y + 2))
        p.addCurve(to: CGPoint(x: r.maxX - 1, y: y - 0.5),
                   control1: CGPoint(x: r.minX + w * 0.66, y: y - 2),
                   control2: CGPoint(x: r.minX + w * 0.86, y: y + 1.5))
        return p
    }
}

/// A circle drawn freehand: a little out of round, the ends overlapping.
private struct WobblyCircle: Shape {
    var wobble: CGFloat = 0.04
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY), rad = min(r.width, r.height) / 2
        func pt(_ deg: Double, _ k: CGFloat) -> CGPoint {
            let a = deg * .pi / 180
            return CGPoint(x: c.x + cos(a) * rad * k, y: c.y + sin(a) * rad * k)
        }
        let w = wobble
        var p = Path()
        p.move(to: pt(-95, 1))
        p.addCurve(to: pt(0, 1 + w),   control1: pt(-60, 1.06 + w), control2: pt(-25, 1.05))
        p.addCurve(to: pt(92, 1 - w),  control1: pt(28, 1.06 + w),  control2: pt(62, 1.03 - w))
        p.addCurve(to: pt(182, 1 + w), control1: pt(120, 1.04),     control2: pt(152, 1.05 + w))
        p.addCurve(to: pt(275, 1.02),  control1: pt(212, 1.04 - w), control2: pt(244, 1.06))
        return p
    }
}

/// A small notary-style seal, doodled: two freehand rings, the owner's check
/// in the middle, and "SIGNED · FACE ID · NOV 9 2026" around the edge.
private struct DoodleSeal: View {
    let method: String
    let date: Date

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                WobblyCircle(wobble: 0.04)
                    .stroke(Color.accent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                WobblyCircle(wobble: 0.03)
                    .stroke(Color.accent.opacity(0.8), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                    .padding(s * 0.15)
                RingText(text: ringText, radius: s * 0.415, fontSize: s * 0.085)
                CheckDoodleShape()
                    .stroke(Color.accent, style: StrokeStyle(lineWidth: s * 0.028, lineCap: .round, lineJoin: .round))
                    .frame(width: s * 0.38, height: s * 0.38)
            }
            .frame(width: s, height: s)
        }
    }

    private var ringText: String {
        let d = date.formatted(.dateTime.month(.abbreviated).day().year())
        return "\(String(localized: "Signed")) · \(method) · \(d) · ".uppercased()
    }
}

/// Letters set around a circle, clockwise from the top.
private struct RingText: View {
    let text: String
    let radius: CGFloat
    let fontSize: CGFloat

    var body: some View {
        let chars = Array(text)
        let step = 360.0 / Double(max(chars.count, 1))
        ZStack {
            ForEach(chars.indices, id: \.self) { i in
                Text(String(chars[i]))
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(Color.accent)
                    .offset(y: -radius)
                    .rotationEffect(.degrees(Double(i) * step))
            }
        }
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
