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
                ContractWorkspaceView(initialPrompt: draft.title, existing: draft)
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

                StatusBadge(status: contract.status, incoming: contract.isIncoming)
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

    private var label: String {
        incoming && status == .sent ? String(localized: "To Sign") : status.label
    }

    private var color: Color {
        switch status {
        case .draft:    return Color(.secondaryLabel)
        case .sent:     return Color.brand
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
    @Environment(\.dismiss) private var dismiss

    init(contract: GeneratedContract) {
        self.contract = contract
        _attributedBody = State(initialValue: contract.displayBody())
    }

    /// A contract this phone signed for someone else. "Not now" on the
    /// confirmation screen used to be the last chance to send the signed
    /// copy back; now it's here for as long as the contract is.
    private var canSendBack: Bool {
        contract.isIncoming && contract.status == .signed
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
                        StatusBadge(status: contract.status, incoming: contract.isIncoming)
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
                .padding(.bottom, 40)
                .readableColumn(Layout.readableWidth + 32)
            }
            .background(Color.pageBackground.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if canSendBack {
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
            ActivityView(activityItems: [SigningConfirmationView.returnMessage(for: contract)]) { _ in
                showShare = false
            }
            .presentationDetents([.medium, .large])
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Display body helper
// RTFD (rich edits) wins over markdown source when present.
// ─────────────────────────────────────────────────────────────────────────────

extension GeneratedContract {
    func displayBody() -> NSMutableAttributedString {
        if let data = bodyRTFD,
           let attr = try? NSMutableAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.rtfd],
               documentAttributes: nil
           ) {
            attr.applyAttachmentSizes(attachmentSizes)
            attr.adaptTextColorsToAppearance()
            attr.redrawSignatureFieldBoxes()
            return attr
        }
        return .fromHandshakeMarkdown(content)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Preview
// ─────────────────────────────────────────────────────────────────────────────

#Preview {
    HistoryView()
}
