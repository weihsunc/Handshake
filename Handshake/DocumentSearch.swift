import SwiftUI
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Find in the contract (phone workspace)
//
// A magnifier sits left of "Edit with HandShake". Tapping it turns the whole
// bottom bar into a search bar (Figma iOS 27 kit, 12740:24039):
//
//     [🔍 Search keywords or fields      🎙]  (✕)
//
// Typing finds words in the document and the Signature / Date boxes: "sign"
// or "date" matches the boxes as well as the text. Matches are drawn with
// UIKit's own find highlight (UITextSearching decorations on the UITextView),
// which never touches the attributed string, so nothing reaches the saved
// document. The current match is the stronger highlight and is scrolled into
// view; the chevrons (or Return) step through them.
// ─────────────────────────────────────────────────────────────────────────────

enum DocumentSearch {

    /// Every match for `query`, in document order: plain-text hits plus any
    /// field box whose name ("Signature", "Date") contains the query.
    static func matches(for query: String, in text: NSAttributedString) -> [NSRange] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let ns = text.string as NSString
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

        var out: [NSRange] = []
        var from = 0
        while from < ns.length {
            let r = ns.range(of: q, options: options, range: NSRange(location: from, length: ns.length - from))
            guard r.location != NSNotFound else { break }
            out.append(r)
            from = r.location + max(r.length, 1)
        }
        for field in text.signatureFields() where field.kind.searchName.range(of: q, options: options) != nil {
            out.append(field.range)
        }
        return out.sorted { $0.location < $1.location }
    }

    /// Clears the old highlights and draws the new ones on the editor.
    /// TextKit 2 rendering attributes: drawn by the layout manager only, never
    /// written into the text storage, so they can't leak into the saved RTFD.
    /// (UITextView's found-text decorations were tried first; they only draw
    /// while the system find panel is up.)
    @MainActor
    static func decorate(_ tv: UITextView, matches: [NSRange], current: Int?) {
        clear(tv)
        for (i, r) in matches.enumerated() {
            let color = i == current ? currentColor : matchColor
            // TextKit 2 is UITextView's default and nothing here opts out.
            // (iOS has no TextKit 1 equivalent of a draw-only attribute.)
            guard let tlm = tv.textLayoutManager,
                  let range = textRange(r, in: tlm) else { continue }
            tlm.addRenderingAttribute(.backgroundColor, value: color, for: range)
        }
    }

    @MainActor
    static func clear(_ tv: UITextView) {
        guard let tlm = tv.textLayoutManager else { return }
        tlm.removeRenderingAttribute(.backgroundColor, for: tlm.documentRange)
    }

    /// Safari's find colours: every match softly, the current one solid.
    private static let matchColor   = UIColor.systemYellow.withAlphaComponent(0.35)
    private static let currentColor = UIColor.systemYellow

    @MainActor
    private static func textRange(_ r: NSRange, in tlm: NSTextLayoutManager) -> NSTextRange? {
        guard let tcm = tlm.textContentManager,
              let start = tcm.location(tcm.documentRange.location, offsetBy: r.location),
              let end   = tcm.location(start, offsetBy: r.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    /// Scrolls the screen's scroll view (the editor itself doesn't scroll; the
    /// SwiftUI ScrollView around it does) so the match sits in the upper part
    /// of the screen, clear of the keyboard and the bar.
    @MainActor
    static func reveal(_ r: NSRange, in tv: UITextView) {
        guard let range = textRange(r, in: tv) else { return }
        var scroller = tv.superview
        while let v = scroller, !(v is UIScrollView) { scroller = v.superview }
        guard let scroll = scroller as? UIScrollView else { return }
        let rect = tv.convert(tv.firstRect(for: range), to: scroll)
        guard rect.origin.x.isFinite, rect.origin.y.isFinite else { return }
        let visibleH = scroll.bounds.height - scroll.adjustedContentInset.top - scroll.adjustedContentInset.bottom
        let target = rect.midY - visibleH * 0.3 - scroll.adjustedContentInset.top
        let maxY = max(-scroll.adjustedContentInset.top,
                       scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        let y = min(max(target, -scroll.adjustedContentInset.top), maxY)
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: true)
    }

    @MainActor
    private static func textRange(_ r: NSRange, in tv: UITextView) -> UITextRange? {
        guard r.location + r.length <= (tv.attributedText?.length ?? 0),
              let start = tv.position(from: tv.beginningOfDocument, offset: r.location),
              let end   = tv.position(from: start, offset: r.length) else { return nil }
        return tv.textRange(from: start, to: end)
    }
}

extension SignatureField {
    /// What a search for the box matches against.
    var searchName: String {
        switch self {
        case .signature: return "Signature"
        case .date:      return "Date"
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Glass circle button (the magnifier, and ✕ while searching)
// Same surface as the chat bar pill, so the two read as one bar.
// ─────────────────────────────────────────────────────────────────────────────

struct BarCircleButton: View {
    let systemImage: String
    let label: String
    var size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.medium))
                .foregroundStyle(Color(.label))
                .frame(width: size, height: size)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.10), radius: 20, x: 0, y: 8)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Search bar
// ─────────────────────────────────────────────────────────────────────────────

struct DocumentSearchBar: View {
    @Binding var query: String
    var focus: FocusState<Bool>.Binding
    /// Number of matches and which one is current (nil when there are none).
    let matchCount: Int
    let current: Int?
    var height: CGFloat
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void

    @State private var speech = SpeechInput()
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 32

    private var hasQuery: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color(.secondaryLabel))
                    .accessibilityHidden(true)

                TextField("Search keywords or fields", text: $query)
                    .font(.body)
                    .tint(Color(.label))
                    .focused(focus)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit(onNext)

                trailing
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .frame(height: height)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.10), radius: 20, x: 0, y: 8)

            BarCircleButton(systemImage: "xmark", label: String(localized: "Close search"), size: height) {
                speech.stop()
                onClose()
            }
        }
        .alert("Can't use the microphone",
               isPresented: Binding(get: { speech.errorText != nil },
                                    set: { if !$0 { speech.errorText = nil } })) {
            Button("OK", role: .cancel) { speech.errorText = nil }
        } message: { Text(speech.errorText ?? "") }
    }

    /// Mic while empty (Figma); once there's a query, the match count and
    /// the arrows to step through matches.
    @ViewBuilder
    private var trailing: some View {
        if hasQuery && !speech.isRecording {
            Text(matchCount == 0 ? String(localized: "No results")
                                 : String(localized: "\((current ?? 0) + 1) of \(matchCount)"))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Color(.secondaryLabel))
                .lineLimit(1)
                .fixedSize()
                .accessibilityAddTraits(.updatesFrequently)

            HStack(spacing: 0) {
                stepButton("chevron.up",   label: String(localized: "Previous match"), action: onPrevious)
                stepButton("chevron.down", label: String(localized: "Next match"),     action: onNext)
            }
            .disabled(matchCount == 0)
        } else {
            Button {
                if speech.isRecording {
                    speech.stop()
                } else {
                    speech.start { text in query = text }
                }
            } label: {
                Image(systemName: speech.isRecording ? "mic.fill" : "mic")
                    .font(.body.weight(.medium))
                    .foregroundStyle(speech.isRecording ? Color.brand : Color(.secondaryLabel))
                    .frame(width: iconSize, height: iconSize)
                    .symbolEffect(.pulse, isActive: speech.isRecording)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(speech.isRecording ? "Stop dictation" : "Dictate")
        }
    }

    private func stepButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(matchCount == 0 ? Color(.tertiaryLabel) : Color(.label))
                .frame(width: iconSize, height: iconSize)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
