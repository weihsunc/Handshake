import UIKit
import SwiftUI
import UniformTypeIdentifiers

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Share › Handshake
//
// Takes what another app shares — screenshots, photos, text (a copied message,
// a Notes call transcript), a PDF, or an exported chat (WhatsApp's .zip,
// LINE's .txt) — copies it into the import inbox, and opens Handshake on it.
// No reading or AI here: the extension has a tight memory limit, and the app
// does the reading where the user can see and confirm it.
// ─────────────────────────────────────────────────────────────────────────────

final class ShareViewController: UIViewController {

    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareCard(model: model, done: { [weak self] in self?.finish() }))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.backgroundColor = .clear
        view.addSubview(host.view)
        host.didMove(toParent: self)

        Task { await collect() }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    // ── Copy what was shared into the inbox ────────────────────────────────

    private func collect() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }

        let id = UUID()
        guard let dir = try? ImportInbox.makeFolder(for: id) else { model.state = .failed; return }

        var files: [String] = []
        var texts: [String] = []
        var sawImage = false

        for (i, p) in providers.enumerated() {
            if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                if let data = try? await p.loadData(UTType.image) {
                    let name = "image-\(i).img"
                    try? data.write(to: dir.appendingPathComponent(name))
                    files.append(name); sawImage = true
                }
            } else if let type = [UTType.pdf, .zip, UTType("public.zip-archive")].compactMap({ $0 })
                        .first(where: { p.hasItemConformingToTypeIdentifier($0.identifier) }) {
                if let url = try? await p.copyFile(type, into: dir) { files.append(url.lastPathComponent) }
            } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let text = try? await p.loadText() { texts.append(text) }
            } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                if let url = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    if url.isFileURL, let text = try? String(contentsOf: url, encoding: .utf8) {
                        texts.append(text)
                    }
                }
            }
        }

        var item: InboxItem
        if sawImage {
            item = InboxItem(id: id, kind: .images, files: files.filter { $0.hasPrefix("image-") })
        } else if let file = files.first {
            item = InboxItem(id: id, kind: .file, files: [file])
        } else if !texts.isEmpty {
            item = InboxItem(id: id, kind: .text, text: texts.joined(separator: "\n\n"))
        } else {
            ImportInbox.remove(id)
            model.state = .failed
            return
        }
        item.created = Date()

        do { try ImportInbox.save(item) } catch { model.state = .failed; return }

        // Open the app on it. Share extensions have no official way to open
        // their app; if this doesn't take, the app picks the share up the
        // next time it comes to the front (ImportInbox.newest).
        let url = URL(string: "handshake://import/\(id.uuidString)")!
        model.state = openApp(url) ? .opening : .saved
        if model.state == .opening {
            try? await Task.sleep(for: .milliseconds(600))
            finish()
        }
    }

    private func openApp(_ url: URL) -> Bool {
        var responder: UIResponder? = self
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        while let r = responder {
            if r.isKind(of: UIApplication.self), r.responds(to: selector) {
                typealias Open = @convention(c) (NSObject, Selector, URL, NSDictionary, Any?) -> Void
                let imp = r.method(for: selector)
                unsafeBitCast(imp, to: Open.self)(r, selector, url, NSDictionary(), nil)
                return true
            }
            responder = r.next
        }
        return false
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Item provider helpers
// ─────────────────────────────────────────────────────────────────────────────

private extension NSItemProvider {
    func loadData(_ type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { c in
            _ = loadDataRepresentation(for: type) { data, error in
                if let data { c.resume(returning: data) } else { c.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }

    func copyFile(_ type: UTType, into dir: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { c in
            _ = loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                guard let url else { c.resume(throwing: error ?? CocoaError(.fileReadUnknown)); return }
                let dest = dir.appendingPathComponent(url.lastPathComponent)
                do {
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.copyItem(at: url, to: dest)
                    c.resume(returning: dest)
                } catch { c.resume(throwing: error) }
            }
        }
    }

    func loadText() async throws -> String {
        let item = try await loadItem(forTypeIdentifier: UTType.plainText.identifier)
        if let s = item as? String { return s }
        if let s = item as? NSAttributedString { return s.string }
        if let d = item as? Data, let s = String(data: d, encoding: .utf8) { return s }
        if let u = item as? URL { return try String(contentsOf: u, encoding: .utf8) }
        throw CocoaError(.fileReadUnknown)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - The card
// ─────────────────────────────────────────────────────────────────────────────

@Observable
final class ShareModel {
    enum State { case adding, opening, saved, failed }
    var state: State = .adding
}

struct ShareCard: View {
    let model: ShareModel
    var done: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            switch model.state {
            case .adding, .opening:
                ProgressView()
                Group {
                    if model.state == .adding { Text("Adding to Handshake…") } else { Text("Opening Handshake…") }
                }
                .font(.headline)
            case .saved:
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 36, weight: .light))
                Text("Added to Handshake")
                    .font(.headline)
                Text("Open Handshake to finish your draft.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Done", action: done)
                    .buttonStyle(.borderedProminent)
                    .tint(Color(uiColor: .label))
            case .failed:
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 36, weight: .light))
                Text("Couldn't add this")
                    .font(.headline)
                Text("Handshake can take screenshots, photos, text, PDFs and exported chats.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Done", action: done)
                    .buttonStyle(.borderedProminent)
                    .tint(Color(uiColor: .label))
            }
        }
        .padding(28)
        .frame(maxWidth: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
