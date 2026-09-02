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

        // Everything presented anywhere has to come down before we can
        // present: RootView's own cover/alert, but also HomeView's workspace
        // cover and history sheet — SwiftUI only lets one presentation per
        // view be active, and a cover already up under HomeView blocks ours
        // entirely, so the link would be silently dropped.
        signingTarget = nil
        linkError     = nil
        DeepLinkRouter.shared.dismissAll()

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))   // dismiss animations
            apply(route)
        }
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
// MARK: - DeepLinkRouter
//
// The one thing a deep link needs from the rest of the app: "close whatever
// you have open." Views that present sheets or covers observe `dismissTick`
// and drop their presentation state when it changes.
// ─────────────────────────────────────────────────────────────────────────────

@Observable
final class DeepLinkRouter {
    static let shared = DeepLinkRouter()
    private(set) var dismissTick = 0
    private init() {}

    func dismissAll() { dismissTick += 1 }
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
