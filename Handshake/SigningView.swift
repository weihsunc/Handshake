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
// On success the [Signature] placeholder is replaced with a stamped
// SignatureBlockView, the contract is marked signed, and a confirmation screen
// takes over. See HANDOFF §8 on what this signature is and isn't.
// ─────────────────────────────────────────────────────────────────────────────

struct SigningView: View {

    let contract: GeneratedContract

    @State private var attributedBody: NSMutableAttributedString
    @State private var editorHeight:   CGFloat = 300
    @State private var bodyWidth:      CGFloat = 320

    @State private var signerName:  String
    @State private var isSigning:   Bool = false
    @State private var signError:   String? = nil
    @State private var confirmed:   SignatureStamp? = nil
    /// Path B: SignWell's embedded page, shown after Face ID.
    @State private var providerSigningURL: URL? = nil
    @State private var pendingStamp: SignatureStamp? = nil
    /// Local mirror of status so the view updates after signing without
    /// re-reading the store.
    @State private var status: ContractStatus

    @Environment(\.dismiss) private var dismiss

    init(contract: GeneratedContract) {
        self.contract   = contract
        _attributedBody = State(initialValue: contract.displayBody())
        _status         = State(initialValue: contract.status)
        // Pre-fill with the first recipient; editable because the person
        // holding the device is the one signing and may not be listed.
        _signerName     = State(initialValue: contract.signedBy
                                ?? contract.recipients.first?.name
                                ?? "")
    }

    private var isSigned: Bool { status == .signed }

    private var canSign: Bool {
        !signerName.trimmingCharacters(in: .whitespaces).isEmpty && !isSigning
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {

                Color(red: 0.98, green: 0.98, blue: 0.98)
                    .ignoresSafeArea()

                document

                if !isSigned {
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
            .alert("Couldn't sign",
                   isPresented: Binding(get: { signError != nil },
                                        set: { if !$0 { signError = nil } })) {
                Button("OK", role: .cancel) { signError = nil }
            } message: {
                Text(signError ?? "")
            }
        }
        .fullScreenCover(item: $confirmed) { stamp in
            SigningConfirmationView(contractTitle: contract.title, stamp: stamp) {
                confirmed = nil
                dismiss()
            }
        }
        .fullScreenCover(item: $providerSigningURL) { url in
            ProviderSigningWebView(url: url) {
                // Provider captured the signature. Record locally, then confirm.
                providerSigningURL = nil
                if let stamp = pendingStamp { finishLocally(stamp, name: signerName) }
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
                    StatusBadge(status: status)
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
                    .onAppear { bodyWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in bodyWidth = w }
                }
                .frame(height: editorHeight)
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, isSigned ? 40 : 190)
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

            VStack(spacing: 12) {

                // Signing as ─────────────────────────────────────────────────
                HStack(spacing: 10) {
                    Text("Signing as")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 117/255, green: 117/255, blue: 117/255))
                    TextField("Your full name", text: $signerName)
                        .font(.system(size: 15))
                        .textContentType(.name)
                        .submitLabel(.done)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(red: 244/255, green: 244/255, blue: 245/255))
                )

                PurplePillButton(title: isSigning ? "Verifying…" : "Sign with Face ID",
                                 fullWidth: true) {
                    Task { await sign() }
                }
                .opacity(canSign ? 1 : 0.4)
                .allowsHitTesting(canSign)

                Text(Self.consentText)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 117/255, green: 117/255, blue: 117/255))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 34)
            .background(Color(red: 0.98, green: 0.98, blue: 0.98))
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Signing
    // ─────────────────────────────────────────────────────────────────────────

    private func sign() async {
        let name = signerName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        isSigning = true
        defer { isSigning = false }

        do {
            try await SignatureService.authenticate(
                reason: "Confirm your identity to sign \"\(contract.title)\"."
            )
        } catch SignatureError.cancelled {
            return                                   // user backed out — no error UI
        } catch {
            signError = error.localizedDescription
            return
        }

        // Authenticated — stamp the document.
        let stamp = SignatureService.stamp(signerName: name, contractID: contract.id)

        switch contract.providerRef?.backend ?? .onDevice {

        case .docuseal:
            // Path A: Face ID was the signature. Tell the provider, with our evidence.
            guard let ref = contract.providerRef else { finishLocally(stamp, name: name); return }
            do {
                try await SigningProviders.completeDocuSeal(
                    ref: ref, signerName: name, stamp: stamp, consentText: Self.consentText
                )
            } catch {
                signError = error.localizedDescription
                return
            }
            finishLocally(stamp, name: name)

        case .signwell:
            // Path B: Face ID was the unlock. The provider's page does the signing.
            guard let s = contract.providerRef?.signingURLs.first, let url = URL(string: s) else {
                signError = "No signing link from the provider."
                return
            }
            pendingStamp       = stamp
            providerSigningURL = url

        case .onDevice:
            finishLocally(stamp, name: name)
        }
    }

    /// Copy shown above the button. Under Path A this is what establishes
    /// intent + consent, so it's also sent to the provider as evidence.
    static let consentText = "By signing you agree to this contract and to doing business electronically."

    /// Stamp the document, persist, confirm — shared by all three paths.
    private func finishLocally(_ stamp: SignatureStamp, name: String) {
        let stamped = NSMutableAttributedString(attributedString: attributedBody)
        stamped.stampSignature(stamp, width: bodyWidth)
        attributedBody = stamped                     // new instance so the view syncs

        let rtfd = try? stamped.data(
            from: NSRange(location: 0, length: stamped.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )

        ContractStore.shared.markSigned(
            id:            contract.id,
            signedBy:      name,
            signatureHash: stamp.hash,
            bodyRTFD:      rtfd
        )

        status    = .signed
        confirmed = stamp
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SigningConfirmationView
// ─────────────────────────────────────────────────────────────────────────────

struct SigningConfirmationView: View {

    let contractTitle: String
    let stamp: SignatureStamp
    var onDone: () -> Void

    @State private var appeared = false

    private static let purple = Color(red: 76/255, green: 0, blue: 255/255)

    var body: some View {
        ZStack {
            Color(red: 0.98, green: 0.98, blue: 0.98).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 84, weight: .regular))
                    .foregroundStyle(Self.purple)
                    .scaleEffect(appeared ? 1 : 0.6)
                    .opacity(appeared ? 1 : 0)
                    .padding(.bottom, 28)

                Text("Signed")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Color(.label))
                    .padding(.bottom, 10)

                Text(contractTitle)
                    .font(.system(size: 17))
                    .foregroundStyle(Color(red: 117/255, green: 117/255, blue: 117/255))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 28)

                VStack(spacing: 6) {
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

                    Text(stamp.isoTimestamp)
                    Text("Fingerprint \(stamp.fingerprint)")
                        .monospaced()
                }
                .font(.system(size: 11))
                .foregroundStyle(Color(red: 117/255, green: 117/255, blue: 117/255))

                Spacer()

                PurplePillButton(title: "Done", fullWidth: true) { onDone() }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 34)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { appeared = true }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Identifiable conformance for the confirmation cover
// ─────────────────────────────────────────────────────────────────────────────

extension SignatureStamp: Identifiable {
    var id: String { hash }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Preview
// ─────────────────────────────────────────────────────────────────────────────

#Preview {
    SigningView(contract: GeneratedContract(
        id: UUID(),
        title: "Mutual Non-Disclosure Agreement",
        content: "**MUTUAL NDA**\n\nThis Agreement is entered into between the parties below.\n\n[Signature]",
        recipients: [Recipient(name: "Dana Whitfield")],
        status: .sent
    ))
}
