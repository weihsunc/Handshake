import SwiftUI
import StoreKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Send packs (StoreKit)
//
// Sends beyond the 2 free ones are bought in packs — consumable in-app
// purchases (App Store Connect, and Handshake.storekit for testing in Xcode):
//
//   com.weihsun.Handshake.sends.1    1 send     $2.99
//   com.weihsun.Handshake.sends.5    5 sends    $11.99
//   com.weihsun.Handshake.sends.10   10 sends   $19.99
//
// The balance is the backend's (SendCredits.swift). A purchase is made with
// the Handshake account's id as its appAccountToken, then StoreKit's signed
// transaction goes to /credits/purchase, which checks Apple's signature and
// adds the sends once. The transaction is finished only after the backend
// has counted it, so if the app quits or the connection drops in between,
// the next launch reports it again (Transaction.unfinished).
//
// Prices shown always come from StoreKit (displayPrice), never from here.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
@Observable
final class SendPacks {

    static let shared = SendPacks()

    /// Product id → sends. Matches PACKS in the backend.
    static let sends: [String: Int] = [
        "com.weihsun.Handshake.sends.1":  1,
        "com.weihsun.Handshake.sends.5":  5,
        "com.weihsun.Handshake.sends.10": 10,
    ]

    /// The packs, fewest sends first. Empty until loaded (or when the App
    /// Store has none, e.g. before they exist in App Store Connect).
    private(set) var products: [Product] = []
    private(set) var loaded = false

    private var listener: Task<Void, Never>?

    private init() {}

    func load() async {
        guard !loaded || products.isEmpty else { return }
        let found = (try? await Product.products(for: Array(Self.sends.keys))) ?? []
        products = found.sorted { (Self.sends[$0.id] ?? 0) < (Self.sends[$1.id] ?? 0) }
        loaded = true
    }

    /// Call once at launch.
    func start() {
        guard listener == nil else { return }
        listener = Task { [weak self] in
            for await result in StoreKit.Transaction.unfinished { _ = try? await self?.deliver(result) }
            for await result in StoreKit.Transaction.updates    { _ = try? await self?.deliver(result) }
        }
    }

    /// Buys a pack for the signed-in Handshake account. true when the sends
    /// were added; false when cancelled or waiting for approval (Ask to Buy —
    /// the sends come through `start()` once approved).
    func buy(_ product: Product, with purchase: PurchaseAction) async throws -> Bool {
        guard let account = await BackendSession.shared.userID() else { throw SendPacksError.signInRequired }
        switch try await purchase(product, options: [.appAccountToken(account)]) {
        case .success(let result):
            try await deliver(result)
            return true
        case .pending:
            throw SendPacksError.pending
        case .userCancelled:
            return false
        @unknown default:
            return false
        }
    }

    /// Reports a purchase to the backend and finishes it once counted. Not
    /// finished on failure, so it's tried again on the next launch.
    @discardableResult
    private func deliver(_ result: VerificationResult<StoreKit.Transaction>) async throws -> Int? {
        guard Self.sends[result.unsafePayloadValue.productID] != nil else { return nil }
        guard case .verified(let transaction) = result else { throw SendPacksError.unverified }
        do {
            let json = try await BackendClient.post("credits/purchase", ["jws": result.jwsRepresentation])
            CreditsStore.shared.update(json)
            await transaction.finish()
            return (json as? [String: Any])?["credits"] as? Int
        } catch BackendError.http(let code, _) where code == 403 {
            // Bought while signed in to another Handshake account; stays
            // unfinished until that account is signed in here again.
            throw SendPacksError.otherAccount
        }
    }

    /// "$2.40 each" for packs of more than one.
    static func perSend(_ product: Product) -> String? {
        guard let n = sends[product.id], n > 1 else { return nil }
        let each = (product.price / Decimal(n)).formatted(product.priceFormatStyle)
        return String(localized: "\(each) each")
    }
}

enum SendPacksError: LocalizedError {
    case signInRequired, pending, unverified, otherAccount

    var errorDescription: String? {
        switch self {
        case .signInRequired: return String(localized: "Sign in to buy sends.")
        case .pending:        return String(localized: "Your purchase is waiting for approval. The sends are added as soon as it's approved.")
        case .unverified:     return String(localized: "The App Store couldn't confirm this purchase. Try again, or contact support if you were charged.")
        case .otherAccount:   return String(localized: "This purchase belongs to another Handshake account. Sign in with that Apple ID to use it.")
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SendPacksSheet
//
// Opened from the send flow when no sends are left (then the send carries on
// once a pack is bought) and from Profile's Buy Sends.
// ─────────────────────────────────────────────────────────────────────────────

struct SendPacksSheet: View {
    /// True when opened because a send was refused; changes the heading.
    var outOfSends = false
    /// Called after sends were added (the sheet has closed).
    var bought: () -> Void = {}

    @State private var packs = SendPacks.shared
    @State private var credits = CreditsStore.shared
    @State private var buying: Product.ID?
    @State private var message: String?
    @Environment(\.purchase) private var purchase
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(outOfSends ? "No sends left" : "Get more sends")
                            .font(.title2.weight(.semibold))
                        Text(outOfSends
                             ? "You've used your \(CreditsStore.freeSends) free sends. Buy a pack to send this contract."
                             : "Each send is one contract, however many people sign it.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                if !credits.hasSession {
                    Section {
                        SignInToSendButton { message = $0 }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                    } footer: {
                        Text("Sends belong to your Handshake account, so sign in first.")
                    }
                }

                Section {
                    if packs.products.isEmpty {
                        if packs.loaded {
                            Text("Sends can't be bought right now. Try again later.")
                                .foregroundStyle(.secondary)
                        } else {
                            HStack { Spacer(); ProgressView(); Spacer() }
                        }
                    }
                    ForEach(packs.products) { product in
                        packRow(product)
                    }
                } footer: {
                    Text("Sending the same contract again after changes is free. Signing is always free for the people you send to. Payment is through your Apple Account.")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.pageBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            await packs.load()
            await credits.refresh()
        }
        .alert("Sends", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
        .interactiveDismissDisabled(buying != nil)
    }

    private func packRow(_ product: Product) -> some View {
        Button {
            Task { await buy(product) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(product.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if let each = SendPacks.perSend(product) {
                        Text(each)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if buying == product.id {
                    ProgressView()
                } else {
                    Text(product.displayPrice)
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.accent.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.accent)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .disabled(buying != nil || !credits.hasSession)
        .accessibilityLabel("\(product.displayName), \(product.displayPrice)")
    }

    private func buy(_ product: Product) async {
        buying = product.id
        defer { buying = nil }
        do {
            if try await packs.buy(product, with: purchase) {
                Haptics.success()
                dismiss()
                bought()
            }
        } catch {
            message = error.localizedDescription
        }
    }
}
