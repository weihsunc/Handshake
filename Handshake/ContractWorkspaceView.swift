import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ContractWorkspaceView
//
// Architecture:
//   ZStack (bottom-aligned)
//     ├── Background
//     ├── Contract scroll view          (zIndex 0)
//     ├── Custom draggable AI panel     (zIndex 1) — snaps large ↔ medium ↔ dismissed
//     └── Hero ChatBar                  (zIndex 2) — NEVER moves, always on top
//
// The ChatBar is NOT inside the AI panel. It lives above it in the ZStack,
// so dragging the panel never affects the ChatBar.
// ─────────────────────────────────────────────────────────────────────────────

struct ContractWorkspaceView: View {

    let initialPrompt: String
    /// When set, the workspace opens this saved contract instead of generating
    /// a new one (used by HistoryView for drafts).
    var existing: GeneratedContract? = nil

    // ── AI state ──────────────────────────────────────────────────────────────
    @State private var messages:     [ChatMessage] = []
    @State private var isLoading:    Bool          = false
    @State private var isAILoading:  Bool          = false
    @State private var errorText:    String?       = nil
    @State private var aiChatPrompt: String        = ""
    @State private var showAIPanel:       Bool  = true
    @State private var showSendFlow:      Bool  = false
    @State private var showImagePicker:   Bool  = false
    @State private var showDocumentPicker: Bool = false

    // ── Panel drag state ──────────────────────────────────────────────────────
    /// Measured content-area height (set once by GeometryReader; excludes nav bar).
    @State private var contentH:     CGFloat = 0
    @State private var panelHeight:  CGFloat = 600   // overwritten in onAppear
    @State private var dragOffset:   CGFloat = 0

    // ── Contract / editor state ───────────────────────────────────────────────
    @State private var contract:       GeneratedContract?      = nil
    @State private var attributedBody: NSMutableAttributedString = NSMutableAttributedString()
    @State private var editorHeight:   CGFloat                 = 300
    @State private var isEditing:      Bool                    = false
    @State private var textViewRef:    UITextView?             = nil

    @Environment(\.dismiss) private var dismiss

    // ── Layout constants ──────────────────────────────────────────────────────
    /// Spacing reserved at the bottom for the floating ChatBar pill + safe area
    private static let chatBarH: CGFloat = 90
    /// Small gap between panel top and navigation bar — keeps the drag handle
    /// clearly in the content area, never behind nav buttons.
    private static let panelTopGap: CGFloat  = 10

    /// Large: fills the entire content area (GeometryReader-measured, NOT screen height).
    private var largePanelH: CGFloat  { max(300, contentH - Self.chatBarH - Self.panelTopGap) }
    /// Medium: roughly 46% of the content area.
    private var mediumPanelH: CGFloat { max(200, contentH * 0.46) }

    /// Title shown before the contract exists. The prompt's first few words read
    /// as a sentence fragment in the nav bar ("Create a contract for a"), so use
    /// a neutral placeholder until the AI returns a real title.
    private var sheetTitle: String { "New Agreement" }

    /// Status as the store sees it. SendFlowView marks the contract sent while
    /// this workspace is still open, and the local `contract` copy doesn't
    /// learn about it until the next persist() — so read the store directly.
    private var liveStatus: ContractStatus {
        guard let id = contract?.id else { return .draft }
        return ContractStore.shared.contract(id: id)?.status ?? .draft
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Body
    // ─────────────────────────────────────────────────────────────────────────

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {

                // ── 0: Background ──────────────────────────────────────────────
                Color(red: 0.98, green: 0.98, blue: 0.98)
                    .ignoresSafeArea()

                // ── 0: Contract document ───────────────────────────────────────
                if let c = contract {
                    contractScrollView(c)
                        .transition(.opacity)
                        .zIndex(0)
                }

                // ── 1: Custom draggable AI panel ───────────────────────────────
                if showAIPanel {
                    aiPanel
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(1)
                }

                // ── 2: Hero ChatBar — always on top, never moves ───────────────
                heroChatBar
                    .zIndex(2)
            }
            .animation(.easeInOut(duration: 0.4), value: contract != nil)
            .animation(.spring(response: 0.38, dampingFraction: 0.8), value: showAIPanel)
            .onAppear {
                guard contentH == 0 else { return }
                contentH    = geo.size.height
                panelHeight = largePanelH
            }
        }
        // ── Custom top bar injected into the safe area so it never squashes ───
        // SwiftUI's ToolbarItem(.navigationBarTrailing) clamps any custom-styled
        // view to an icon-square. Moving the bar into safeAreaInset gives it full
        // SwiftUI layout and lets PurplePillButton size itself to its content.
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    if isEditing { isEditing = false } else { dismiss() }
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 17, weight: .semibold))
                }
            }
            ToolbarItem(placement: .principal) {
                Text(contract?.title ?? sheetTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(.label))
                    .lineLimit(1)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if isEditing {
                    Button("Done") { isEditing = false }
                        .font(.system(size: 17, weight: .semibold))
                } else if contract != nil && liveStatus != .signed {
                    ToolbarPillButton(title: "Send") { showSendFlow = true }
                } else if contract != nil {
                    StatusBadge(status: .signed)
                } else {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showSendFlow) {
            if let c = contract {
                SendFlowView(contract: c)
            }
        }
        .sheet(isPresented: $showImagePicker) {
            PhotoPickerView { image in
                showImagePicker = false
                insertImage(image)
            }
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPickerView { url in
                showDocumentPicker = false
                insertAttachmentPlaceholder(url: url)
            }
        }
        .task { await generateInitial() }
        .onDisappear { persist() }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Contract scroll view
    // ─────────────────────────────────────────────────────────────────────────

    @ViewBuilder
    private func contractScrollView(_ c: GeneratedContract) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                HStack(alignment: .top) {
                    Text(c.title)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Color(.label))
                        .fixedSize(horizontal: false, vertical: true)
                    if liveStatus != .draft {
                        Spacer(minLength: 8)
                        StatusBadge(status: liveStatus)
                            .padding(.top, 6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                GeometryReader { geo in
                    RichTextEditorImpl(
                        attributedText:  $attributedBody,
                        dynamicHeight:   $editorHeight,
                        isEditing:       isEditing,
                        availableWidth:  geo.size.width,
                        onReady:         { tv in textViewRef = tv },
                        onEditingBegan:  { isEditing = true }
                    )
                }
                .frame(height: editorHeight)
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, Self.chatBarH + 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: isEditing) { _, editing in
            if !editing {
                textViewRef?.resignFirstResponder()
                persist()   // auto-save manual edits when leaving edit mode
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Hero ChatBar (zIndex 2)
    //
    // Intentionally NO background fill — only the pill itself (rendered inside
    // ChatBar / FormattingToolbar) has a surface. Everything around the pill is
    // fully transparent so the contract or the AI panel show through.
    // ─────────────────────────────────────────────────────────────────────────

    private var heroChatBar: some View {
        VStack(spacing: 0) {
            if isEditing {
                FormattingToolbar { action in handleFormat(action) }
                    .padding(.bottom, 2)    // small gap above keyboard
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                ChatBar(prompt: $aiChatPrompt, onSend: {
                    // Re-open panel when user sends a message after dismissing it
                    if !showAIPanel {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                            panelHeight = mediumPanelH
                            showAIPanel = true
                        }
                    }
                    sendToAI()
                })
                .padding(.horizontal, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Bottom padding clears the home indicator safe area
        .padding(.bottom, 34)
        .animation(.easeInOut(duration: 0.22), value: isEditing)
        // No background — transparent outside the pill
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Custom draggable AI panel (zIndex 1)
    // ─────────────────────────────────────────────────────────────────────────

    private var aiPanel: some View {
        // VStack: panel content on top, solid cover below.
        // The cover fills the gap from the panel bottom to the screen edge so
        // the contract never bleeds through underneath the ChatBar.
        VStack(spacing: 0) {

            // ── Rounded panel card ────────────────────────────────────────────
            VStack(spacing: 0) {

                // Drag handle
                Capsule()
                    .fill(.secondary.opacity(0.35))
                    .frame(width: 36, height: 5)
                    .padding(.top, 8)
                    .padding(.bottom, 8)

                // Message list
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {

                            ForEach(messages) { msg in
                                MessageBubble(message: msg).id(msg.id)
                            }

                            if isLoading || isAILoading {
                                HStack(spacing: 8) {
                                    ProgressView().scaleEffect(0.75)
                                    Text("Working on it…")
                                        .font(.system(size: 15))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 16)
                                .id("loading")
                            }

                            if let err = errorText {
                                Text(err)
                                    .font(.system(size: 15))
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 16)
                            }

                            Color.clear.frame(height: 16)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                    }
                    .onChange(of: messages.count) { _, _ in
                        withAnimation {
                            if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                    .onChange(of: isLoading) { _, loading in
                        withAnimation { if loading { proxy.scrollTo("loading", anchor: .bottom) } }
                    }
                    .onChange(of: isAILoading) { _, loading in
                        withAnimation { if loading { proxy.scrollTo("loading", anchor: .bottom) } }
                    }
                }
            }
            .frame(height: max(120, panelHeight - dragOffset))
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.12), radius: 20, y: -6)
            )

            // ── Solid cover — hides contract content below the panel ──────────
            // Same material as the panel so the surface looks continuous.
            // ChatBar (zIndex 2) floats above this invisibly.
            Rectangle()
                .fill(.regularMaterial)
                .frame(height: Self.chatBarH)
                .ignoresSafeArea(edges: .bottom)
        }
        .gesture(panelDragGesture)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Panel drag gesture
    // ─────────────────────────────────────────────────────────────────────────

    private var panelDragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let delta = value.translation.height
                let projected = panelHeight - delta
                // Cap upward expansion at the large detent
                if projected <= largePanelH {
                    dragOffset = delta
                }
            }
            .onEnded { value in
                // Use predicted end for a snappy feel on fast flicks
                let projectedH = panelHeight - value.predictedEndTranslation.height
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    dragOffset = 0
                    let midpoint = (largePanelH + mediumPanelH) / 2
                    if projectedH < 160 {
                        showAIPanel = false            // flicked away
                    } else if projectedH < midpoint {
                        panelHeight = mediumPanelH    // snap to medium
                    } else {
                        panelHeight = largePanelH     // snap to large
                    }
                }
            }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Initial generation
    // ─────────────────────────────────────────────────────────────────────────

    private func generateInitial() async {
        // ── Reopening a saved draft: load it, skip generation ────────────────
        if let saved = existing {
            await MainActor.run {
                contract       = saved
                attributedBody = saved.displayBody()
                messages.append(ChatMessage(
                    content: "Welcome back! Keep editing directly on the contract, or ask me to update it for you.",
                    isUser: false
                ))
                // Document front and center; chat bar re-opens the panel on demand
                showAIPanel = false
            }
            return
        }

        messages.append(ChatMessage(content: initialPrompt, isUser: true))
        isLoading = true
        errorText = nil

        do {
            let result = try await AIService.generateContract(for: initialPrompt)
            await MainActor.run {
                isLoading      = false
                contract       = result
                attributedBody = .fromHandshakeMarkdown(result.content)
                persist()   // save immediately — a generated contract is a draft

                messages.append(ChatMessage(
                    content: "Created! Feel free to edit directly on the contract or ask me to update it for you!",
                    isUser: false
                ))

                // Drop panel to medium so the contract is visible behind it
                withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
                    panelHeight = mediumPanelH
                }
            }
        } catch {
            await MainActor.run {
                isLoading = false
                errorText = error.localizedDescription
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Persistence
    // Serializes the current rich-text body to RTFD (preserves formatting and
    // inline images) and upserts the contract into the store.
    // ─────────────────────────────────────────────────────────────────────────

    private func persist() {
        guard var c = contract else { return }
        let body = NSAttributedString(attributedString: attributedBody)
        if body.length > 0 {
            c.bodyRTFD = try? body.data(
                from: NSRange(location: 0, length: body.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
            )
        }
        // Status metadata is owned by the store (SendFlow may have marked this
        // contract sent while the workspace was open) — never regress it here.
        if let stored = ContractStore.shared.contract(id: c.id) {
            c.recipients = stored.recipients
            c.status     = stored.status
            c.sentAt     = stored.sentAt
            c.signedAt   = stored.signedAt
        }
        contract = c
        ContractStore.shared.upsert(c)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Follow-up message
    // ─────────────────────────────────────────────────────────────────────────

    private func sendToAI() {
        let text = aiChatPrompt.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        aiChatPrompt = ""

        messages.append(ChatMessage(content: text, isUser: true))
        isAILoading = true
        errorText   = nil

        let history = messages
            .map { $0.isUser ? "User: \($0.content)" : "Assistant: \($0.content)" }
            .joined(separator: "\n\n")

        Task {
            do {
                let result = try await AIService.generateContract(for: history)
                await MainActor.run {
                    isAILoading    = false
                    // Keep the same contract identity (and metadata) across AI
                    // updates — otherwise every update would create a new draft.
                    if var updated = contract {
                        updated.title    = result.title
                        updated.content  = result.content
                        updated.bodyRTFD = nil   // body regenerated from markdown
                        contract = updated
                    } else {
                        contract = result
                    }
                    attributedBody = .fromHandshakeMarkdown(result.content)
                    persist()
                    messages.append(ChatMessage(
                        content: "Updated! Feel free to keep editing or ask me for more changes.",
                        isUser: false
                    ))
                }
            } catch {
                await MainActor.run {
                    isAILoading = false
                    errorText   = error.localizedDescription
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Format dispatch
    // ─────────────────────────────────────────────────────────────────────────

    private func handleFormat(_ action: FormatAction) {
        switch action {
        case .bold:             applyTrait(.traitBold)
        case .italic:           applyTrait(.traitItalic)
        case .underline:        applyUnderline()
        case .heading1:         applyHeading(size: 26)
        case .heading2:         applyHeading(size: 20)
        case .bulletList:       applyList(numbered: false)
        case .numberedList:     applyList(numbered: true)
        case .alignLeft:        applyAlignment(.left)
        case .alignCenter:      applyAlignment(.center)
        case .alignRight:       applyAlignment(.right)
        case .insertImage:      showImagePicker = true
        case .insertAttachment: showDocumentPicker = true
        case .insertSignature:  insertSignaturePlaceholder()
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Text formatting helpers
    // All operate directly on UITextView.textStorage so the cursor never jumps.
    // ─────────────────────────────────────────────────────────────────────────

    private func applyTrait(_ trait: UIFontDescriptor.SymbolicTraits) {
        guard let tv = textViewRef, tv.selectedRange.length > 0 else { return }
        let range = tv.selectedRange
        tv.textStorage.beginEditing()
        tv.textStorage.enumerateAttribute(.font, in: range) { value, sub, _ in
            let cur    = (value as? UIFont) ?? UIFont.systemFont(ofSize: 17)
            let has    = cur.fontDescriptor.symbolicTraits.contains(trait)
            var traits = cur.fontDescriptor.symbolicTraits
            if has { traits.remove(trait) } else { traits.insert(trait) }
            let desc   = cur.fontDescriptor.withSymbolicTraits(traits) ?? cur.fontDescriptor
            tv.textStorage.addAttribute(.font, value: UIFont(descriptor: desc, size: cur.pointSize), range: sub)
        }
        tv.textStorage.endEditing()
        attributedBody = NSMutableAttributedString(attributedString: tv.textStorage)
    }

    private func applyUnderline() {
        guard let tv = textViewRef, tv.selectedRange.length > 0 else { return }
        let range = tv.selectedRange
        tv.textStorage.beginEditing()
        let has = tv.textStorage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) != nil
        if has {
            tv.textStorage.removeAttribute(.underlineStyle, range: range)
        } else {
            tv.textStorage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }
        tv.textStorage.endEditing()
        attributedBody = NSMutableAttributedString(attributedString: tv.textStorage)
    }

    private func applyHeading(size: CGFloat) {
        guard let tv = textViewRef else { return }
        let nsText = tv.text as NSString
        let range = tv.selectedRange.length > 0
            ? tv.selectedRange
            : nsText.paragraphRange(for: tv.selectedRange)
        tv.textStorage.beginEditing()
        tv.textStorage.enumerateAttribute(.font, in: range) { value, sub, _ in
            let cur    = (value as? UIFont) ?? UIFont.systemFont(ofSize: 17)
            var traits = cur.fontDescriptor.symbolicTraits
            traits.insert(.traitBold)
            let desc   = cur.fontDescriptor.withSymbolicTraits(traits) ?? cur.fontDescriptor
            tv.textStorage.addAttribute(.font, value: UIFont(descriptor: desc, size: size), range: sub)
        }
        tv.textStorage.endEditing()
        attributedBody = NSMutableAttributedString(attributedString: tv.textStorage)
    }

    private func applyList(numbered: Bool) {
        guard let tv = textViewRef else { return }
        let nsText = tv.text as NSString
        var sel = tv.selectedRange
        if sel.length == 0 { sel = nsText.paragraphRange(for: sel) }

        var ranges: [NSRange] = []
        var loc = sel.location
        while loc < sel.location + sel.length {
            let r = nsText.paragraphRange(for: NSRange(location: loc, length: 0))
            ranges.append(r); loc = r.location + r.length
        }
        if ranges.isEmpty { ranges.append(nsText.paragraphRange(for: sel)) }

        tv.textStorage.beginEditing()
        for (i, r) in ranges.enumerated().reversed() {
            let prefix = numbered ? "\(ranges.count - i). " : "• "
            tv.textStorage.insert(NSAttributedString(string: prefix, attributes: baseAttrs()), at: r.location)
        }
        tv.textStorage.endEditing()
        attributedBody = NSMutableAttributedString(attributedString: tv.textStorage)
    }

    private func applyAlignment(_ alignment: NSTextAlignment) {
        guard let tv = textViewRef else { return }
        let nsText = tv.text as NSString
        let range = tv.selectedRange.length > 0
            ? tv.selectedRange
            : nsText.paragraphRange(for: tv.selectedRange)
        tv.textStorage.beginEditing()
        tv.textStorage.enumerateAttributes(in: range, options: []) { _, sub, _ in
            let existing = tv.textStorage.attribute(.paragraphStyle, at: sub.location, effectiveRange: nil)
            let para: NSMutableParagraphStyle
            if let e = existing as? NSParagraphStyle {
                para = e.mutableCopy() as! NSMutableParagraphStyle
            } else {
                para = NSMutableParagraphStyle(); para.lineSpacing = 3
            }
            para.alignment = alignment
            tv.textStorage.addAttribute(.paragraphStyle, value: para, range: sub)
        }
        tv.textStorage.endEditing()
        attributedBody = NSMutableAttributedString(attributedString: tv.textStorage)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Insert helpers
    // ─────────────────────────────────────────────────────────────────────────

    private func insertImage(_ image: UIImage) {
        guard let tv = textViewRef else { return }
        let attachment = NSTextAttachment()
        let maxW = tv.textContainer.size.width
        let scale = maxW / max(image.size.width, 1)
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: 0, width: maxW, height: image.size.height * scale)
        let attrImg = NSMutableAttributedString(attachment: attachment)
        // Wrap with newlines so it sits on its own line
        attrImg.insert(NSAttributedString(string: "\n", attributes: baseAttrs()), at: 0)
        attrImg.append(NSAttributedString(string: "\n", attributes: baseAttrs()))
        tv.textStorage.beginEditing()
        tv.textStorage.insert(attrImg, at: tv.selectedRange.location)
        tv.textStorage.endEditing()
        attributedBody = NSMutableAttributedString(attributedString: tv.textStorage)
    }

    private func insertAttachmentPlaceholder(url: URL) {
        guard let tv = textViewRef else { return }
        let name = url.lastPathComponent
        let block = "\n📎 \(name)\n"
        let attrs: [NSAttributedString.Key: Any] = [
            .font:            UIFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: UIColor.systemBlue
        ]
        let attrStr = NSAttributedString(string: block, attributes: attrs)
        tv.textStorage.beginEditing()
        tv.textStorage.insert(attrStr, at: tv.selectedRange.location)
        tv.textStorage.endEditing()
        attributedBody = NSMutableAttributedString(attributedString: tv.textStorage)
    }

    private func insertSignaturePlaceholder() {
        guard let tv = textViewRef else { return }
        let block = "\n\n────────────────────────\nSignature          Date\n\n"
        let attrs: [NSAttributedString.Key: Any] = [
            .font:            UIFont.systemFont(ofSize: 14),
            .foregroundColor: UIColor.secondaryLabel
        ]
        let attrStr = NSAttributedString(string: block, attributes: attrs)
        tv.textStorage.beginEditing()
        tv.textStorage.insert(attrStr, at: tv.selectedRange.location)
        tv.textStorage.endEditing()
        attributedBody = NSMutableAttributedString(attributedString: tv.textStorage)
    }

    private func baseAttrs() -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle(); para.lineSpacing = 3
        return [.font: UIFont.systemFont(ofSize: 17),
                .foregroundColor: UIColor.label,
                .paragraphStyle: para]
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Preview
// ─────────────────────────────────────────────────────────────────────────────

#Preview {
    NavigationStack {
        ContractWorkspaceView(initialPrompt: "Create an NDA between Apple and Wei for 1 year")
    }
}
