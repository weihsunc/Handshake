import Foundation
import AuthenticationServices

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - AccountStore
//
// The signed-in account, via Sign in with Apple. There's no Handshake server,
// so the account lives on this device: Apple's stable user identifier plus
// the name and email Apple shares on the FIRST sign-in only (later sign-ins
// return just the identifier, so those two are kept from the first time).
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

    private init() {
        userID = defaults.string(forKey: Key.userID)
        name   = defaults.string(forKey: Key.name)
        email  = defaults.string(forKey: Key.email)
    }

    /// Result of a SignInWithAppleButton.
    func handle(_ result: Result<ASAuthorization, Error>) -> String? {
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
            return nil
        }
    }

    func signOut() {
        userID = nil; name = nil; email = nil
        save()
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
