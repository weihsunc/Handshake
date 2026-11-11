import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Config
//
// Non-secret configuration. The API key itself lives in Secrets.swift, which is
// gitignored — see that file for setup instructions.
// ─────────────────────────────────────────────────────────────────────────────

enum Config {
    static let anthropicAPIKey = Secrets.anthropicAPIKey

    /// The signing link page (web/sign/index.html) once it's hosted, e.g.
    /// "https://<host>/sign/". Set: every signing link points there and the
    /// page offers Get Handshake or signing in the browser (DocuSeal). nil:
    /// links are handshake:// and the message adds the browser link itself.
    static let linkPageURL: String? = nil
}
