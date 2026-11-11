import Foundation
import CryptoKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Short signing links
//
// A full signing link carries the whole contract (~5,000+ characters), which
// plain SMS can cut off. A short link carries only an id and a key:
//
//     https://gethandshake.app/sign/#s=<id>.<key>
//
// The app encrypts the link's contents (the same fragment the long link
// carries) with a fresh AES-256-GCM key, uploads only the ciphertext to the
// link page's own site (Cloudflare, web/functions/api/links), and puts the key
// after the "#" — browsers never send that part to a server, so the host
// stores bytes it can't read. The page fetches them and decrypts in the
// browser. Stored links expire after a year.
//
// If the upload fails (offline, site down), the caller sends the long link,
// which still works everywhere except plain SMS.
// ─────────────────────────────────────────────────────────────────────────────

enum ShortLinks {
    /// The short link for this fragment ("id=…&d=…&ds=…") on `page`
    /// ("https://gethandshake.app/sign/"), or nil if it couldn't be stored.
    static func make(fragment: String, page: String) async -> String? {
        guard let pageURL = URL(string: page), let scheme = pageURL.scheme, let host = pageURL.host,
              let api = URL(string: "\(scheme)://\(host)/api/links") else { return nil }

        let key = SymmetricKey(size: .bits256)
        guard let sealed = try? AES.GCM.seal(Data(fragment.utf8), using: key),
              let combined = sealed.combined else { return nil }   // nonce ‖ ciphertext ‖ tag

        var req = URLRequest(url: api, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = combined
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["id"] as? String,
                  id.range(of: "^[A-Za-z0-9_-]{12}$", options: .regularExpression) != nil
            else { return nil }
            let k = key.withUnsafeBytes { Data($0) }
            return "\(page)#s=\(id).\(base64url(k))"
        } catch {
            print("Short link failed — sending the full link:", error.localizedDescription)
            return nil
        }
    }

    private static func base64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
