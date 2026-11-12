import Foundation
import AuthenticationServices

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - AccountStore
//
// The signed-in account, via Sign in with Apple. Apple's stable user
// identifier plus the name and email Apple shares on the FIRST sign-in only
// (later sign-ins return just the identifier, so those two are kept from the
// first time) live on this device.
//
// With the backend set up, signing in also makes the Handshake account there
// (send credits, SendCredits.swift): Apple's identity token goes to
// /auth/apple and the session comes back into BackendSession.
//
// "Log out" forgets the account on this device. Apple has no server-side
// session to end; to remove Handshake from their Apple Account entirely, a
// user goes to Settings › Apple Account › Sign in with Apple.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
@Observable
final class AccountStore {

    static let shared = AccountStore()

    private(set) var userID: String?
    private(set) var name:   String?
    private(set) var email:  String?

    var isSignedIn: Bool { userID != nil }

    /// Initials for the avatar: "Dana Whitfield" → "DW".
    var initials: String {
        let parts = (name ?? "").split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    private let defaults = UserDefaults.standard
    private enum Key {
        static let userID = "account.appleUserID"
        static let name   = "account.name"
        static let email  = "account.email"
    }

    /// The raw nonce for the sign-in in progress; Apple gets its hash.
    private var pendingNonce: String?

    private init() {
        userID = defaults.string(forKey: Key.userID)
        name   = defaults.string(forKey: Key.name)
        email  = defaults.string(forKey: Key.email)
    }

    /// The request side of a SignInWithAppleButton.
    func prepare(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = [.fullName, .email]
        let nonce = AppleNonce.make()
        pendingNonce = nonce
        request.nonce = AppleNonce.sha256(nonce)
    }

    /// Result of a SignInWithAppleButton. nil when signed in (or cancelled),
    /// otherwise the message to show.
    func handle(_ result: Result<ASAuthorization, Error>) async -> String? {
        switch result {
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return nil }
            return error.localizedDescription
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential else {
                return String(localized: "Sign in didn't return an Apple ID.")
            }
            userID = cred.user
            let full = [cred.fullName?.givenName, cred.fullName?.familyName]
                .compactMap { $0 }.joined(separator: " ")
            if !full.isEmpty    { name  = full }
            if let e = cred.email { email = e }
            save()
            return await connectBackend(cred)
        }
    }

    /// Makes (or finds) the Handshake account on the backend and keeps its
    /// session. Signed in to Apple either way; this only fails the backend part.
    private func connectBackend(_ cred: ASAuthorizationAppleIDCredential) async -> String? {
        guard BackendClient.isConfigured else { return nil }
        guard let data = cred.identityToken, let token = String(data: data, encoding: .utf8) else {
            return String(localized: "Signed in, but Apple didn't return a token for Handshake. Try again.")
        }
        var body: [String: Any] = ["idToken": token]
        if let pendingNonce { body["nonce"] = pendingNonce }
        pendingNonce = nil
        do {
            let json = try await BackendClient.post("auth/apple", body, authorized: false)
            await BackendSession.shared.store((json as? [String: Any])?["session"])
            CreditsStore.shared.signedIn(json)
            return nil
        } catch {
            return String(localized: "Signed in, but couldn't reach Handshake: \(error.localizedDescription)")
        }
    }

    func signOut() {
        userID = nil; name = nil; email = nil
        save()
        CreditsStore.shared.signedOut()
        Task { await BackendSession.shared.clear() }
    }

    /// The user can revoke Handshake from their Apple Account settings at any
    /// time; when they have, forget the account here too. Call on launch.
    func refreshCredentialState() async {
        guard let id = userID else { return }
        let state = try? await ASAuthorizationAppleIDProvider().credentialState(forUserID: id)
        if state == .revoked || state == .notFound { signOut() }
    }

    private func save() {
        defaults.set(userID, forKey: Key.userID)
        defaults.set(name,   forKey: Key.name)
        defaults.set(email,  forKey: Key.email)
    }
}
