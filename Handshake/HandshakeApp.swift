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

        // handshake://signed/<uuid>?d=…  — the signed copy coming back to the sender.
        case "signed":
            guard let carried = ContractTransfer.payload(in: url), carried.status == .signed else {
                return .failed(Self.unreadableMessage(url))
            }
            if let mine = store.contract(id: id) {
                // Opening the same copy twice mustn't stamp twice.
                if mine.status == .signed, mine.signatureHash == carried.signatureHash {
                    return .view(mine)
                }
                // Sender's own record: keep their edits, and put the signer's
                // stamp and date into it. Before, only the status changed —
                // the sender's "Signed" copy still showed an empty box.
                let stamped = Self.stamped(mine.displayBody(), with: carried)
                store.markSigned(id: mine.id,
                                 signedBy: carried.signedBy,
                                 signatureHash: carried.signatureHash,
                                 bodyRTFD: stamped?.rtfd,
                                 attachmentSizes: stamped?.sizes,
                                 signedAt: carried.signedAt ?? .now,
                                 signedSlot: carried.signedSlot,
                                 signedDate: carried.signedDate)
                if let updated = store.contract(id: id) { return .view(updated) }
            }
            // No local record — show it, stamped the same way.
            var copy = carried
            if let stamped = Self.stamped(carried.displayBody(), with: carried) {
                copy.bodyRTFD = stamped.rtfd
                copy.attachmentSizes = stamped.sizes
            }
            store.upsert(copy)
            return .view(copy)

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

    /// The signer's stamp and date, put into `body` in the slot they signed.
    /// Returns nil (leave the document alone) when there's no signature to
    /// draw — older links carry no slot, so the first slot is used then.
    @MainActor
    private static func stamped(_ body: NSMutableAttributedString,
                                with signed: GeneratedContract) -> (rtfd: Data, sizes: [CGSize])? {
        guard let name = signed.signedBy, let hash = signed.signatureHash else { return nil }
        let stamp = SignatureStamp(signerName: name, signedAt: signed.signedAt ?? .now, hash: hash)
        let slots = SignatureSlots.find(in: body)
        let slot  = signed.signedSlot.flatMap { slots.indices.contains($0) ? slots[$0].range : nil }
        // The signer's screen width isn't known here; 360 is a phone's text
        // column, and the block clamps to 200…420 anyway.
        body.stampSignature(stamp, width: 360, slot: slot, signedDate: signed.signedDate)
        guard let rtfd = try? body.data(from: NSRange(location: 0, length: body.length),
                                        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        else { return nil }
        return (rtfd, body.attachmentSizes)
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
