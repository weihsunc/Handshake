import SwiftUI
import PhotosUI
import PDFKit
import Vision
import VisionKit
import AppIntents
import UniformTypeIdentifiers

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Start from
//
// The "Start from" list on Home: other ways into a draft than typing.
//
//   chat    screenshots of a conversation, or a pasted message
//   call    a pasted call transcript (iPhone's call recording keeps one in Notes)
//   paper   a scanned, photographed or PDF contract, rebuilt as an editable one
//   siri    "Make a contract with Handshake" (CreateContractIntent)
//
// Text is read on the phone (Vision); only the text goes to the AI, never
// the images. No app can read Messages or call history, so the user always
// brings the material — the sheets say how.
// ─────────────────────────────────────────────────────────────────────────────

enum StartSource: String, Identifiable, CaseIterable {
    case chat, call, paper, siri
    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat:  String(localized: "A chat")
        case .call:  String(localized: "A call")
        case .paper: String(localized: "A paper contract")
        case .siri:  String(localized: "Siri")
        }
    }

    var subtitle: String {
        switch self {
        case .chat:  String(localized: "Share screenshots or an exported chat")
        case .call:  String(localized: "From a call recording's transcript")
        case .paper: String(localized: "Scan it into an editable draft")
        case .siri:  String(localized: "Make one hands-free")
        }
    }

    var symbol: String {
        switch self {
        case .chat:  "bubble.left.and.bubble.right"
        case .call:  "phone"
        case .paper: "doc.viewfinder"
        case .siri:  "waveform"
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Draft source
// What a Start-from sheet hands the workspace: the text it read, and how to
// ask the AI about it. The workspace shows `bubble` as the user's message and
// sends `aiPrompt` instead of the bare note.
// ─────────────────────────────────────────────────────────────────────────────

struct DraftSource: Equatable {
    enum Kind: String, Codable {
        case chat, call, paper, file
        /// Which Start-from sheet shows it.
        var startSource: StartSource {
            switch self { case .call: .call; case .paper: .paper; case .chat, .file: .chat }
        }
    }
    let kind: Kind
    let text: String
    /// Screenshots or pages read, for the user's message ("3 screenshots").
    var pieces: Int = 1

    /// The user's message in the chat panel.
    func bubble(note: String) -> String {
        let lead: String
        switch kind {
        case .chat:  lead = pieces > 1
                            ? String(localized: "Draft a contract from this chat (\(pieces) screenshots).")
                            : String(localized: "Draft a contract from this chat.")
        case .call:  lead = String(localized: "Draft a contract from this call.")
        case .paper: lead = String(localized: "Turn this paper contract into an editable one.")
        case .file:  lead = String(localized: "Draft a contract from this.")
        }
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? lead : lead + "\n" + n
    }

    /// What the AI is asked. English instructions; the contract's language
    /// follows the material (generateContract's language rule).
    func aiPrompt(note: String) -> String {
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteLine = n.isEmpty ? "" : "\nMy note: \(n)\n"
        let body = String(text.prefix(60_000))
        switch kind {
        case .chat:
            return """
            Below is a conversation, read from screenshots of a chat app. Lines starting "Me:" \
            are my messages, "Them:" are the other person's; a "Chat with:" line names the other \
            person (or group); other lines are dates or app labels. Draft the agreement we are making in it. Use the names, amounts, dates \
            and terms we agreed on, and put anything we didn't settle in [brackets]. Write the \
            contract in the language of the conversation.
            \(noteLine)
            Conversation:
            <<<
            \(body)
            >>>
            """
        case .call:
            return """
            Below is the transcript of a phone call. Draft the agreement made in it. Use the \
            names, amounts, dates and terms agreed on, and put anything not settled in \
            [brackets]. Write the contract in the language of the call.
            \(noteLine)
            Transcript:
            <<<
            \(body)
            >>>
            """
        case .paper:
            return """
            Below is the text of a paper contract, read from photos, so some words may be \
            misread. Rebuild it as an editable contract: keep its title, wording, numbering \
            and clauses; fix obvious misreadings; turn blank lines, handwritten entries and \
            unfilled spaces into [brackets]; and end with the signature block. Don't add \
            clauses that aren't in it. Write it in the language of the original.
            \(noteLine)
            Text:
            <<<
            \(body)
            >>>
            """
        case .file:
            return """
            Below is text shared from another app — a conversation, notes or a document. \
            Draft the agreement it describes. Use the names, amounts, dates and terms in it, \
            and put anything not settled in [brackets]. Write the contract in its language.
            \(noteLine)
            Text:
            <<<
            \(body)
            >>>
            """
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Text reader (on-device OCR)
// ─────────────────────────────────────────────────────────────────────────────

enum TextReader {

    /// A chat screenshot as "Me: …" / "Them: …" lines. Bubbles on the right
    /// are the phone owner's, on the left the other person's; centred lines
    /// (the name at the top, dates) are kept as they are. The status bar and
    /// the compose field are dropped.
    static func chat(from images: [UIImage]) async -> String {
        var out: [String] = []
        for image in images {
            guard let cg = image.cgImage else { continue }
            var req = RecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.automaticallyDetectsLanguage = true
            guard let lines = try? await req.perform(on: cg, orientation: image.cgOrientation) else { continue }

            var current: (who: String, text: String)? = nil
            var previous: CGRect? = nil
            var sawBubble = false
            func flush() { if let c = current { out.append(c.who.isEmpty ? c.text : "\(c.who): \(c.text)") }; current = nil }

            // Top to bottom (Vision's origin is bottom-left).
            for line in lines.sorted(by: { $0.boundingBox.cgRect.maxY > $1.boundingBox.cgRect.maxY }) {
                let r = line.boundingBox.cgRect
                guard r.maxY < 0.95, r.minY > 0.06 else { continue }    // status bar, compose field
                let text = line.transcript.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                let left = r.minX, right = 1 - r.maxX
                var who = right < 0.2 && right < left - 0.08 ? "Me"
                        : left  < 0.2 && left  < right - 0.08 ? "Them" : ""
                // A bubble's short last line ("1?") sits under the line above,
                // starting where it starts — part of the same message.
                if let p = previous, let c = current, !c.who.isEmpty,
                   abs(r.minX - p.minX) < 0.04, p.minY - r.maxY < r.height * 0.9 {
                    who = c.who
                }
                previous = r
                // The centred name above the first bubble is the chat's title:
                // the other person (or the group).
                if who.isEmpty, !sawBubble, r.minY > 0.75,
                   !text.contains(where: \.isNumber), out.isEmpty || out.last == "" {
                    flush(); out.append("Chat with: \(text)"); continue
                }
                if !who.isEmpty { sawBubble = true }
                if let c = current, c.who == who, !who.isEmpty {
                    current = (who, c.text + " " + text)               // a wrapped bubble
                } else {
                    flush(); current = (who, text)
                }
            }
            flush()
            out.append("")
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A document page in reading order, line by line. Built from text
    /// positions rather than Vision's paragraphs: a fill-in blank ("made on
    /// ______ between") isn't text, and paragraph grouping split those lines
    /// and shuffled the pieces. Here a wide gap inside a line becomes "____",
    /// and a tall gap between lines a paragraph break.
    static func document(from images: [UIImage]) async -> String {
        var pages: [String] = []
        for image in images {
            guard let cg = image.cgImage else { continue }
            var req = RecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.automaticallyDetectsLanguage = true
            guard let obs = try? await req.perform(on: cg, orientation: image.cgOrientation) else { continue }

            // Group runs into lines: same height on the page.
            var lines: [[(rect: CGRect, text: String)]] = []
            for o in obs.sorted(by: { $0.boundingBox.cgRect.midY > $1.boundingBox.cgRect.midY }) {
                let r = o.boundingBox.cgRect
                let t = o.transcript.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty else { continue }
                if let last = lines.last?.first, abs(last.rect.midY - r.midY) < min(last.rect.height, r.height) * 0.5 {
                    lines[lines.count - 1].append((r, t))
                } else {
                    lines.append([(r, t)])
                }
            }

            var out: [String] = []
            var previous: CGRect? = nil
            for line in lines {
                let runs = line.sorted { $0.rect.minX < $1.rect.minX }
                var text = ""
                var lastMaxX: CGFloat? = nil
                for run in runs {
                    if let x = lastMaxX { text += run.rect.minX - x > 0.04 ? " ____ " : " " }
                    text += run.text
                    lastMaxX = run.rect.maxX
                }
                let r = runs.map(\.rect).reduce(runs[0].rect) { $0.union($1) }
                if let p = previous, p.minY - r.maxY > r.height * 0.9 { out.append("") }
                out.append(text)
                previous = r
            }
            pages.append(out.joined(separator: "\n"))
        }
        return pages.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A PDF's text. A scanned PDF has none, so its pages are read as images.
    static func pdf(at url: URL) async -> (text: String, pages: Int) {
        guard let pdf = PDFDocument(url: url) else { return ("", 0) }
        let text = (pdf.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 80 { return (text, pdf.pageCount) }
        var images: [UIImage] = []
        for i in 0..<min(pdf.pageCount, 12) {
            guard let page = pdf.page(at: i) else { continue }
            let box = page.bounds(for: .mediaBox)
            let scale = 2000 / max(box.width, box.height, 1)
            images.append(page.thumbnail(of: CGSize(width: box.width * scale, height: box.height * scale), for: .mediaBox))
        }
        return (await document(from: images), pdf.pageCount)
    }
}

extension UIImage {
    var cgOrientation: CGImagePropertyOrientation {
        switch imageOrientation {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Document camera
// VisionKit's scanner, presented from UIKit like the contact picker (wrapped
// in a SwiftUI sheet, UIKit pickers tend to dismiss the sheet under them).
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
enum DocumentScanning {
    static var isAvailable: Bool { VNDocumentCameraViewController.isSupported }

    static func scan(_ done: @escaping ([UIImage]) -> Void) {
        let vc = VNDocumentCameraViewController()
        let delegate = Delegate(done)
        current = delegate
        vc.delegate = delegate
        topViewController()?.present(vc, animated: true)
    }

    private static var current: Delegate?

    private final class Delegate: NSObject, VNDocumentCameraViewControllerDelegate {
        let done: ([UIImage]) -> Void
        init(_ done: @escaping ([UIImage]) -> Void) { self.done = done }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            let pages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            controller.dismiss(animated: true)
            done(pages)
            DocumentScanning.current = nil
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            controller.dismiss(animated: true)
            DocumentScanning.current = nil
        }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            controller.dismiss(animated: true)
            DocumentScanning.current = nil
        }
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var vc = scene?.keyWindow?.rootViewController
        while let next = vc?.presentedViewController { vc = next }
        return vc
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Start-from sheet  (chat · call · paper)
//
// Step 1: bring the material (pick, paste or scan). Step 2: see what was
// read, add an optional note, Draft contract.
// ─────────────────────────────────────────────────────────────────────────────

struct StartFromSheet: View {
    let source: StartSource
    /// Already read (shared to Handshake): the sheet opens at step 2.
    var preset: PendingDraft? = nil
    /// Hands the material and the note to Home, which opens the workspace.
    var onStart: (DraftSource, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles  = false
    @State private var thumbnails: [UIImage] = []
    @State private var material: DraftSource? = nil
    @State private var reading = false
    @State private var note = ""
    @State private var problem: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                header

                if let material {
                    readySection(material)
                } else {
                    addSection
                    tipSection
                }

                if let problem {
                    Section { Text(problem).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(preset != nil ? String(localized: "Shared with Handshake") : source.title)
            .onAppear {
                if let preset, material == nil {
                    material = preset.source
                    thumbnails = preset.thumbnails
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(Text("Cancel"))
                }
                if material != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Draft")) { start() }
                            .buttonStyle(.glassProminent)
                            .tint(Color.action)
                    }
                }
            }
            .overlay {
                if reading {
                    ProgressView(String(localized: "Reading…"))
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems,
                      maxSelectionCount: source == .paper ? 12 : 10,
                      selectionBehavior: .ordered, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await readPhotos(items) }
        }
        .fileImporter(isPresented: $showFiles,
                      allowedContentTypes: source == .paper ? [.pdf, .image] : [.plainText, .pdf]) { result in
            if case .success(let url) = result { Task { await readFile(url) } }
        }
        .presentationDetents([.large])
    }

    // ── Header ──────────────────────────────────────────────────────────────

    private var header: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: source.symbol)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Color.primaryInk)
                Text(explainer)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
    }

    private var explainer: String {
        if preset != nil {
            return String(localized: "Handshake read what you shared. Add a note if it helps, then draft. Only the text is sent to the AI.")
        }
        return switch source {
        case .chat:  String(localized: "Handshake reads the conversation and drafts the agreement in it. Screenshots stay on your phone; only the text is sent to the AI.")
        case .call:  String(localized: "Handshake drafts the agreement from what was said. Only the text is sent to the AI.")
        case .paper: String(localized: "Handshake reads the contract and turns it into one you can edit and send. Photos stay on your phone; only the text is sent to the AI.")
        case .siri:  ""
        }
    }

    // ── Step 1: bring the material ─────────────────────────────────────────

    @ViewBuilder private var addSection: some View {
        Section {
            switch source {
            case .chat:
                row(String(localized: "Choose screenshots"), "photo.on.rectangle") { showPhotos = true }
                paste(String(localized: "Paste a message"))
            case .call:
                paste(String(localized: "Paste the transcript"))
                row(String(localized: "Choose a text file"), "doc.text") { showFiles = true }
            case .paper:
                if DocumentScanning.isAvailable {
                    row(String(localized: "Scan with the camera"), "camera.viewfinder") {
                        DocumentScanning.scan { pages in Task { await readPages(pages) } }
                    }
                }
                row(String(localized: "Choose photos"), "photo.on.rectangle") { showPhotos = true }
                row(String(localized: "Choose a PDF"), "doc") { showFiles = true }
            case .siri:
                EmptyView()
            }
        }
    }

    private func row(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .foregroundStyle(Color.primaryInk)
        }
    }

    /// The system paste button: no "allow paste?" prompt, since the tap is
    /// the permission.
    private func paste(_ title: String) -> some View {
        HStack {
            Label(title, systemImage: "doc.on.clipboard")
                .foregroundStyle(Color.primaryInk)
            Spacer()
            pasteButton
        }
    }

    private var pasteButton: some View {
        PasteButton(payloadType: String.self) { strings in
            let text = strings.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            Task { @MainActor in
                withAnimation { material = DraftSource(kind: source == .call ? .call : .chat, text: text) }
            }
        }
        .buttonBorderShape(.capsule)
        .labelStyle(.titleOnly)
        .tint(Color.action)
    }

    @ViewBuilder private var tipSection: some View {
        switch source {
        case .chat:
            Section(String(localized: "Other ways")) {
                tip(String(localized: "In Messages, take screenshots, then tap Share › Handshake."), logos: [])
                tip(String(localized: "In WhatsApp or LINE, open the chat's settings, tap Export Chat, then choose Handshake."),
                    logos: ["logo-whatsapp", "logo-line"])
            }
        case .call:
            Section(String(localized: "Where to find it")) {
                tip(String(localized: "Recorded a call? Open the recording in Notes, tap ⋯ › Copy Transcript, then paste it here. Or share the note to Handshake."), logos: [])
            }
        default:
            EmptyView()
        }
    }

    private func tip(_ text: String, logos: [String]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            let shown = logos.filter { UIImage(named: $0) != nil }
            if shown.isEmpty {
                Image(systemName: "lightbulb")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
            } else {
                HStack(spacing: -6) {
                    ForEach(shown, id: \.self) { name in
                        Image(name).resizable().scaledToFit()
                            .frame(width: 24, height: 24)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // ── Step 2: what was read, a note, Draft ───────────────────────────────

    @ViewBuilder private func readySection(_ m: DraftSource) -> some View {
        Section {
            if !thumbnails.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(thumbnails.indices, id: \.self) { i in
                            Image(uiImage: thumbnails[i]).resizable().scaledToFill()
                                .frame(width: 56, height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
            }
            Text(m.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(8)
            Button(String(localized: "Start over"), role: .destructive) {
                withAnimation { material = nil; thumbnails = []; photoItems = []; note = "" }
            }
        } header: {
            Text(String(localized: "What Handshake read"))
        }

        Section {
            TextField(String(localized: "Anything to add? (optional)"), text: $note,
                      prompt: Text(notePlaceholder), axis: .vertical)
                .lineLimit(1...4)
        } footer: {
            Text(String(localized: "You can change everything once the draft is ready."))
        }
    }

    private var notePlaceholder: String {
        switch source {
        case .paper: String(localized: "e.g. I'm the tenant, update the rent to $1,200")
        default:     String(localized: "e.g. I'm the one renting out the room")
        }
    }

    private func start() {
        guard let material else { return }
        onStart(material, note)
        dismiss()
    }

    // ── Reading ─────────────────────────────────────────────────────────────

    private func readPhotos(_ items: [PhotosPickerItem]) async {
        reading = true; problem = nil
        var images: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let img = UIImage(data: data) { images.append(img) }
        }
        await readPages(images)
    }

    private func readPages(_ images: [UIImage]) async {
        reading = true; problem = nil
        let text = source == .chat ? await TextReader.chat(from: images)
                                   : await TextReader.document(from: images)
        thumbnails = images.map { $0.downscaled(maxPixels: 300) }
        finish(text, kind: source == .chat ? .chat : .paper, pieces: images.count)
    }

    private func readFile(_ url: URL) async {
        reading = true; problem = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let kind: DraftSource.Kind = source == .call ? .call : source == .paper ? .paper : .chat
        if url.pathExtension.lowercased() == "pdf" {
            let r = await TextReader.pdf(at: url)
            finish(r.text, kind: kind, pieces: r.pages)
        } else if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
            await readPages([img])
        } else {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            finish(text, kind: kind, pieces: 1)
        }
    }

    private func finish(_ text: String, kind: DraftSource.Kind, pieces: Int) {
        reading = false
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 10 else {
            problem = String(localized: "Handshake couldn't find any text in that. Try a clearer photo, or paste the text instead.")
            thumbnails = []
            return
        }
        withAnimation { material = DraftSource(kind: kind, text: t, pieces: max(1, pieces)) }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Siri sheet
// ─────────────────────────────────────────────────────────────────────────────

struct SiriStartSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "waveform")
                    .font(.system(size: 32, weight: .light))
                Text(String(localized: "Say “Make a contract with Handshake”. Siri asks what it's for, then opens your draft here."))
                    .font(.body)
                    .foregroundStyle(Color.primaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                ShortcutsLink()
                    .shortcutsLinkStyle(.automaticOutline)
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .navigationTitle(String(localized: "Siri"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(Text("Cancel"))
                }
            }
        }
        .presentationDetents([.medium])
    }
}
