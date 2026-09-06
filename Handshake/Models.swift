import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ContractStatus
// ─────────────────────────────────────────────────────────────────────────────

enum ContractStatus: String, Codable {
    case draft
    case sent
    case signed
    case declined

    var label: String {
        switch self {
        case .draft:    return "Draft"
        case .sent:     return "Pending"
        case .signed:   return "Signed"
        case .declined: return "Declined"
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - GeneratedContract
//
// `content` is the AI-generated markdown source. `bodyRTFD` captures the user's
// rich-text edits (formatting, inline images) as RTFD data — when present it
// takes precedence over `content` for display.
// ─────────────────────────────────────────────────────────────────────────────

struct GeneratedContract: Identifiable, Codable {
    let id: UUID
    var title: String
    var content: String
    var bodyRTFD: Data?             = nil
    var recipients: [Recipient]     = []
    var status: ContractStatus      = .draft
    var createdAt: Date             = .now
    var sentAt: Date?               = nil
    var signedAt: Date?             = nil

    // ── Signature record (set by SignatureService on a successful Face ID sign)
    /// Name the signer signed under.
    var signedBy: String?           = nil
    /// SHA256 of name + contract id + timestamp + device id. Tamper-evidence
    /// only — there's no independent chain of custody. See HANDOFF §8.
    var signatureHash: String?      = nil

    /// Set when the contract was sent through a provider (DocuSeal / SignWell).
    /// nil means on-device signing only.
    var providerRef: ProviderRef?   = nil
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ChatMessage  (in-memory only, not persisted)
// ─────────────────────────────────────────────────────────────────────────────

struct ChatMessage: Identifiable {
    let id = UUID()
    let content: String
    let isUser: Bool
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Recipient
// ─────────────────────────────────────────────────────────────────────────────

struct Recipient: Identifiable, Codable {
    let id: UUID
    var name:  String
    var email: String
    var phone: String

    init(id: UUID = UUID(), name: String = "", email: String = "", phone: String = "") {
        self.id    = id
        self.name  = name
        self.email = email
        self.phone = phone
    }
}
