import SwiftUI
import AuthenticationServices

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ProfileView
//
// Opened from the person button on Home. Four parts:
//   account   Sign in with Apple (AccountStore). Name + email, or a sign-in button.
//   sends     Sends left (CreditsStore): 2 free, then send packs bought
//             with StoreKit (SendPacks). The balance is the backend's.
//   legal     Which AI model drafts the contracts and what does the signing —
//             read from the code that actually does it, so it can't drift.
//   log out   Forgets the account on this device; contracts stay.
//
// Copy rule (HANDOFF §8): never call the signature legally binding.
// ─────────────────────────────────────────────────────────────────────────────

/// Fill these in once the pages exist; a row only appears when its URL is set.
/// The App Store requires a privacy policy URL before release.
enum LegalLinks {
    static let terms:   URL? = nil
    static let privacy: URL? = nil
}

struct ProfileView: View {

    @State private var account = AccountStore.shared
    @State private var credits = CreditsStore.shared
    @State private var showPacks = false
    @State private var confirmLogout = false
    @State private var message: String? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                accountSection
                if BackendClient.isConfigured { sendsSection }
                legalSection
                if account.isSignedIn { logoutSection }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.pageBackground.ignoresSafeArea())
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.body.weight(.semibold))
                }
            }
        }
        .task { await credits.refresh() }
        .sheet(isPresented: $showPacks) { SendPacksSheet() }
        .task { await account.refreshCredentialState() }
        .confirmationDialog("Log out of Handshake?", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Log Out", role: .destructive) { account.signOut() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your contracts stay on this \(UIDevice.current.model).")
        }
        .alert("Profile", isPresented: Binding(get: { message != nil },
                                               set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Account
    // ─────────────────────────────────────────────────────────────────────────

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if account.isSignedIn {
                HStack(spacing: 14) {
                    Text(account.initials)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(
                            LinearGradient(colors: [Color(.systemGray2),     // like Contacts' monogram
                                                    Color(.systemGray)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.name ?? "Apple ID")
                            .font(.headline)
                        Text(account.email ?? String(localized: "Email hidden by Apple"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
                LabeledContent("Signed in with", value: "Apple")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Sign in to keep your name and your sends with you.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    SignInToSendButton { message = $0 }
                }
                .padding(.vertical, 6)
            }
        } header: {
            Text("Account")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Sends
    // ─────────────────────────────────────────────────────────────────────────

    private var sendsSection: some View {
        Section {
            if let n = credits.credits {
                LabeledContent("Sends left", value: n.formatted())
                Button("Buy Sends") { showPacks = true }
            } else if account.isSignedIn && !credits.hasSession {
                // Signed in to Apple on this phone before accounts reached the
                // backend (or the session lapsed): sign in once more.
                VStack(alignment: .leading, spacing: 12) {
                    Text("Sign in again to see your sends.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    SignInToSendButton { message = $0 }
                }
                .padding(.vertical, 6)
            } else if credits.hasSession {
                LabeledContent("Sends left") { ProgressView() }
            } else {
                LabeledContent("Sends left", value: String(localized: "Sign in to see"))
            }
        } header: {
            Text("Sends")
        } footer: {
            Text("Your first \(CreditsStore.freeSends) contracts are free to send. Signing is always free for the people you send to.")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Legal
    // ─────────────────────────────────────────────────────────────────────────

    private var signingProvider: String {
        guard BackendClient.isConfigured else { return String(localized: "On this device") }
        switch Secrets.signingBackend {
        case .onDevice: return String(localized: "On this device")
        case .docuseal: return "DocuSeal"
        case .signwell: return "SignWell"
        }
    }

    private var signingExplanation: String {
        let biometry = SignatureService.biometryName
        switch signingProvider {
        case "DocuSeal", "SignWell":
            return String(localized: "Signatures are confirmed with \(biometry) and completed through \(signingProvider).")
        default:
            return String(localized: "Signatures are confirmed with \(biometry). Handshake keeps a fingerprint of each signature on this \(UIDevice.current.model); no third party holds a copy.")
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = info?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    private var legalSection: some View {
        Section {
            LabeledContent("AI model", value: "\(AIService.modelDisplayName) · Anthropic")
            LabeledContent("E-signature", value: signingProvider)
            if let url = LegalLinks.terms   { Link("Terms of Service", destination: url) }
            if let url = LegalLinks.privacy { Link("Privacy Policy",   destination: url) }
            LabeledContent("Version", value: appVersion)
        } header: {
            Text("Legal")
        } footer: {
            Text("Your prompts and contract text are sent to Anthropic to draft and revise contracts. \(signingExplanation) Drafts are generated by AI and aren't legal advice.")
        }
        .tint(Color.accent)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Log out
    // ─────────────────────────────────────────────────────────────────────────

    private var logoutSection: some View {
        Section {
            Button("Log Out", role: .destructive) { confirmLogout = true }
                .frame(maxWidth: .infinity)
        }
    }
}

#Preview {
    ProfileView()
}
