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
    var submitterIds: [String] = []     // DocuSeal: one per recipient
    var signingURLs: [String] = []      // SignWell: embedded signing URL per recipient
}

enum BackendError: LocalizedError {
    case notConfigured
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:   return "No backend URL in Secrets.swift."
        case .http(let c, let m): return "Backend error \(c): \(m)"
        case .badResponse:     return "Unexpected response from the backend."
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
            // POST /submissions/pdf answers with an ARRAY of submitters, each
            // carrying its own id and the shared submission_id.
            let json = try await BackendClient.post("docuseal/start", body)
            let list = (json as? [[String: Any]])
                ?? ((json as? [String: Any])?["submitters"] as? [[String: Any]])
                ?? []
            guard !list.isEmpty else { throw BackendError.badResponse }
            let ids   = list.compactMap { Self.idString($0["id"]) }
            let docId = list.first.flatMap { Self.idString($0["submission_id"]) } ?? ids.first ?? ""
            return ProviderRef(backend: .docuseal, documentId: docId, submitterIds: ids)

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

    /// Path A only. After Face ID succeeded on the phone, tell DocuSeal the
    /// submitter is complete and hand over the evidence we collected.
    static func completeDocuSeal(ref: ProviderRef,
                                 signerName: String,
                                 stamp: SignatureStamp,
                                 consentText: String) async throws {
        guard let submitterId = ref.submitterIds.first else { throw BackendError.badResponse }
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
        _ = try await BackendClient.post("docuseal/complete", [
            "submitterId": submitterId,
            "signerName":  signerName,
            "evidence": [
                "signedAt":      stamp.isoTimestamp,
                "deviceId":      deviceId,
                "signatureHash": stamp.hash,
                "consentText":   consentText,
            ],
        ])
    }

    /// Path B only. Ask SignWell whether every recipient has signed.
    static func signwellIsComplete(ref: ProviderRef) async throws -> Bool {
        let json = try await BackendClient.post("signwell/status", ["documentId": ref.documentId])
        return ((json as? [String: Any])?["status"] as? String)?.lowercased() == "completed"
    }

    /// Provider ids arrive as Int or String depending on the vendor.
    private static func idString(_ v: Any?) -> String? {
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

    static func render(_ contract: GeneratedContract) -> Data {
        let page   = CGRect(x: 0, y: 0, width: 612, height: 792)        // US Letter, points
        let inset  = page.insetBy(dx: 72, dy: 72)

        let body = NSMutableAttributedString()
        body.append(NSAttributedString(string: contract.title + "\n\n", attributes: [
            .font: UIFont.systemFont(ofSize: 22, weight: .bold),
            .foregroundColor: UIColor.black,
        ]))
        let doc = contract.displayBody()
        // Force a print-safe colour; the editor uses dynamic label colours.
        doc.addAttribute(.foregroundColor, value: UIColor.black, range: NSRange(location: 0, length: doc.length))
        body.append(doc)

        let renderer = UIGraphicsPDFRenderer(bounds: page)
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

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
