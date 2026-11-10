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
        case .draft:    return String(localized: "Draft")
        case .sent:     return String(localized: "Pending")
        case .signed:   return String(localized: "Signed")
        case .declined: return String(localized: "Declined")
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
    /// Point size of each attachment in `bodyRTFD`, in document order. RTFD
    /// drops attachment bounds, and the boxes and stamp are drawn at 3×, so
    /// without these they'd load 3× too big. nil on older records.
    var attachmentSizes: [CGSize]?  = nil
    var recipients: [Recipient]     = []
    /// Sender-only distribution list. Never included in contract links.
    var copyRecipients: [CopyRecipient] = []
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

    // ── Recipient side ──────────────────────────────────────────────────────
    /// true when this copy arrived through a signing link — it's someone
    /// else's contract for this phone's owner to sign, not one they wrote.
    /// History lists these under "Waiting for You" and opens them to sign.
    var isIncoming: Bool            = false
    /// Who sent it, when the sender was signed in (carried in the link).
    var senderName: String?         = nil
    /// Which signature slot was signed (index into SignatureSlots.find) and
    /// the date the signer entered. Carried back with the signed copy so the
    /// sender's document gets the same stamp in the same place.
    var signedSlot: Int?            = nil
    var signedDate: Date?           = nil

    // ── Parties (Nov 8) ─────────────────────────────────────────────────────
    /// Every signature on the contract, one per party, the way DocuSign keeps
    /// one per recipient. Stamps are drawn from these when the document is
    /// shown (displayBody), never baked into bodyRTFD — so two copies signed
    /// by different people merge instead of the last one overwriting the
    /// first. Empty on older records, whose RTFD already has the stamp in it.
    var signatures: [PartySignature] = []
    /// How many signatures complete the contract (the signature boxes, or the
    /// recipients when there are no boxes). Set when it's sent.
    var partyCount: Int?            = nil
    /// Incoming: the party this phone's owner was asked to sign as. Carried
    /// in their own link, so they never have to pick. nil on older links.
    var myParty: Int?               = nil
    /// Where the signed copy goes back to: the sender's email or phone.
    var replyTo: String?            = nil
    /// A recipient declined, and why (optional).
    var declinedBy: String?         = nil
    var declineReason: String?      = nil
    /// A recipient asked for changes instead of signing.
    var changeRequest: ChangeRequest? = nil
    /// The party the sender signs as, by name ("Freelancer").
    ///   nil  — not known yet; the send screen falls back to the box left over
    ///   ""   — the sender chose not to sign
    /// The AI suggests it from the request ("I'm a freelancer…") when it
    /// drafts; the sender's choice on the send screen replaces it.
    var senderRole: String?         = nil
    /// The AI's suggested next steps from its latest draft (NEXT: line).
    /// Shown as chips under its reply; not needed after that.
    var nextSteps: [String]         = []
}

/// One party's signature. `slot` indexes SignatureSlots.find on the
/// UNSIGNED document (baseBody), so it means the same box on every phone.
struct PartySignature: Codable, Hashable {
    var slot: Int
    var role: String?
    var name: String
    var signedAt: Date
    var hash: String
    /// What the signer put in the date field after their box, if it has one.
    var date: Date?
    /// "Face ID" / "Touch ID" — whatever confirmed it.
    var method: String?
}

struct ChangeRequest: Codable, Hashable {
    var by: String
    var text: String
    var at: Date
}

extension GeneratedContract {
    /// Signatures still missing before the contract is complete.
    var signaturesNeeded: Int { max(0, (partyCount ?? 1) - signatures.count) }
    var isPartlySigned: Bool { !signatures.isEmpty && signaturesNeeded > 0 }
    var canSendCCCopies: Bool { !isIncoming && status == .signed && signaturesNeeded == 0 && !copyRecipients.isEmpty }
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
        attachmentSizes = try c.decodeIfPresent([CGSize].self,      forKey: .attachmentSizes)
        recipients    = try c.decodeIfPresent([Recipient].self,     forKey: .recipients)    ?? []
        copyRecipients = try c.decodeIfPresent([CopyRecipient].self, forKey: .copyRecipients) ?? []
        status        = try c.decodeIfPresent(ContractStatus.self,  forKey: .status)        ?? .draft
        createdAt     = try c.decodeIfPresent(Date.self,            forKey: .createdAt)     ?? .now
        sentAt        = try c.decodeIfPresent(Date.self,            forKey: .sentAt)
        signedAt      = try c.decodeIfPresent(Date.self,            forKey: .signedAt)
        signedBy      = try c.decodeIfPresent(String.self,          forKey: .signedBy)
        signatureHash = try c.decodeIfPresent(String.self,          forKey: .signatureHash)
        providerRef   = try c.decodeIfPresent(ProviderRef.self,     forKey: .providerRef)
        messages      = try c.decodeIfPresent([ChatMessage].self,   forKey: .messages)      ?? []
        isIncoming    = try c.decodeIfPresent(Bool.self,            forKey: .isIncoming)    ?? false
        senderName    = try c.decodeIfPresent(String.self,          forKey: .senderName)
        signedSlot    = try c.decodeIfPresent(Int.self,             forKey: .signedSlot)
        signedDate    = try c.decodeIfPresent(Date.self,            forKey: .signedDate)
        signatures    = try c.decodeIfPresent([PartySignature].self, forKey: .signatures)   ?? []
        partyCount    = try c.decodeIfPresent(Int.self,             forKey: .partyCount)
        myParty       = try c.decodeIfPresent(Int.self,             forKey: .myParty)
        replyTo       = try c.decodeIfPresent(String.self,          forKey: .replyTo)
        declinedBy    = try c.decodeIfPresent(String.self,          forKey: .declinedBy)
        declineReason = try c.decodeIfPresent(String.self,          forKey: .declineReason)
        changeRequest = try c.decodeIfPresent(ChangeRequest.self,   forKey: .changeRequest)
        senderRole    = try c.decodeIfPresent(String.self,          forKey: .senderRole)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ChatMessage  (persisted on its GeneratedContract)
// ─────────────────────────────────────────────────────────────────────────────

struct ChatMessage: Identifiable, Codable, Hashable {
    var id = UUID()
    let content: String
    let isUser: Bool
    /// Next steps offered under an assistant reply (tap to ask for them).
    var suggestions: [String]? = nil
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Recipient
// ─────────────────────────────────────────────────────────────────────────────

struct Recipient: Identifiable, Codable {
    let id: UUID
    var name:  String
    var email: String
    var phone: String
    /// The party (signature slot) this recipient signs as. nil on records
    /// from before parties were assigned.
    var party: Int?
    /// That party's name ("Freelancer") when it was sent. Sending again
    /// matches by this first: a revision can reorder or add signature boxes,
    /// and the box number alone would then hand them someone else's.
    var partyRole: String?

    init(id: UUID = UUID(), name: String = "", email: String = "", phone: String = "",
         party: Int? = nil, partyRole: String? = nil) {
        self.id    = id
        self.name  = name
        self.email = email
        self.phone = phone
        self.party = party
        self.partyRole = partyRole
    }
}

struct CopyRecipient: Identifiable, Codable {
    var id = UUID()
    var name: String
    var address: String
    var sentAt: Date? = nil

    static func isValidAddress(_ address: String) -> Bool {
        if address.contains("@") {
            let parts = address.split(separator: "@", omittingEmptySubsequences: false)
            return parts.count == 2 && parts.allSatisfy { !$0.isEmpty } && !address.contains(where: \.isWhitespace)
        }
        return address.filter(\.isNumber).count >= 7 && address.allSatisfy { $0.isNumber || "+-(). ".contains($0) }
    }

    static func addressKey(_ address: String) -> String {
        address.contains("@") ? address.lowercased() : address.filter(\.isNumber)
    }
}
