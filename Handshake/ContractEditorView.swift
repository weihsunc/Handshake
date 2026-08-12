import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ContractEditorView
// ─────────────────────────────────────────────────────────────────────────────

struct ContractEditorView: View {
    @State private var contract:        GeneratedContract
    @State private var attributedBody:  NSMutableAttributedString
    @State private var isEditing:       Bool = false
    @State private var editorHeight:    CGFloat = 300
    @State private var chatPrompt:      String = ""
    @State private var textViewRef:     UITextView? = nil
    @State private var showSendFlow:    Bool = false
    @Environment(\.dismiss) private var dismiss

    init(contract: GeneratedContract) {
        _contract      = State(initialValue: contract)
        _attributedBody = State(initialValue: .fromHandshakeMarkdown(contract.content))
    }

    var body: some View {
        ZStack(alignment: .bottom) {

            // ── Background ──────────────────────────────────────────
            Color(red: 0.98, green: 0.98, blue: 0.98)
                .ignoresSafeArea()

            // ── Document scroll view ────────────────────────────────
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // Large title
                    Text(contract.title)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Color(.label))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)

                    // Rich-text body — GeometryReader passes the real width
                    // so UITextView wraps correctly and reports the right height.
                    GeometryReader { geo in
                        RichTextEditorImpl(
                            attributedText:  $attributedBody,
                            dynamicHeight:   $editorHeight,
                            isEditing:       isEditing,
                            availableWidth:  geo.size.width,
                            onReady:         { tv in textViewRef = tv },
                            onEditingBegan:  { isEditing = true }
                        )
                    }
                    .frame(height: editorHeight)
                }
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 140)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: isEditing) { _, editing in
                if !editing { textViewRef?.resignFirstResponder() }
            }

            // ── Bottom bar ─────────────────────────────────────────
            Group {
                if isEditing {
                    FormattingToolbar { action in handleFormat(action) }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    ChatBar(prompt: $chatPrompt, onSend: {})
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.22), value: isEditing)
        }
        // ── Navigation bar ──────────────────────────────────────────
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                GlassIconButton(systemName: "chevron.left") {
                    if isEditing { isEditing = false } else { dismiss() }
                }
            }
            ToolbarItem(placement: .principal) {
                Text(contract.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(.label))
                    .lineLimit(1)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if isEditing {
                    BlackPillButton(title: "Save") { isEditing = false }
                } else {
                    PurplePillButton(title: "Send") { showSendFlow = true }
                }
            }
        }
        .sheet(isPresented: $showSendFlow) {
            SendFlowView(contract: contract)
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: - Format dispatch
    // ─────────────────────────────────────────────────────────────

    private func handleFormat(_ action: FormatAction) {
        switch action {
        case .bold:              applyTrait(.traitBold)
        case .italic:            applyTrait(.traitItalic)
        case .underline:         applyUnderline()
        case .heading1:          applyHeading(size: 26)
        case .heading2:          applyHeading(size: 20)
        case .bulletList:        applyList(numbered: false)
        case .numberedList:      applyList(numbered: true)
        case .alignLeft:         applyAlignment(.left)
        case .alignCenter:       applyAlignment(.center)
        case .alignRight:        applyAlignment(.right)
        case .insertImage:       break  // handled by ContractWorkspaceView via sheet
        case .insertAttachment:  break
        case .insertSignature:   insertSignaturePlaceholder()
        }
    }

    private func applyTrait(_ trait: UIFontDescriptor.SymbolicTraits) {
        guard let tv = textViewRef, tv.selectedRange.length > 0 else { return }
        let range = tv.selectedRange
        tv.textStorage.beginEditing()
        tv.textStorage.enumerateAttribute(.font, in: range) { value, sub, _ in
            let cur    = (value as? UIFont) ?? UIFont.systemFont(ofSize: 17)
            let has    = cur.fontDescriptor.symbolicTraits.contains(trait)
            var traits = cur.fontDescriptor.symbolicTraits
            if has { traits.remove(trait) } else { traits.insert(trait) }
            let desc   = cur.fontDescriptor.withSymbolicTraits(traits) ?? cur.fontDescriptor
            tv.textStorage.addAttribute(.font, value: UIFont(descriptor: desc, size: cur.pointSize), range: sub)
        }
        tv.textStorage.endEditing()
        attributedBody = NSMutableAttributedString(attributedString: tv.textStorage)
    }

    private func applyUnderline() {
        guard let tv = textViewRef, tv.selectedRange.length > 0 else { return }
        let range = tv.selectedRange
        tv.textStorage.beginEditing()
        let existing = tv.textStorage.attribute(.underlineStyle, at: range.location, effectiveRange: nil)
        if existing != nil {
            tv.textStorage.removeAttribute(.underlineStyle, range: range)
        } else {
            tv.textStorage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }
        tv.textStorage.endEditing()
        attributedBody = NSMutableAttributedString(attributedString: tv.textStorage)
    }

    private func applyHeading(size: CGFloat) {
        guard let tv = textViewRef else { return }
        let nsText = tv.text as NSString
        let range = tv.selectedRange.length > 0
            ? tv.selectedRange
            : nsText.paragraphRange(for: tv.selectedRange)
        tv.textStorage.beginEditing()
        tv.textStorage.enumerateAttribute(.font, in: range) { value, sub, _ in
            let cur    = (value as? UIFont) ?? UIFont.systemFont(ofSize: 17)
            var traits = cur.fontDescriptor.symbolicTraits
            traits.insert(.traitBold)
            let desc   = cur.fontDescriptor.withSymbolicTraits(traits) ?? cur.fontDescriptor
            tv.textStorage.addAttribute(.font, value: UIFont(descriptor: desc, size: size), range: sub)
        }
        tv.textStorage.endEditing()
        attributedBody = NSMutableAttributedString(attributedString: tv.textStorage)
    }

    private func applyList(numbered: Bool) {
        guard let tv = textViewRef else { return }
        let nsText = tv.text as NSString
        var sel = tv.selectedRange
        if sel.length == 0 { sel = nsText.paragraphRange(for: sel) }

        var ranges: [NSRange] = []
        var loc = sel.location
        while loc < sel.location + sel.length {
            let r = nsText.paragraphRange(for: NSRange(location: loc, length: 0))
            ranges.append(r)
            loc = r.location + r.length
        }
        if ranges.isEmpty { ranges.append(nsText.paragraphRange(for: sel)) }

        tv.textStorage.beginEditing()
        for (i, r) in ranges.enumerated().reversed() {
            let prefix = numbered ? "\(ranges.count - i). " : "• "
            tv.textStorage.insert(NSAttributedString(string: prefix, attributes: baseAttrs()), at: r.location)
        }
        tv.textStorage.endEditing()
        attributedBody = NSMutableAttributedString(attributedString: tv.textStorage)
    }

    private func applyAlignment(_ alignment: NSTextAlignment) {
        guard let tv = textViewRef else { return }
        let nsText = tv.text as NSString
        let range = tv.selectedRange.length > 0
            ? tv.selectedRange
            : nsText.paragraphRange(for: tv.selectedRange)
        tv.textStorage.beginEditing()
        tv.textStorage.enumerateAttributes(in: range, options: []) { _, sub, _ in
            let existing = tv.textStorage.attribute(.paragraphStyle, at: sub.location, effectiveRange: nil)
            let para: NSMutableParagraphStyle
            if let e = existing as? NSParagraphStyle {
                para = e.mutableCopy() as! NSMutableParagraphStyle
            } else {
                para = NSMutableParagraphStyle(); para.lineSpacing = 3
            }
            para.alignment = alignment
            tv.textStorage.addAttribute(.paragraphStyle, value: para, range: sub)
        }
        tv.textStorage.endEditing()
        attributedBody = NSMutableAttributedString(attributedString: tv.textStorage)
    }

    private func insertSignaturePlaceholder() {
        guard let tv = textViewRef else { return }
        let block = "\n\n────────────────────────\nSignature          Date\n\n"
        let attrs: [NSAttributedString.Key: Any] = [
            .font:            UIFont.systemFont(ofSize: 14),
            .foregroundColor: UIColor.secondaryLabel
        ]
        let attrStr = NSAttributedString(string: block, attributes: attrs)
        tv.textStorage.beginEditing()
        tv.textStorage.insert(attrStr, at: tv.selectedRange.location)
        tv.textStorage.endEditing()
        attributedBody = NSMutableAttributedString(attributedString: tv.textStorage)
    }

    private func baseAttrs() -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle(); para.lineSpacing = 3
        return [.font: UIFont.systemFont(ofSize: 17),
                .foregroundColor: UIColor.label,
                .paragraphStyle: para]
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - RichTextEditorImpl  (UITextView ↔ SwiftUI)
// ─────────────────────────────────────────────────────────────────────────────

struct RichTextEditorImpl: UIViewRepresentable {
    @Binding var attributedText: NSMutableAttributedString
    @Binding var dynamicHeight:  CGFloat
    var isEditing:      Bool
    var availableWidth: CGFloat
    var onReady:        (UITextView) -> Void
    var onEditingBegan: () -> Void
    /// false = read-only rendering (history viewer). Editable contexts must
    /// keep the default `true` — see the gotcha note below.
    var allowsEditing:  Bool = true

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isScrollEnabled  = false
        tv.backgroundColor  = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        // Always editable (when editing is allowed) so UIKit fires
        // textViewDidBeginEditing on the first tap. Keyboard visibility is
        // controlled exclusively via becomeFirstResponder / resignFirstResponder
        // — NOT by toggling isEditable.
        tv.isEditable       = allowsEditing
        tv.isSelectable     = true
        tv.delegate         = context.coordinator
        // Let SwiftUI control the width; suppress UITextView's own size ambitions.
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tv.attributedText   = attributedText
        DispatchQueue.main.async { onReady(tv) }
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        // Sync attributed text only when not actively typing (prevents cursor jumps).
        if !tv.isFirstResponder {
            if tv.attributedText != attributedText {
                tv.attributedText = attributedText
            }
        }

        // Recalculate height whenever width or content changes.
        recalcHeight(tv)

        // Keyboard: resign when the parent dismisses editing (Done / back button).
        // Never call becomeFirstResponder programmatically — UIKit handles that
        // naturally when the user taps, triggering textViewDidBeginEditing.
        if !isEditing && tv.isFirstResponder {
            tv.resignFirstResponder()
        }
    }

    private func recalcHeight(_ tv: UITextView) {
        guard availableWidth > 0 else { return }
        let size = tv.sizeThatFits(CGSize(width: availableWidth, height: .greatestFiniteMagnitude))
        let h = max(size.height, 100)
        DispatchQueue.main.async {
            if abs(self.dynamicHeight - h) > 1 { self.dynamicHeight = h }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RichTextEditorImpl
        init(_ p: RichTextEditorImpl) { parent = p }

        func textViewDidBeginEditing(_ tv: UITextView) {
            parent.onEditingBegan()
        }

        func textViewDidChange(_ tv: UITextView) {
            parent.attributedText = NSMutableAttributedString(attributedString: tv.attributedText)
            parent.recalcHeight(tv)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Markdown parser  (**bold** → UIFont.bold, no asterisks shown)
// ─────────────────────────────────────────────────────────────────────────────

extension NSMutableAttributedString {

    static func fromHandshakeMarkdown(_ text: String) -> NSMutableAttributedString {
        let result   = NSMutableAttributedString()
        let baseFont = UIFont.systemFont(ofSize: 17)
        let boldFont = UIFont.boldSystemFont(ofSize: 17)

        let para = NSMutableParagraphStyle()
        para.lineSpacing      = 3
        para.paragraphSpacing = 0

        let base: [NSAttributedString.Key: Any] = [
            .font:            baseFont,
            .foregroundColor: UIColor.label,
            .paragraphStyle:  para
        ]

        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            result.append(parseLine(line, base: base, boldFont: boldFont))
            if i < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: base))
            }
        }
        return result
    }

    private static func parseLine(
        _ line: String,
        base: [NSAttributedString.Key: Any],
        boldFont: UIFont
    ) -> NSAttributedString {

        var boldAttrs = base
        boldAttrs[.font] = boldFont

        let out       = NSMutableAttributedString()
        var remaining = line

        while !remaining.isEmpty {
            guard let open = remaining.range(of: "**") else {
                out.append(NSAttributedString(string: remaining, attributes: base))
                break
            }
            let before = String(remaining[..<open.lowerBound])
            if !before.isEmpty {
                out.append(NSAttributedString(string: before, attributes: base))
            }
            remaining = String(remaining[open.upperBound...])

            if let close = remaining.range(of: "**") {
                let boldText = String(remaining[..<close.lowerBound])
                out.append(NSAttributedString(string: boldText, attributes: boldAttrs))
                remaining = String(remaining[close.upperBound...])
            } else {
                out.append(NSAttributedString(string: remaining, attributes: base))
                break
            }
        }
        return out
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Photo Picker  (PHPickerViewController bridge)
// Presents the system photo library and delivers a single UIImage via callback.
// ─────────────────────────────────────────────────────────────────────────────

struct PhotoPickerView: UIViewControllerRepresentable {
    var onImagePicked: (UIImage) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 1
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onImagePicked: onImagePicked) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onImagePicked: (UIImage) -> Void
        init(onImagePicked: @escaping (UIImage) -> Void) { self.onImagePicked = onImagePicked }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let result = results.first else { return }
            result.itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
                guard let img = object as? UIImage else { return }
                DispatchQueue.main.async { self.onImagePicked(img) }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Document Picker  (UIDocumentPickerViewController bridge)
// Delivers the picked file URL so callers can insert an attachment placeholder.
// ─────────────────────────────────────────────────────────────────────────────

struct DocumentPickerView: UIViewControllerRepresentable {
    var onFilePicked: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [.data, .pdf, .image, .plainText]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFilePicked: onFilePicked) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFilePicked: (URL) -> Void
        init(onFilePicked: @escaping (URL) -> Void) { self.onFilePicked = onFilePicked }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            DispatchQueue.main.async { self.onFilePicked(url) }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Preview
// ─────────────────────────────────────────────────────────────────────────────

#Preview {
    NavigationStack {
        ContractEditorView(contract: GeneratedContract(
            id: UUID(),
            title: "Non-Disclosure Agreement (NDA)",
            content: """
            **Non-Disclosure Agreement (NDA)**

            This Non-Disclosure Agreement ("Agreement") is entered into as of [Date], between:

            [Your Company Name], hereinafter referred to as the "Disclosing Party," and

            [Recipient's Company Name], hereinafter referred to as the "Receiving Party."

            **Confidential Information:**
            The Disclosing Party may disclose certain confidential and proprietary information to the Receiving Party.

            **Obligations:**
            1. The Receiving Party agrees to maintain the confidentiality of all information received.
            2. The Receiving Party shall not disclose information to any third party.
            3. The Receiving Party shall only use information for the stated purpose.

            **Term:** This Agreement shall be effective for [Duration].

            **Governing Law:** This Agreement is governed by the laws of [State/Country].
            """
        ))
    }
}
