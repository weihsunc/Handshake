import SwiftUI

@main
struct HandshakeApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - RootView
//
// Owns the app's single deep-link entry point. Recipients receive a link of the
// form:
//
//     handshake://sign/<contract-uuid>
//
// (see SendFlowView). Opening it presents the signing screen for that contract.
// The scheme itself is registered in Handshake/Info.plist.
// ─────────────────────────────────────────────────────────────────────────────

struct RootView: View {

    @State private var signingTarget: SigningTarget? = nil
    @State private var linkError:     LinkError?     = nil

    var body: some View {
        NavigationStack {
            HomeView()
        }
        .onOpenURL { open($0) }
        .fullScreenCover(item: $signingTarget) { target in
            SigningView(contract: target.contract)
        }
        .alert(item: $linkError) { err in
            Alert(title: Text("Can't open this link"),
                  message: Text(err.message),
                  dismissButton: .default(Text("OK")))
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Routing
    // ─────────────────────────────────────────────────────────────────────────

    private func open(_ url: URL) {
        guard let route = Self.route(for: url) else { return }   // not our scheme

        // Anything already presented has to come down first: a live
        // fullScreenCover swallows the alert, and SwiftUI ignores a second
        // `item:` binding change while the first is still on screen.
        guard signingTarget == nil, linkError == nil else {
            signingTarget = nil
            linkError     = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))   // dismiss animation
                apply(route)
            }
            return
        }

        apply(route)
    }

    private func apply(_ route: Route) {
        switch route {
        case .sign(let contract): signingTarget = SigningTarget(contract: contract)
        case .failed(let message): linkError    = LinkError(message: message)
        }
    }

    /// Pure URL → route resolution. Returns nil for URLs that aren't ours.
    private static func route(for url: URL) -> Route? {
        guard url.scheme?.lowercased() == "handshake" else { return nil }

        // handshake://sign/<uuid>  →  host "sign", uuid as the path
        guard url.host?.lowercased() == "sign" else {
            return .failed("That link isn't a signing link.")
        }

        guard let id = UUID(uuidString: url.lastPathComponent) else {
            return .failed("That signing link is malformed.")
        }

        guard let contract = ContractStore.shared.contract(id: id) else {
            // Expected on a second device — contracts live only on the device
            // that created them until there's a backend (HANDOFF §7).
            return .failed("This contract isn't on this device. Contracts are stored locally, so a signing link only opens on the device that created it.")
        }

        return .sign(contract)
    }

    private enum Route {
        case sign(GeneratedContract)
        case failed(String)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Routing values
// ─────────────────────────────────────────────────────────────────────────────

struct SigningTarget: Identifiable {
    let contract: GeneratedContract
    var id: UUID { contract.id }
}

struct LinkError: Identifiable {
    let message: String
    var id: String { message }
}
