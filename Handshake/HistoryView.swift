import SwiftUI
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - HistoryView
//
// Contract history, grouped by status:
//   Waiting for You · Pending Signature · Signed · Drafts
//
// Waiting for You: contracts that came in by link and aren't signed yet —
//   tap to open the signing screen. Before, these sat under "Pending
//   Signature" and opened read-only, so a recipient who closed the signing
//   screen once had no way back to sign except the original link.
// Drafts: swipe-to-delete, tap to reopen in the workspace (editable).
// Sent / signed: tap to view read-only.
// ─────────────────────────────────────────────────────────────────────────────

struct HistoryView: View {

    @State private var store = ContractStore.shared
    @State private var openDraft:    GeneratedContract? = nil
    @State private var viewContract: GeneratedContract? = nil
    @State private var signContract: GeneratedContract? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.isEmpty {
                    emptyState
                } else {
                    contractList
                }
            }
            .background(Color.pageBackground)
            .navigationTitle("Contracts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.body.weight(.semibold))
                }
            }
        }
        // Draft → reopen the full workspace (editable, AI panel available)
        .fullScreenCover(item: $openDraft) { draft in
            NavigationStack {
                // A revision that hasn't gone back out yet keeps what was
                // asked for in the chat bar, so it isn't lost on reopening.
                ContractWorkspaceView(initialPrompt: draft.title, existing: draft,
                                      prefillPrompt: draft.changeRequest.map {
                                          String(localized: "\($0.by) asked for these changes: \($0.text)")
                                      })
            }
        }
        // Sent / signed → read-only viewer
        .sheet(item: $viewContract) { contract in
            ReadOnlyContractView(contract: contract)
        }
        // Received, not yet signed → the signing screen
        .fullScreenCover(item: $signContract) { contract in
            SigningView(contract: contract)
        }
    }

    private var toSign:  [GeneratedContract] { store.pending.filter(\.isIncoming) }
    private var waiting: [GeneratedContract] { store.pending.filter { !$0.isIncoming } }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - List
    // ─────────────────────────────────────────────────────────────────────────

    private var contractList: some View {
        List {
            if !toSign.isEmpty {
                Section("Waiting for You") {
                    ForEach(toSign) { c in
                        ContractRow(contract: c) { signContract = c }
                    }
                }
            }

            if !waiting.isEmpty {
                Section("Pending Signature") {
                    ForEach(waiting) { c in
                        ContractRow(contract: c) { viewContract = c }
                    }
                }
            }

            if !store.completed.isEmpty {
                Section("Signed") {
                    ForEach(store.completed) { c in
                        ContractRow(contract: c) { viewContract = c }
                    }
                }
            }

            if !store.declined.isEmpty {
                Section("Declined") {
                    ForEach(store.declined) { c in
                        ContractRow(contract: c) { viewContract = c }
                    }
                }
            }

            if !store.drafts.isEmpty {
                Section("Drafts") {
                    ForEach(store.drafts) { c in
                        ContractRow(contract: c) { openDraft = c }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    store.delete(id: c.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Empty state
    // ─────────────────────────────────────────────────────────────────────────

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.secondary)
            Text("No contracts yet")
                .font(.title3.weight(.semibold))
            Text("Contracts you create will show up here —\ndrafts, pending signatures, and signed.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ContractRow
// ─────────────────────────────────────────────────────────────────────────────

private struct ContractRow: View {
    let contract: GeneratedContract
    var onTap: () -> Void

    private var subtitle: String {
        // On a recipient's phone the recipients are themselves; who it came
        // from is the useful line.
        if contract.isIncoming {
            return contract.senderName.map { String(localized: "From \($0)") }
                ?? String(localized: "Received")
        }
        let names = contract.recipients
            .map(\.name)
            .filter { !$0.isEmpty }
        return names.isEmpty ? String(localized: "No recipients") : names.formatted(.list(type: .and))
    }

    private var displayDate: Date {
        switch contract.status {
        case .draft:            return contract.createdAt
        case .sent:             return contract.sentAt   ?? contract.createdAt
        case .signed, .declined: return contract.signedAt ?? contract.createdAt
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(contract.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color(.label))
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(subtitle)
                            .lineLimit(1)
                        Text("·")
                        Text(displayDate, format: .relative(presentation: .named))
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                StatusBadge(contract: contract)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - StatusBadge
// ─────────────────────────────────────────────────────────────────────────────

struct StatusBadge: View {
    let status: ContractStatus
    /// A contract that came in to be signed reads "To Sign", not "Pending".
    var incoming: Bool = false
    /// Overrides for a whole contract: "1 of 2 Signed", "Changes Asked".
    private var override: (label: String, color: Color)? = nil

    init(status: ContractStatus, incoming: Bool = false) {
        self.status = status
        self.incoming = incoming
    }

    /// The badge for a contract, with where it's got to.
    init(contract c: GeneratedContract) {
        self.init(status: c.status, incoming: c.isIncoming)
        if !c.isIncoming, c.changeRequest != nil, c.status == .sent || c.status == .draft {
            override = (String(localized: "Changes Asked"), .orange)
        } else if let progress = c.progressLabel {
            override = (progress, Color.accent)
        }
    }

    private var label: String {
        override?.label ?? (incoming && status == .sent ? String(localized: "To Sign") : status.label)
    }

    private var color: Color {
        if let override { return override.color }
        switch status {
        case .draft:    return Color(.secondaryLabel)
        case .sent:     return Color.accent
        case .signed:   return Color.statusSigned
        case .declined: return Color.statusDeclined
        }
    }

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ReadOnlyContractView
// Viewer for sent / signed contracts — same document rendering as the
// workspace, but not editable and with no AI panel.
// ─────────────────────────────────────────────────────────────────────────────

struct ReadOnlyContractView: View {

    let contract: GeneratedContract

    @State private var attributedBody: NSMutableAttributedString
    @State private var editorHeight:   CGFloat = 300
    @State private var showShare = false
    @State private var showCopyDelivery = false
    @State private var revising: GeneratedContract? = nil
    @Environment(\.dismiss) private var dismiss

    private let slots: [SignatureSlots.Slot]

    init(contract: GeneratedContract) {
        self.contract = contract
        _attributedBody = State(initialValue: contract.baseBody())
        slots = contract.signatureSlots()
    }

    /// A contract this phone signed for someone else — or the sender's copy
    /// once everyone has signed, to send round. "Not now" on the
    /// confirmation screen used to be the last chance to send it.
    private var canShareSigned: Bool {
        contract.status == .signed && (contract.isIncoming || !contract.signatures.isEmpty)
    }

    /// Where the completed copy goes when the sender shares it: straight to
    /// the one recipient, or the share sheet for several.
    private var shareAddress: String? {
        if contract.isIncoming { return contract.replyTo }
        guard contract.recipients.count == 1, let r = contract.recipients.first else { return nil }
        return r.phone.isEmpty ? r.email : r.phone
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    HStack(alignment: .top) {
                        Text(contract.title)
                            .font(.title.weight(.bold))
                            .foregroundStyle(Color(.label))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        StatusBadge(contract: contract)
                            .padding(.top, 6)
                    }

                    if contract.status == .declined {
                        declinedBanner
                        // Revise and send again, the way DocuSign offers "Correct" on a declined envelope.
                        if !contract.isIncoming {
                            PrimaryPillButton(title: String(localized: "Revise Contract"), fullWidth: true) { revise() }
                        }
                    } else if let request = contract.changeRequest, !contract.isIncoming {
                        changesBanner(request)
                    }
                    if !contract.isIncoming, contract.status != .draft, !signers.isEmpty { signersCard }
                    if contract.canSendCCCopies {
                        Button("Send CC Copies") { showCopyDelivery = true }
                            .buttonStyle(.bordered)
                            .tint(Color.accent)
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
                    .onGeometryChange(for: CGFloat.self) {
                        min($0.size.width.rounded(.down), SignatureBlockView.maxWidth)
                    } action: { width in
                        guard width > 0, !contract.signatures.isEmpty else { return }
                        attributedBody = contract.displayBody(signatureWidth: width)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 40)
                .readableColumn(Layout.readableWidth + 32)
            }
            .background(Color.pageBackground.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if canShareSigned {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            showShare = true
                        } label: {
                            Label("Send Signed Copy", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.body.weight(.semibold))
                }
            }
        }
        .sheet(isPresented: $showShare) {
            ReplyComposeSheet(address: shareAddress,
                              subject: String(localized: "Signed: \(contract.title)"),
                              message: SigningConfirmationView.returnMessage(for: contract)) { _ in
                showShare = false
            }
        }
        .sheet(isPresented: $showCopyDelivery) {
            CopyDeliveryView(contract: contract)
        }
        .fullScreenCover(item: $revising, onDismiss: { dismiss() }) { draft in
            NavigationStack {
                ContractWorkspaceView(initialPrompt: draft.title, existing: draft,
                                      prefillPrompt: draft.changeRequest.map {
                                          String(localized: "\($0.by) asked for these changes: \($0.text)")
                                      })
            }
        }
    }

    // ── Who signs, and who has ───────────────────────────────────────────────

    private struct Signer: Identifiable {
        let id: Int
        let role: String?
        let name: String
        let signed: PartySignature?
    }

    /// One row per party: the recipient assigned to it, or the sender.
    private var signers: [Signer] {
        let count = contract.partyCount ?? slots.count
        guard count > 0 else { return [] }
        return (0..<count).map { i in
            let who = contract.recipients.first { $0.party == i }?.name
                ?? contract.signature(forSlot: i)?.name
                ?? String(localized: "You")
            return Signer(id: i,
                          role: slots.indices.contains(i) && slots.count > 1 ? slots[i].role : nil,
                          name: who,
                          signed: contract.signature(forSlot: i))
        }
    }

    private var signersCard: some View {
        VStack(spacing: 0) {
            ForEach(signers) { s in
                HStack(spacing: 12) {
                    Image(systemName: s.signed == nil ? "circle.dashed" : "checkmark.circle.fill")
                        .foregroundStyle(s.signed == nil ? Color(.tertiaryLabel) : Color.statusSigned)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name).font(.subheadline.weight(.semibold))
                        if let role = s.role {
                            Text(role).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Group {
                        if let sig = s.signed {
                            Text(sig.signedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        } else {
                            Text("Waiting")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                if s.id != signers.last?.id { Divider().padding(.leading, 48) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cardFill))
    }

    // ── Banners ──────────────────────────────────────────────────────────────

    private var declinedBanner: some View {
        Banner(icon: "xmark.circle.fill", tint: Color.statusDeclined,
               title: String(localized: "\(contract.declinedBy ?? String(localized: "The recipient")) declined to sign"),
               detail: contract.declineReason)
    }

    private func changesBanner(_ r: ChangeRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Banner(icon: "text.bubble.fill", tint: .orange,
                   title: String(localized: "\(r.by) asked for changes"),
                   detail: r.text)
            PrimaryPillButton(title: String(localized: "Revise Contract"), fullWidth: true) { revise() }
        }
    }

    /// Back to a draft so it can be edited and sent again. Signatures go:
    /// they were on the old wording.
    private func revise() {
        ContractStore.shared.update(id: contract.id) { c in
            c.status = .draft
            c.signatures = []
            c.signedBy = nil; c.signatureHash = nil
            c.declinedBy = nil; c.declineReason = nil
        }
        revising = ContractStore.shared.contract(id: contract.id)
    }
}

private struct Banner: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(Color.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Preview
// ─────────────────────────────────────────────────────────────────────────────

#Preview {
    HistoryView()
}
