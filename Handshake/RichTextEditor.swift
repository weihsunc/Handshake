import SwiftUI
import UIKit

// ───────────────────────────────────────────────────────────────────────────
// MARK: - RichTextEditorImpl  (UITextView ↔ SwiftUI)
//
// Extracted from the former ContractEditorView.swift, which was deleted once
// its own view struct went dead. Used by the workspace editor, the read-only
// history viewer, and the signing screen.
// ───────────────────────────────────────────────────────────────────────────

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
