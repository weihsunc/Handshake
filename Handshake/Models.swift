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
