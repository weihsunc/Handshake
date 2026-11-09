import SwiftUI
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SignatureBlockView
//
// The stamp that replaces the [Signature] placeholder once a contract is
// signed, in the app's doodle style: an ink ✕, the signer's name in Mrs
// Saint Delafield over a hand-drawn line, the local time and a short fingerprint of the
// SHA256 hash, and a small tilted rubber-stamp seal ("SIGNED · FACE ID ·
// date" around a doodled Face ID face).
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
        // "Signed on the line" (owner's pick, Nov 9) — an ink ✕, the name over
        // a hand-drawn line, the date and fingerprint underneath, a small seal
        // beside it — inside a quiet card with a header, so it reads as
        // something the app added, not words in the contract.
        VStack(alignment: .leading, spacing: 10) {
            Text("Signed electronically with Handshake")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.secondaryInk)

        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    InkCross()
                        .stroke(ink, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                        .frame(width: 11, height: 11)
                    // Mrs Saint Delafield (bundled, SIL OFL — Handshake/Fonts).
                    // Fine strokes, so it's set larger than a system face.
                    Text(stamp.signerName)
                        .font(.custom("MrsSaintDelafield-Regular", size: 40))
                        .foregroundStyle(ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                // The face keeps a deep descender; without this the line
                // floats well below the name instead of sitting under it.
                .padding(.bottom, -14)
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
                .frame(width: 70, height: 70)
                .rotationEffect(.degrees(-10))
                .accessibilityHidden(true)
        }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        // The card fills the width it's drawn at, so its edges line up with
        // the text column (it used to hug its content and sit centred).
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF4 / 255))      // stone/100
        )
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

/// A small rubber-stamp seal: a heavy outer ring and a fine inner one, true
/// circles like a real seal, "SIGNED · FACE ID · NOV 9 2026" around the edge,
/// a doodled Face ID face in the middle, and speckled ink so it reads as
/// pressed rather than drawn.
struct DoodleSeal: View {
    let method: String
    let date: Date

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                Circle()
                    .strokeBorder(Color.accent, lineWidth: s * 0.05)
                Circle()
                    .strokeBorder(Color.accent, lineWidth: s * 0.016)
                    .padding(s * 0.175)
                RingText(text: ringText, radius: s * 0.385, fontSize: s * 0.082)
                FaceIDDoodle()
                    .stroke(Color.accent, style: StrokeStyle(lineWidth: s * 0.03, lineCap: .round, lineJoin: .round))
                    .frame(width: s * 0.32, height: s * 0.32)
            }
            .frame(width: s, height: s)
            .mask(StampTexture(seed: 7))
        }
    }

    private var ringText: String {
        let d = date.formatted(.dateTime.month(.abbreviated).day().year())
        return "\(String(localized: "Signed")) · \(method) · \(d) · ".uppercased()
    }
}

/// The Face ID glyph, drawn by hand: four rounded corner brackets, two eyes,
/// a nose, a smile — the strokes a little off-true, like the other doodles.
private struct FaceIDDoodle: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * w, y: r.minY + y * h) }
        var path = Path()
        // Corners: down the side, round the corner, along the edge.
        path.move(to: p(0.02, 0.30)); path.addLine(to: p(0.01, 0.12))
        path.addQuadCurve(to: p(0.13, 0.01), control: p(0.0, 0.0)); path.addLine(to: p(0.31, 0.02))
        path.move(to: p(0.69, 0.01)); path.addLine(to: p(0.87, 0.02))
        path.addQuadCurve(to: p(0.99, 0.13), control: p(1.0, 0.0)); path.addLine(to: p(0.98, 0.31))
        path.move(to: p(0.99, 0.70)); path.addLine(to: p(0.98, 0.87))
        path.addQuadCurve(to: p(0.86, 0.99), control: p(1.0, 1.0)); path.addLine(to: p(0.69, 0.98))
        path.move(to: p(0.30, 0.99)); path.addLine(to: p(0.13, 0.98))
        path.addQuadCurve(to: p(0.01, 0.86), control: p(0.0, 1.0)); path.addLine(to: p(0.02, 0.69))
        // Eyes.
        path.move(to: p(0.33, 0.33)); path.addLine(to: p(0.335, 0.43))
        path.move(to: p(0.67, 0.33)); path.addLine(to: p(0.665, 0.43))
        // Nose.
        path.move(to: p(0.51, 0.34)); path.addLine(to: p(0.50, 0.57))
        path.addQuadCurve(to: p(0.43, 0.59), control: p(0.49, 0.60))
        // Smile.
        path.move(to: p(0.32, 0.70))
        path.addQuadCurve(to: p(0.68, 0.69), control: p(0.50, 0.84))
        return path
    }
}

/// Uneven ink for the seal: the mask is solid with small specks knocked out,
/// the way a rubber stamp never inks perfectly. Seeded, so it's the same
/// pattern every time the stamp is drawn.
private struct StampTexture: View {
    let seed: UInt64

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            ctx.blendMode = .destinationOut
            var rng = SeededRandom(seed: seed)
            let area = size.width * size.height
            for _ in 0..<Int(area / 18) {
                let x = rng.next() * size.width, y = rng.next() * size.height
                let r = 0.2 + rng.next() * 0.6
                let a = 0.2 + rng.next() * 0.4
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                         with: .color(.white.opacity(a)))
            }
            // A couple of worn arcs where the ink didn't take.
            for _ in 0..<2 {
                let cx = size.width / 2, cy = size.height / 2
                let rad = min(size.width, size.height) * (0.42 + rng.next() * 0.08)
                let start = Angle.degrees(rng.next() * 360)
                var arc = Path()
                arc.addArc(center: CGPoint(x: cx, y: cy), radius: rad, startAngle: start,
                           endAngle: start + .degrees(14 + rng.next() * 20), clockwise: false)
                ctx.stroke(arc, with: .color(.white.opacity(0.35)), lineWidth: 1)
            }
        }
    }
}

/// A tiny deterministic generator (values in 0..<1).
private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((state >> 33) & 0xFFFFFF) / CGFloat(0x1000000)
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
