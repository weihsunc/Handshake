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
//   • "When it's signed": the reply address is carried in the link, so the
//     recipient's reply opens already addressed to the sender.
// ─────────────────────────────────────────────────────────────────────────────

struct SendFlowView: View {

    let contract: GeneratedContract
    /// Called when the page goes away, after any typed blanks are saved.
    var onClose: () -> Void = {}
    /// Done on the Sent page: finished with this contract, close it.
    var onDone: () -> Void = {}
    /// Blanks were filled in from the form: where the new text sits, and how
    /// many blanks. The workspace takes the sender back to show them.
    var onBlanksFilled: (_ ranges: [NSRange], _ count: Int) -> Void = { _, _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    /// Signature boxes on the unsigned document, and whose they are.
    @State private var slots: [SignatureSlots.Slot]
    /// "[ADDRESS]"-style placeholders still in the document.
    @State private var blanks: [String]
    /// Where each blank sits ("…entered into as of ____ (the Effective…").
    @State private var blankContext: [String: String]
    /// What the sender typed for each blank. Written into the document when
    /// it's sent (or on leaving the page, so nothing typed is lost).
    @State private var blankValues: [String: String] = [:]
    @State private var showFillBlanks = false

    @State private var recipients: [Recipient]
    @State private var copyRecipients: [CopyRecipient]
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
    /// The DocuSeal submission for this send (when DocuSeal is on): made
    /// before the links go out, since each link carries its signer's part
    /// and each message their browser signing link.
    @State private var docuSealRef: ProviderRef? = nil
    @State private var signError: String? = nil
    @State private var isSigning = false
    /// The sender's own signature, made when they tap Sign & Send. Saved to
    /// the contract only once something was actually sent.
    @State private var ownSignature: PartySignature? = nil

    /// After sending: the confirmation replaces the form (who it went to,
    /// how, what happens next). Back is gone from then on; Done returns to
    /// the document.
    @State private var showSent = false
    /// What happened to each recipient's link, by recipient id.
    @State private var outcomes: [UUID: Outcome] = [:]
    /// Shared this round, unconfirmed: "Not yet" on "Did you send it?" puts
    /// these back to not sent.
    @State private var roundShared: [UUID] = []
    /// How many timeline steps have come in on the Sent page.
    @State private var revealedSteps = 0

    /// The party being chosen in the sheet (or a signer being added).
    @State private var editing: PartyEdit? = nil
    @State private var editingReply = false
    /// Boxes added on this page (by role, lowercased). Removing their
    /// signer removes the box too; boxes the contract came with stay.
    @State private var addedRoles: Set<String> = []
    @State private var replyDraft = ""

    private static let replyToKey = "send.replyTo"
    private static let myNameKey  = "send.myName"

    init(contract: GeneratedContract, onClose: @escaping () -> Void = {},
         onDone: @escaping () -> Void = {},
         onBlanksFilled: @escaping ([NSRange], Int) -> Void = { _, _ in }) {
        self.contract = contract
        self.onClose  = onClose
        self.onDone   = onDone
        self.onBlanksFilled = onBlanksFilled
        let stored = ContractStore.shared.contract(id: contract.id) ?? contract
        let base   = stored.baseBody()
        let found  = SignatureSlots.find(in: base)
        _slots = State(initialValue: found)
        let foundBlanks = SignatureSlots.blanks(in: base)
        _blanks = State(initialValue: foundBlanks)
        _blankContext = State(initialValue: Self.contexts(of: foundBlanks, in: base))
        // The sender's party: what they chose last time ("" = not signing),
        // or the AI's guess from the request. A name no box has any more
        // counts as unknown.
        var mine: Int? = Self.index(ofRole: stored.senderRole, in: found)
        let senderDecided = stored.senderRole == "" || mine != nil
        // Sending again (after changes were asked for, say): start from the
        // people it went to last time, in the same parties — by name first,
        // so a reordered signature block keeps everyone in their role.
        let start = stored.recipients.map { r in
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
        _copyRecipients = State(initialValue: stored.copyRecipients)
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

    /// Who a party (or, in a document without boxes, a signer) is.
    private func assign(_ choice: PartyChoice, party p: Int?, recipientID: UUID?) {
        switch choice {
        case .me:
            guard let p else { return }
            // One box, one signer: whoever had it is off the contract.
            recipients.removeAll { $0.party == p }
            myParty = p
        case .person(let name, let contact):
            if let p, myParty == p { myParty = nil }
            let i = p.flatMap { p in recipients.firstIndex { $0.party == p } }
                 ?? recipientID.flatMap { id in recipients.firstIndex { $0.id == id } }
            var r = i.map { recipients[$0] } ?? Recipient(party: p)
            r.name = name.trimmingCharacters(in: .whitespaces)
            Self.setContact(contact, on: &r)
            if let i { recipients[i] = r } else { recipients.append(r) }
        case .nobody:
            if let p {
                if myParty == p { myParty = nil }
                recipients.removeAll { $0.party == p }
                if addedRoles.contains(slots[p].role.lowercased()) { removeSignatureBox(p) }
            } else if let recipientID {
                recipients.removeAll { $0.id == recipientID }
            }
        }
    }

    /// One field for either: an "@" makes it an email, anything else a
    /// phone number. The other is cleared, so an old number can't take
    /// over delivery (Messages is tried before Mail).
    private static func setContact(_ value: String, on r: inout Recipient) {
        let v = value.trimmingCharacters(in: .whitespaces)
        if v.contains("@") { r.email = v; r.phone = "" } else { r.phone = v; r.email = "" }
    }

    nonisolated static func contact(of r: Recipient) -> String {
        let e = r.email.trimmingCharacters(in: .whitespaces)
        return e.isEmpty ? r.phone.trimmingCharacters(in: .whitespaces) : e
    }

    /// A new signature box at the end of the contract, for a signer it
    /// didn't name ("WITNESS: [FULL NAME]", the box, the date). Returns the
    /// new box's party.
    private func addSignatureBox(role: String) -> Int? {
        guard let stored = ContractStore.shared.contract(id: contract.id) else { return nil }
        let body = stored.baseBody()
        let head = role.replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespaces).uppercased()
        guard !head.isEmpty else { return nil }
        let trimmed = body.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let block = NSMutableAttributedString.fromHandshakeMarkdown(
            (trimmed.isEmpty ? "" : "\n\n") + "\(head): [FULL NAME]\n[Signature]\n[Date]")
        // Trim trailing blank lines first so the gap above it is one blank line.
        while body.length > 0, let last = body.string.last, last.isNewline {
            body.deleteCharacters(in: NSRange(location: body.length - 1, length: 1))
        }
        body.append(block)
        saveBody(body)
        guard !slots.isEmpty else { return nil }
        addedRoles.insert(slots[slots.count - 1].role.lowercased())
        return slots.count - 1
    }

    /// Takes out a box added here: its role line, the box and its date, up
    /// to the next party (or the end). Parties after it move up one.
    private func removeSignatureBox(_ p: Int) {
        guard slots.indices.contains(p),
              let stored = ContractStore.shared.contract(id: contract.id) else { return }
        let body = stored.baseBody()
        let found = SignatureSlots.find(in: body)
        guard found.indices.contains(p) else { return }
        let start = found[p].roleLine?.location ?? found[p].range.location
        let end = p + 1 < found.count
            ? (found[p + 1].roleLine?.location ?? found[p + 1].range.location)
            : body.length
        guard end > start else { return }
        addedRoles.remove(found[p].role.lowercased())
        body.deleteCharacters(in: NSRange(location: start, length: end - start))
        while body.length > 0, let last = body.string.last, last.isNewline {
            body.deleteCharacters(in: NSRange(location: body.length - 1, length: 1))
        }
        for i in recipients.indices { if let q = recipients[i].party, q > p { recipients[i].party = q - 1 } }
        if let m = myParty, m > p { myParty = m - 1 }
        saveBody(body)
    }

    /// Writes the document back and re-reads its boxes and blanks.
    private func saveBody(_ body: NSMutableAttributedString) {
        ContractStore.shared.update(id: contract.id) { $0.setBody(body) }
        slots = SignatureSlots.find(in: body)
        let b = SignatureSlots.blanks(in: body)
        blanks = b
        blankContext = Self.contexts(of: b, in: body)
    }

    private static func contexts(of blanks: [String], in body: NSAttributedString) -> [String: String] {
        Dictionary(uniqueKeysWithValues: blanks.compactMap { b in
            SignatureSlots.context(of: b, in: body).map { (b, $0) }
        })
    }

    /// People sent to before, most recent first — the sheet's suggestions.
    private var pastRecipients: [Recipient] {
        var seen = Set<String>(), out: [Recipient] = []
        let sent = ContractStore.shared.contracts
            .filter { !$0.isIncoming && $0.id != contract.id }
            .sorted { ($0.sentAt ?? $0.createdAt) > ($1.sentAt ?? $1.createdAt) }
        for c in sent {
            for r in c.recipients {
                let name = r.name.trimmingCharacters(in: .whitespaces)
                let contact = Self.contact(of: r)
                guard !name.isEmpty, !contact.isEmpty,
                      seen.insert((name + "|" + contact).lowercased()).inserted else { continue }
                out.append(r)
            }
        }
        return out
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Validation
    // ─────────────────────────────────────────────────────────────────────────

    nonisolated private static func isComplete(_ r: Recipient) -> Bool {
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
        let copyAddresses = copyRecipients.map { CopyRecipient.addressKey($0.address) }
        let signerAddresses = Set(recipients.map { CopyRecipient.addressKey(Self.contact(of: $0)) })
        if Set(copyAddresses).count != copyAddresses.count || !signerAddresses.isDisjoint(with: copyAddresses) {
            out.append(String(localized: "Use a different address for each signer and each person getting a copy."))
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

    private var form: some View {
          ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    signersSection

                    if triedToSend && !problems.isEmpty {
                        VStack(spacing: 6) {
                            ForEach(problems, id: \.self) { p in
                                Label(p, image: "ph-warning-circle")
                                    .font(.footnote)
                                    .foregroundStyle(Color.statusDeclined)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                        .id("problems")
                        .transition(.opacity)
                    }

                    if !blanks.isEmpty {
                        blanksAlert
                            .padding(.top, 24)
                    }

                    whenSignedSection
                        .padding(.top, 24)
                }
                .padding(.top, 12)
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
    }

    var body: some View {
        Group {
            if showSent { sentPage.transition(.opacity) } else { form }
        }
        .sheet(item: $activeSheet) { d in deliverySheet(d) }
        .sheet(item: $editing) { e in partySheet(e) }
        .alert("Signed copies come back to", isPresented: $editingReply) {
            TextField("Your email or phone", text: $replyDraft)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Save") { replyTo = replyDraft.trimmingCharacters(in: .whitespaces) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Recipients' replies open already addressed to you. Optional.")
        }
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
            Button("Not yet", role: .cancel) {
                for id in roundShared { outcomes[id] = .notSent }
            }
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
        .sheet(isPresented: $showFillBlanks, onDismiss: blanksFormClosed) {
            FillBlanksSheet(blanks: blanks, context: blankContext,
                            auto: autoValues, values: $blankValues)
        }
        // However the page is left (back, swipe, or after sending), keep any
        // blanks typed in, then let the workspace reload the stored copy.
        // After a send this is a no-op: send() already applied them.
        .onDisappear {
            applyBlanks(includeAuto: false)
            saveDraftSigners()
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
    /// Returns where the values went (empty: nothing changed) and how many
    /// blanks were filled.
    @discardableResult
    private func applyBlanks(includeAuto: Bool) -> (ranges: [NSRange], count: Int) {
        var fills: [String: String] = [:]
        for b in blanks {
            let v = (blankValues[b] ?? (includeAuto ? autoValues[b] : nil) ?? "")
            if !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fills[b] = v }
        }
        guard !fills.isEmpty, let stored = ContractStore.shared.contract(id: contract.id) else { return ([], 0) }
        let body = stored.baseBody()
        let ranges = SignatureSlots.fillTracking(fills, in: body)
        guard !ranges.isEmpty else { return ([], 0) }
        ContractStore.shared.update(id: contract.id) { $0.setBody(body) }
        blanks = SignatureSlots.blanks(in: body)
        blankContext = Self.contexts(of: blanks, in: body)
        blankValues = blankValues.filter { blanks.contains($0.key) }
        return (ranges, fills.count)
    }

    /// The fill-in form closed. Anything typed goes into the contract now,
    /// and the sender is taken back to it to see the changes.
    private func blanksFormClosed() {
        let (ranges, count) = applyBlanks(includeAuto: false)
        guard !ranges.isEmpty else { return }
        onBlanksFilled(ranges, count)
    }

    /// Who signs what, kept with the draft when the page is left without
    /// sending — so coming back (after filling blanks, say) starts from it.
    private func saveDraftSigners() {
        guard !showSent else { return }
        let rs = finalRecipients
        let role: String? = slots.isEmpty ? nil : (mySlot.map { slots[$0].role } ?? "")
        ContractStore.shared.update(id: contract.id) { c in
            guard c.status == .draft else { return }
            c.recipients = rs
            c.copyRecipients = copyRecipients
            if let role { c.senderRole = role }
        }
        let name = myName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { UserDefaults.standard.set(name, forKey: Self.myNameKey) }
        let reply = replyTo.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(reply.isEmpty ? nil : reply, forKey: Self.replyToKey)
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

    // ── Signers ──────────────────────────────────────────────────────────

    /// One row per signature box: the contract says who signs, the sender
    /// says who that is. A document without boxes lists its signers instead.
    private var signersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Who signs")
                .font(.footnote)
                .foregroundStyle(Color.secondaryInk)
                .padding(.horizontal, 20)
            VStack(spacing: 0) {
                if slots.isEmpty {
                    ForEach(Array(recipients.enumerated()), id: \.element.id) { i, r in
                        if i > 0 { Divider().padding(.leading, 62) }
                        signerRow(role: String(localized: "Signer \(i + 1)"), me: false, person: r) {
                            editing = PartyEdit(party: nil, recipientID: r.id)
                        }
                    }
                } else {
                    ForEach(slots.indices, id: \.self) { p in
                        if p > 0 { Divider().padding(.leading, 62) }
                        signerRow(role: slots[p].role, me: myParty == p,
                                  person: recipients.first { $0.party == p }) {
                            editing = PartyEdit(party: p, recipientID: nil)
                        }
                    }
                }
                if !(slots.isEmpty && recipients.isEmpty) { Divider().padding(.leading, 62) }
                Button { editing = PartyEdit(party: nil, recipientID: nil, adding: true) } label: {
                    HStack(spacing: 12) {
                        Image("ph-plus-circle-fill")
                            .font(.system(size: 22))
                            .frame(width: 34)
                        Text("Add Signer")
                        Spacer()
                    }
                    .foregroundStyle(Color.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .background(Color.raisedSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)

            if !slots.isEmpty {
                Group {
                    if mySlot != nil {
                        Text("You'll sign with \(SignatureService.biometryName) first so the other signers can see your signature.")
                    } else {
                        Text("Your signers will send the signed copy back to you.")
                    }
                }
                .font(.footnote)
                .foregroundStyle(Color.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.top, 2)
            }
        }
    }

    /// A party, and who's signing it: you, someone, or nobody yet.
    private func signerRow(role: String, me: Bool, person: Recipient?,
                           action: @escaping () -> Void) -> some View {
        let name = me ? myName.trimmingCharacters(in: .whitespaces)
                      : person?.name.trimmingCharacters(in: .whitespaces) ?? ""
        let contact = person.map(Self.contact(of:)) ?? ""
        let assigned = me || person != nil
        let warn = triedToSend
        var detail: Text {
            if me {
                return name.isEmpty
                    ? Text("You · \(Text("Add your name").foregroundStyle(warn ? Color.orange : Color.accent))")
                    : Text("You · \(name)")
            }
            if let _ = person {
                if name.isEmpty { return Text("Add a name").foregroundStyle(warn ? Color.orange : Color.accent) }
                if contact.isEmpty { return Text("\(name) · \(Text("Add an email or phone").foregroundStyle(warn ? Color.orange : Color.accent))") }
                return Text("\(name) · \(contact)")
            }
            return Text("Choose who signs").foregroundStyle(warn ? Color.orange : Color.accent)
        }
        return Button(action: action) {
            HStack(spacing: 12) {
                Monogram(name: name, empty: !assigned)
                VStack(alignment: .leading, spacing: 2) {
                    Text(role)
                        .foregroundStyle(Color.primaryInk)
                    detail
                        .font(.footnote)
                        .foregroundStyle(Color.secondaryInk)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image("ph-caret-right").flipsForRightToLeftLayoutDirection(true)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Where the finished contract goes: back to you (each signer's reply
    /// is addressed to you), and to anyone you copy in. One card, so the two
    /// "signed copy" ideas read as one story.
    private var whenSignedSection: some View {
        let addr = replyTo.trimmingCharacters(in: .whitespaces)
        return VStack(alignment: .leading, spacing: 6) {
            Text("When it's signed")
                .font(.footnote)
                .foregroundStyle(Color.secondaryInk)
                .padding(.horizontal, 20)
            VStack(spacing: 0) {
                // Back to you
                Button {
                    replyDraft = addr
                    editingReply = true
                } label: {
                    destinationRow(icon: "ph-arrow-bend-up-left", flips: true,
                                   title: Text("Comes back to you"),
                                   detail: addr.isEmpty
                                       ? Text("Add an email or phone").foregroundStyle(Color.accent)
                                       : Text(addr))
                }
                .buttonStyle(.plain)

                // Copies
                ForEach(copyRecipients) { person in
                    Divider().padding(.leading, 62)
                    Button { editing = PartyEdit(recipientID: person.id, copyOnly: true) } label: {
                        HStack(spacing: 12) {
                            Monogram(name: person.name)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(person.name).foregroundStyle(Color.primaryInk)
                                Text("Gets a copy · \(person.address)")
                                    .font(.footnote).foregroundStyle(Color.secondaryInk)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Image("ph-caret-right").flipsForRightToLeftLayoutDirection(true)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color(.tertiaryLabel))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Divider().padding(.leading, 62)
                Button { editing = PartyEdit(copyOnly: true) } label: {
                    HStack(spacing: 12) {
                        Image("ph-plus").font(.body).frame(width: 34)
                        Text("Send a copy to someone else")
                        Spacer()
                    }
                    .foregroundStyle(Color.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .background(Color.raisedSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)

            Group {
                if copyRecipients.isEmpty {
                    Text("Each signer's reply is addressed to you.")
                } else {
                    Text("Each signer's reply is addressed to you. You send the copies once everyone has signed.")
                }
            }
            .font(.footnote)
            .foregroundStyle(Color.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 20)
            .padding(.top, 2)
        }
    }

    /// A row in "When it's signed" that isn't a person: an icon where the
    /// monogram would be, so it lines up with the people below it.
    private func destinationRow(icon: String, flips: Bool = false, title: Text, detail: Text) -> some View {
        HStack(spacing: 12) {
            Image(icon).flipsForRightToLeftLayoutDirection(flips)
                .font(.title3)
                .foregroundStyle(Color.primaryInk)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                title.foregroundStyle(Color.primaryInk)
                detail
                    .font(.footnote)
                    .foregroundStyle(Color.secondaryInk)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image("ph-caret-right").flipsForRightToLeftLayoutDirection(true)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func partySheet(_ e: PartyEdit) -> some View {
        if e.copyOnly { copyRecipientSheet(e) }
        else { signerSheet(e) }
    }

    private func copyRecipientSheet(_ e: PartyEdit) -> some View {
        let person = copyRecipients.first { $0.id == e.recipientID }
        return PartySheet(role: nil, asksForRole: false, canBeMe: false, startsAsMe: false,
                          name: person?.name ?? "", contact: person?.address ?? "", canRemove: person != nil,
                          myName: $myName, suggestions: [], copyOnly: true) { choice, _ in
            switch choice {
            case .person(let name, let contact):
                if let i = copyRecipients.firstIndex(where: { $0.id == person?.id }) {
                    copyRecipients[i].name = name
                    copyRecipients[i].address = contact
                } else {
                    copyRecipients.append(CopyRecipient(name: name, address: contact))
                }
            case .nobody: copyRecipients.removeAll { $0.id == person?.id }
            case .me: break
            }
            saveDraftSigners()
        }
    }

    private func signerSheet(_ e: PartyEdit) -> some View {
        let p = e.party
        let person = p.map { p in recipients.first { $0.party == p } }
                  ?? e.recipientID.flatMap { id in recipients.first { $0.id == id } }
        let taken = Set(recipients.compactMap { r in
            r.id == person?.id ? nil : (r.name + "|" + Self.contact(of: r)).lowercased() })
        return PartySheet(
            role: p.map { slots[$0].role },
            asksForRole: e.adding && !slots.isEmpty,
            canBeMe: !slots.isEmpty,
            startsAsMe: p != nil && myParty == p,
            name: person?.name ?? "",
            contact: person.map(Self.contact(of:)) ?? "",
            canRemove: !e.adding && (person != nil || (p != nil && myParty == p)
                                     || p.map { addedRoles.contains(slots[$0].role.lowercased()) } == true),
            myName: $myName,
            suggestions: pastRecipients.filter { !taken.contains(($0.name + "|" + Self.contact(of: $0)).lowercased()) }
        ) { choice, newRole in
            if e.adding, slots.isEmpty {
                assign(choice, party: nil, recipientID: nil)
            } else if e.adding {
                guard case .nobody = choice else {
                    if let p = addSignatureBox(role: newRole) { assign(choice, party: p, recipientID: nil) }
                    return
                }
            } else {
                assign(choice, party: p, recipientID: e.recipientID)
            }
        }
    }

    // ── Blanks ───────────────────────────────────────────────────────────

    /// Must-fix before it goes out: how many, the first two by name, and a
    /// small Fill In on the right. Once they're all filled, a quiet green
    /// line to review them.
    @ViewBuilder
    private var blanksAlert: some View {
        let pending = pendingBlanks
        if pending.isEmpty {
            Button { showFillBlanks = true } label: {
                HStack(spacing: 10) {
                    Label("All blanks filled in", image: "ph-check-circle-fill")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("Review").font(.subheadline.weight(.semibold))
                    Image("ph-caret-right").flipsForRightToLeftLayoutDirection(true).font(.footnote.weight(.semibold)).opacity(0.6)
                }
                .foregroundStyle(Color.statusSigned)
                .padding(14)
                .background(Color.statusSigned.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
        } else {
            Button { showFillBlanks = true } label: {
                HStack(alignment: .center, spacing: 12) {
                    Image("ph-warning-fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pending.count == 1 ? String(localized: "1 blank to fill in")
                                                : String(localized: "\(pending.count) blanks to fill in"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.orange)
                        Text(blanksNamed(pending))
                            .font(.footnote)
                            .foregroundStyle(Color.secondaryInk)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 4)
                    Text("Fill In")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.orange)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.orange.opacity(0.14), in: Capsule())
                }
                .padding(14)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
        }
    }

    /// "Effective Date, State/Country and 19 more" — the blanks by name.
    private func blanksNamed(_ pending: [String]) -> String {
        let shown = pending.prefix(2).map(blankLabel)
        return pending.count > 2
            ? String(localized: "\(shown.joined(separator: ", ")) and \(pending.count - 2) more")
            : shown.formatted(.list(type: .and))
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Sent
    // ─────────────────────────────────────────────────────────────────────────

    /// The step after sending, told as one timeline: you signed, the link
    /// went to each person, they sign, the copy comes back. Done closes the
    /// contract; View Contract goes back to it. Anyone whose message was
    /// cancelled can be sent again from their step.
    private var sentPage: some View {
        let steps = sentSteps
        return ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    PaperPlaneDoodle(size: 84)
                        .padding(.bottom, 6)
                    Text("Sent for Signing")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Color.primaryInk)
                    Text(contract.title)
                        .font(.subheadline)
                        .foregroundStyle(Color.secondaryInk)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .padding(.bottom, 32)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                        timelineRow(step, isLast: i == steps.count - 1)
                            .opacity(revealedSteps > i ? 1 : 0)
                            .offset(y: revealedSteps > i ? 0 : 6)
                    }
                }
                .padding(.horizontal, 28)

                Text("It's under Pending Signature in Contracts until everyone has signed.")
                    .font(.footnote)
                    .foregroundStyle(Color.secondaryInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // In line with the steps' text, past the markers.
                    .padding(.leading, 28 + 20 + 14)
                    .padding(.trailing, 28)
                    .padding(.top, 20)
                    .opacity(revealedSteps >= steps.count ? 1 : 0)
            }
            .padding(.bottom, 24)
            .readableColumn()
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.pageBackground.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                PrimaryPillButton(title: String(localized: "Done"), fullWidth: true) { onDone() }
                Button(String(localized: "View Contract")) { dismiss() }
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.accent)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .readableColumn()
            .background(Color.pageBackground)
        }
        .toolbar(.hidden, for: .navigationBar)
        // Sent is sent: no way back into the form, only on.
        .navigationBarBackButtonHidden(true)
        .onAppear { revealSteps(steps.count) }
    }

    private enum StepState { case done, waiting, problem }
    private struct SentStep {
        var state: StepState
        var title: String
        var detail: String?
        /// A recipient whose message didn't go: their step offers Send.
        var resend: Recipient? = nil
    }

    private var sentSteps: [SentStep] {
        let rs = finalRecipients
        var steps: [SentStep] = []
        if let own = ownSignature {
            let role = own.role ?? ""
            steps.append(SentStep(
                state: .done,
                title: role.isEmpty ? String(localized: "You signed") : String(localized: "You signed as \(role)"),
                detail: "\(own.method ?? SignatureService.biometryName) · \(own.signedAt.formatted(date: .omitted, time: .shortened))"))
        }
        for r in rs {
            let outcome = outcomes[r.id] ?? .notSent
            let how: String
            switch outcome {
            case .messages: how = String(localized: "Messages")
            case .mail:     how = String(localized: "Mail")
            case .shared:   how = String(localized: "Link shared")
            case .notSent:  how = String(localized: "Not sent")
            }
            let detail = [r.partyRole, how].compactMap { $0 }.joined(separator: " · ")
            steps.append(outcome == .notSent
                ? SentStep(state: .problem, title: String(localized: "Not sent to \(r.name)"), detail: detail, resend: r)
                : SentStep(state: .done,    title: String(localized: "Sent to \(r.name)"),     detail: detail))
        }
        let delivered = rs.filter { (outcomes[$0.id] ?? .notSent) != .notSent }
        if delivered.count == 1 {
            steps.append(SentStep(state: .waiting, title: String(localized: "\(delivered[0].name) signs"),
                                  detail: String(localized: "Waiting")))
        } else if delivered.count > 1 {
            steps.append(SentStep(state: .waiting, title: String(localized: "Everyone signs"),
                                  detail: delivered.map(\.name).formatted(.list(type: .and))))
        }
        steps.append(SentStep(state: .waiting, title: String(localized: "Signed copy comes back"),
                              detail: replyAddress.map { String(localized: "To \($0)") } ?? String(localized: "To you")))
        if !copyRecipients.isEmpty {
            steps.append(SentStep(state: .waiting, title: String(localized: "Send Copies"),
                                  detail: String(localized: "After everyone signs")))
        }
        return steps
    }

    private func timelineRow(_ step: SentStep, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                stepMarker(step.state)
                if !isLast {
                    Rectangle()
                        .fill(Color(.separator))
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, 3)
                }
            }
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.body)
                    .foregroundStyle(step.state == .waiting ? Color.secondaryInk : Color.primaryInk)
                if let d = step.detail {
                    Text(d)
                        .font(.footnote)
                        .foregroundStyle(step.state == .problem ? Color.orange : Color.secondaryInk)
                }
            }
            .padding(.bottom, isLast ? 0 : 22)
            Spacer(minLength: 8)
            if let r = step.resend {
                Button(String(localized: "Send")) { deliver([r]) }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accent)
                    .buttonStyle(.plain)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func stepMarker(_ state: StepState) -> some View {
        switch state {
        case .done:
            Image("ph-check")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.onInk)
                .frame(width: 20, height: 20)
                .background(Color.ink, in: Circle())
        case .waiting:
            Circle()
                .strokeBorder(Color(.tertiaryLabel), lineWidth: 1.5)
                .frame(width: 20, height: 20)
        case .problem:
            Image("ph-exclamation-mark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.orange, in: Circle())
        }
    }

    /// The steps come in one after another once the plane is drawn.
    private func revealSteps(_ n: Int) {
        guard revealedSteps == 0 else { return }
        if reduceMotion { revealedSteps = n; return }
        for i in 1...n {
            withAnimation(.easeOut(duration: 0.3).delay(0.9 + Double(i) * 0.12)) { revealedSteps = i }
        }
    }

    private var replyAddress: String? {
        let r = replyTo.trimmingCharacters(in: .whitespaces)
        return r.isEmpty ? nil : r
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

        await prepareDocuSeal()

        outcomes = [:]
        deliver(finalRecipients)
    }

    /// DocuSeal on: one submission, a submitter per box, before any link goes
    /// out. The sender's own Face ID signature completes their submitter. If
    /// DocuSeal can't be reached the send carries on with app links only
    /// (DocuSealSync retries the sender's part later if only that failed).
    private func prepareDocuSeal() async {
        guard Secrets.signingBackend == .docuseal, BackendClient.isConfigured else { return }
        isSigning = true
        defer { isSigning = false }

        let rs = finalRecipients
        let me = myName.trimmingCharacters(in: .whitespaces)
        let reply = replyTo.trimmingCharacters(in: .whitespaces)
        var parties: [DocuSealParty]
        if slots.isEmpty {
            parties = rs.map { r in
                DocuSealParty(role: Self.docuSealRole(for: r), name: r.name, email: r.email, phone: r.phone)
            }
        } else {
            parties = slots.indices.map { p in
                if p == mySlot {
                    return DocuSealParty(role: slots[p].role, name: me,
                                         email: reply.contains("@") ? reply : "",
                                         phone: reply.contains("@") ? "" : reply)
                }
                let r = rs.first { $0.party == p }
                return DocuSealParty(role: slots[p].role, name: r?.name ?? "", email: r?.email ?? "", phone: r?.phone ?? "")
            }
        }

        let latest = ContractStore.shared.contract(id: contract.id) ?? contract
        do {
            let ref = try await SigningProviders.startDocuSeal(contract: latest, parties: parties)
            docuSealRef = ref
            if let own = ownSignature, let role = own.role {
                let stamp = SignatureStamp(signerName: own.name, signedAt: own.signedAt, hash: own.hash, method: own.method)
                try? await SigningProviders.completeDocuSeal(ref: ref, role: role, signerName: own.name, stamp: stamp,
                                                             signedDate: own.date,
                                                             consentText: SigningView.consentText)
            }
        } catch {
            docuSealRef = nil
            print("DocuSeal start failed — sending app links only:", error.localizedDescription)
        }
    }

    /// The DocuSeal role a recipient signs as: their box's party, or, in a
    /// document without boxes, "Signer N" by their order.
    static func docuSealRole(for r: Recipient) -> String {
        r.partyRole ?? "Signer \((r.party ?? 0) + 1)"
    }

    /// This recipient's browser signing page, when DocuSeal is on.
    private func browserLink(for r: Recipient) -> String? {
        docuSealRef?.signingURL(role: Self.docuSealRole(for: r)).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Opens a compose sheet for each of these, one after another.
    private func deliver(_ rs: [Recipient]) {
        didSend = false
        sharedSomething = false
        roundShared = []
        queue = rs.map(Delivery.init)
        next()
    }

    /// One compose sheet per recipient, one after another.
    private func next() {
        guard !queue.isEmpty else { finish(); return }
        activeSheet = queue.removeFirst()
    }

    private func delivered(_ d: Delivery, sent: Bool, shared: Bool = false) {
        if sent   { didSend = true }
        if shared { sharedSomething = true }
        let id = d.recipient.id
        switch d.channel {
        case .sms(let phone)  where sent:   outcomes[id] = .messages(phone)
        case .mail(let email) where sent:   outcomes[id] = .mail(email)
        case .share           where shared: outcomes[id] = .shared; roundShared.append(id)
        default: if outcomes[id] == nil || outcomes[id] == .notSent { outcomes[id] = .notSent }
        }
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
                delivered(d, sent: r == .sent)
            }
            .ignoresSafeArea()
        case .mail(let email):
            MailComposeView(toRecipients: [email], subject: mailSubject, body: mailBody(for: d.recipient)) { r in
                delivered(d, sent: r == .sent || r == .saved)
            }
            .ignoresSafeArea()
        case .share:
            // Fallback for simulator / devices where compose sheets are
            // unavailable. One combined string, not [subject, body] — two
            // items makes the share sheet describe them as "2 Images".
            ActivityView(activityItems: ["\(mailSubject)\n\n\(mailBody(for: d.recipient))"]) { completed in
                delivered(d, sent: false, shared: completed)
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
            ContractStore.shared.markSent(id: contract.id, recipients: rs, copyRecipients: copyRecipients, providerRef: ref,
                                          partyCount: partyCount,
                                          replyTo: reply.isEmpty ? nil : reply,
                                          senderName: senderName,
                                          senderRole: slots.isEmpty ? nil : (mySlot.map { slots[$0].role } ?? ""),
                                          ownSignature: ownSignature)
            Haptics.success()
            withAnimation(.easeInOut(duration: 0.25)) { showSent = true }
        }

        let backend = Secrets.signingBackend
        guard backend != .onDevice, BackendClient.isConfigured else { mark(nil); return }
        // DocuSeal's submission was made before the links went out.
        if backend == .docuseal { mark(docuSealRef); return }

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
        // Only this recipient's DocuSeal submitter goes with their link.
        c.providerRef   = docuSealRef?.only(role: Self.docuSealRole(for: r))
        if let own = ownSignature {
            c.signatures.removeAll { $0.slot == own.slot }
            c.merge(signatures: [own])
        }
        // With the link page set up, recipients land there: the app if they
        // have it (universal link), otherwise Get Handshake or the browser.
        if let page = Config.linkPageURL {
            var fragment = "id=\(c.id.uuidString)&d=\(ContractTransfer.encode(c))"
            if let ds = browserLink(for: r),
               let q = ds.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
                fragment += "&ds=\(q)"
            }
            return "\(page)#\(fragment)"
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
        // The link page offers the app and the browser itself.
        if Config.linkPageURL != nil {
            if let senderName {
                return String(localized: "\(senderName) invited you to sign \"\(contract.title)\". Review and sign it here:\n\(link)")
            }
            return String(localized: "You've been invited to sign \"\(contract.title)\". Review and sign it here:\n\(link)")
        }
        var body: String
        if let senderName {
            body = String(localized: "\(senderName) invited you to sign \"\(contract.title)\". Open it in the Handshake app to review and sign with Face ID:\n\(link)")
        } else {
            body = String(localized: "You've been invited to sign \"\(contract.title)\". Open it in the Handshake app to review and sign with Face ID:\n\(link)")
        }
        if let web = browserLink(for: r) {
            body += "\n\n" + String(localized: "Don't have Handshake? Sign in your browser instead:\n\(web)")
        }
        return body
    }

    private var mailSubject: String { String(localized: "Please sign: \(contract.title)") }

    // The old closing line said the link was "unique to you"; now it is —
    // it opens the box this recipient signs.
    private func mailBody(for r: Recipient) -> String {
        let intro = senderName.map { String(localized: "\($0) invited you to review and sign the following agreement:") }
            ?? String(localized: "You've been invited to review and sign the following agreement:")
        let link = signingLink(for: r)
        if Config.linkPageURL != nil {
            return String(localized: """
                Hi,

                \(intro)

                \(contract.title)

                Tap the link below to review and sign:
                \(link)
                """)
        }
        let closing = browserLink(for: r).map { String(localized: "Don't have Handshake? Sign in your browser instead:\n\($0)") }
            ?? String(localized: "The link opens in Handshake, so you'll need the app installed on your iPhone or iPad.")
        return String(localized: """
            Hi,

            \(intro)

            \(contract.title)

            Tap the link below to open it in the Handshake app and sign with Face ID:
            \(link)

            \(closing)
            """)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - FillBlanksSheet
//
// One field per "[…]" blank, with the sentence it sits in. Name blanks the
// send screen already knows come pre-filled; the sender can change them.
// ─────────────────────────────────────────────────────────────────────────────

struct FillBlanksSheet: View {
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

    private func label(_ b: String) -> String { blankLabel(b) }

    private func focusNext(after b: String) {
        guard let i = blanks.firstIndex(of: b) else { return }
        focused = blanks.dropFirst(i + 1).first
        if focused == nil { dismiss() }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Delivery
// ─────────────────────────────────────────────────────────────────────────────

/// What became of one recipient's link.
private enum Outcome: Equatable {
    case messages(String), mail(String), shared, notSent
}

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
// MARK: - Parties
// ─────────────────────────────────────────────────────────────────────────────

/// "[FREELANCER FULL NAME]" → "Freelancer Full Name".
private func blankLabel(_ b: String) -> String {
    let inner = b.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    return inner == inner.uppercased() && inner != inner.lowercased() ? inner.capitalized : inner
}

/// The sheet's subject: a party (signature box), a signer in a document
/// without boxes, or a new signer being added.
private struct PartyEdit: Identifiable {
    let id = UUID()
    var party: Int?
    var recipientID: UUID?
    var adding = false
    var copyOnly = false
}

private enum PartyChoice {
    case me
    case person(name: String, contact: String)
    case nobody
}

/// Initials in a circle, Contacts-style; a dashed "+" for nobody yet.
private struct Monogram: View {
    let name: String
    var empty = false

    var body: some View {
        ZStack {
            if empty {
                Circle().strokeBorder(Color(.tertiaryLabel), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                Image("ph-plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.secondaryInk)
            } else {
                Circle().fill(Color(.systemGray4))
                Text(initials).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }

    private var initials: String {
        let s = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        return s.isEmpty ? "?" : s
    }
}

/// Who signs as one party: you, or someone — typed, picked from people
/// you've sent to before, or from Contacts. Adding a signer also asks what
/// they sign as; a box for them goes at the end of the contract.
private struct PartySheet: View {
    let role: String?
    let asksForRole: Bool
    let canBeMe: Bool
    let startsAsMe: Bool
    let name: String
    let contact: String
    let canRemove: Bool
    @Binding var myName: String
    let suggestions: [Recipient]
    var copyOnly = false
    var onSave: (PartyChoice, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isMe = false
    @State private var newRole = ""
    @State private var typedName = ""
    @State private var typedContact = ""
    @State private var invalidCopyAddress = false
    @FocusState private var focus: Field?
    private enum Field { case role, name, contact, myName }

    var body: some View {
        NavigationStack {
            Form {
                if asksForRole {
                    Section {
                        TextField("Witness, Guarantor…", text: $newRole)
                            .focused($focus, equals: .role)
                            .textInputAutocapitalization(.words)
                    } header: {
                        Text("Signs as")
                    } footer: {
                        Text("A signature box for them is added at the end of the contract.")
                    }
                }

                if canBeMe {
                    Section {
                        Button { withAnimation { isMe = true }; focus = nil } label: {
                            HStack(spacing: 12) {
                                Monogram(name: myName)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Me").foregroundStyle(Color.primaryInk)
                                    Text("You sign with \(SignatureService.biometryName) before it's sent.")
                                        .font(.footnote)
                                        .foregroundStyle(Color.secondaryInk)
                                }
                                Spacer()
                                if isMe { Image("ph-check").fontWeight(.semibold).foregroundStyle(Color.accent) }
                            }
                        }
                        if isMe {
                            TextField("Your full name", text: $myName)
                                .textContentType(.name)
                                .focused($focus, equals: .myName)
                        }
                    }
                }

                Section {
                    HStack {
                        TextField("Full name", text: $typedName)
                            .textContentType(.name)
                            .focused($focus, equals: .name)
                            .submitLabel(.next)
                            .onSubmit { focus = .contact }
                        if canBeMe, !isMe, !typedName.isEmpty || !typedContact.isEmpty {
                            Image("ph-check").fontWeight(.semibold).foregroundStyle(Color.accent)
                        }
                    }
                    TextField("Email or phone", text: $typedContact)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focus, equals: .contact)
                        .submitLabel(.done)
                        .onSubmit(save)
                    Button {
                        ContactPicking.pick { n, c in
                            typedName = n; typedContact = c
                            withAnimation { isMe = false }
                        }
                    } label: {
                        Label("Choose from Contacts", image: "ph-user-circle")
                    }
                } header: {
                    if canBeMe { Text("Someone else") }
                } footer: {
                    if invalidCopyAddress {
                        Text("Enter a valid email address or phone number.").foregroundStyle(Color.statusDeclined)
                    }
                }

                if !shownSuggestions.isEmpty {
                    Section("People you've sent to") {
                        ForEach(shownSuggestions) { r in
                            Button {
                                typedName = r.name
                                typedContact = SendFlowView.contact(of: r)
                                withAnimation { isMe = false }
                                focus = nil
                            } label: {
                                HStack(spacing: 12) {
                                    Monogram(name: r.name)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(r.name).foregroundStyle(Color.primaryInk)
                                        Text(SendFlowView.contact(of: r))
                                            .font(.footnote)
                                            .foregroundStyle(Color.secondaryInk)
                                    }
                                }
                            }
                        }
                    }
                }

                if canRemove {
                    Section {
                        Button(copyOnly ? String(localized: "Don't Send a Copy") : String(localized: "Remove Signer"), role: .destructive) {
                            onSave(.nobody, ""); dismiss()
                        }
                    }
                }
            }
            .onChange(of: focus) { _, f in
                if f == .name || f == .contact { withAnimation { isMe = false } }
            }
            .onChange(of: typedContact) { _, _ in invalidCopyAddress = false }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: save).fontWeight(.semibold)
                }
            }
            .onAppear {
                isMe = startsAsMe
                typedName = name
                typedContact = contact
                if asksForRole { focus = .role }
                else if !startsAsMe && name.isEmpty { focus = .name }
            }
        }
    }

    private var title: String {
        if copyOnly { return name.isEmpty ? String(localized: "Send a Copy") : String(localized: "Edit Copy") }
        if asksForRole || (role == nil && name.isEmpty) { return String(localized: "Add Signer") }
        return role ?? String(localized: "Signer")
    }

    /// Filtered by what's typed; the first few when nothing is.
    private var shownSuggestions: [Recipient] {
        let q = typedName.trimmingCharacters(in: .whitespaces).lowercased()
        let list = q.isEmpty ? suggestions : suggestions.filter {
            $0.name.lowercased().contains(q) || SendFlowView.contact(of: $0).lowercased().contains(q)
        }
        return Array(list.filter { $0.name != typedName || SendFlowView.contact(of: $0) != typedContact }.prefix(4))
    }

    private func save() {
        let n = typedName.trimmingCharacters(in: .whitespaces)
        let c = typedContact.trimmingCharacters(in: .whitespaces)
        let r = newRole.trimmingCharacters(in: .whitespaces)
        if copyOnly {
            guard !n.isEmpty else { focus = .name; return }
            guard CopyRecipient.isValidAddress(c) else {
                invalidCopyAddress = true
                focus = .contact
                return
            }
        }
        if asksForRole && r.isEmpty { focus = .role; return }
        if canBeMe && isMe {
            onSave(.me, r)
        } else if !(n.isEmpty && c.isEmpty) {
            onSave(.person(name: n, contact: c), r)
        }
        // Nothing entered: the party stays as it was.
        dismiss()
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
