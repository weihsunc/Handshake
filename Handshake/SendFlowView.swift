import SwiftUI
import MessageUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SendFlowView
//
// Who signs what, then send. Modelled on DocuSign / Dropbox Sign:
//
//   • Each recipient is assigned a party ("Signs as Tenant"), picked from the
//     contract's own signature boxes. Their link names that box, so their
//     phone never asks which party they are.
//   • The sender picks their own party too ("You · Signs as Freelancer", or
//     not signing). Pre-selected from what they chose last time, else the
//     AI's read of the request, else the one box left over. They sign it
//     with Face ID before anything goes out ("Sign & Send"), so the
//     recipient sees the sender's signature already in place.
//   • Parties are remembered by NAME as well as box number, so a revision
//     that reorders the signature block doesn't swap people's roles.
//   • Each recipient gets their own message and link (one compose sheet
//     each), because the link differs by the box it unlocks.
//   • Placeholders still in the text ("[ADDRESS]") are flagged before sending.
//   • "Signed copies come back to" is carried in the link, so the
//     recipient's reply opens already addressed to the sender.
// ─────────────────────────────────────────────────────────────────────────────

struct SendFlowView: View {

    let contract: GeneratedContract
    /// Called when the page goes away, after any typed blanks are saved.
    var onClose: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    /// Signature boxes on the unsigned document, and whose they are.
    private let slots: [SignatureSlots.Slot]
    /// "[ADDRESS]"-style placeholders still in the document.
    @State private var blanks: [String]
    /// Where each blank sits ("…entered into as of ____ (the Effective…").
    private let blankContext: [String: String]
    /// What the sender typed for each blank. Written into the document when
    /// it's sent (or on leaving the page, so nothing typed is lost).
    @State private var blankValues: [String: String] = [:]
    @State private var showFillBlanks = false

    @State private var recipients: [Recipient]
    /// The box the sender signs. nil: they aren't signing.
    @State private var myParty: Int?
    @State private var myName: String
    @State private var replyTo: String

    @State private var queue: [Delivery] = []
    @State private var activeSheet: Delivery? = nil
    @State private var didSend = false
    @State private var sharedSomething = false
    @State private var askedAboutShare = false
    @State private var askedAboutBlanks = false
    /// Problems stay hidden until the sender taps Send; from then on they
    /// update live and disappear as each is fixed.
    @State private var triedToSend = false
    @State private var providerError: String? = nil
    @State private var signError: String? = nil
    @State private var isSigning = false
    /// The sender's own signature, made when they tap Sign & Send. Saved to
    /// the contract only once something was actually sent.
    @State private var ownSignature: PartySignature? = nil

    private static let replyToKey = "send.replyTo"
    private static let myNameKey  = "send.myName"

    init(contract: GeneratedContract, onClose: @escaping () -> Void = {}) {
        self.contract = contract
        self.onClose  = onClose
        let stored = ContractStore.shared.contract(id: contract.id) ?? contract
        let base   = stored.baseBody()
        let found  = SignatureSlots.find(in: base)
        slots  = found
        let foundBlanks = SignatureSlots.blanks(in: base)
        _blanks = State(initialValue: foundBlanks)
        blankContext = Dictionary(uniqueKeysWithValues: foundBlanks.compactMap { b in
            SignatureSlots.context(of: b, in: base).map { (b, $0) }
        })
        // The sender's party: what they chose last time ("" = not signing),
        // or the AI's guess from the request. A name no box has any more
        // counts as unknown.
        var mine: Int? = Self.index(ofRole: stored.senderRole, in: found)
        let senderDecided = stored.senderRole == "" || mine != nil
        // Sending again (after changes were asked for, say): start from the
        // people it went to last time, in the same parties — by name first,
        // so a reordered signature block keeps everyone in their role.
        let start = (stored.recipients.isEmpty ? [Recipient()] : stored.recipients).map { r in
            var r = r
            if let i = Self.index(ofRole: r.partyRole, in: found) { r.party = i }
            return r
        }
        let rs = Self.assignDefaults(start, slotCount: found.count, reserved: mine)
        // Not decided: the sender takes the one box left over, as before.
        if !senderDecided {
            let left = found.indices.filter { p in !rs.contains { $0.party == p } }
            mine = left.count == 1 ? left[0] : nil
        }
        _recipients = State(initialValue: rs)
        _myParty    = State(initialValue: found.isEmpty ? nil : mine)
        _myName  = State(initialValue: AccountStore.shared.name
                                ?? UserDefaults.standard.string(forKey: Self.myNameKey) ?? "")
        // An Apple private-relay address only accepts mail from domains the
        // developer registers, so a recipient's reply would bounce. Skip it.
        let account = AccountStore.shared.email.flatMap { $0.contains("privaterelay.appleid.com") ? nil : $0 }
        _replyTo = State(initialValue: UserDefaults.standard.string(forKey: Self.replyToKey) ?? account ?? "")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Parties
    // ─────────────────────────────────────────────────────────────────────────

    /// The order recipients take parties in. With the sender's party known,
    /// the others in document order. Without it, the second party first and
    /// the first party last: the sender is more often the first party
    /// (LANDLORD, then TENANT), so one recipient gets the second.
    private static func preferenceOrder(_ n: Int, reserved: Int? = nil) -> [Int] {
        if let reserved { return (0..<n).filter { $0 != reserved } }
        return n <= 1 ? Array(0..<n) : Array(1..<n) + [0]
    }

    private static func index(ofRole role: String?, in slots: [SignatureSlots.Slot]) -> Int? {
        SignatureSlots.index(ofRole: role, in: slots)
    }

    /// Gives every recipient without a valid, unique party the next free one.
    private static func assignDefaults(_ rs: [Recipient], slotCount n: Int, reserved: Int? = nil) -> [Recipient] {
        guard n > 0 else { return rs.map { var r = $0; r.party = nil; return r } }
        var used = Set<Int>(reserved.map { [$0] } ?? []), out = rs
        for i in out.indices {
            if let p = out[i].party, p < n, used.insert(p).inserted { continue }
            out[i].party = nil
        }
        for i in out.indices where out[i].party == nil {
            out[i].party = preferenceOrder(n, reserved: reserved).first { !used.contains($0) }
            if let p = out[i].party { used.insert(p) }
        }
        return out
    }

    /// Boxes nobody — no recipient, not the sender — is signing.
    private var unassigned: [Int] {
        slots.indices.filter { p in p != myParty && !recipients.contains { $0.party == p } }
    }

    /// The box the sender signs, if any.
    private var mySlot: Int? { slots.indices.contains(myParty ?? -1) ? myParty : nil }

    /// With no boxes in the document, each recipient's signature goes at the
    /// end and counts on its own; a party index per recipient keeps them apart.
    private var finalRecipients: [Recipient] {
        guard slots.isEmpty else {
            return recipients.map { r in
                var r = r
                r.partyRole = r.party.flatMap { slots.indices.contains($0) ? slots[$0].role : nil }
                return r
            }
        }
        return recipients.enumerated().map { i, r in var r = r; r.party = i; r.partyRole = nil; return r }
    }

    private var partyCount: Int { slots.isEmpty ? recipients.count : slots.count }

    private func pick(_ party: Int, for id: UUID) {
        guard let i = recipients.firstIndex(where: { $0.id == id }) else { return }
        // Two people can't sign one box: whoever had it takes this one's old box.
        if myParty == party {
            myParty = recipients[i].party
        } else if let j = recipients.firstIndex(where: { $0.party == party }), j != i {
            recipients[j].party = recipients[i].party
        }
        recipients[i].party = party
    }

    /// The sender's own choice. nil: not signing.
    private func pickMine(_ party: Int?) {
        if let party, let j = recipients.firstIndex(where: { $0.party == party }) {
            // The recipient who had it takes the sender's old box, or the
            // first free one; with none free they're asked to choose.
            recipients[j].party = myParty ?? unassigned.first { $0 != party }
        }
        myParty = party
    }

    private func addRecipient() {
        var r = Recipient()
        r.party = Self.preferenceOrder(slots.count, reserved: myParty)
            .first { p in p != myParty && !recipients.contains { $0.party == p } }
        recipients.append(r)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Validation
    // ─────────────────────────────────────────────────────────────────────────

    private static func isComplete(_ r: Recipient) -> Bool {
        !r.name.trimmingCharacters(in: .whitespaces).isEmpty &&
        (!r.email.trimmingCharacters(in: .whitespaces).isEmpty ||
         !r.phone.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// What has to change before it can go out. Shown after a Send tap.
    private var problems: [String] {
        var out: [String] = []
        if !recipients.allSatisfy(Self.isComplete) {
            out.append(String(localized: "Add a name, and an email or phone number, for each recipient."))
        }
        if mySlot != nil && myName.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append(String(localized: "Enter your full name to sign."))
        }
        if !slots.isEmpty && recipients.count > slots.count {
            out.append(String(localized: "This contract has \(slots.count) signature boxes, one per signer. Remove a recipient, or add a box for them."))
        }
        if !slots.isEmpty, recipients.contains(where: { $0.party == nil }), recipients.count <= slots.count {
            out.append(String(localized: "Choose what each recipient signs as."))
        }
        if !unassigned.isEmpty {
            let roles = unassigned.map { slots[$0].role }.formatted(.list(type: .and))
            out.append(String(localized: "No one is signing as \(roles). Choose it for yourself or a recipient, or delete the extra signature box."))
        }
        return out
    }

    private var canSend: Bool { !recipients.isEmpty && problems.isEmpty }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Body
    // ─────────────────────────────────────────────────────────────────────────

    var body: some View {
          ScrollViewReader { scroller in
            ScrollView {
                VStack(spacing: 12) {
                    if !blanks.isEmpty { blanksCard }

                    ForEach($recipients) { $recipient in
                        RecipientCard(
                            recipient: $recipient,
                            slots: slots,
                            canDelete: recipients.count > 1,
                            onPick: { pick($0, for: recipient.id) },
                            onDelete: { recipients.removeAll { $0.id == recipient.id } }
                        )
                    }

                    Button(action: addRecipient) {
                        Label("Add Recipient", systemImage: "plus.circle.fill")
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)

                    if triedToSend && !problems.isEmpty {
                        VStack(spacing: 6) {
                            ForEach(problems, id: \.self) { p in
                                Label(p, systemImage: "exclamationmark.circle")
                                    .font(.footnote)
                                    .foregroundStyle(Color.statusDeclined)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 16)
                        .id("problems")
                        .transition(.opacity)
                    }

                    if !slots.isEmpty { youCard }

                    replyCard
                }
                .padding(.top, 20)
                .padding(.bottom, 40)
                .readableColumn(Layout.readableWidth + 32)
            }
            .background(Color.pageBackground.ignoresSafeArea())
            .navigationTitle("Send for Signing")
            .navigationBarTitleDisplayMode(.inline)
            // A pushed page: the system back button (and edge swipe) leave it.
            // Hidden only while Face ID / the provider call is in flight.
            .navigationBarBackButtonHidden(isSigning)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    // Not disabled for missing details: tapping says what's
                    // missing instead of leaving a grey button to puzzle over.
                    ToolbarPillButton(title: mySlot == nil ? String(localized: "Send")
                                                           : String(localized: "Sign & Send")) {
                        guard canSend else {
                            withAnimation(.easeOut(duration: 0.2)) { triedToSend = true }
                            UINotificationFeedbackGenerator().notificationOccurred(.warning)
                            DispatchQueue.main.async {
                                withAnimation { scroller.scrollTo("problems", anchor: .center) }
                            }
                            return
                        }
                        startSend()
                    }
                    .disabled(isSigning)
                }
            }
          }
        .sheet(item: $activeSheet) { d in deliverySheet(d) }
        .alert("Couldn't register with the signing provider",
               isPresented: Binding(get: { providerError != nil }, set: { if !$0 { providerError = nil } })) {
            Button("OK", role: .cancel) { providerError = nil }
        } message: { Text(providerError ?? "") }
        .alert("Couldn't sign",
               isPresented: Binding(get: { signError != nil }, set: { if !$0 { signError = nil } })) {
            Button("OK", role: .cancel) { signError = nil }
        } message: { Text(signError ?? "") }
        .alert("Did you send it?", isPresented: $askedAboutShare) {
            Button("Yes, mark as sent") { didSend = true; finalize() }
            Button("Not yet", role: .cancel) { }
        } message: {
            Text("Handshake can't confirm delivery through the share sheet. Marking it sent moves it to Pending Signature.")
        }
        .alert("Send with blanks?", isPresented: $askedAboutBlanks) {
            Button("Send Anyway") { Task { await send() } }
            Button("Fill In") { showFillBlanks = true }
            Button("Go Back", role: .cancel) { }
        } message: {
            Text("Recipients will see \(blanksSummary) as they are.")
        }
        .sheet(isPresented: $showFillBlanks) {
            FillBlanksSheet(blanks: blanks, context: blankContext,
                            auto: autoValues, values: $blankValues)
        }
        // However the page is left (back, swipe, or after sending), keep any
        // blanks typed in, then let the workspace reload the stored copy.
        // After a send this is a no-op: send() already applied them.
        .onDisappear {
            applyBlanks(includeAuto: false)
            onClose()
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Blanks
    // ─────────────────────────────────────────────────────────────────────────

    /// Name blanks the send screen already knows: "[FREELANCER FULL NAME]"
    /// is whoever signs as Freelancer — the sender, or that recipient.
    private var autoValues: [String: String] {
        var out: [String: String] = [:]
        for b in blanks {
            guard let p = SignatureSlots.party(forNameBlank: b, in: slots) else { continue }
            let name = (p == mySlot ? myName : recipients.first { $0.party == p }?.name ?? "")
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { out[b] = name }
        }
        return out
    }

    private func value(for blank: String) -> String {
        (blankValues[blank] ?? autoValues[blank] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Blanks that would still go out as "[…]".
    private var pendingBlanks: [String] { blanks.filter { value(for: $0).isEmpty } }

    /// Writes the filled blanks into the stored document. `includeAuto`:
    /// also the names taken from this screen (only when actually sending —
    /// on leaving the page they may not be final).
    private func applyBlanks(includeAuto: Bool) {
        var fills: [String: String] = [:]
        for b in blanks {
            let v = (blankValues[b] ?? (includeAuto ? autoValues[b] : nil) ?? "")
            if !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fills[b] = v }
        }
        guard !fills.isEmpty, let stored = ContractStore.shared.contract(id: contract.id) else { return }
        let body = stored.baseBody()
        guard SignatureSlots.fill(fills, in: body) else { return }
        ContractStore.shared.update(id: contract.id) { $0.setBody(body) }
        blanks = SignatureSlots.blanks(in: body)
        blankValues = blankValues.filter { blanks.contains($0.key) }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Cards
    // ─────────────────────────────────────────────────────────────────────────

    private var blanksSummary: String {
        let pending = pendingBlanks
        let shown = Array(pending.prefix(3))
        return pending.count > 3
            ? String(localized: "\(shown.joined(separator: ", ")) and \(pending.count - 3) more")
            : shown.formatted(.list(type: .and))
    }

    /// Orange while blanks are left; a quiet confirmation once they're all
    /// filled. Either way, tapping opens the form.
    private var blanksCard: some View {
        let pending = pendingBlanks.count
        let done = pending == 0
        // One tint per card: the action takes the banner's own colour, so
        // a blue link doesn't sit on an orange wash.
        let tint = done ? Color.statusSigned : Color.orange
        return Button { showFillBlanks = true } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(done ? String(localized: "All blanks filled in")
                               : pending == 1 ? String(localized: "1 blank still to fill in")
                                              : String(localized: "\(pending) blanks still to fill in"),
                          systemImage: done ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tint)
                    Text(done ? String(localized: "They go into the contract when you send it.")
                              : String(localized: "\(blanksSummary) still need filling in."))
                        .font(.footnote)
                        .foregroundStyle(Color.secondaryInk)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Text(done ? String(localized: "Review") : String(localized: "Fill In"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tint.opacity(0.6))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(tint.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    private var youCard: some View {
        SendCard(header: String(localized: "You")) {
            CardRow(icon: "signature") {
                Text("Signs as")
                    .foregroundStyle(Color.secondaryInk)
                Spacer()
                Menu {
                    Picker("Signs as", selection: Binding(
                        get: { mySlot ?? -1 },
                        set: { pickMine($0 >= 0 ? $0 : nil) }
                    )) {
                        ForEach(slots.indices, id: \.self) { i in
                            Text(slots[i].role).tag(i)
                        }
                        Divider()
                        Text("I'm not signing").tag(-1)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(mySlot.map { slots[$0].role } ?? String(localized: "Not signing"))
                            .fontWeight(.medium)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(Color.accent)
                }
            }
            if mySlot != nil {
                Divider().padding(.leading, 48)
                CardRow(icon: "person") {
                    TextField("Your full name", text: $myName)
                        .textContentType(.name)
                }
            }
        } footer: {
            if mySlot != nil {
                Text("You'll sign with \(SignatureService.biometryName) before it's sent, so recipients see your signature in place.")
            } else {
                Text("Only your recipients sign. You'll get the signed copy back.")
            }
        }
    }

    private var replyCard: some View {
        SendCard(header: String(localized: "Signed copies come back to")) {
            CardRow(icon: "arrowshape.turn.up.left") {
                TextField("Your email or phone", text: $replyTo)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        } footer: {
            Text("Recipients' replies open already addressed to you. Optional.")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Send
    // ─────────────────────────────────────────────────────────────────────────

    private func startSend() {
        if !pendingBlanks.isEmpty { askedAboutBlanks = true; return }
        Task { await send() }
    }

    private func send() async {
        // Filled blanks (and the names from this screen) go into the
        // document first, so the links, and the sender's signature, are on
        // the finished wording.
        applyBlanks(includeAuto: true)
        // The sender's own box first. A signature already on the record for
        // that box (sending again, wording unchanged) is reused.
        if let slot = mySlot, ownSignature?.slot != slot {
            let name = myName.trimmingCharacters(in: .whitespaces)
            if let kept = ContractStore.shared.contract(id: contract.id)?.signature(forSlot: slot),
               kept.name == name {
                ownSignature = kept
            } else {
                isSigning = true
                defer { isSigning = false }
                do {
                    try await SignatureService.authenticate(
                        reason: String(localized: "Confirm your identity to sign \"\(contract.title)\".")
                    )
                } catch SignatureError.cancelled {
                    return
                } catch {
                    signError = error.localizedDescription
                    return
                }
                let stamp = SignatureService.stamp(signerName: name, contractID: contract.id)
                ownSignature = PartySignature(slot: slot, role: slots[slot].role, name: name,
                                              signedAt: stamp.signedAt, hash: stamp.hash,
                                              date: slots[slot].hasDate ? stamp.signedAt : nil,
                                              method: SignatureService.biometryName)
            }
        }

        let reply = replyTo.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(reply.isEmpty ? nil : reply, forKey: Self.replyToKey)
        let name = myName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { UserDefaults.standard.set(name, forKey: Self.myNameKey) }

        didSend = false
        sharedSomething = false
        queue = finalRecipients.map(Delivery.init)
        next()
    }

    /// One compose sheet per recipient, one after another.
    private func next() {
        guard !queue.isEmpty else { finish(); return }
        activeSheet = queue.removeFirst()
    }

    private func delivered(sent: Bool, shared: Bool = false) {
        if sent   { didSend = true }
        if shared { sharedSomething = true }
        activeSheet = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { next() }
    }

    private func finish() {
        if didSend { finalize() }
        // A share completed, but iOS won't say whether it was actually
        // delivered (it could have been "Copy"), so confirm rather than assume.
        else if sharedSomething { askedAboutShare = true }
        // Nothing went out: stay here, nothing marked.
    }

    @ViewBuilder
    private func deliverySheet(_ d: Delivery) -> some View {
        switch d.channel {
        case .sms(let phone):
            MessageComposeView(recipients: [phone], body: smsBody(for: d.recipient)) { r in
                delivered(sent: r == .sent)
            }
            .ignoresSafeArea()
        case .mail(let email):
            MailComposeView(toRecipients: [email], subject: mailSubject, body: mailBody(for: d.recipient)) { r in
                delivered(sent: r == .sent || r == .saved)
            }
            .ignoresSafeArea()
        case .share:
            // Fallback for simulator / devices where compose sheets are
            // unavailable. One combined string, not [subject, body] — two
            // items makes the share sheet describe them as "2 Images".
            ActivityView(activityItems: ["\(mailSubject)\n\n\(mailBody(for: d.recipient))"]) { completed in
                delivered(sent: false, shared: completed)
            }
            .presentationDetents([.medium, .large])
        }
    }

    /// Called once every compose sheet is done. Marks the contract sent with
    /// its recipients, parties, reply address and the sender's signature.
    /// With a signing provider configured, the provider-side document is
    /// created first so the signing screen has something to complete.
    private func finalize() {
        let rs    = finalRecipients
        let reply = replyTo.trimmingCharacters(in: .whitespaces)
        let mark: (ProviderRef?) -> Void = { ref in
            ContractStore.shared.markSent(id: contract.id, recipients: rs, providerRef: ref,
                                          partyCount: partyCount,
                                          replyTo: reply.isEmpty ? nil : reply,
                                          senderName: senderName,
                                          senderRole: slots.isEmpty ? nil : (mySlot.map { slots[$0].role } ?? ""),
                                          ownSignature: ownSignature)
            Haptics.success()
            dismiss()
        }

        let backend = Secrets.signingBackend
        guard backend != .onDevice, BackendClient.isConfigured else { mark(nil); return }

        Task {
            do {
                let ref = try await SigningProviders.start(contract: contract, recipients: rs, backend: backend)
                mark(ref)
            } catch {
                providerError = error.localizedDescription
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Links and messages
    // ─────────────────────────────────────────────────────────────────────────

    // handshake://sign/<id>?d=… — the link carries the contract itself, so a
    // recipient on another phone can open it with no server (ContractTransfer).
    // Built from the store, so the sender's latest edits are what goes, with
    // this recipient's box (`myParty`) and the sender's signature inside.
    private func signingLink(for r: Recipient) -> String {
        var c = ContractStore.shared.contract(id: contract.id) ?? contract
        c.recipients    = finalRecipients
        c.status        = .sent
        c.sentAt        = .now          // the recipient's History dates it by this
        c.senderName    = senderName
        c.partyCount    = partyCount
        c.myParty       = r.party
        let reply       = replyTo.trimmingCharacters(in: .whitespaces)
        c.replyTo       = reply.isEmpty ? nil : reply
        c.changeRequest = nil
        if let own = ownSignature {
            c.signatures.removeAll { $0.slot == own.slot }
            c.merge(signatures: [own])
        }
        return ContractTransfer.signingLink(for: c)
    }

    /// The sender's name: what they typed to sign, or their Apple name.
    private var senderName: String? {
        let typed = myName.trimmingCharacters(in: .whitespaces)
        if mySlot != nil, !typed.isEmpty { return typed }
        let n = AccountStore.shared.name?.trimmingCharacters(in: .whitespaces) ?? ""
        return n.isEmpty ? nil : n
    }

    private func smsBody(for r: Recipient) -> String {
        let link = signingLink(for: r)
        if let senderName {
            return String(localized: "\(senderName) invited you to sign \"\(contract.title)\". Open it in the Handshake app to review and sign with Face ID:\n\(link)")
        }
        return String(localized: "You've been invited to sign \"\(contract.title)\". Open it in the Handshake app to review and sign with Face ID:\n\(link)")
    }

    private var mailSubject: String { String(localized: "Please sign: \(contract.title)") }

    // The old closing line said the link was "unique to you"; now it is —
    // it opens the box this recipient signs.
    private func mailBody(for r: Recipient) -> String {
        let intro = senderName.map { String(localized: "\($0) invited you to review and sign the following agreement:") }
            ?? String(localized: "You've been invited to review and sign the following agreement:")
        let link = signingLink(for: r)
        return String(localized: """
            Hi,

            \(intro)

            \(contract.title)

            Tap the link below to open it in the Handshake app and sign with Face ID:
            \(link)

            The link opens in Handshake, so you'll need the app installed on your iPhone or iPad.
            """)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - FillBlanksSheet
//
// One field per "[…]" blank, with the sentence it sits in. Name blanks the
// send screen already knows come pre-filled; the sender can change them.
// ─────────────────────────────────────────────────────────────────────────────

private struct FillBlanksSheet: View {
    let blanks: [String]
    let context: [String: String]
    let auto: [String: String]
    @Binding var values: [String: String]
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: String?

    var body: some View {
        NavigationStack {
            Form {
                ForEach(blanks, id: \.self) { b in
                    Section {
                        TextField(label(b), text: Binding(
                            get: { values[b] ?? auto[b] ?? "" },
                            set: { values[b] = $0 }
                        ))   // one line: a blank sits inside a sentence
                        .focused($focused, equals: b)
                        .submitLabel(.next)
                        .onSubmit { focusNext(after: b) }
                    } header: {
                        Text(label(b))
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            if let line = context[b] { Text(line) }
                            if values[b] == nil, auto[b] != nil {
                                Text("Filled in from the name on the send screen.")
                                    .foregroundStyle(Color.accent)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Fill In Blanks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
            .onAppear {
                focused = blanks.first { (values[$0] ?? auto[$0] ?? "").isEmpty }
            }
        }
    }

    /// "[FREELANCER FULL NAME]" → "Freelancer Full Name".
    private func label(_ b: String) -> String {
        let inner = b.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return inner == inner.uppercased() && inner != inner.lowercased() ? inner.capitalized : inner
    }

    private func focusNext(after b: String) {
        guard let i = blanks.firstIndex(of: b) else { return }
        focused = blanks.dropFirst(i + 1).first
        if focused == nil { dismiss() }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Delivery
// ─────────────────────────────────────────────────────────────────────────────

private struct Delivery: Identifiable {
    enum Channel { case sms(String), mail(String), share }

    let id = UUID()
    let recipient: Recipient
    let channel: Channel

    /// One channel per person: Messages when there's a phone number, else
    /// Mail, else the share sheet.
    init(_ r: Recipient) {
        recipient = r
        let phone = r.phone.trimmingCharacters(in: .whitespaces)
        let email = r.email.trimmingCharacters(in: .whitespaces)
        if !phone.isEmpty && MFMessageComposeViewController.canSendText()   { channel = .sms(phone) }
        else if !email.isEmpty && MFMailComposeViewController.canSendMail() { channel = .mail(email) }
        else                                                                 { channel = .share }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Cards
// ─────────────────────────────────────────────────────────────────────────────

private struct SendCard<Content: View, Footer: View>: View {
    let header: String
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 0) {
                Text(header)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.4)
                    .textCase(.uppercase)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                Divider()
                content
            }
            .background(Color.raisedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 8, y: 2)

            footer
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

private struct CardRow<Content: View>: View {
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            content
        }
        .font(.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - RecipientCard
// ─────────────────────────────────────────────────────────────────────────────

private struct RecipientCard: View {
    @Binding var recipient: Recipient
    let slots: [SignatureSlots.Slot]
    var canDelete: Bool
    var onPick: (Int) -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {

            // Header
            HStack {
                Text("Recipient")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.4)
                    .textCase(.uppercase)
                Spacer()
                if canDelete {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.subheadline)
                            .foregroundStyle(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove recipient")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            CardRow(icon: "person") {
                TextField("Full name", text: $recipient.name)
                    .textContentType(.name)
                    .submitLabel(.next)
            }

            Divider().padding(.leading, 48)

            CardRow(icon: "envelope") {
                TextField("Email", text: $recipient.email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.next)
            }

            Divider().padding(.leading, 48)

            CardRow(icon: "phone") {
                TextField("Phone number", text: $recipient.phone)
                    .textContentType(.telephoneNumber)
                    .keyboardType(.phonePad)
            }

            // Which box they sign. Only a choice when there's more than one,
            // or when the sender took theirs and they need another.
            if slots.count > 1 || (!slots.isEmpty && recipient.party == nil) {
                Divider().padding(.leading, 48)
                CardRow(icon: "signature") {
                    Text("Signs as")
                        .foregroundStyle(Color.secondaryInk)
                    Spacer()
                    Menu {
                        Picker("Signs as", selection: Binding(
                            get: { recipient.party ?? -1 },
                            set: { if $0 >= 0 { onPick($0) } }
                        )) {
                            ForEach(slots.indices, id: \.self) { i in
                                Text(slots[i].role).tag(i)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(recipient.party.flatMap { slots.indices.contains($0) ? slots[$0].role : nil }
                                 ?? String(localized: "Choose"))
                                .fontWeight(.medium)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(Color.accent)
                    }
                }
            }
        }
        .background(Color.raisedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
        .padding(.horizontal, 16)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Preview
// ─────────────────────────────────────────────────────────────────────────────

#Preview {
    NavigationStack { SendFlowView(contract: GeneratedContract(
        id: UUID(),
        title: "Non-Disclosure Agreement",
        content: "This NDA is entered into between the parties...\n\nLANDLORD: [FULL NAME]\n[Signature]\n\nTENANT: [FULL NAME]\n[Signature]"
    )) }
}
