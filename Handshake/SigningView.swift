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
    /// Every "[Signature]" in the document and whose it is. When there's more
    /// than one, the signer picks their party; the stamp goes in that slot.
    private let slots: [SignatureSlots.Slot]
    @State private var selectedSlot: Int
    /// The date the signer puts in the date field — theirs to pick, defaulting
    /// to today. Shown only when the chosen slot has a date field after it.
    @State private var signedDate: Date = .now
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
        let found = SignatureSlots.find(in: contract.displayBody())
        slots = found
        // Default to the LAST party: the sender lists themselves first and the
        // person they sent it to second, far more often than not.
        _selectedSlot = State(initialValue: max(0, found.count - 1))
    }

    private var isSigned: Bool { status == .signed }

    /// Does a date field follow the selected signature slot (before the next one)?
    private var slotHasDateField: Bool {
        guard slots.indices.contains(selectedSlot) else { return false }
        let start = slots[selectedSlot].range.location
        let end   = slots.indices.contains(selectedSlot + 1) ? slots[selectedSlot + 1].range.location : Int.max
        let doc   = attributedBody
        if doc.signatureFields().contains(where: { $0.kind == .date && $0.range.location > start && $0.range.location < end }) { return true }
        let r = (doc.string as NSString).range(of: "[Date]", options: [], range: NSRange(location: start, length: doc.length - start))
        return r.location != NSNotFound && r.location < end
    }

    private var canSign: Bool {
        !signerName.trimmingCharacters(in: .whitespaces).isEmpty && !isSigning
    }

    var body: some View {
        NavigationStack {
            ZStack {

                Color.pageBackground
                    .ignoresSafeArea()

                // The sign bar is a safe-area inset, not an overlay: the
                // document gets the right bottom inset on every device and
                // the bar sits above the home indicator without a magic 34.
                document
                    .safeAreaInset(edge: .bottom) {
                        if !isSigned { signBar }
                    }
            }
            .navigationTitle(contract.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") { dismiss() }
                        .font(.body.weight(.semibold))
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
            SigningConfirmationView(
                contractTitle:  contract.title,
                stamp:          stamp,
                signedContract: ContractStore.shared.contract(id: contract.id)
            ) {
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
                        .font(.title.weight(.bold))
                        .foregroundStyle(Color(.label))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    StatusBadge(status: status, incoming: contract.isIncoming)
                        .padding(.top, 6)
                }

                // Who's asking. A recipient had no way to tell from the
                // screen who sent this; the link now carries the sender's
                // name when they were signed in.
                if let from = contract.senderName {
                    Label(String(localized: "From \(from)"), systemImage: "person.crop.circle")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondaryInk)
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
            .padding(.bottom, 24)
            .readableColumn(Layout.readableWidth + 32)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Sign bar
    // ─────────────────────────────────────────────────────────────────────────

    private var signBar: some View {
        VStack(spacing: 0) {
            // Fade so document text doesn't collide with the pill as it scrolls
            LinearGradient(
                colors: [Color.pageBackground.opacity(0),
                         Color.pageBackground],
                startPoint: .top,
                endPoint:   .bottom
            )
            .frame(height: 32)
            .allowsHitTesting(false)

            VStack(spacing: 12) {

                // Sign as (which party) — only when the document has more than
                // one signature slot ───────────────────────────────────────────
                if slots.count > 1 {
                    Picker("Sign as", selection: $selectedSlot) {
                        ForEach(Array(slots.enumerated()), id: \.offset) { i, slot in
                            Text(slot.role).tag(i)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // Date field for this slot ───────────────────────────────────
                if slotHasDateField {
                    HStack {
                        Text("Date")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.secondaryInk)
                        Spacer()
                        DatePicker("", selection: $signedDate, displayedComponents: .date)
                            .labelsHidden()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.cardFill)
                    )
                }

                // Signing as ─────────────────────────────────────────────────
                HStack(spacing: 10) {
                    Text("Signing as")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.secondaryInk)
                    TextField("Your full name", text: $signerName)
                        .font(.subheadline)
                        .textContentType(.name)
                        .submitLabel(.done)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.cardFill)
                )

                // A greyed button with no reason is a dead end; say why.
                if signerName.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Enter your name to sign.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                PurplePillButton(title: isSigning ? "Verifying…" : "Sign with \(SignatureService.biometryName)",
                                 fullWidth: true) {
                    Task { await sign() }
                }
                .opacity(canSign ? 1 : 0.4)
                .disabled(!canSign)

                Text(Self.consentText)
                    .font(.footnote)
                    .foregroundStyle(Color.secondaryInk)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .readableColumn(Layout.readableWidth + 32)
            .background(Color.pageBackground.ignoresSafeArea(edges: .bottom))
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
        // Read before stamping: stamping fills the date box, after which
        // slotHasDateField is false and the date never reached the sender.
        let dateUsed: Date? = slotHasDateField ? signedDate : nil
        let stamped = NSMutableAttributedString(attributedString: attributedBody)
        let slot = slots.indices.contains(selectedSlot) ? slots[selectedSlot].range : nil
        stamped.stampSignature(stamp, width: bodyWidth, slot: slot, signedDate: signedDate)
        attributedBody = stamped                     // new instance so the view syncs

        let rtfd = try? stamped.data(
            from: NSRange(location: 0, length: stamped.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )

        ContractStore.shared.markSigned(
            id:            contract.id,
            signedBy:      name,
            signatureHash: stamp.hash,
            bodyRTFD:      rtfd,
            attachmentSizes: stamped.attachmentSizes,
            // The stamp's own time, so the copy sent back re-stamps the
            // sender's document with exactly what the signer saw.
            signedAt:      stamp.signedAt,
            signedSlot:    slots.isEmpty ? nil : selectedSlot,
            signedDate:    dateUsed
        )

        status    = .signed
        Haptics.success()
        confirmed = stamp
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SigningConfirmationView
// ─────────────────────────────────────────────────────────────────────────────

struct SigningConfirmationView: View {

    let contractTitle: String
    let stamp: SignatureStamp
    /// The signed contract, for sending a copy back to whoever sent it.
    var signedContract: GeneratedContract? = nil
    var onDone: () -> Void

    @State private var appeared  = false
    @State private var showShare = false
    @State private var sentBack  = false
    /// "Copy" in the share sheet: the link is on the clipboard, not sent.
    @State private var copied    = false


    var body: some View {
        ZStack {
            Color.pageBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 84, weight: .regular))
                    .foregroundStyle(Color.brand)
                    .scaleEffect(appeared ? 1 : 0.6)
                    .opacity(appeared ? 1 : 0)
                    .padding(.bottom, 28)

                Text("Signed")
                    .font(.title.weight(.bold))
                    .foregroundStyle(Color(.label))
                    .padding(.bottom, 10)

                Text(contractTitle)
                    .font(.body)
                    .foregroundStyle(Color.secondaryInk)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 28)

                VStack(spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption.weight(.semibold))
                        Text("Verified with \(SignatureService.biometryName)")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(Color.brand)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.brand.opacity(0.10), in: Capsule())

                    Text(stamp.signedAt, format: .dateTime.year().month().day().hour().minute())
                    Text("Fingerprint \(stamp.fingerprint)")
                        .monospaced()
                }
                .font(.caption2)
                .foregroundStyle(Color.secondaryInk)
                .accessibilityElement(children: .combine)

                Spacer()

                VStack(spacing: 10) {
                    if signedContract != nil {
                        // The other party has no way to know this was signed
                        // until the copy reaches them — this is that step.
                        PurplePillButton(title: sentBack ? String(localized: "Signed copy sent ✓")
                                                 : copied ? String(localized: "Link copied. Paste it to the sender")
                                                 : String(localized: "Send signed copy back"),
                                         fullWidth: true) { showShare = true }
                            .opacity(sentBack ? 0.6 : 1)

                        Button(sentBack ? "Done" : "Not now") { onDone() }
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.secondaryInk)
                            .padding(.vertical, 6)
                    } else {
                        PurplePillButton(title: "Done", fullWidth: true) { onDone() }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .readableColumn(480)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { appeared = true }
        }
        .sheet(isPresented: $showShare) {
            if let c = signedContract {
                ActivityView(activityItems: [Self.returnMessage(for: c)],
                             onFinishActivity: { completed, type in
                    showShare = false
                    guard completed else { return }
                    if type == .copyToPasteboard { copied = true } else { sentBack = true }
                })
                .presentationDetents([.medium, .large])
            }
        }
    }

    /// What goes back to the sender: a line of context plus a link that
    /// carries the signed document (ContractTransfer). Opening it on the
    /// sender's phone moves their copy to Signed.
    static func returnMessage(for c: GeneratedContract) -> String {
        let who = c.signedBy ?? String(localized: "The recipient")
        return String(localized: """
            \(who) signed "\(c.title)" with \(SignatureService.biometryName).

            Open in Handshake to record the signature:
            \(ContractTransfer.signedCopyLink(for: c))
            """)
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
