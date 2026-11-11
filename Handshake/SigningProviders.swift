import Foundation
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Signing backends
//
// Three ways a contract can be signed. The app ships with .onDevice — Face ID
// plus a local SHA-256 stamp (HANDOFF §8). The other two hand the legal weight
// to a provider through the backend in backend/, which holds the API keys:
//
//   .docuseal  Path A — Face ID IS the signature. After the tap we tell
//              DocuSeal "this submitter is complete" (its documented
//              "auto-signed via API"). The recipient never sees a third-party
//              screen. We keep the consent line and pass our evidence along.
//   .signwell  Path B — Face ID is the unlock. SignWell's own signing page is
//              shown inside the app in a web view and captures intent itself.
//
// Both providers start in their TEST modes (see backend/README.md).
// ─────────────────────────────────────────────────────────────────────────────

enum SigningBackend: String, Codable {
    case onDevice, docuseal, signwell
}

/// What the provider handed back when a contract was sent. Persisted on the
/// contract so the signing screen can find its way back to the same document.
struct ProviderRef: Codable, Hashable {
    var backend: SigningBackend
    var documentId: String              // DocuSeal submission id / SignWell document id
    var submitterIds: [String] = []     // DocuSeal: one per signature box
    var signingURLs: [String] = []      // browser signing page per submitter (DocuSeal embed_src / SignWell)
    /// DocuSeal: the box each submitter signs ("Freelancer"), same order.
    var roles: [String]? = nil

    /// One party's part of it — what goes in that party's link, so their
    /// phone completes their own submitter and nobody else's.
    func only(role: String) -> ProviderRef? {
        guard let i = roles?.firstIndex(of: role), submitterIds.indices.contains(i) else { return nil }
        var r = self
        r.submitterIds = [submitterIds[i]]
        r.signingURLs  = signingURLs.indices.contains(i) ? [signingURLs[i]] : []
        r.roles        = [role]
        return r
    }

    /// The browser signing page for a party.
    func signingURL(role: String) -> String? {
        guard let i = roles?.firstIndex(of: role), signingURLs.indices.contains(i) else { return nil }
        return signingURLs[i]
    }
}

/// Who signs a DocuSeal submission's box. Email or phone, when known, only
/// labels the submitter in DocuSeal; DocuSeal sends nothing itself.
struct DocuSealParty {
    var role: String
    var name: String = ""
    var email: String = ""
    var phone: String = ""
}

/// One submitter's state, from /docuseal/status.
struct DocuSealSubmitterStatus {
    var id: String
    var role: String
    var name: String
    var completedAt: Date?
}

enum BackendError: LocalizedError {
    case notConfigured
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:   return String(localized: "No backend URL in Secrets.swift.")
        case .http(let c, let m): return String(localized: "Backend error \(c): \(m)")
        case .badResponse:     return String(localized: "Unexpected response from the backend.")
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - BackendClient  (the only thing on the phone that talks to the server)
// ─────────────────────────────────────────────────────────────────────────────

enum BackendClient {

    static var baseURL: URL? { Secrets.backendURL.flatMap(URL.init(string:)) }
    static var isConfigured: Bool { baseURL != nil }

    /// POST JSON to `<backendURL>/<path>`. Returns the decoded JSON, which is
    /// an object for most routes but a top-level array for DocuSeal's
    /// submission create — so the caller casts.
    static func post(_ path: String, _ body: [String: Any]) async throws -> Any {
        guard let base = baseURL else { throw BackendError.notConfigured }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data)
        guard (200..<300).contains(status) else {
            let msg = ((json as? [String: Any])?["error"] as? String)
                ?? String(data: data, encoding: .utf8) ?? ""
            throw BackendError.http(status, msg)
        }
        guard let json else { throw BackendError.badResponse }
        return json
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Providers
// ─────────────────────────────────────────────────────────────────────────────

enum SigningProviders {

    /// Called from the send flow. Creates the provider-side document and
    /// returns what we need to persist. Throws if the backend isn't set up.
    static func start(contract: GeneratedContract,
                      recipients: [Recipient],
                      backend: SigningBackend) async throws -> ProviderRef? {
        guard backend != .onDevice else { return nil }

        let pdf = ContractPDF.render(contract).base64EncodedString()
        let body: [String: Any] = [
            "title":      contract.title,
            "pdfBase64":  pdf,
            "recipients": recipients.map { ["name": $0.name, "email": $0.email] },
        ]

        switch backend {
        case .docuseal:
            // Created earlier, in the send flow, with startDocuSeal — before the
            // links go out, since each link carries its signer's part.
            return nil

        case .signwell:
            let json  = try await BackendClient.post("signwell/start", body)
            let obj   = json as? [String: Any] ?? [:]
            let docId = obj["id"] as? String ?? ""
            let urls  = (obj["recipients"] as? [[String: Any]])?
                .compactMap { $0["embedded_signing_url"] as? String } ?? []
            guard !docId.isEmpty else { throw BackendError.badResponse }
            return ProviderRef(backend: .signwell, documentId: docId, signingURLs: urls)

        case .onDevice:
            return nil
        }
    }

    /// Creates the DocuSeal submission for a contract: one submitter per
    /// signature box, the PDF tagged so each box becomes that party's field.
    /// Called from the send flow before any link goes out.
    static func startDocuSeal(contract: GeneratedContract, parties: [DocuSealParty]) async throws -> ProviderRef {
        let pdf = ContractPDF.render(contract, docuSealRoles: parties.map(\.role)).base64EncodedString()
        let json = try await BackendClient.post("docuseal/start", [
            "title":      contract.title,
            "pdfBase64":  pdf,
            "submitters": parties.map { p -> [String: String] in
                var s = ["role": p.role]
                if !p.name.isEmpty  { s["name"]  = p.name }
                if !p.email.isEmpty { s["email"] = p.email }
                if !p.phone.isEmpty { s["phone"] = p.phone }
                return s
            },
        ])
        let obj  = json as? [String: Any] ?? [:]
        let list = obj["submitters"] as? [[String: Any]] ?? []
        guard let id = idString(obj["id"]), !list.isEmpty else { throw BackendError.badResponse }
        return ProviderRef(backend: .docuseal,
                           documentId: id,
                           submitterIds: list.compactMap { idString($0["id"]) },
                           signingURLs: list.map { $0["url"] as? String ?? "" },
                           roles: list.map { $0["role"] as? String ?? "" })
    }

    /// Path A: after Face ID succeeded on the phone, tell DocuSeal this party's
    /// submitter is complete, with the signature as Handshake draws it and
    /// the evidence we collected.
    static func completeDocuSeal(ref: ProviderRef,
                                 role: String? = nil,
                                 signerName: String,
                                 stamp: SignatureStamp,
                                 signedDate: Date? = nil,
                                 consentText: String) async throws {
        let i = role.flatMap { ref.roles?.firstIndex(of: $0) } ?? 0
        guard ref.submitterIds.indices.contains(i) else { throw BackendError.badResponse }
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
        var body: [String: Any] = [
            "submitterId": ref.submitterIds[i],
            "signerName":  signerName,
            "evidence": [
                "signedAt":      stamp.isoTimestamp,
                "deviceId":      deviceId,
                "signatureHash": stamp.hash,
                "consentText":   consentText,
            ],
        ]
        if let r = ref.roles, r.indices.contains(i), !r[i].isEmpty {
            body["role"] = r[i]
            if let png = signatureImage(signerName) { body["signatureImage"] = png.base64EncodedString() }
            if let signedDate {
                let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian)
                f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
                body["signedDate"] = f.string(from: signedDate)
            }
        }
        _ = try await BackendClient.post("docuseal/complete", body)
    }

    /// Who has signed the submission, in the app or in a browser.
    static func docuSealStatus(ref: ProviderRef) async throws -> [DocuSealSubmitterStatus] {
        let json = try await BackendClient.post("docuseal/status", ["submissionId": ref.documentId])
        let list = (json as? [String: Any])?["submitters"] as? [[String: Any]] ?? []
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        return list.compactMap { s in
            guard let id = idString(s["id"]) else { return nil }
            let at = (s["completedAt"] as? String).flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) }
            return DocuSealSubmitterStatus(id: id, role: s["role"] as? String ?? "",
                                           name: s["name"] as? String ?? "", completedAt: at)
        }
    }

    /// The signer's name in the signature typeface, as a PNG — what DocuSeal
    /// puts in the signature field for someone who signed with Face ID.
    static func signatureImage(_ name: String) -> Data? {
        let font = UIFont(name: SignatureTypeface.forName(name).rawValue, size: 72) ?? .italicSystemFont(ofSize: 56)
        let text = NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: UIColor.black])
        let size = text.size()
        guard size.width > 0 else { return nil }
        let box = CGSize(width: ceil(size.width) + 24, height: ceil(size.height) + 16)
        let format = UIGraphicsImageRendererFormat(); format.opaque = false; format.scale = 2
        return UIGraphicsImageRenderer(size: box, format: format).pngData { _ in
            text.draw(at: CGPoint(x: 12, y: 8))
        }
    }

    /// Path B only. Ask SignWell whether every recipient has signed.
    static func signwellIsComplete(ref: ProviderRef) async throws -> Bool {
        let json = try await BackendClient.post("signwell/status", ["documentId": ref.documentId])
        return ((json as? [String: Any])?["status"] as? String)?.lowercased() == "completed"
    }

    /// Provider ids arrive as Int or String depending on the vendor.
    static func idString(_ v: Any?) -> String? {
        if let i = v as? Int    { return String(i) }
        if let s = v as? String { return s.isEmpty ? nil : s }
        return nil
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ContractPDF
// Both providers want a PDF. The document lives as an NSAttributedString, so
// draw it with UIKit's PDF renderer — Letter size, 1" margins, paginated.
// ─────────────────────────────────────────────────────────────────────────────

enum ContractPDF {

    /// - Parameter docuSealRoles: for DocuSeal, the party of each signature box
    ///   in order. Each box becomes a DocuSeal text tag
    ///   (`{{Freelancer Signature;role=Freelancer;type=signature}}`, and its
    ///   date field `{{Freelancer Date;…;type=date}}`), which DocuSeal turns into
    ///   that party's field and removes from the page. A document with no boxes
    ///   gets one per party at the end. Drawn unsigned: everyone, the sender
    ///   included, signs into DocuSeal's copy.
    static func render(_ contract: GeneratedContract, docuSealRoles: [String]? = nil) -> Data {
        let page   = CGRect(x: 0, y: 0, width: 612, height: 792)        // US Letter, points
        let inset  = page.insetBy(dx: 72, dy: 72)

        let body = NSMutableAttributedString()
        body.append(NSAttributedString(string: contract.title + "\n\n", attributes: [
            .font: UIFont.systemFont(ofSize: 22, weight: .bold),
            .foregroundColor: UIColor.black,
        ]))
        var markdown = docuSealRoles == nil
            ? contract.displayBody(signatureWidth: inset.width).handshakeMarkdown()
            : contract.baseBody().handshakeMarkdown()
        if let roles = docuSealRoles { markdown = tagged(markdown, roles: roles) }
        // Fields as text tokens, not boxes: Core Text doesn't draw attachments.
        let doc = NSMutableAttributedString.fromHandshakeMarkdown(markdown, renderFields: false)
        // Force a print-safe colour; the editor uses dynamic label colours.
        doc.addAttribute(.foregroundColor, value: UIColor.black, range: NSRange(location: 0, length: doc.length))
        body.append(doc)

        let renderer = UIGraphicsPDFRenderer(bounds: page)
        // DocuSeal reads the tags from the PDF's text; they must survive as
        // plain text, so they're left as drawn (DocuSeal erases them).
        return renderer.pdfData { ctx in
            let framesetter = CTFramesetterCreateWithAttributedString(body)
            var location = 0
            let length = body.length
            while location < length {
                ctx.beginPage()
                let path  = CGPath(rect: inset, transform: nil)
                let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(location, 0), path, nil)
                // Core Text draws flipped; put the origin at the bottom-left.
                let cg = ctx.cgContext
                cg.saveGState()
                cg.translateBy(x: 0, y: page.height)
                cg.scaleBy(x: 1, y: -1)
                CTFrameDraw(frame, cg)
                cg.restoreGState()
                let drawn = CTFrameGetVisibleStringRange(frame)
                if drawn.length == 0 { break }
                location += drawn.length
            }
        }
    }
}

extension ContractPDF {
    /// Swaps "[Signature]" / "[Date]" for DocuSeal text tags, box by box.
    static func tagged(_ markdown: String, roles: [String]) -> String {
        let sig = SignatureField.signature.token, date = SignatureField.date.token
        func role(_ i: Int) -> String { roles.indices.contains(i) ? roles[i] : "Party \(i + 1)" }

        var out = ""
        var rest = Substring(markdown)
        var slot = -1                                    // the box the text has reached
        while true {
            let s = rest.range(of: sig), d = rest.range(of: date)
            // Whichever token comes first.
            let isSig: Bool
            let hit: Range<Substring.Index>
            switch (s, d) {
            case let (s?, d?): (hit, isSig) = s.lowerBound < d.lowerBound ? (s, true) : (d, false)
            case let (s?, nil): (hit, isSig) = (s, true)
            case let (nil, d?): (hit, isSig) = (d, false)
            case (nil, nil): out += rest; return slot >= 0 ? out : out + appended(roles.indices.map(role))
            }
            out += rest[..<hit.lowerBound]
            if isSig {
                slot += 1
                out += "{{\(role(slot)) Signature;role=\(role(slot));type=signature}}"
            } else if slot >= 0 {
                // A date belongs to the box before it.
                out += "{{\(role(slot)) Date;role=\(role(slot));type=date}}"
            } else {
                out += date
            }
            rest = rest[hit.upperBound...]
        }
    }

    /// A document with no boxes: one per party at the end.
    private static func appended(_ roles: [String]) -> String {
        roles.map { "\n\n\($0)\n{{\($0) Signature;role=\($0);type=signature}}" }.joined()
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
