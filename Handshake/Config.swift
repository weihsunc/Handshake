import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Config
//
// Non-secret configuration. The API key itself lives in Secrets.swift, which is
// gitignored — see that file for setup instructions.
// ─────────────────────────────────────────────────────────────────────────────

enum Config {
    static let anthropicAPIKey = Secrets.anthropicAPIKey
}
