import Foundation
import Observation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ContractStore
//
// Single source of truth for all contracts. @Observable so SwiftUI views
// update automatically. Persists to a JSON file in Application Support —
// loaded once at launch, saved after every mutation (atomic write).
// ─────────────────────────────────────────────────────────────────────────────

@Observable
final class ContractStore {

    static let shared = ContractStore()

    private(set) var contracts: [GeneratedContract] = []

    // ── Storage location: ~/Library/Application Support/Handshake/contracts.json
    private let fileURL: URL = {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Handshake", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("contracts.json")
    }()

    private init() { load() }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Queries
    // ─────────────────────────────────────────────────────────────────────────

    var drafts: [GeneratedContract] {
        contracts
            .filter { $0.status == .draft }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var pending: [GeneratedContract] {
        contracts
            .filter { $0.status == .sent }
            .sorted { ($0.sentAt ?? $0.createdAt) > ($1.sentAt ?? $1.createdAt) }
    }

    var completed: [GeneratedContract] {
        contracts
            .filter { $0.status == .signed || $0.status == .declined }
            .sorted { ($0.signedAt ?? $0.createdAt) > ($1.signedAt ?? $1.createdAt) }
    }

    var isEmpty: Bool { contracts.isEmpty }

    func contract(id: UUID) -> GeneratedContract? {
        contracts.first { $0.id == id }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Mutations  (every mutation saves to disk)
    // ─────────────────────────────────────────────────────────────────────────

    /// Insert a new contract or replace an existing one (matched by id).
    func upsert(_ contract: GeneratedContract) {
        if let i = contracts.firstIndex(where: { $0.id == contract.id }) {
            contracts[i] = contract
        } else {
            contracts.append(contract)
        }
        save()
    }

    func delete(id: UUID) {
        contracts.removeAll { $0.id == id }
        save()
    }

    func markSent(id: UUID, recipients: [Recipient]) {
        guard let i = contracts.firstIndex(where: { $0.id == id }) else { return }
        contracts[i].recipients = recipients
        contracts[i].status     = .sent
        contracts[i].sentAt     = .now
        save()
    }

    func markSigned(id: UUID) {
        guard let i = contracts.firstIndex(where: { $0.id == id }) else { return }
        contracts[i].status   = .signed
        contracts[i].signedAt = .now
        save()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Disk
    // ─────────────────────────────────────────────────────────────────────────

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        contracts = (try? decoder.decode([GeneratedContract].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(contracts) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
