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
    @State private var textView:       UITextView? = nil

    @State private var signerName:  String
    /// Every "[Signature]" in the UNSIGNED document and whose it is.
    private let slots: [SignatureSlots.Slot]
    /// The box this person signs, when their link named it — the normal case
    /// now. nil for links from before parties were assigned: they pick.
    private let assignedSlot: Int?
    /// Boxes no one has signed yet (the sender may have signed theirs).
    private let openSlots: [Int]
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

    // ── Sheets: sign details, a request for changes, the reply to the sender
    @State private var sheet: SignSheet? = nil
    @State private var askDecline = false
    @State private var declineReason = ""
    @State private var changesText = ""

    private enum SignSheet: Identifiable {
        case sign, changes, reply(subject: String, message: String)
        var id: String {
            switch self {
            case .sign: "sign"
            case .changes: "changes"
            case .reply: "reply"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss

    init(contract: GeneratedContract) {
        self.contract   = contract
        _attributedBody = State(initialValue: contract.displayBody())
        _status         = State(initialValue: contract.status)
        let found = contract.signatureSlots()
        slots = found
        let open = found.indices.filter { contract.signature(forSlot: $0) == nil }
        openSlots = open
        if let p = contract.myParty, found.isEmpty || open.contains(p) {
            assignedSlot = p
        } else {
            assignedSlot = nil
        }
        // Unassigned (older link): default to the LAST open party — the
        // sender lists themselves first far more often than not.
        _selectedSlot = State(initialValue: assignedSlot ?? open.last ?? 0)
        // The name the sender gave this recipient; editable, because the
        // person holding the phone is the one signing.
        let mine = contract.recipients.first { $0.party != nil && $0.party == contract.myParty }
        // (signedBy only once it's signed: on an incoming copy it can be
        // the sender's, from their own signature.)
        _signerName = State(initialValue: (contract.status == .signed ? contract.signedBy : nil)
                            ?? mine?.name
                            ?? contract.recipients.first?.name
                            ?? "")
    }

    private var isSigned: Bool { status == .signed }
    private var isDeclined: Bool { status == .declined }

    private var role: String? {
        slots.indices.contains(selectedSlot) && slots.count > 1 ? slots[selectedSlot].role : nil
    }

    /// Does a date field follow the selected signature slot (before the next one)?
    private var slotHasDateField: Bool {
        slots.indices.contains(selectedSlot) && slots[selectedSlot].hasDate
    }

    /// Old links don't say who's who: the signer picks among the open boxes.
    private var needsPicker: Bool { assignedSlot == nil && openSlots.count > 1 }

    private var canSign: Bool {
        !signerName.trimmingCharacters(in: .whitespaces).isEmpty && !isSigning
    }

    /// The signer's own box in the document as shown (signed boxes are
    /// stamps there, so count among the unsigned ones).
    private var myBoxRange: NSRange? {
        guard !isSigned, slots.indices.contains(selectedSlot) else { return nil }
        let k = openSlots.filter { $0 < selectedSlot }.count
        let boxes = attributedBody.signatureFields().filter { $0.kind == .signature }
        return boxes.indices.contains(k) ? boxes[k].range : nil
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
                        if !isSigned && !isDeclined { signBar }
                    }
            }
            .navigationTitle(contract.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
                if !isSigned && !isDeclined {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Button {
                                sheet = .changes
                            } label: {
                                Label("Ask for Changes", systemImage: "text.bubble")
                            }
                            Button(role: .destructive) {
                                askDecline = true
                            } label: {
                                Label("Decline to Sign", systemImage: "xmark.circle")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .accessibilityLabel("More")
                    }
                }
            }
            .alert("Couldn't sign",
                   isPresented: Binding(get: { signError != nil },
                                        set: { if !$0 { signError = nil } })) {
                Button("OK", role: .cancel) { signError = nil }
            } message: {
                Text(signError ?? "")
            }
            .alert("Decline to sign?", isPresented: $askDecline) {
                TextField("Reason (optional)", text: $declineReason)
                Button("Decline", role: .destructive) { decline() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("The sender is told you declined, with your reason if you give one.")
            }
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .sign:
                signSheet
            case .changes:
                changesSheet
            case .reply(let subject, let message):
                ReplyComposeSheet(address: contract.replyTo, subject: subject, message: message) { _ in
                    sheet = nil
                    dismiss()
                }
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

                // Who's asking, and as whom they're asked to sign.
                VStack(alignment: .leading, spacing: 6) {
                    if let from = contract.senderName {
                        Label(String(localized: "From \(from)"), systemImage: "person.crop.circle")
                    }
                    if let role, !isSigned, !isDeclined, assignedSlot != nil {
                        Label(String(localized: "You're signing as \(role)"), systemImage: "signature")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(Color.secondaryInk)

                GeometryReader { geo in
                    RichTextEditorImpl(
                        attributedText:  $attributedBody,
                        dynamicHeight:   $editorHeight,
                        isEditing:       false,
                        availableWidth:  geo.size.width,
                        onReady:         { tv in textView = tv },
                        onEditingBegan:  { },
                        allowsEditing:   false
                    )
                }
                .frame(height: editorHeight)
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 24)
            .readableColumn(Layout.readableWidth + 32)
        }
    }

    /// Scrolls to their box, like DocuSign's "Start" tab. (A highlight was
    /// tried; the box image is opaque, so only its corners showed.)
    private func jumpToMyBox() {
        guard let tv = textView, let r = myBoxRange else { return }
        DocumentSearch.reveal(r, in: tv)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Sign bar
    //
    // One row: jump to your box, and the button that opens the sign sheet.
    // It used to hold the party picker, the date, the name, the button and
    // the consent line — about 40% of a phone screen, with the contract
    // squeezed into what was left.
    // ─────────────────────────────────────────────────────────────────────────

    @ScaledMetric(relativeTo: .body) private var barH: CGFloat = 52

    private var signBar: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [Color.pageBackground.opacity(0), Color.pageBackground],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 28)
                .allowsHitTesting(false)

            HStack(spacing: 10) {
                if myBoxRange != nil {
                    BarCircleButton(systemImage: "arrow.down.to.line",
                                    label: String(localized: "Go to your signature box"),
                                    size: barH, action: jumpToMyBox)
                }
                PurplePillButton(title: role.map { String(localized: "Sign as \($0)") } ?? String(localized: "Sign"),
                                 fullWidth: true) {
                    sheet = .sign
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .readableColumn(Layout.readableWidth + 32)
            .background(Color.pageBackground.ignoresSafeArea(edges: .bottom))
        }
        // iOS 26 sheets are glass: the purple pill glowed through the bottom
        // of every sheet opened over it. It steps back while one is up.
        .opacity(sheet == nil ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: sheet == nil)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Sign sheet
    // ─────────────────────────────────────────────────────────────────────────

    private var signSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(role.map { String(localized: "Sign as \($0)") } ?? String(localized: "Sign"))
                .font(.title3.weight(.bold))
                .padding(.top, 8)

            if needsPicker {
                Picker("Sign as", selection: $selectedSlot) {
                    ForEach(openSlots, id: \.self) { i in
                        Text(slots[i].role).tag(i)
                    }
                }
                .pickerStyle(.segmented)
            }

            HStack(spacing: 10) {
                Text("Name")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.secondaryInk)
                TextField("Your full name", text: $signerName)
                    .font(.body)
                    .textContentType(.name)
                    .submitLabel(.done)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cardFill))

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
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cardFill))
            }

            Spacer(minLength: 0)

            Text(Self.consentText)
                .font(.footnote)
                .foregroundStyle(Color.secondaryInk)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            PurplePillButton(title: isSigning ? String(localized: "Verifying…") : String(localized: "Sign with \(SignatureService.biometryName)"),
                             fullWidth: true) {
                Task { await sign() }
            }
            .opacity(canSign ? 1 : 0.4)
            .disabled(!canSign)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .presentationDetents([.height(needsPicker ? 380 : (slotHasDateField ? 340 : 290)), .large])
        .presentationDragIndicator(.visible)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Ask for changes / decline
    // ─────────────────────────────────────────────────────────────────────────

    private var changesSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Tell \(contract.senderName ?? String(localized: "the sender")) what you'd like changed. They can revise it and send you a new version.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondaryInk)
                TextEditor(text: $changesText)
                    .frame(minHeight: 140)
                    .padding(8)
                    .scrollContentBackground(.hidden)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cardFill))
                Spacer()
            }
            .padding(16)
            .navigationTitle("Ask for Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { sheet = nil }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Send") { requestChanges() }
                        .fontWeight(.semibold)
                        .disabled(changesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var myName: String {
        let n = signerName.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? String(localized: "The recipient") : n
    }

    private func requestChanges() {
        let text = changesText.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = ChangeRequest(by: myName, text: text, at: .now)
        ContractStore.shared.update(id: contract.id) { $0.changeRequest = request }
        var c = ContractStore.shared.contract(id: contract.id) ?? contract
        c.changeRequest = request
        let message = String(localized: """
            \(myName) asked for changes to "\(contract.title)":

            \(text)

            Open in Handshake to revise it:
            \(ContractTransfer.replyLink(for: c))
            """)
        showReply(subject: String(localized: "Changes requested: \(contract.title)"), message: message)
    }

    private func decline() {
        let reason = declineReason.trimmingCharacters(in: .whitespacesAndNewlines)
        ContractStore.shared.update(id: contract.id) { c in
            c.status = .declined
            c.declinedBy = myName
            c.declineReason = reason.isEmpty ? nil : reason
        }
        status = .declined
        let c = ContractStore.shared.contract(id: contract.id) ?? contract
        let line = reason.isEmpty
            ? String(localized: "\(myName) declined to sign \"\(contract.title)\".")
            : String(localized: "\(myName) declined to sign \"\(contract.title)\": \(reason)")
        let message = String(localized: "\(line)\n\nOpen in Handshake to record it:\n\(ContractTransfer.replyLink(for: c))")
        showReply(subject: String(localized: "Declined: \(contract.title)"), message: message)
    }

    /// One sheet at a time: the current one comes down, then the reply goes up.
    private func showReply(subject: String, message: String) {
        sheet = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            sheet = .reply(subject: subject, message: message)
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
                reason: String(localized: "Confirm your identity to sign \"\(contract.title)\".")
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
                signError = String(localized: "No signing link from the provider.")
                return
            }
            sheet = nil
            pendingStamp       = stamp
            providerSigningURL = url

        case .onDevice:
            finishLocally(stamp, name: name)
        }
    }

    /// Copy shown above the button. Under Path A this is what establishes
    /// intent + consent, so it's also sent to the provider as evidence.
    static var consentText: String { String(localized: "By signing you agree to this contract and to doing business electronically.") }

    /// Record the signature, redraw, confirm — shared by all three paths.
    private func finishLocally(_ stamp: SignatureStamp, name: String) {
        // A document with no boxes still needs each signature told apart:
        // the party index the sender gave this recipient does that.
        let slot = slots.isEmpty ? (contract.myParty ?? 0) : selectedSlot
        let sig = PartySignature(slot: slot,
                                 role: slots.indices.contains(slot) ? slots[slot].role : nil,
                                 name: name,
                                 signedAt: stamp.signedAt,
                                 hash: stamp.hash,
                                 date: slotHasDateField ? signedDate : nil,
                                 method: SignatureService.biometryName)

        ContractStore.shared.update(id: contract.id) { c in
            c.merge(signatures: [sig])
            c.status        = .signed
            c.signedAt      = stamp.signedAt
            c.signedBy      = name
            c.signatureHash = stamp.hash
            c.signedSlot    = slot
            c.signedDate    = sig.date
            c.changeRequest = nil
        }
        if let updated = ContractStore.shared.contract(id: contract.id) {
            attributedBody = updated.displayBody()
        }

        status = .signed
        Haptics.success()
        // The sign sheet comes down first; the confirmation goes up after.
        sheet = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { confirmed = stamp }
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

                        // Where it's going, when the sender said.
                        if let to = signedContract?.replyTo, !sentBack {
                            Text("To \(to)")
                                .font(.footnote)
                                .foregroundStyle(Color.secondaryInk)
                        }

                        Button(sentBack ? "Done" : "Not now") { onDone() }
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.secondaryInk)
                            .padding(.vertical, 6)
                    } else {
                        PurplePillButton(title: String(localized: "Done"), fullWidth: true) { onDone() }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .readableColumn(480)
                .opacity(showShare ? 0 : 1)        // see SigningView.signBar
                .animation(.easeOut(duration: 0.2), value: showShare)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { appeared = true }
        }
        .sheet(isPresented: $showShare) {
            if let c = signedContract {
                ReplyComposeSheet(address: c.replyTo,
                                  subject: String(localized: "Signed: \(c.title)"),
                                  message: Self.returnMessage(for: c)) { outcome in
                    showShare = false
                    switch outcome {
                    case .sent:      sentBack = true
                    case .copied:    copied = true
                    case .cancelled: break
                    }
                }
            }
        }
    }

    /// What goes back to the sender: a line of context plus a link that
    /// carries the signed document (ContractTransfer). Opening it on the
    /// sender's phone moves their copy to Signed.
    static func returnMessage(for c: GeneratedContract) -> String {
        // The sender's completed copy, going round to everyone.
        if !c.isIncoming {
            return String(localized: """
                Everyone has signed "\(c.title)".

                Open in Handshake for the completed copy:
                \(ContractTransfer.signedCopyLink(for: c))
                """)
        }
        let who = c.myParty.flatMap { c.signature(forSlot: $0)?.name }
            ?? c.signedBy ?? String(localized: "The recipient")
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
