import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Template data
// ─────────────────────────────────────────────────────────────────────────────

struct ContractTemplate: Identifiable {
    let id = UUID()
    let emoji: String
    let title: String
    let prompt: String
}

// First person, real people, real amounts: what someone would actually say.
// Shown as the swipeable "Or say it your way" row and used for autocomplete.
private let templates: [ContractTemplate] = [
    ContractTemplate(emoji: "📷", title: String(localized: "Lending gear"),
        prompt: String(localized: "I'm lending my camera to Jamie for two weeks. If it breaks, they cover the repair.")),
    ContractTemplate(emoji: "🏠", title: String(localized: "Roommate agreement"),
        prompt: String(localized: "Alex is moving into my spare room. $900 a month, utilities split 50/50.")),
    ContractTemplate(emoji: "🎨", title: String(localized: "Design project"),
        prompt: String(localized: "I'm designing a logo for Acme Bakery. $1,500, half up front, two rounds of changes.")),
    ContractTemplate(emoji: "🤫", title: String(localized: "Non-Disclosure Agreement"),
        prompt: String(localized: "I'm pitching my app idea to a developer next week and want them to keep it to themselves.")),
    ContractTemplate(emoji: "🐕", title: String(localized: "Dog walking"),
        prompt: String(localized: "My neighbor is walking Biscuit on weekdays for $20 a walk.")),
    ContractTemplate(emoji: "💸", title: String(localized: "Personal loan"),
        prompt: String(localized: "I'm lending my friend Sam $2,000. They'll pay me back $200 a month.")),
    ContractTemplate(emoji: "💍", title: String(localized: "Wedding photography"),
        prompt: String(localized: "I'm shooting Mia and Leo's wedding on June 14. $3,200 for 300 edited photos.")),
    ContractTemplate(emoji: "🚐", title: String(localized: "Buying together"),
        prompt: String(localized: "My sister and I are buying a van 50/50 and need a plan if one of us wants out.")),
    ContractTemplate(emoji: "💻", title: String(localized: "Website build"),
        prompt: String(localized: "I'm building a website for a local gym. $4,000 over six weeks.")),
    ContractTemplate(emoji: "🛋️", title: String(localized: "Selling an item"),
        prompt: String(localized: "I'm selling my couch to Taylor for $350, as is, picked up on Saturday.")),
    ContractTemplate(emoji: "🎸", title: String(localized: "Band agreement"),
        prompt: String(localized: "Our band splits gig money four ways. We need rules for who owns the songs.")),
    ContractTemplate(emoji: "🧹", title: String(localized: "House cleaning"),
        prompt: String(localized: "Rosa cleans my apartment every other Friday for $120.")),
]


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - HomeView
//
// Three states, one screen (Figma 2160:6597 → 2160:6694):
//
//   idle      illustration + greeting, "Start from" (chat, call, paper,
//             Siri), then "Or say it your way": example cards in a row
//             that swipes sideways
//   focused   hero collapses; the cards pin to the top, chat bar rides the
//             keyboard. Tapping a card launches generation.
//   typing    the cards become autocomplete suggestions — templates ranked
//             by how well they match what's been typed. Tapping one fills
//             the prompt instead of launching, so it can be edited first.
// ─────────────────────────────────────────────────────────────────────────────

struct HomeView: View {
    @State private var prompt      = ""
    /// The draft being written (the workspace cover). Item-driven, not a
    /// Bool: with isPresented, the cover could be built from the state before
    /// the change and open with no source.
    @State private var workspace: PendingDraft? = nil
    @State private var showHistory = false
    @State private var showProfile = false
    @State private var isFocused   = false
    /// A Start-from row that was tapped (its sheet is up).
    @State private var startSource: StartSource? = nil
    /// Something shared to Handshake, shown in the Start-from sheet first.
    @State private var importReview: PendingDraft? = nil
    private var router = DeepLinkRouter.shared
    private var draftRouter = NewDraftRouter.shared

    // ── AI autocomplete ──────────────────────────────────────────────────────
    @State private var aiSuggestions: [PromptSuggestion] = []
    @State private var aiQuery:       String = ""          // query aiSuggestions answer
    @State private var aiCache:       [String: [PromptSuggestion]] = [:]
    @State private var aiTask:        Task<Void, Never>? = nil
    @State private var lastPicked:    String = ""          // don't re-suggest what was just tapped

    private var trimmed: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Drives which cards show and what a tap does. Deliberately NOT tied to
    /// focus: touching a card resigns the text field on touch-down, and if the
    /// branch depended on focus the examples list would swap in under the
    /// finger and *its* action (launch) would fire on touch-up.
    private var hasText: Bool    { !trimmed.isEmpty }
    /// Hero shows only when idle — collapsed while focused, and stays
    /// collapsed after a suggestion fills the prompt and drops focus.
    private var showHero: Bool   { !isFocused && !hasText }

    /// Instant, local first paint while the model is thinking: templates that
    /// plausibly complete what's been typed. Prefix matches on the prompt rank
    /// first, then keyword overlap. Empty → the examples, so the list never
    /// blanks out mid-keystroke.
    private var localSuggestions: [ContractTemplate] {
        let q     = trimmed.lowercased()
        let words = Set(q.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 3 })

        let scored: [(ContractTemplate, Int)] = templates.compactMap { t in
            let hay = (t.title + " " + t.prompt).lowercased()
            var score = 0
            if t.prompt.lowercased().hasPrefix(q) { score += 100 }
            score += words.filter { hay.contains($0) }.count
            return score > 0 ? (t, score) : nil
        }
        let ranked = scored.sorted { $0.1 > $1.1 }.map(\.0)
        return ranked.isEmpty ? templates : ranked
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    if showHero {
                        hero
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        startFrom
                            .transition(.opacity)
                        examplesRow
                            .transition(.opacity)
                    } else {
                        cards
                            .id("cards")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, showHero ? 16 : 8)
                .padding(.bottom, 16)
                .readableColumn(Layout.readableWidth + 32)
            }
            .scrollDismissesKeyboard(.interactively)
            // Collapsing the hero removes ~400pt above the cards, but the scroll
            // view keeps its offset — so the first card would slide up behind
            // the toolbar. Pin the list to the top whenever focus changes.
            .onChange(of: showHero) { _, idle in
                guard !idle else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    proxy.scrollTo("cards", anchor: .top)
                }
            }
        }
        .background(Color.pageBackground.ignoresSafeArea())   // stone/50 #FAFAF9
        // The chat bar is a bottom safe-area inset, so the list scrolls under
        // it and it rides the keyboard automatically when focused.
        .safeAreaInset(edge: .bottom) {
            ChatBar(prompt: $prompt, placeholder: String(localized: "Describe your deal…"), onSend: {
                guard !trimmed.isEmpty else { return }
                workspace = PendingDraft(prompt: trimmed)
            }, onFocusChange: { focused in
                isFocused = focused
            })
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .readableColumn(Layout.readableWidth + 32)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showHero)
        .animation(.spring(response: 0.3,  dampingFraction: 0.85), value: hasText)
        .animation(.easeInOut(duration: 0.2), value: aiSuggestions)
        .onChange(of: trimmed) { _, text in fetchSuggestions(for: text) }
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                GlassIconButton(systemName: "line.3.horizontal", label: String(localized: "Contracts")) {
                    showHistory = true
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                GlassIconButton(systemName: "person", label: String(localized: "Profile")) {
                    showProfile = true
                }
            }
        }
        // ── Contract workspace (full-screen, AI panel always on top) ─────
        .fullScreenCover(item: $workspace, onDismiss: { prompt = "" }) { draft in
            NavigationStack {
                ContractWorkspaceView(initialPrompt: draft.prompt, source: draft.source)
            }
        }
        // ── Start from: chat / call / paper / Siri ───────────────────────
        .sheet(item: $startSource) { source in
            if source == .siri {
                SiriStartSheet()
            } else {
                StartFromSheet(source: source) { material, note in
                    // Open once the sheet is down: one presentation at a time.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))
                        launch(PendingDraft(prompt: note, source: material))
                    }
                }
            }
        }
        .sheet(item: $importReview) { pending in
            StartFromSheet(source: pending.source?.kind.startSource ?? .chat, preset: pending) { material, note in
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(450))
                    launch(PendingDraft(prompt: note, source: material))
                }
            }
        }
        // ── Siri or a share asked for a new draft ────────────────────────
        .onChange(of: draftRouter.pending) { _, pending in
            guard let pending else { return }
            draftRouter.pending = nil
            let busy = workspace != nil || showHistory || showProfile || startSource != nil || importReview != nil
            workspace = nil; showHistory = false; showProfile = false; startSource = nil; importReview = nil
            Task { @MainActor in
                if busy { try? await Task.sleep(for: .milliseconds(500)) }
                if pending.review { importReview = pending } else { launch(pending) }
            }
        }
        // ── Contract history (hamburger menu) ────────────────────────────
        .sheet(isPresented: $showHistory) {
            HistoryView()
        }
        // ── Profile (person button) ──────────────────────────────────────
        .sheet(isPresented: $showProfile) {
            ProfileView()
        }
        // ── Deep link arriving: close our presentations so RootView can
        //    present the signing screen (see DeepLinkRouter).
        .onChange(of: router.dismissTick) { _, _ in
            workspace   = nil
            showHistory = false
            showProfile = false
            startSource = nil
            importReview = nil
        }
    }

    private func launch(_ draft: PendingDraft) {
        prompt    = draft.prompt
        workspace = draft
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Hero  (illustration + welcome)
    // ─────────────────────────────────────────────────────────────────────────

    private var hero: some View {
        VStack(spacing: 12) {
            HandshakeIllustration()
                .frame(height: 130)

            Text(greeting)
                .font(.title2.weight(.semibold))
                .tracking(-0.5)
                .foregroundStyle(Color(.label))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var greeting: String {
        let first = AccountStore.shared.name?
            .split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty
            ? String(localized: "What are we shaking on today?")
            : String(localized: "Hi \(first), what are we shaking on today?")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Start from  (chat · call · paper · Siri)
    // ─────────────────────────────────────────────────────────────────────────

    private var startFrom: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel(String(localized: "Start from"))
            VStack(spacing: 0) {
                ForEach(StartSource.allCases) { source in
                    Button { startSource = source } label: {
                        HStack(spacing: 14) {
                            Image(systemName: source.symbol)
                                .font(.system(size: 20, weight: .light))
                                .foregroundStyle(Color.primaryInk)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.title)
                                    .font(.body)
                                    .foregroundStyle(Color.primaryInk)
                                Text(source.subtitle)
                                    .font(.footnote)
                                    .foregroundStyle(Color.secondaryInk)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color(.tertiaryLabel))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if source != StartSource.allCases.last {
                        Divider().padding(.leading, 58)
                    }
                }
            }
            .background(Color.cardFill, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Or say it your way  (examples, swiped sideways)
    // ─────────────────────────────────────────────────────────────────────────

    private var examplesRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel(String(localized: "Or say it your way"))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(templates) { t in
                        Button {
                            lastPicked = t.prompt
                            launch(PendingDraft(prompt: t.prompt))
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(t.prompt)
                                    .font(.callout)
                                    .foregroundStyle(Color.primaryInk)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(3, reservesSpace: true)
                                Text(verbatim: "\(t.emoji) \(t.title)")
                                    .font(.footnote)
                                    .foregroundStyle(Color.secondaryInk)
                                    .lineLimit(1)
                            }
                            .padding(14)
                            .frame(width: 230, alignment: .leading)
                            .background(Color.cardFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .padding(.horizontal, -16)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Color.secondaryInk)
            .padding(.leading, 4)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Cards  (examples, or suggestions while typing)
    // ─────────────────────────────────────────────────────────────────────────

    private var cards: some View {
        // One ForEach, one source of truth. Which list and what a tap does are
        // both decided by hasText at the moment of the tap — see the note on
        // hasText for why this must not depend on focus.
        LazyVStack(spacing: 16) {
            if hasText && !aiSuggestions.isEmpty && aiQuery == trimmed.lowercased() {
                // Model's completions for exactly what's typed now
                ForEach(aiSuggestions) { sug in
                    TemplateCard(emoji: sug.emoji, title: sug.title, description: sug.prompt) {
                        lastPicked = sug.prompt
                        prompt     = sug.prompt          // fill, don't launch
                    }
                    .transition(.opacity)
                }
            } else {
                ForEach(hasText ? localSuggestions : templates) { t in
                    TemplateCard(emoji: t.emoji, title: t.title, description: t.prompt) {
                        // Decide BEFORE assigning: hasText reads `prompt`, so
                        // checking it after the assignment is always true and
                        // the launch path never fires. Example → launch;
                        // suggestion (text already present) → fill.
                        let isExample = !hasText
                        lastPicked = t.prompt
                        prompt     = t.prompt
                        if isExample { workspace = PendingDraft(prompt: t.prompt) }
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - AI autocomplete
    //
    // Debounced ~450 ms after the last keystroke, cancelled by the next one,
    // cached per query. On failure the local suggestions simply stay up.
    // ─────────────────────────────────────────────────────────────────────────

    private func fetchSuggestions(for text: String) {
        aiTask?.cancel()

        let q = text.lowercased()
        guard q.count >= 3, text != lastPicked else { return }

        if let hit = aiCache[q] {
            aiSuggestions = hit
            aiQuery       = q
            return
        }

        aiTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }

            guard let result = try? await AIService.suggestPrompts(for: text),
                  !Task.isCancelled, !result.isEmpty else { return }

            aiCache[q]    = result
            aiSuggestions = result
            aiQuery       = q
        }
    }
}

#Preview {
    NavigationStack { HomeView() }
}
