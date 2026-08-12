import SwiftUI
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - HistoryView
//
// Contract history, grouped by status:
//   Pending Signature · Signed · Drafts
//
// Drafts: swipe-to-delete, tap to reopen in the workspace (editable).
// Sent / signed: tap to view read-only.
// ─────────────────────────────────────────────────────────────────────────────

struct HistoryView: View {

    @State private var store = ContractStore.shared
    @State private var openDraft:    GeneratedContract? = nil
    @State private var viewContract: GeneratedContract? = nil
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
            .background(Color(red: 0.98, green: 0.98, blue: 0.98))
            .navigationTitle("Contracts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 17, weight: .semibold))
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
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - List
    // ─────────────────────────────────────────────────────────────────────────

    private var contractList: some View {
        List {
            if !store.pending.isEmpty {
                Section("Pending Signature") {
                    ForEach(store.pending) { c in
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
                .font(.system(size: 20, weight: .semibold))
            Text("Contracts you create will show up here —\ndrafts, pending signatures, and signed.")
                .font(.system(size: 15))
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
        let names = contract.recipients
            .map(\.name)
            .filter { !$0.isEmpty }
        return names.isEmpty ? "No recipients" : names.joined(separator: ", ")
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
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color(.label))
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(subtitle)
                            .lineLimit(1)
                        Text("·")
                        Text(displayDate, format: .relative(presentation: .named))
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                StatusBadge(status: contract.status)
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

    private var color: Color {
        switch status {
        case .draft:    return Color(.secondaryLabel)
        case .sent:     return Color(red: 76/255, green: 0, blue: 255/255)   // #4C00FF
        case .signed:   return Color(red: 0.13, green: 0.60, blue: 0.28)
        case .declined: return Color(red: 0.80, green: 0.16, blue: 0.16)
        }
    }

    var body: some View {
        Text(status.label)
            .font(.system(size: 12, weight: .semibold))
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
    @Environment(\.dismiss) private var dismiss

    init(contract: GeneratedContract) {
        self.contract = contract
        _attributedBody = State(initialValue: contract.displayBody())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    HStack(alignment: .top) {
                        Text(contract.title)
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(Color(.label))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
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
                .padding(.bottom, 40)
            }
            .background(Color(red: 0.98, green: 0.98, blue: 0.98).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 17, weight: .semibold))
                }
            }
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
