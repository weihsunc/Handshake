import SwiftUI

struct ChatSheetView: View {
    let initialPrompt: String

    @State private var messages:    [ChatMessage]      = []
    @State private var inputText:   String             = ""
    @State private var isLoading:   Bool               = false
    @State private var contract:    GeneratedContract? = nil
    @State private var showEditor:  Bool               = false
    @State private var errorText:   String?            = nil

    @Environment(\.dismiss) private var dismiss

    // Derive a short sheet title from whatever the user typed
    private var sheetTitle: String {
        let words = initialPrompt
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ")
            .prefix(5)
            .joined(separator: " ")
        return words.isEmpty ? "New Agreement" : String(words)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {

                // ── Message list ──────────────────────────────────
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {

                            ForEach(messages) { msg in
                                MessageBubble(message: msg).id(msg.id)
                            }

                            if isLoading {
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

                            Color.clear.frame(height: 90) // breathing room above chat bar
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 20)
                    }
                    // FIX: scroll to UUID when a message is added
                    .onChange(of: messages.count) { _, _ in
                        withAnimation {
                            if let lastId = messages.last?.id {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                    // FIX: scroll to the loading indicator (String ID) separately
                    .onChange(of: isLoading) { _, _ in
                        withAnimation {
                            if isLoading { proxy.scrollTo("loading", anchor: .bottom) }
                        }
                    }
                }

                // ── Bottom chat bar ───────────────────────────────
                ChatBar(prompt: $inputText, onSend: sendFollowUp)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
            }
            .navigationTitle(sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.secondary)
                }
            }
        }
        // Process the initial prompt as soon as the sheet appears
        .task { await processPrompt(initialPrompt) }
        // Show the generated contract as a full-screen cover
        .fullScreenCover(isPresented: $showEditor) {
            if let c = contract {
                NavigationStack { ContractEditorView(contract: c) }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: - Actions
    // ─────────────────────────────────────────────────────────────

    /// Handles any user message — first prompt or follow-up.
    private func processPrompt(_ text: String) async {
        messages.append(ChatMessage(content: text, isUser: true))
        isLoading = true
        errorText = nil

        do {
            if AIService.needsClarification(for: text) {
                // Ask clarifying questions
                let questions = try await AIService.getClarification(for: text)
                isLoading = false
                messages.append(ChatMessage(content: questions, isUser: false))
            } else {
                // Generate contract directly
                let result = try await AIService.generateContract(for: text)
                isLoading  = false
                contract   = result
                showEditor = true
            }
        } catch {
            isLoading = false
            errorText = error.localizedDescription
        }
    }

    /// Called when the user sends a follow-up reply in the chat.
    /// Builds the full conversation history so Claude has context.
    private func sendFollowUp() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        inputText = ""

        // Build full context from prior conversation
        let history = messages
            .map { $0.isUser ? "User: \($0.content)" : "Assistant: \($0.content)" }
            .joined(separator: "\n\n")
        let combined = history + "\n\nUser: \(text)"

        Task {
            // Add the user message and generate from full context
            messages.append(ChatMessage(content: text, isUser: true))
            isLoading = true
            errorText = nil
            do {
                let result = try await AIService.generateContract(for: combined)
                isLoading  = false
                contract   = result
                showEditor = true
            } catch {
                isLoading = false
                errorText = error.localizedDescription
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Message Bubble
// ─────────────────────────────────────────────────────────────────────────────

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.isUser { Spacer(minLength: 60) }

            Group {
                if let attr = try? AttributedString(markdown: message.content) {
                    Text(attr)
                } else {
                    Text(message.content)
                }
            }
            .font(.system(size: 17))
            .lineSpacing(3)
            .foregroundStyle(message.isUser ? .white : Color(.label))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(message.isUser ? Color(.label) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 18))

            if !message.isUser { Spacer(minLength: 60) }
        }
    }
}

#Preview {
    ChatSheetView(initialPrompt: "Create an NDA between Apple and Wei Chen for 1 year")
}
