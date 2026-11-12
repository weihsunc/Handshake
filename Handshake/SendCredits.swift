import SwiftUI
import CryptoKit
import Security
import AuthenticationServices

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Send credits
//
// Pricing (owner, Nov 11, 2026): 2 free sends per Apple ID, then $2.99 a send.
// Only the sender pays; signing is always free. The balance lives on the
// backend (Supabase), never on the phone, so it survives a reinstall or a
// new phone and can't be edited here.
//
//   BackendSession   the Handshake account session made from Sign in with
//                    Apple (Supabase Auth), kept in the Keychain. BackendClient
//                    sends its access token with every call.
//   CreditsStore     sends left, for Profile and the send flow.
//   SignInToSendButton  Sign in with Apple, with the nonce the backend checks.
//
// The backend charges when the DocuSeal submission is made (/docuseal/start):
// 402 no_credits when none are left, 401 sign_in_required once it enforces
// credits (ENFORCE_CREDITS). Buying sends (StoreKit) waits on the Apple
// Developer account.
// ─────────────────────────────────────────────────────────────────────────────

actor BackendSession {

    static let shared = BackendSession()

    struct Tokens: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
    }

    private var tokens: Tokens?
    private var refreshing: Task<Tokens?, Never>?

    private init() { tokens = Keychain.load() }

    var hasSession: Bool { tokens != nil }

    /// Keeps the `session` object the backend returns from /auth/apple.
    func store(_ session: Any?) {
        guard let t = Self.parse(session) else { return }
        tokens = t
        Keychain.save(t)
    }

    func clear() {
        tokens = nil
        Keychain.delete()
    }

    /// The access token was refused: refresh on the next call.
    func expire() {
        tokens?.expiresAt = .distantPast
    }

    /// An access token good for at least a minute, refreshed when needed.
    /// nil when signed out, or when the session can't be renewed (then it's
    /// forgotten and the user signs in again).
    func accessToken() async -> String? {
        guard let t = tokens else { return nil }
        if t.expiresAt.timeIntervalSinceNow > 60 { return t.accessToken }
        if let refreshing { return await refreshing.value?.accessToken }

        let task = Task { () -> Tokens? in
            do {
                let json = try await BackendClient.post("auth/refresh", ["refreshToken": t.refreshToken], authorized: false)
                return Self.parse((json as? [String: Any])?["session"])
            } catch BackendError.http(let code, _) where code == 401 {
                return nil                      // refresh token no longer valid
            } catch {
                return t                        // offline: keep it, the call fails on its own
            }
        }
        refreshing = task
        let new = await task.value
        refreshing = nil
        if let new { tokens = new; Keychain.save(new) } else { clear() }
        return new?.accessToken
    }

    private static func parse(_ any: Any?) -> Tokens? {
        guard let s = any as? [String: Any],
              let access = s["accessToken"] as? String,
              let refresh = s["refreshToken"] as? String else { return nil }
        let expires = (s["expiresAt"] as? Double).map(Date.init(timeIntervalSince1970:))
            ?? Date().addingTimeInterval(3600)
        return Tokens(accessToken: access, refreshToken: refresh, expiresAt: expires)
    }

    /// One Keychain item, this device only (not synced, not in backups).
    private enum Keychain {
        static let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: "com.weihsun.Handshake.backend",
            kSecAttrAccount as String: "session",
        ]

        static func load() -> Tokens? {
            var q = query
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
                  let data = out as? Data else { return nil }
            return try? JSONDecoder().decode(Tokens.self, from: data)
        }

        static func save(_ t: Tokens) {
            guard let data = try? JSONEncoder().encode(t) else { return }
            delete()
            var q = query
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(q as CFDictionary, nil)
        }

        static func delete() {
            SecItemDelete(query as CFDictionary)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - CreditsStore
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
@Observable
final class CreditsStore {

    static let shared = CreditsStore()

    /// Matches FREE_SENDS in the backend; for copy only — the backend decides.
    static let freeSends = 2

    /// Sends left. nil until known (signed out, or not loaded yet).
    private(set) var credits: Int?
    /// Signed in to the backend (not just to Apple on this phone).
    private(set) var hasSession = false

    private init() {}

    func refresh() async {
        hasSession = await BackendSession.shared.hasSession
        guard hasSession, BackendClient.isConfigured else { credits = nil; return }
        if let json = try? await BackendClient.post("credits/balance", [:]) as? [String: Any],
           let c = json["credits"] as? Int {
            credits = c
        }
        hasSession = await BackendSession.shared.hasSession
        if !hasSession { credits = nil }
    }

    /// The balance the backend reported with a send or a sign-in.
    func update(_ json: Any) {
        if let c = (json as? [String: Any])?["credits"] as? Int { credits = c }
    }

    func signedIn(_ json: Any) {
        hasSession = true
        update(json)
    }

    func signedOut() {
        hasSession = false
        credits = nil
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Sign in with Apple, with a nonce
// ─────────────────────────────────────────────────────────────────────────────

/// Apple puts the SHA-256 of this into the identity token; the backend
/// (Supabase Auth) checks it against the raw value, so a stolen token can't
/// be replayed.
enum AppleNonce {
    static func make() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Apple's button, wired to AccountStore. `done` gets nil on success, or the
/// message to show (cancelling shows nothing and doesn't call it).
struct SignInToSendButton: View {
    var done: (String?) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SignInWithAppleButton(.signIn) { request in
            AccountStore.shared.prepare(request)
        } onCompletion: { result in
            if case .failure(let e) = result, (e as? ASAuthorizationError)?.code == .canceled { return }
            Task { done(await AccountStore.shared.handle(result)) }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: 50)
        .clipShape(Capsule())
    }
}

/// Shown when the backend wants a signed-in sender (401 sign_in_required).
struct SignInToSendSheet: View {
    var signedIn: () -> Void
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign in to send")
                .font(.title2.weight(.semibold))
            Text("Your first \(CreditsStore.freeSends) contracts are free to send. Signing is always free for the people you send to.")
                .font(.body)
                .foregroundStyle(.secondary)
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            SignInToSendButton { error in
                if let error { message = error; return }
                dismiss()
                signedIn()
            }
        }
        .padding(24)
        .presentationDetents([.height(300)])
    }
}
