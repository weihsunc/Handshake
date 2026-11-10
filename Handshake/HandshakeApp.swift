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
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            HomeView()
        }
        .onOpenURL { open($0) }
        // Something shared to Handshake whose extension couldn't open the app.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { ImportHandling.checkInbox() }
        }
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
        // handshake://import/<id> — from the share extension, not a signing link.
        if url.scheme?.lowercased() == "handshake", url.host?.lowercased() == "import" {
            if let id = UUID(uuidString: url.lastPathComponent) {
                signingTarget = nil; viewTarget = nil
                ImportHandling.open(id)
            }
            return
        }
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
            return .failed(String(localized: "That link is malformed."))
        }
        let store = ContractStore.shared

        switch url.host?.lowercased() {

        // handshake://sign/<uuid>?d=…  — a recipient opening an invitation.
        case "sign":
            let carried = ContractTransfer.payload(in: url).map { c -> GeneratedContract in
                var c = c; c.isIncoming = true; return c
            }
            if let local = store.contract(id: id) {
                // A copy that came in by link and isn't signed yet is replaced
                // by the newer one: a sender who edits and re-sends would
                // otherwise leave the recipient looking at the old version.
                // The sender's own record (not incoming) is never touched.
                if local.isIncoming, local.status != .signed, let carried {
                    store.upsert(carried)
                    return .sign(carried)
                }
                return .sign(local)                       // same phone as the sender
            }
            if let carried {
                // Another phone: the link brought the document with it.
                // Keep a local copy so History shows it and re-opens work.
                store.upsert(carried)
                return .sign(carried)
            }
            return .failed(Self.unreadableMessage(url))

        // handshake://signed/<uuid>?d=…  — a signed copy: a recipient's coming
        // back to the sender, or the sender's completed copy going round.
        case "signed":
            guard let carried = ContractTransfer.payload(in: url), !carried.signatures.isEmpty else {
                return .failed(Self.unreadableMessage(url))
            }
            if var mine = store.contract(id: id) {
                // A copy signed by an older build has its stamp baked into
                // the document and no records; leave it as it is.
                if mine.signatures.isEmpty, mine.status == .signed, mine.bodyRTFD != nil {
                    return .view(mine)
                }
                // Each signature goes in its own box; boxes already signed
                // keep theirs. Before, the last copy back overwrote the
                // record, so a second signer replaced the first.
                mine.merge(signatures: carried.signatures)
                if mine.partyCount == nil { mine.partyCount = carried.partyCount }
                mine.refreshCompletion()
                store.upsert(mine)
                return .view(mine)
            }
            // No local record — keep the copy as it came.
            store.upsert(carried)
            return .view(carried)

        // handshake://reply/<uuid>?d=…  — a recipient declined, or asked for changes.
        case "reply":
            guard let carried = ContractTransfer.payload(in: url) else {
                return .failed(Self.unreadableMessage(url))
            }
            guard store.contract(id: id) != nil else {
                return .failed(String(localized: "This reply is about a contract that isn't on this phone."))
            }
            store.update(id: id) { c in
                if carried.status == .declined {
                    c.status        = .declined
                    c.declinedBy    = carried.declinedBy
                    c.declineReason = carried.declineReason
                    c.changeRequest = nil          // a decline answers the contract as a whole
                } else if let request = carried.changeRequest {
                    c.changeRequest = request
                }
            }
            if let updated = store.contract(id: id) { return .view(updated) }
            return .failed(Self.unreadableMessage(url))

        default:
            return .failed(String(localized: "That link isn't a signing link."))
        }
    }

    /// A link with a payload that won't decode was almost always cut short
    /// on its way (a messaging app or a copy that dropped the tail).
    private static func unreadableMessage(_ url: URL) -> String {
        ContractTransfer.hasPayload(in: url)
            ? String(localized: "This link is incomplete. It may have been cut off when it was copied or forwarded. Ask the sender to send it again.")
            : String(localized: "This link doesn't contain the contract. Ask the sender to send it again from the latest version of Handshake.")
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
