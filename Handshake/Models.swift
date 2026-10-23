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

    /// The AI conversation about this contract. Persisted with it, so
    /// reopening a draft shows what was actually discussed rather than a
    /// canned greeting.
    var messages: [ChatMessage]     = []
}

// Declared in an extension on purpose: an initializer inside the struct body
// would remove the synthesized memberwise init that call sites and previews
// rely on (GeneratedContract(id:title:content:recipients:status:)).
extension GeneratedContract {
    // Tolerant decoding. Every field after `content` was added after the
    // first records were written, and the store loads with
    // `try? decode … ?? []` — a strict synthesized decoder would fail the
    // WHOLE file on one missing key, show an empty history, and the next
    // save would overwrite it with nothing. decodeIfPresent keeps old files
    // loading as fields are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id            = try c.decode(UUID.self,            forKey: .id)
        title         = try c.decode(String.self,          forKey: .title)
        content       = try c.decode(String.self,          forKey: .content)
        bodyRTFD      = try c.decodeIfPresent(Data.self,            forKey: .bodyRTFD)
        recipients    = try c.decodeIfPresent([Recipient].self,     forKey: .recipients)    ?? []
        status        = try c.decodeIfPresent(ContractStatus.self,  forKey: .status)        ?? .draft
        createdAt     = try c.decodeIfPresent(Date.self,            forKey: .createdAt)     ?? .now
        sentAt        = try c.decodeIfPresent(Date.self,            forKey: .sentAt)
        signedAt      = try c.decodeIfPresent(Date.self,            forKey: .signedAt)
        signedBy      = try c.decodeIfPresent(String.self,          forKey: .signedBy)
        signatureHash = try c.decodeIfPresent(String.self,          forKey: .signatureHash)
        providerRef   = try c.decodeIfPresent(ProviderRef.self,     forKey: .providerRef)
        messages      = try c.decodeIfPresent([ChatMessage].self,   forKey: .messages)      ?? []
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ChatMessage  (persisted on its GeneratedContract)
// ─────────────────────────────────────────────────────────────────────────────

struct ChatMessage: Identifiable, Codable, Hashable {
    var id = UUID()
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
