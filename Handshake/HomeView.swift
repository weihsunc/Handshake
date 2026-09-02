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

private let templates: [ContractTemplate] = [
    ContractTemplate(
        emoji: "📄", title: "Consulting Agreement",
        prompt: "Create a contract for a freelance web development project that includes project scope, timeline, payment terms, deliverables, and confidentiality agreements."
    ),
    ContractTemplate(
        emoji: "🔏", title: "Non-Disclosure Agreement",
        prompt: "Generate a clear, professional Non-Disclosure Agreement (NDA) covering parties, confidential information, obligations, duration, exclusions, remedies, and jurisdiction."
    ),
    ContractTemplate(
        emoji: "🏰", title: "Apartment Rental Agreement",
        prompt: "Create a lease agreement for an apartment with monthly rent, security deposit, lease term, utilities included, maintenance responsibilities, and standard rights and obligations."
    ),
    ContractTemplate(
        emoji: "💼", title: "Employment Contract",
        prompt: "Draft a comprehensive employment contract covering job title, compensation, benefits, working hours, confidentiality, non-compete clauses, and termination conditions."
    ),
    ContractTemplate(
        emoji: "🤝", title: "Partnership Agreement",
        prompt: "Create a partnership agreement outlining roles, profit sharing, decision-making authority, capital contributions, dispute resolution, and exit procedures."
    ),
]

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - HomeView
//
// Three states, one screen (Figma 2160:6597 → 2160:6694):
//
//   idle      illustration + welcome, then the example cards as a vertical
//             list scrolling under the chat bar
//   focused   hero collapses; the cards pin to the top, chat bar rides the
//             keyboard. Tapping a card launches generation.
//   typing    the cards become autocomplete suggestions — templates ranked
//             by how well they match what's been typed. Tapping one fills
//             the prompt instead of launching, so it can be edited first.
// ─────────────────────────────────────────────────────────────────────────────

struct HomeView: View {
    @State private var prompt      = ""
    @State private var showSheet   = false
    @State private var showHistory = false
    @State private var isFocused   = false
    private var router = DeepLinkRouter.shared

    private var trimmed: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isTyping: Bool   { isFocused && !trimmed.isEmpty }

    /// Templates that plausibly complete what's been typed. Prefix matches on
    /// the prompt rank first, then keyword overlap. Empty → fall back to the
    /// examples so the list never blanks out mid-keystroke.
    private var suggestions: [ContractTemplate] {
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

                    if !isFocused {
                        hero
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    cards
                        .id("cards")
                }
                .padding(.horizontal, 16)
                .padding(.top, isFocused ? 8 : 16)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            // Collapsing the hero removes ~400pt above the cards, but the scroll
            // view keeps its offset — so the first card would slide up behind
            // the toolbar. Pin the list to the top whenever focus changes.
            .onChange(of: isFocused) { _, _ in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    proxy.scrollTo("cards", anchor: .top)
                }
            }
        }
        .background(Color(red: 0.98, green: 0.98, blue: 0.976).ignoresSafeArea())   // stone/50 #FAFAF9
        // The chat bar is a bottom safe-area inset, so the list scrolls under
        // it and it rides the keyboard automatically when focused.
        .safeAreaInset(edge: .bottom) {
            ChatBar(prompt: $prompt, onSend: {
                guard !trimmed.isEmpty else { return }
                showSheet = true
            }, onFocusChange: { focused in
                isFocused = focused
            })
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isFocused)
        .animation(.spring(response: 0.3,  dampingFraction: 0.85), value: isTyping)
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                GlassIconButton(systemName: "line.3.horizontal") {
                    showHistory = true
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                GlassIconButton(systemName: "person")
            }
        }
        // ── Contract workspace (full-screen, AI panel always on top) ─────
        .fullScreenCover(isPresented: $showSheet, onDismiss: { prompt = "" }) {
            NavigationStack {
                ContractWorkspaceView(initialPrompt: prompt)
            }
        }
        // ── Contract history (hamburger menu) ────────────────────────────
        .sheet(isPresented: $showHistory) {
            HistoryView()
        }
        // ── Deep link arriving: close our presentations so RootView can
        //    present the signing screen (see DeepLinkRouter).
        .onChange(of: router.dismissTick) { _, _ in
            showSheet   = false
            showHistory = false
        }
        #if DEBUG
        // Lets a headless verification run open History without a tap:
        //   xcrun simctl launch <udid> com.weihsun.Handshake -HandshakeOpenHistory
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-HandshakeOpenHistory") {
                showHistory = true
            }
        }
        #endif
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Hero  (illustration + welcome)
    // ─────────────────────────────────────────────────────────────────────────

    private var hero: some View {
        VStack(spacing: 24) {
            HandshakeIllustration()
                .frame(height: 240)

            VStack(spacing: 16) {
                Text("Welcome to Handshake!")
                    .font(.system(size: 30, weight: .semibold))
                    .tracking(-0.75)
                    .foregroundStyle(Color(.label))

                Text("We automate contract and deal\nmaking process.")
                    .font(.system(size: 20))
                    .foregroundStyle(Color(.label))
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Cards  (examples, or suggestions while typing)
    // ─────────────────────────────────────────────────────────────────────────

    @ViewBuilder
    private var cards: some View {
        LazyVStack(spacing: 16) {
            if isTyping {
                ForEach(suggestions) { t in
                    TemplateCard(emoji: t.emoji, title: t.title, description: t.prompt) {
                        prompt = t.prompt          // autocomplete — fill, don't launch
                    }
                    .transition(.opacity)
                }
            } else {
                ForEach(templates) { t in
                    TemplateCard(emoji: t.emoji, title: t.title, description: t.prompt) {
                        prompt    = t.prompt
                        showSheet = true
                    }
                    .transition(.opacity)
                }
            }
        }
    }
}

#Preview {
    NavigationStack { HomeView() }
}
