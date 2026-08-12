import Foundation

enum AIError: Error, LocalizedError {
    case invalidResponse
    case apiError(Int)
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .invalidResponse:   return "Unexpected response from AI."
        case .apiError(let c):   return "API error (status \(c)). Check your key in Secrets.swift."
        case .missingAPIKey:     return "Add your Anthropic API key to Secrets.swift."
        }
    }
}

enum AIService {

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    // ─────────────────────────────────────────────────────────────
    // MARK: - Public
    // ─────────────────────────────────────────────────────────────

    /// Returns true when the prompt is too vague to generate directly.
    static func needsClarification(for prompt: String) -> Bool {
        let words = prompt.split(separator: " ")
        let lower = prompt.lowercased()

        let hasEnoughWords = words.count >= 10
        let hasParties     = lower.contains("between") || lower.contains(" and ")
        let hasDuration    = ["month","year","week","day","annual","quarterly"]
                               .contains(where: lower.contains)
        let hasAmount      = lower.contains("$") || lower.contains("usd") ||
                             lower.contains("per") || lower.contains("fee")

        // Need at least words + one other signal, or be very detailed
        return !(hasEnoughWords || (hasParties && (hasDuration || hasAmount)))
    }

    /// Ask Claude for 2-3 clarifying questions.
    static func getClarification(for prompt: String) async throws -> String {
        try await call(
            system: """
            You are a friendly contract assistant inside Handshake, an app that creates agreements.
            The user wants a contract but hasn't provided enough detail.
            Ask exactly 2–3 short clarifying questions as a numbered list.
            Keep the intro to one sentence. Focus on: parties, duration, payment, scope.
            """,
            message: "I want to create: \(prompt)"
        )
    }

    /// Generate a full contract from a (possibly multi-turn) prompt.
    static func generateContract(for prompt: String) async throws -> GeneratedContract {
        let raw = try await call(
            system: """
            You are a professional contract attorney. Generate a complete, legally formatted contract.

            Start your response with exactly:
            TITLE: [Short descriptive contract title]
            ---

            Then write the full contract body.

            Formatting rules:
            - Use **Section Header:** on its own line for section titles
            - Use numbered lists for clauses (1. 2. 3. …)
            - Use [brackets] for any field the user must fill in
            - Include all standard sections for this agreement type

            Be thorough, professional, and complete.
            """,
            message: prompt
        )

        // Parse TITLE / body
        let lines = raw.components(separatedBy: "\n")
        var title = "Agreement"
        var bodyStart = 0

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("TITLE:") {
                title = trimmed
                    .replacingOccurrences(of: "TITLE:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            if trimmed == "---" {
                bodyStart = i + 1
                break
            }
        }

        let body = lines[bodyStart...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return GeneratedContract(id: UUID(), title: title, content: body)
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: - Private
    // ─────────────────────────────────────────────────────────────

    private static func call(system: String, message: String) async throws -> String {
        guard Config.anthropicAPIKey != "YOUR_API_KEY_HERE" else {
            throw AIError.missingAPIKey
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json",         forHTTPHeaderField: "Content-Type")
        req.setValue(Config.anthropicAPIKey,     forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",               forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model":      "claude-haiku-4-5-20251001",
            "max_tokens": 2048,
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
            let content = json["content"]  as? [[String: Any]],
            let text    = content.first?["text"] as? String
        else { throw AIError.invalidResponse }

        return text
    }
}
