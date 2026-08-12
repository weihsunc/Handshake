import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Template data
// ─────────────────────────────────────────────────────────────────────────────

private struct ContractTemplate: Identifiable {
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
// ─────────────────────────────────────────────────────────────────────────────

struct HomeView: View {
    @State private var prompt            = ""
    @State private var showSheet         = false
    @State private var showHistory       = false
    @State private var isKeyboardVisible = false

    var body: some View {
        ZStack(alignment: .bottom) {

            // ── Background ──────────────────────────────────────────────
            Color(red: 0.98, green: 0.98, blue: 0.98)
                .ignoresSafeArea()

            // ── Centre content: illustration or templates ────────────────
            if isKeyboardVisible {
                // Template cards slide in from top when keyboard shows
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 16) {
                            ForEach(templates) { t in
                                TemplateCard(
                                    emoji: t.emoji,
                                    title: t.title,
                                    description: t.prompt
                                ) {
                                    prompt = t.prompt
                                    showSheet = true
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                    }
                    Spacer()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))

            } else {
                // Default illustration + welcome text
                VStack(spacing: 0) {
                    Spacer()

                    HandshakeIllustration()
                        .padding(.bottom, 28)

                    VStack(spacing: 10) {
                        Text("Welcome to Handshake!")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(Color(.label))

                        Text("We automate contract and deal\nmaking process.")
                            .font(.system(size: 17))
                            .foregroundStyle(Color(.secondaryLabel))
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                    }

                    Spacer()
                    Spacer()
                }
                .padding(.horizontal, 16)
                .transition(.opacity)
            }

            // ── Chat bar (always visible) ───────────────────────────────
            ChatBar(prompt: $prompt, onSend: {
                guard !prompt.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                showSheet = true
            }, onFocusChange: { focused in
                // FocusState fires immediately on tap — works with hardware keyboard too
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    isKeyboardVisible = focused
                }
            })
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isKeyboardVisible)
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
        // ── Keyboard notifications (software keyboard fallback) ───────────
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                isKeyboardVisible = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                isKeyboardVisible = false
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
}

#Preview {
    NavigationStack { HomeView() }
}
