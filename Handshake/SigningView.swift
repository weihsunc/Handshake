import SwiftUI
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SigningView
//
// The recipient's side of the flow. Reached from a handshake://sign/<uuid>
// deep link (see RootView). The contract is read-only here — a recipient
// reviews, they don't edit — with a "Sign with Face ID" pill pinned to the
// bottom over a fade so long documents scroll underneath it.
//
// Face ID auth, the signature stamp and the confirmation screen are wired up in
// SignatureService / SignatureBlockView.
// ─────────────────────────────────────────────────────────────────────────────

struct SigningView: View {

    let contract: GeneratedContract

    @State private var attributedBody: NSMutableAttributedString
    @State private var editorHeight:   CGFloat = 300
    @Environment(\.dismiss) private var dismiss

    init(contract: GeneratedContract) {
        self.contract   = contract
        _attributedBody = State(initialValue: contract.displayBody())
    }

    private var isAlreadySigned: Bool { contract.status == .signed }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {

                Color(red: 0.98, green: 0.98, blue: 0.98)
                    .ignoresSafeArea()

                document

                if !isAlreadySigned {
                    signBar
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(contract.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color(.label))
                        .lineLimit(1)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") { dismiss() }
                        .font(.system(size: 17, weight: .semibold))
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Document
    // ─────────────────────────────────────────────────────────────────────────

    private var document: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                HStack(alignment: .top) {
                    Text(contract.title)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Color(.label))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    StatusBadge(status: contract.status)
                        .padding(.top, 6)
                }

                GeometryReader { geo in
                    RichTextEditorImpl(
                        attributedText:  $attributedBody,
                        dynamicHeight:   $editorHeight,
                        isEditing:       false,
                        availableWidth:  geo.size.width,
                        onReady:         { _ in },
                        onEditingBegan:  { },
                        allowsEditing:   false
                    )
                }
                .frame(height: editorHeight)
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, isAlreadySigned ? 40 : 140)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Sign bar
    // ─────────────────────────────────────────────────────────────────────────

    private var signBar: some View {
        VStack(spacing: 0) {
            // Fade so document text doesn't collide with the pill as it scrolls
            LinearGradient(
                colors: [Color(red: 0.98, green: 0.98, blue: 0.98).opacity(0),
                         Color(red: 0.98, green: 0.98, blue: 0.98)],
                startPoint: .top,
                endPoint:   .bottom
            )
            .frame(height: 32)
            .allowsHitTesting(false)

            VStack(spacing: 10) {
                PurplePillButton(title: "Sign with Face ID", fullWidth: true) { }

                Text("Your identity is confirmed on this device.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 117/255, green: 117/255, blue: 117/255))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 34)
            .background(Color(red: 0.98, green: 0.98, blue: 0.98))
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Preview
// ─────────────────────────────────────────────────────────────────────────────

#Preview {
    SigningView(contract: GeneratedContract(
        id: UUID(),
        title: "Mutual Non-Disclosure Agreement",
        content: "**MUTUAL NDA**\n\nThis Agreement is entered into between the parties below.\n\n[Signature]",
        status: .sent
    ))
}
