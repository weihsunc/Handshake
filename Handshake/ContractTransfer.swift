import Foundation
import Compression

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ContractTransfer
//
// Moves a contract between two phones with no server. The link carries the
// document itself, not just an id:
//
//     handshake://sign/<uuid>?d=<base64url(zlib(JSON))>
//
// The JSON is a stripped GeneratedContract — title, markdown body, recipients,
// status, timestamps, signer/hash if signed. The RTFD is deliberately left out
// (it's ~10× the size and the recipient never edits), so the recipient sees
// the markdown rendering. Deflate keeps a typical 8 KB contract to ~2.5 KB,
// which survives SMS, Mail and the share sheet.
//
// The same encoding, with status = .signed, carries the signed copy back to
// the sender. So both directions work over any messaging channel, offline,
// with nothing stored anywhere but the two phones.
// ─────────────────────────────────────────────────────────────────────────────

enum ContractTransfer {

    /// The wire form. A subset of GeneratedContract so future fields on the
    /// model can't silently bloat or break links.
    struct Payload: Codable {
        var v = 1
        var id: UUID
        var title: String
        var content: String
        var recipients: [Recipient]
        var status: ContractStatus
        var createdAt: Date
        var sentAt: Date?
        var signedAt: Date?
        var signedBy: String?
        var signatureHash: String?
        // Added Nov 8 — optional, so links from older builds still decode.
        /// The sender's name, when they're signed in.
        var from: String?
        /// Which signature slot the recipient signed, and the date they
        /// entered, so the sender's copy can be stamped to match.
        var signedSlot: Int?
        var signedDate: Date?
        // Parties (Nov 8 evening) — optional for the same reason.
        /// Every signature so far, one per box.
        var sigs: [PartySignature]?
        /// How many signatures complete it.
        var parties: Int?
        /// The box THIS link's recipient signs. Each recipient gets their own
        /// link, so this is how their phone knows without asking.
        var me: Int?
        /// The sender's email or phone, for the copy coming back.
        var reply: String?
        var declinedBy: String?
        var declineReason: String?
        var change: ChangeRequest?

        init(_ c: GeneratedContract) {
            id = c.id; title = c.title; content = c.content
            recipients = c.recipients; status = c.status
            createdAt = c.createdAt; sentAt = c.sentAt; signedAt = c.signedAt
            signedBy = c.signedBy; signatureHash = c.signatureHash
            from = c.senderName; signedSlot = c.signedSlot; signedDate = c.signedDate
            sigs = c.signatures.isEmpty ? nil : c.signatures
            parties = c.partyCount; me = c.myParty; reply = c.replyTo
            declinedBy = c.declinedBy; declineReason = c.declineReason; change = c.changeRequest
        }

        var contract: GeneratedContract {
            var c = GeneratedContract(id: id, title: title, content: content)
            c.recipients = recipients; c.status = status
            c.createdAt = createdAt; c.sentAt = sentAt; c.signedAt = signedAt
            c.signedBy = signedBy; c.signatureHash = signatureHash
            c.senderName = from; c.signedSlot = signedSlot; c.signedDate = signedDate
            c.partyCount = parties; c.myParty = me; c.replyTo = reply
            c.declinedBy = declinedBy; c.declineReason = declineReason; c.changeRequest = change
            if let sigs {
                c.signatures = sigs
            } else if let signedBy, let signatureHash {
                // A signed copy from an older build: one signer, the slot and
                // date as separate fields.
                c.signatures = [PartySignature(slot: signedSlot ?? 0, role: nil, name: signedBy,
                                               signedAt: signedAt ?? .now, hash: signatureHash,
                                               date: signedDate, method: nil)]
            }
            return c
        }
    }

    // ── Encode ───────────────────────────────────────────────────────────────

    static func signingLink(for c: GeneratedContract) -> String {
        "handshake://sign/\(c.id.uuidString)?d=\(encode(c))"
    }

    static func signedCopyLink(for c: GeneratedContract) -> String {
        "handshake://signed/\(c.id.uuidString)?d=\(encode(c))"
    }

    /// A recipient's answer that isn't a signature: declined, or asked for changes.
    static func replyLink(for c: GeneratedContract) -> String {
        "handshake://reply/\(c.id.uuidString)?d=\(encode(c))"
    }

    static func encode(_ c: GeneratedContract) -> String {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let json = (try? enc.encode(Payload(c))) ?? Data()
        return base64url(deflate(json))
    }

    // ── Decode ───────────────────────────────────────────────────────────────

    static func decode(_ d: String) -> GeneratedContract? {
        guard let raw = unbase64url(d), let json = inflate(raw) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(Payload.self, from: json))?.contract
    }

    /// Is there a `d` payload at all? Separates "this link was cut short"
    /// (payload present but unreadable) from "this link never had one".
    static func hasPayload(in url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.contains { $0.name == "d" } ?? false
    }

    /// Pulls the `d` query item off a handshake:// URL, if present.
    static func payload(in url: URL) -> GeneratedContract? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "d" }?.value
            .flatMap(decode)
    }

    // ── zlib via Compression ─────────────────────────────────────────────────

    private static func deflate(_ data: Data) -> Data { transform(data, COMPRESSION_STREAM_ENCODE) }
    private static func inflate(_ data: Data) -> Data? {
        let out = transform(data, COMPRESSION_STREAM_DECODE)
        return out.isEmpty ? nil : out
    }

    private static func transform(_ input: Data, _ op: compression_stream_operation) -> Data {
        var out = Data()
        let bufSize = 64 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }

        var stream = compression_stream(dst_ptr: buf, dst_size: bufSize, src_ptr: buf, src_size: 0, state: nil)
        guard compression_stream_init(&stream, op, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return Data() }
        defer { compression_stream_destroy(&stream) }

        return input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data in
            stream.src_ptr  = src.bindMemory(to: UInt8.self).baseAddress!
            stream.src_size = input.count
            repeat {
                stream.dst_ptr  = buf
                stream.dst_size = bufSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                out.append(buf, count: bufSize - stream.dst_size)
                if status == COMPRESSION_STATUS_END { break }
                if status == COMPRESSION_STATUS_ERROR { return Data() }
            } while true
            return out
        }
    }

    // ── base64url (no padding, URL-safe) ─────────────────────────────────────

    private static func base64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func unbase64url(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }
}
