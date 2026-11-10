import SwiftUI
import Compression

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Shared to Handshake
//
// The app side of the share extension (Shared/ImportInbox.swift). An item
// arrives by handshake://import/<id>, or — if the extension couldn't open the
// app — the next time the app comes to the front. It's read here (text from
// screenshots, PDFs and chat exports) and handed to Home, which shows the
// Start-from sheet with it filled in so the user can add a note and draft.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
enum ImportHandling {
    private static var inFlight: Set<UUID> = []

    /// handshake://import/<id>
    static func open(_ id: UUID) {
        guard let item = ImportInbox.load(id) else { return }
        handle(item)
    }

    /// The app came to the front: anything shared that didn't get opened.
    static func checkInbox() {
        guard let item = ImportInbox.newest() else { return }
        handle(item)
    }

    private static func handle(_ item: InboxItem) {
        guard !inFlight.contains(item.id) else { return }
        inFlight.insert(item.id)
        // Read the files into memory, then clear the inbox, so a second
        // trigger (URL and activation arrive together) finds nothing.
        let dir = ImportInbox.folder(for: item.id)
        let files: [(name: String, data: Data)] = item.files.compactMap { name in
            guard let dir, let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
            return (name, data)
        }
        ImportInbox.remove(item.id)

        Task {
            defer { inFlight.remove(item.id) }
            guard let draft = await draft(from: item, files: files) else { return }
            NewDraftRouter.shared.open(draft)
        }
    }

    private static func draft(from item: InboxItem, files: [(name: String, data: Data)]) async -> PendingDraft? {
        switch item.kind {
        case .text:
            guard let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return PendingDraft(source: DraftSource(kind: .file, text: text), review: true)

        case .images:
            let images = files.compactMap { UIImage(data: $0.data) }
            guard !images.isEmpty else { return nil }
            // Screenshots of a chat have right-aligned bubbles ("Me:"); a
            // photo or screenshot of a document has almost none.
            let chat = await TextReader.chat(from: images)
            let mine = chat.components(separatedBy: "\n").filter { $0.hasPrefix("Me: ") }.count
            let thumbs = images.map { $0.downscaled(maxPixels: 300) }
            if mine >= 2 {
                return PendingDraft(source: DraftSource(kind: .chat, text: chat, pieces: images.count),
                                    review: true, thumbnails: thumbs)
            }
            let doc = await TextReader.document(from: images)
            guard doc.count >= 10 else { return nil }
            return PendingDraft(source: DraftSource(kind: .paper, text: doc, pieces: images.count),
                                review: true, thumbnails: thumbs)

        case .file:
            guard let file = files.first else { return nil }
            let ext = (file.name as NSString).pathExtension.lowercased()
            if ext == "pdf" {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
                try? file.data.write(to: url)
                defer { try? FileManager.default.removeItem(at: url) }
                let r = await TextReader.pdf(at: url)
                guard r.text.count >= 10 else { return nil }
                return PendingDraft(source: DraftSource(kind: .paper, text: r.text, pieces: r.pages), review: true)
            }
            // WhatsApp exports a .zip holding _chat.txt; LINE a .txt.
            let text = ext == "zip" ? ZipReader.firstText(in: file.data)
                                    : String(data: file.data, encoding: .utf8)
            guard let text, !text.isEmpty else { return nil }
            return PendingDraft(source: DraftSource(kind: .file, text: text), review: true)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Zip reader
// Just enough of the zip format to pull the chat text out of WhatsApp's
// export: the central directory, then the first .txt entry, stored or
// deflated. (iOS has no public unzip API.)
// ─────────────────────────────────────────────────────────────────────────────

enum ZipReader {
    static func firstText(in zip: Data) -> String? {
        let b = [UInt8](zip)
        func u16(_ o: Int) -> Int { o + 1 < b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : 0 }
        func u32(_ o: Int) -> Int { o + 3 < b.count ? u16(o) | u16(o + 2) << 16 : 0 }

        // End of central directory: last occurrence of PK\5\6.
        guard b.count > 22 else { return nil }
        var eocd = -1
        for o in stride(from: b.count - 22, through: max(0, b.count - 65_557), by: -1)
            where b[o] == 0x50 && b[o + 1] == 0x4B && b[o + 2] == 5 && b[o + 3] == 6 { eocd = o; break }
        guard eocd >= 0 else { return nil }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)

        for _ in 0..<count {
            guard u32(p) == 0x02014B50 else { return nil }
            let method = u16(p + 10)
            let compressed = u32(p + 20), size = u32(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
            let local = u32(p + 42)
            let name = String(decoding: b[(p + 46)..<min(b.count, p + 46 + nameLen)], as: UTF8.self)
            p += 46 + nameLen + extraLen + commentLen

            guard name.lowercased().hasSuffix(".txt"), !name.hasPrefix("__MACOSX") else { continue }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + compressed <= b.count else { return nil }
            let slice = Array(b[start..<(start + compressed)])

            if method == 0 { return String(decoding: slice, as: UTF8.self) }
            guard method == 8, size > 0, size < 50_000_000 else { continue }
            var out = [UInt8](repeating: 0, count: size)
            let n = compression_decode_buffer(&out, size, slice, slice.count, nil, COMPRESSION_ZLIB)
            guard n > 0 else { continue }
            return String(decoding: out[0..<n], as: UTF8.self)
        }
        return nil
    }
}
