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
    @State private var pickedPhoto: PhotosPickerItem? = nil
    @State private var showDocumentPicker: Bool = false

    // ── Panel drag state ──────────────────────────────────────────────────────
    /// Measured content-area height (set once by GeometryReader; excludes nav bar).
    @State private var contentH:     CGFloat = 0
    /// The content area as it is *right now* — shrinks while the keyboard is
    /// up. The detents are sized from contentH (stable); this clamps the panel
    /// so a medium panel over the keyboard can't climb under the nav bar.
    @State private var liveH:        CGFloat = 0
    /// Which detent the panel rests at. A detent, not a height: the heights
    /// depend on contentH, which isn't measured until onAppear, and a draft
    /// reopened before that used to land at the 200 pt floor instead of medium.
    @State private var detent:       PanelDetent = .large
    @State private var dragOffset:   CGFloat = 0
    /// Is the message list scrolled to its top? At large, a downward drag
    /// from the top collapses the panel instead of bouncing the list.
    @State private var listAtTop:    Bool = true

    enum PanelDetent { case medium, large }
    private var panelHeight: CGFloat { detent == .large ? largePanelH : mediumPanelH }
    /// What the panel card actually renders at: the detent (plus any drag),
    /// never taller than what fits above the chat bar in the current layout.
    private var clampedPanelHeight: CGFloat {
        let wanted = max(120, panelHeight - dragOffset)
        guard liveH > 0 else { return wanted }
        return min(wanted, max(120, liveH - Self.chatBarH - Self.panelTopGap))
    }

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
                Color.pageBackground
                    .ignoresSafeArea()

                // ── 0: Contract document ───────────────────────────────────────
                if let c = contract {
                    contractScrollView(c)
                        .transition(.opacity)
                        .zIndex(0)
                } else if isLoading {
                    // ~20 s of blank page while the first draft generates was
                    // the worst moment of the first-run flow. A document-shaped
                    // skeleton says "something is coming, here".
                    GeneratingSkeleton()
                        .readableColumn(Layout.readableWidth + 32)
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
            // The first layout inside a fullScreenCover reports a zero
            // height, so onAppear alone left contentH at 0 and both detents
            // at their floors (200 / 300 pt) — "large" was barely taller
            // than "medium". Take the first real measurement, whenever it comes.
            .onAppear {
                if contentH == 0, geo.size.height > 0 { contentH = geo.size.height }
            }
            .onChange(of: geo.size.height) { _, h in
                if contentH == 0, h > 0 { contentH = h }
                liveH = h
            }
        }
        // ── Custom top bar injected into the safe area so it never squashes ───
        // SwiftUI's ToolbarItem(.navigationBarTrailing) clamps any custom-styled
        // view to an icon-square. Moving the bar into safeAreaInset gives it full
        // SwiftUI layout and lets PurplePillButton size itself to its content.
        .navigationBarBackButtonHidden(true)
        // The system title, not a principal Text: iOS 26 lays a custom
        // principal item out at its full width when the first layout already
        // has a long title (a reopened draft), and it ran under "Send".
        .navigationTitle(contract?.title ?? sheetTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    if isEditing { isEditing = false } else { dismiss() }
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.body.weight(.semibold))
                }
                .accessibilityLabel(isEditing ? "Stop editing" : "Back")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if isEditing {
                    Button("Done") { isEditing = false }
                        .font(.body.weight(.semibold))
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
        // System pickers, owned by SwiftUI. The old UIKit bridges sat inside a
        // .sheet and dismissed themselves; SwiftUI then dismissed again and
        // took the whole workspace with it.
        .photosPicker(isPresented: $showImagePicker, selection: $pickedPhoto, matching: .images)
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            pickedPhoto = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    insertImage(image)
                }
            }
        }
        .fileImporter(isPresented: $showDocumentPicker,
                      allowedContentTypes: [.data, .pdf, .image, .plainText]) { result in
            if case .success(let url) = result { insertAttachmentPlaceholder(url: url) }
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
                        .font(.title.weight(.bold))
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
                        onEditingBegan:  {
                            isEditing = true
                            // The panel covered half the document and pushed the
                            // formatting toolbar under it. Editing is about the
                            // document; the chat bar brings the panel back on send.
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                                showAIPanel = false
                            }
                        }
                    )
                }
                .frame(height: editorHeight)
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, Self.chatBarH + 24)
            // iPad / landscape: the document keeps a page-like measure.
            .readableColumn(Layout.readableWidth + 32)
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
                // Once there's a document the bar edits it; "Start with" only
                // makes sense before the first draft exists.
                ChatBar(prompt: $aiChatPrompt,
                        placeholder: contract == nil ? "Start with HandShake" : "Edit with HandShake",
                        onSend: {
                    // Re-open panel when user sends a message after dismissing it
                    if !showAIPanel {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                            detent      = .medium
                            showAIPanel = true
                        }
                    }
                    sendToAI()
                }, onFocusChange: { focused in
                    // Tapping into the bar is the ask to talk — bring the
                    // conversation up at medium, over the keyboard, instead of
                    // waiting for the first message to be sent.
                    if focused && !showAIPanel && contract != nil {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                            detent      = .medium
                            showAIPanel = true
                        }
                    }
                }, onAttach: contract == nil ? nil : { kind in
                    // Same pickers the formatting toolbar uses; the insert
                    // lands at the editor's current cursor.
                    switch kind {
                    case .photo: showImagePicker    = true
                    case .file:  showDocumentPicker = true
                    }
                })
                .padding(.horizontal, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // The ZStack already respects the bottom safe area; this is only the
        // gap above it — same 8 as Home, so the pill sits at the same height.
        .padding(.bottom, 8)
        .readableColumn(Layout.readableWidth + 32)
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

                // Drag handle: a full-width strip that always resizes the panel,
                // whatever the list is doing.
                Capsule()
                    .fill(Color(.tertiaryLabel))
                    .frame(width: 36, height: 5)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                    .highPriorityGesture(panelDragGesture)
                    .accessibilityLabel("Assistant panel")
                    .accessibilityHint("Drag up to expand, down to shrink or close")

                // Message list
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {

                            ForEach(messages) { msg in
                                MessageBubble(message: msg).id(msg.id)
                            }

                            if isLoading || isAILoading {
                                // First draft vs a follow-up edit get different stages.
                                ThinkingIndicator(task: contract == nil ? .drafting : .editing)
                                    .padding(.horizontal, 16)
                                    .id("loading")
                                    .transition(.opacity)
                            }

                            if let err = errorText {
                                Text(err)
                                    .font(.subheadline)
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
                    // Sheet behaviour (think the Maps sheet): at medium the
                    // list doesn't scroll, so a drag anywhere on the panel
                    // resizes it. At large the list scrolls, and a drag down
                    // from its top collapses the panel (see panelDragGesture).
                    .scrollDisabled(detent != .large)
                    .scrollBounceBehavior(.basedOnSize)
                    .onScrollGeometryChange(for: Bool.self) { g in
                        g.contentOffset.y <= g.contentInsets.top + 1
                    } action: { _, atTop in
                        listAtTop = atTop
                    }
                }
            }
            .frame(height: clampedPanelHeight)
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
        // On a wide screen the panel is a centred sheet over the document's
        // column, not a slab across the whole display.
        .readableColumn(Layout.readableWidth + 32)
        // Simultaneous so it coexists with the list's own scrolling at large;
        // the gesture itself decides when to act.
        .simultaneousGesture(panelDragGesture)
    }

    /// Should this drag move the panel? Always below large (the list is
    /// scroll-disabled there). At large, only a downward drag that starts
    /// with the list at its top — otherwise the drag belongs to the list.
    private func panelShouldFollow(_ delta: CGFloat) -> Bool {
        detent != .large || (listAtTop && delta > 0)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Panel drag gesture
    // ─────────────────────────────────────────────────────────────────────────

    private var panelDragGesture: some Gesture {
        // Global coordinates: the panel moves with the finger while it's being
        // dragged, so in its own space the finger barely moves and the
        // velocity comes out near zero or reversed — a flick down could snap
        // it to large. Measured against the screen, it's the real motion.
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                let delta = value.translation.height
                guard panelShouldFollow(delta) else { dragOffset = 0; return }
                let projected = panelHeight - delta
                // Past the large detent the panel follows the finger at a
                // quarter speed — a sheet-like rubber band instead of a wall.
                let over = projected - largePanelH
                dragOffset = over <= 0 ? delta : delta + over * 0.75
            }
            .onEnded { value in
                guard panelShouldFollow(value.translation.height) else { dragOffset = 0; return }
                // A flick decides by direction; a slow drag by where it ends.
                let velocity   = value.velocity.height
                let projectedH = panelHeight - value.predictedEndTranslation.height
                let atLarge    = detent == .large
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    dragOffset = 0
                    let midpoint = (largePanelH + mediumPanelH) / 2
                    if velocity < -500 {
                        detent = .large               // flicked up
                    } else if velocity > 500 {
                        if atLarge { detent = .medium } else { showAIPanel = false }
                    } else if projectedH < 160 {
                        showAIPanel = false            // dragged away
                    } else if projectedH < midpoint {
                        detent = .medium              // settle at medium
                    } else {
                        detent = .large               // settle at large
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
                // Pick the conversation up where it left off. The greeting is
                // only for drafts that never had one (older records).
                messages = saved.messages
                if messages.isEmpty {
                    messages.append(ChatMessage(
                        content: "Welcome back! Keep editing directly on the contract, or ask me to update it for you.",
                        isUser: false
                    ))
                    // Nothing to catch up on: document front and center, the
                    // chat bar re-opens the panel on demand.
                    showAIPanel = false
                } else {
                    // There's a real conversation — show it, at medium, so
                    // the document is still visible behind it.
                    detent = .medium
                    showAIPanel = true
                }
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
                messages.append(ChatMessage(
                    content: "Created! Feel free to edit directly on the contract or ask me to update it for you!",
                    isUser: false
                ))
                persist()   // save immediately — a generated contract is a draft (and its reply)

                // Drop panel to medium so the contract is visible behind it
                withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
                    detent = .medium
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
            c.attachmentSizes = body.attachmentSizes
            // Keep the markdown in step with the edited document. `content` is
            // what crosses to the recipient in the signing link; frozen at the
            // AI's first draft, a signature box the sender placed never reached
            // them.
            c.content = body.handshakeMarkdown()
        }
        // Status metadata is owned by the store (SendFlow may have marked this
        // contract sent while the workspace was open) — never regress it here.
        if let stored = ContractStore.shared.contract(id: c.id) {
            c.recipients = stored.recipients
            c.status     = stored.status
            c.sentAt     = stored.sentAt
            c.signedAt   = stored.signedAt
        }
        c.messages = messages
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
        persist()                      // keep the question even if the reply fails
        isAILoading = true
        errorText   = nil

        // The model has to SEE the contract to revise it. Before this, only the
        // chat transcript was sent, so "add a clause" came back as a snippet —
        // which the TITLE/--- guard now rejects, and which previously replaced
        // the whole body. The document text (not `contract.content`) is used so
        // the user's manual edits are what gets revised.
        let transcript = messages
            .map { $0.isUser ? "User: \($0.content)" : "Assistant: \($0.content)" }
            .joined(separator: "\n\n")
        let currentTitle = contract?.title ?? "Agreement"
        let currentBody  = attributedBody.string
        let request = """
            CURRENT CONTRACT — revise this, do not start over:
            TITLE: \(currentTitle)
            ---
            \(currentBody)

            CONVERSATION:
            \(transcript)

            Apply the user's latest request to the current contract. Return the COMPLETE \
            updated contract in the required format — a TITLE: line, then ---, then the \
            entire body with the change incorporated. Never return only the changed \
            section, a diff, or a summary.
            """

        Task {
            do {
                let result = try await AIService.generateContract(for: request)
                await MainActor.run {
                    isAILoading    = false
                    // Keep the same contract identity (and metadata) across AI
                    // updates — otherwise every update would create a new draft.
                    if var updated = contract {
                        updated.title    = result.title
                        updated.content  = result.content
                        updated.bodyRTFD = nil   // body regenerated from markdown
                        updated.attachmentSizes = nil
                        contract = updated
                    } else {
                        contract = result
                    }
                    attributedBody = .fromHandshakeMarkdown(result.content)
                    messages.append(ChatMessage(
                        content: "Updated! Feel free to keep editing or ask me for more changes.",
                        isUser: false
                    ))
                    persist()          // after the append, so the reply is saved too
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
        case .insertDate:       insertDatePlaceholder()
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
            let cur    = (value as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
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
            let cur    = (value as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
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

        // Continue an existing list ("3." above → this one is "4.").
        let start = numbered
            ? ListNumbering.nextNumber(in: nsText, forParagraphAt: ranges.first?.location ?? 0)
            : 1

        tv.textStorage.beginEditing()
        for (i, r) in ranges.enumerated().reversed() {
            let prefix = numbered ? "\(start + i). " : "• "
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
        // An attachment built from `image` alone is dropped when the document
        // is saved as RTFD, so the photo vanished the next time the contract
        // opened. Built from data it is kept — and as the JPEG itself; with
        // `image` set, iOS re-encodes it as PNG (~4 MB a photo). The bytes
        // live in the contract store, so downscale first.
        let photo = image.downscaled(maxPixels: 1200)
        guard let jpeg = photo.jpegData(compressionQuality: 0.75) else { return }
        let attachment = NSTextAttachment(data: jpeg, ofType: UTType.jpeg.identifier)
        let maxW = tv.textContainer.size.width - 2 * tv.textContainer.lineFragmentPadding
        let scale = maxW / max(photo.size.width, 1)
        attachment.bounds = CGRect(x: 0, y: 0, width: maxW, height: photo.size.height * scale)
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
            .font:            UIFont.preferredFont(forTextStyle: .subheadline),
            .foregroundColor: UIColor.systemBlue
        ]
        let attrStr = NSAttributedString(string: block, attributes: attrs)
        tv.textStorage.beginEditing()
        tv.textStorage.insert(attrStr, at: tv.selectedRange.location)
        tv.textStorage.endEditing()
        attributedBody = NSMutableAttributedString(attributedString: tv.textStorage)
    }

    // ── Signature / date fields ───────────────────────────────────────────────
    //
    // The sender places a FIELD for the recipient to fill — the e-sign model.
    // A signature box is where the recipient signs (Face ID → stamp); a date
    // box is where they pick a date. In the document each is an attachment
    // drawing a dashed box; in markdown (and in the link to the recipient)
    // it's "[Signature]" / "[Date]". See SignatureField.
    //
    // Inserted on its own line at the END of the current paragraph, never
    // mid-word: the cursor sits wherever the user last tapped.

    private func insertSignaturePlaceholder() { insertField(.signature) }
    private func insertDatePlaceholder()      { insertField(.date) }

    private func insertField(_ kind: SignatureField) {
        guard let tv = textViewRef else { return }
        let box = NSMutableAttributedString(attachment: SignatureField.makeAttachment(kind))
        box.addAttributes(baseAttrs(), range: NSRange(location: 0, length: 1))

        tv.textStorage.beginEditing()
        let caret = tv.textStorage.insertFieldBox(box, near: tv.selectedRange.location,
                                                  attributes: baseAttrs())
        tv.textStorage.endEditing()
        tv.selectedRange = NSRange(location: caret, length: 0)
        attributedBody = NSMutableAttributedString(attributedString: tv.textStorage)
        Haptics.place()
    }

    private func baseAttrs() -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle(); para.lineSpacing = 3
        return [.font: UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: UIColor.label,
                .paragraphStyle: para]
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - GeneratingSkeleton
// Placeholder document shown while the first draft generates. Shapes only —
// a title block and paragraph lines in the card gray, gently pulsing.
// ─────────────────────────────────────────────────────────────────────────────

private struct GeneratingSkeleton: View {
    @State private var pulse = false
    private let gray = Color.cardFill   // #F4F4F5

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            bar(width: 0.72, height: 30)
            bar(width: 0.46, height: 30)
            Spacer().frame(height: 10)
            bar(width: 0.38, height: 16)
            Spacer().frame(height: 6)
            ForEach(0..<4, id: \.self) { _ in bar(width: 1.0, height: 14) }
            bar(width: 0.58, height: 14)
            Spacer().frame(height: 16)
            bar(width: 0.42, height: 16)
            Spacer().frame(height: 6)
            ForEach(0..<3, id: \.self) { _ in bar(width: 1.0, height: 14) }
            bar(width: 0.66, height: 14)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(pulse ? 0.55 : 1)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityLabel("Generating your contract")
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                .fill(gray)
                .frame(width: geo.size.width * width, height: height)
        }
        .frame(height: height)
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
