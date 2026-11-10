import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Import inbox
//
// How "Share › Handshake" hands things to the app. The share extension can't
// run the app's UI, so it copies what was shared into the App Group container
// (one folder per share, with an item.json manifest), then opens
// handshake://import/<id>. The app reads the folder, turns it into a draft
// source and deletes it.
//
// Compiled into both targets (Shared/ is a synchronized folder in each).
// ─────────────────────────────────────────────────────────────────────────────

struct InboxItem: Codable, Identifiable {
    enum Kind: String, Codable { case text, images, file }

    var id = UUID()
    var created = Date()
    var kind: Kind
    /// For .text: what was shared.
    var text: String? = nil
    /// For .images / .file: file names inside the item's folder, in order.
    var files: [String] = []
}

enum ImportInbox {
    static let appGroup = "group.com.weihsun.Handshake"
    /// Shares older than this are dropped rather than opened as a surprise.
    static let freshFor: TimeInterval = 60 * 60

    static var root: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    static func folder(for id: UUID) -> URL? {
        root?.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Makes the item's folder; the caller copies files into it, then calls save.
    static func makeFolder(for id: UUID) throws -> URL {
        guard let dir = folder(for: id) else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func save(_ item: InboxItem) throws {
        let dir = try makeFolder(for: item.id)
        let data = try JSONEncoder().encode(item)
        try data.write(to: dir.appendingPathComponent("item.json"), options: .atomic)
    }

    static func load(_ id: UUID) -> InboxItem? {
        guard let url = folder(for: id)?.appendingPathComponent("item.json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(InboxItem.self, from: data)
    }

    /// The newest fresh share, if any. Older ones are deleted on the way.
    static func newest() -> InboxItem? {
        guard let root, let ids = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return nil }
        var fresh: [InboxItem] = []
        for name in ids {
            guard let id = UUID(uuidString: name) else { continue }
            if let item = load(id), Date().timeIntervalSince(item.created) < freshFor {
                fresh.append(item)
            } else {
                remove(id)
            }
        }
        return fresh.max { $0.created < $1.created }
    }

    static func remove(_ id: UUID) {
        guard let dir = folder(for: id) else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}
