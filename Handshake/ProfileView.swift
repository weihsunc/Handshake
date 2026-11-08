import SwiftUI
import StoreKit
import AuthenticationServices

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ProfileView
//
// Opened from the person button on Home. Four parts:
//   account   Sign in with Apple (AccountStore). Name + email, or a sign-in button.
//   plan      What the user is subscribed to. Billing is Apple's: StoreKit's own
//             manage-subscriptions sheet and AppStore.sync() for restore.
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
    @State private var plan: String = "Free"
    @State private var showManage   = false
    @State private var confirmLogout = false
    @State private var restoring    = false
    @State private var message: String? = nil
    @Environment(\.dismiss) private var dismiss

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            List {
                accountSection
                planSection
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
        .manageSubscriptionsSheet(isPresented: $showManage)
        .task { await loadPlan() }
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
                            LinearGradient(colors: [Color.brandFill,
                                                    Color.brandDeep],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.name ?? "Apple ID")
                            .font(.headline)
                        Text(account.email ?? "Email hidden by Apple")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
                LabeledContent("Signed in with", value: "Apple")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Sign in to keep your name and plan with you.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.fullName, .email]
                    } onCompletion: { result in
                        message = account.handle(result)
                    }
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(height: 50)
                    .clipShape(Capsule())
                }
                .padding(.vertical, 6)
            }
        } header: {
            Text("Account")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Plan & billing (Apple)
    // ─────────────────────────────────────────────────────────────────────────

    private var planSection: some View {
        Section {
            LabeledContent("Current plan", value: plan)
            Button("Manage Subscription") { showManage = true }
            Button(restoring ? "Restoring…" : "Restore Purchases") {
                Task { await restore() }
            }
            .disabled(restoring)
        } header: {
            Text("Plan & Billing")
        } footer: {
            Text("Billing is handled by Apple. Payments, renewals, cancellations and refunds are managed in your Apple Account.")
        }
        .tint(Color.brand)
    }

    /// The active auto-renewing subscription, if any. Products come from App
    /// Store Connect; until some exist this always reads "Free".
    private func loadPlan() async {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result,
                  t.productType == .autoRenewable, t.revocationDate == nil else { continue }
            let product = try? await Product.products(for: [t.productID]).first
            plan = product?.displayName ?? t.productID
        }
    }

    private func restore() async {
        restoring = true
        defer { restoring = false }
        do {
            try await AppStore.sync()
            await loadPlan()
            message = plan == "Free" ? "No purchases to restore." : "Restored: \(plan)."
        } catch {
            message = error.localizedDescription
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Legal
    // ─────────────────────────────────────────────────────────────────────────

    private var signingProvider: String {
        guard BackendClient.isConfigured else { return "On this device" }
        switch Secrets.signingBackend {
        case .onDevice: return "On this device"
        case .docuseal: return "DocuSeal"
        case .signwell: return "SignWell"
        }
    }

    private var signingExplanation: String {
        let biometry = SignatureService.biometryName
        switch signingProvider {
        case "DocuSeal", "SignWell":
            return "Signatures are confirmed with \(biometry) and completed through \(signingProvider)."
        default:
            return "Signatures are confirmed with \(biometry). Handshake keeps a fingerprint of each signature on this \(UIDevice.current.model); no third party holds a copy."
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
        .tint(Color.brand)
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
