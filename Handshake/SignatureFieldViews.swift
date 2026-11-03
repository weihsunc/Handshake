import SwiftUI
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Field boxes
//
// What a placed-but-unfilled field looks like in the document: a dashed,
// purple-tinted box with an icon and a label, the e-sign convention for
// "someone still has to fill this in". Rendered at scale 1 for the same RTFD
// reason as the signed stamp (see SignatureBlockView).
// ─────────────────────────────────────────────────────────────────────────────

private let fieldPurple = Color(red: 76/255, green: 0, blue: 255/255)

struct SignatureFieldBox: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "signature")
                .font(.system(size: 20, weight: .medium))
            VStack(alignment: .leading, spacing: 1) {
                Text("Signature").font(.system(size: 15, weight: .semibold))
                Text("Sign with Face ID").font(.system(size: 12))
            }
            Spacer()
        }
        .foregroundStyle(fieldPurple)
        .padding(.horizontal, 14)
        .frame(width: 300, height: 64)
        .background(fieldPurple.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(fieldPurple.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
    }
}

struct DateFieldBox: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.system(size: 16, weight: .medium))
            Text("Date").font(.system(size: 15, weight: .semibold))
            Spacer()
        }
        .foregroundStyle(fieldPurple)
        .padding(.horizontal, 12)
        .frame(width: 170, height: 44)
        .background(fieldPurple.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(fieldPurple.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
    }
}

extension SignatureField {

    /// A ready-to-insert attachment for this field.
    @MainActor
    static func makeAttachment(_ kind: SignatureField) -> NSTextAttachment {
        let renderer: ImageRenderer<AnyView>
        switch kind {
        case .signature: renderer = ImageRenderer(content: AnyView(SignatureFieldBox()))
        case .date:      renderer = ImageRenderer(content: AnyView(DateFieldBox()))
        }
        renderer.scale = 1
        let image = renderer.uiImage ?? UIImage()
        let png   = image.pngData() ?? Data()
        return attachment(kind, png: png, size: image.size)
    }
}
