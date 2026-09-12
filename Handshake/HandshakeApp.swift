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
    @State private var viewTarget:    SigningTarget? = nil
    @State private var linkError:     LinkError?     = nil

    var body: some View {
        NavigationStack {
            HomeView()
        }
        .onOpenURL { open($0) }
        #if DEBUG
        // Feeds a handshake:// URL straight to the router at launch, skipping
        // the system "Open in Handshake?" prompt that a headless test can't tap:
        //   xcrun simctl launch <udid> com.weihsun.Handshake -HandshakeOpenURL 'handshake://…'
        .task {
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-HandshakeOpenURL"), i + 1 < args.count,
               let url = URL(string: args[i + 1]) {
                try? await Task.sleep(for: .milliseconds(600))
                open(url)
            }
        }
        #endif
        .fullScreenCover(item: $signingTarget) { target in
            SigningView(contract: target.contract)
        }
        .sheet(item: $viewTarget) { target in
            ReadOnlyContractView(contract: target.contract)
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
        viewTarget    = nil
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
        case .view(let contract): viewTarget    = SigningTarget(contract: contract)
        case .failed(let message): linkError    = LinkError(message: message)
        }
    }

    /// Pure URL → route resolution. Returns nil for URLs that aren't ours.
    private static func route(for url: URL) -> Route? {
        guard url.scheme?.lowercased() == "handshake" else { return nil }

        guard let id = UUID(uuidString: url.lastPathComponent) else {
            return .failed("That link is malformed.")
        }
        let store = ContractStore.shared

        switch url.host?.lowercased() {

        // handshake://sign/<uuid>?d=…  — a recipient opening an invitation.
        case "sign":
            if let local = store.contract(id: id) {
                return .sign(local)                       // same phone as the sender
            }
            if let carried = ContractTransfer.payload(in: url) {
                // Another phone: the link brought the document with it.
                // Keep a local copy so History shows it and re-opens work.
                store.upsert(carried)
                return .sign(carried)
            }
            return .failed("This link doesn't contain the contract. Ask the sender to send it again from the latest version of Handshake.")

        // handshake://signed/<uuid>?d=…  — the signed copy coming back to the sender.
        case "signed":
            guard let carried = ContractTransfer.payload(in: url), carried.status == .signed else {
                return .failed("That signed copy couldn't be read.")
            }
            if let mine = store.contract(id: id) {
                // Sender's own record: keep their edits, take the signature.
                store.markSigned(id: mine.id,
                                 signedBy: carried.signedBy,
                                 signatureHash: carried.signatureHash)
                if let updated = store.contract(id: id) { return .view(updated) }
            }
            store.upsert(carried)                          // no local record — just show it
            return .view(carried)

        default:
            return .failed("That link isn't a signing link.")
        }
    }

    private enum Route {
        case sign(GeneratedContract)
        case view(GeneratedContract)       // read-only: a signed copy arrived
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
