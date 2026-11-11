import Foundation

enum AIError: Error, LocalizedError {
    case invalidResponse
    case apiError(Int)
    case missingAPIKey
    /// The model answered, but not in the TITLE / --- / body shape we asked
    /// for. Distinct from invalidResponse (which is transport-level) so the
    /// user sees "try again" rather than "check your key".
    case malformedContract
    /// The model's safety check declined the request (HTTP 200 with
    /// stop_reason "refusal"). Haiku 5.5 has no server-side fallback.
    case refused

    var errorDescription: String? {
        switch self {
        case .invalidResponse:    return String(localized: "Unexpected response from AI.")
        case .apiError(let c):    return String(localized: "API error (status \(c)). Check your key in Secrets.swift.")
        case .missingAPIKey:      return String(localized: "Add your Anthropic API key to Secrets.swift.")
        case .malformedContract:  return String(localized: "The AI didn't return a usable contract. Try rephrasing your request or sending it again.")
        case .refused:            return String(localized: "The AI declined this request. Try describing the agreement differently.")
        }
    }
}

/// One autocomplete card on Home: what the user is probably trying to say,
/// as a short label plus a prompt that's ready to send as-is.
struct PromptSuggestion: Identifiable, Hashable {
    let emoji: String
    let title: String
    let prompt: String
    var id: String { title + prompt }
}

enum AIService {

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// The model that drafts and revises contracts. Named on the Profile
    /// screen's legal section, so it must stay the one actually called.
    static let modelID          = "claude-haiku-5-5"
    static let modelDisplayName = "Claude Haiku 5.5"

    // ─────────────────────────────────────────────────────────────
    // MARK: - Public
    // ─────────────────────────────────────────────────────────────

    /// Autocomplete for the Home chat bar: turn a few typed words ("NDA",
    /// "lease for my", …) into 3 concrete contract ideas the user can tap.
    /// Cheap on purpose — called on a debounce while typing.
    static func suggestPrompts(for text: String) async throws -> [PromptSuggestion] {
        let raw = try await call(
            system: """
            You power autocomplete in Handshake, an app that drafts contracts from a short description.
            The user has typed the beginning of a request. Suggest exactly 3 specific, different \
            contracts they might mean. Stay on the topic of what they typed.

            Output exactly 3 lines, nothing else, each formatted as:
            EMOJI | TITLE | PROMPT

            - EMOJI: one emoji that fits the contract
            - TITLE: at most 6 words, sentence case, no trailing period (e.g. "NDA for a new employee")
            - PROMPT: one sentence, 15-30 words, written as an instruction that could be sent as-is \
              (e.g. "Create a non-disclosure agreement between an employer and a new employee covering \
              confidential information, duration, and exclusions.")
            - Write TITLE and PROMPT in the same language the user is typing in.
            """,
            message: text,
            maxTokens: 1024,       // Haiku 5.5 thinks by default and thinking counts here
            effort: "low"          // fires while typing: keep it fast and cheap
        )

        return raw
            .components(separatedBy: "\n")
            .compactMap { line -> PromptSuggestion? in
                let parts = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count >= 3, !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
                let emoji = parts[0].isEmpty ? "✨" : String(parts[0].prefix(2))
                return PromptSuggestion(emoji: emoji, title: parts[1], prompt: parts[2])
            }
            .prefix(3)
            .map { $0 }
    }

    /// Generate a full contract from a (possibly multi-turn) prompt.
    static func generateContract(for prompt: String) async throws -> GeneratedContract {
        let raw = try await call(
            system: """
            You draft contracts in Handshake, an app that turns a short description into an \
            agreement people can sign. You are not a lawyer and you don't give legal advice: \
            you write down what the person describes as a clear, complete, well-organized contract.

            Start your response with exactly:
            TITLE: [Short descriptive contract title]
            SENDER: [The party role the person making this request will sign as, written \
            exactly as its label in the signature block (e.g. FREELANCER). Infer it from \
            the request ("I'm a freelancer…", "my tenant", "for my employee"). Write NONE \
            if the request doesn't make it clear.]
            NEXT: [3 or 4 optional ideas for edits the person could ask you to make, \
            separated by " | ". The app shows them as "Optional ideas", so they are \
            options, never advice. Each:
              - starts with a verb and is at most 5 words (e.g. "Add a late fee", \
                "Clarify due dates", "Cover missed payments", "Make it interest-free")
              - is specific to this contract; mix kinds (add, clarify, change, cover, \
                shorten) and use "Add" at most once
              - describes an edit to the wording, never a judgment about it: no "should", \
                no warnings or risks, nothing about what is legal, required, valid, \
                enforceable, compliant, or protects someone legally
            The last idea is always "Simplify the wording" (in the contract's language). \
            Never suggest filling in the [bracketed] fields — the app does that.]
            ---

            Then write the full contract body.

            Formatting rules:
            - Put each section title on its own line in bold, like **1. PROJECT SCOPE** \
              (the words "Section Header" must never appear in the output)
            - Use numbered lists for clauses (1. 2. 3. …)
            - Never use tables (Markdown, HTML, or aligned text columns), even if requested. \
              Present schedules, milestones, fees, and comparisons as numbered lists instead, \
              keeping all details and labelling each value (e.g. "1. Milestone: Design approval; \
              Due date: [DATE]; Payment: [AMOUNT]"). When revising an existing contract, \
              convert any tables to numbered lists without losing information.
            - Use [brackets] for any field the user must fill in
            - Include all standard sections for this agreement type
            - END with a signature block, one entry per party, exactly in this form \
              (keep the bracketed tokens verbatim — the app fills them in when someone signs):
              **SIGNATURES**
              [PARTY ROLE, e.g. LANDLORD]: [FULL NAME]
              [Signature]
              [Date]
              (In a contract that isn't in English, translate the heading, the role and \
              the [FULL NAME] placeholder; only [Signature] and [Date] stay in English.)
            - The contract body is the ENTIRE output. Do not add notes, disclaimers, \
              advice, or commentary before or after it.
            - No legal advice inside the contract either: don't state or imply that the \
              contract or any clause is legally valid, enforceable, compliant, or required \
              by law, and don't cite statutes, regulations, or court cases unless the person \
              asks for a clause that refers to one. Ordinary clauses (e.g. which place's law \
              governs, with the place as a [bracketed] field) are fine.

            Language:
            - Write the title and the whole contract in the language of the user's request \
              (a request in Japanese gets a contract in Japanese, and so on).
            - These markers stay exactly as shown, untranslated, because the app reads them: \
              "TITLE:", "SENDER:", "NEXT:", "NONE", "---", "[Signature]", "[Date]". Everything else, \
              including the NEXT suggestions and the \
              SIGNATURES heading, the role labels and the [bracketed] fill-in fields, is \
              written in the contract's language. Write role labels in capitals where the \
              script has capitals, followed by a colon.

            Be thorough, clear, and complete.
            """,
            message: prompt,
            maxTokens: 16000,      // thinking + a full contract; 16K is the non-streaming ceiling
            effort: "medium"
        )

        // Parse TITLE / body. Both markers are required: without "---" the
        // whole reply (TITLE line included) would become the body; without a
        // TITLE the contract would be filed as a generic "Agreement".
        let lines = raw.components(separatedBy: "\n")
        var title: String? = nil
        var sender: String? = nil
        var next: [String] = []
        var bodyStart: Int? = nil

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("TITLE:") {
                let t = trimmed
                    .replacingOccurrences(of: "TITLE:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { title = t }
            }
            // Optional: a guess, never required. The send screen shows it as
            // the sender's pre-selected party, and they can change it.
            if trimmed.hasPrefix("SENDER:") {
                let r = String(trimmed.dropFirst("SENDER:".count))
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                if !r.isEmpty && r.uppercased() != "NONE" { sender = r }
            }
            // Optional: suggested next steps, shown as chips under the reply.
            if trimmed.hasPrefix("NEXT:") {
                next = String(trimmed.dropFirst("NEXT:".count))
                    .components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces)
                              .trimmingCharacters(in: CharacterSet(charactersIn: "[]\"")) }
                    .filter { !$0.isEmpty && $0.count <= 60 }
                next = Array(next.prefix(4))
            }
            if trimmed == "---" {
                bodyStart = i + 1
                break
            }
        }

        guard let title, let bodyStart else {
            throw AIError.malformedContract
        }

        let body = lines[bodyStart...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count >= 40 else {
            throw AIError.malformedContract
        }

        var contract = GeneratedContract(id: UUID(), title: title, content: body)
        contract.senderRole = sender
        contract.nextSteps  = next
        return contract
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: - Private
    // ─────────────────────────────────────────────────────────────

    /// One Messages API call. Haiku 5.5 runs adaptive thinking by default and
    /// rejects temperature / top_p / top_k and assistant prefill, so none are
    /// sent; `effort` (low…max, default medium) is the knob for how much it thinks.
    private static func call(system: String, message: String,
                             maxTokens: Int = 2048, effort: String = "medium") async throws -> String {
        // With a backend configured the key stays on the server (HANDOFF §9):
        // same request body, different door.
        let viaBackend = BackendClient.baseURL?.appendingPathComponent("ai/messages")
        if viaBackend == nil {
            guard Config.anthropicAPIKey != "YOUR_API_KEY_HERE" else {
                throw AIError.missingAPIKey
            }
        }

        var req = URLRequest(url: viaBackend ?? endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json",         forHTTPHeaderField: "Content-Type")
        if viaBackend == nil {
            req.setValue(Config.anthropicAPIKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01",           forHTTPHeaderField: "anthropic-version")
        }

        let body: [String: Any] = [
            "model":      modelID,
            "max_tokens": maxTokens,
            "output_config": ["effort": effort],
            "system":     system,
            "messages":   [["role": "user", "content": message]]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw AIError.apiError(http.statusCode)
        }

        guard
            let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = json["content"]  as? [[String: Any]]
        else { throw AIError.invalidResponse }

        if json["stop_reason"] as? String == "refusal" { throw AIError.refused }

        // The reply can open with `thinking` blocks (empty text by default), so
        // read the answer by block type, never by position.
        let text = content
            .filter  { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else { throw AIError.invalidResponse }

        return text
    }
}
