import SwiftUI
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Theme
//
// The few colours Handshake picks itself. Everything else is a system colour
// (label, separator, materials), which already adapts.
//
// One warm neutral scale (Notion-like), built around ink #1F1E1C:
//
//   token          light     dark      used for
//   ink            #1F1E1C   #EDECE9   primary actions (Send pills, send
//                                      circle, filled buttons), the chat
//                                      placeholder, the user's chat bubble,
//                                      headings drawn in our own colour
//   onInk          #FFFFFF   #1F1E1C   text / icons on ink
//   secondaryInk   #787774   #9B9A97   captions, footnotes
//   pageBackground #FAFAF9   system    screen ground (stone/50)
//   cardFill       #F5F5F4   system    cards, wells (stone/100)
//
// The handshake drawing (app icon, chat-bar mark) uses the same ink.
// The accent colour isn't decided yet: `action` is ink for now, so swapping
// it later moves every primary action at once. Purple (`brand`) remains
// only on text/menus and the signature boxes until then.
// ─────────────────────────────────────────────────────────────────────────────

extension Color {
    // ── Neutrals ─────────────────────────────────────────────────────────
    static let ink            = Color(light: 0x1F1E1C, dark: 0xEDECE9)
    static let onInk          = Color(light: 0xFFFFFF, dark: 0x1F1E1C)

    /// Primary actions. Ink until the accent colour is chosen.
    static let action         = ink
    static let onAction       = onInk

    /// The user's chat bubble: ink with white text in light. In dark a raised
    /// warm grey with light text — an off-white slab in the conversation
    /// would outshine the document behind it.
    static let userBubble     = Color(light: 0x1F1E1C, dark: 0x3A3936)
    static let onUserBubble   = Color(light: 0xFFFFFF, dark: 0xEDECE9)

    /// Body ink where we draw our own (not the editor, which uses label).
    static let primaryInk     = Color(UIColor { $0.userInterfaceStyle == .dark ? .label
                                                                               : UIColor(hex: 0x1F1E1C) })
    static let secondaryInk   = Color(light: 0x787774, dark: 0x9B9A97)

    /// Screen background: stone/50 #FAFAF9, system black in dark.
    static let pageBackground = Color(UIColor { $0.userInterfaceStyle == .dark ? .systemBackground
                                                                               : UIColor(hex: 0xFAFAF9) })
    /// Cards and input wells: stone/100 #F5F5F4, system grey 6 in dark.
    static let cardFill       = Color(UIColor { $0.userInterfaceStyle == .dark ? .secondarySystemBackground
                                                                               : UIColor(hex: 0xF5F5F4) })
    /// White panels that sit on the page (recipient rows).
    static let raisedSurface  = Color(.secondarySystemGroupedBackground)

    // ── Purple: text / menus / signature boxes, until the accent is set ──
    /// Purple text / icons on the page background (#4C00FF on black is
    /// ~2.3:1, so it lightens in dark).
    static let brand          = Color(light: 0x4C00FF, dark: 0x9D80FF)
    /// Purple behind white text. Same in both modes.
    static let brandFill      = Color(hex: 0x4C00FF)
    /// Far end of the old brand gradient (#26065D) — profile avatar only.
    static let brandDeep      = Color(hex: 0x26065D)

    static let statusSigned   = Color(UIColor { $0.userInterfaceStyle == .dark ? .systemGreen
                                                                               : UIColor(red: 0.13, green: 0.60, blue: 0.28, alpha: 1) })
    static let statusDeclined = Color(UIColor { $0.userInterfaceStyle == .dark ? .systemRed
                                                                               : UIColor(red: 0.80, green: 0.16, blue: 0.16, alpha: 1) })

    // ── Helpers ──────────────────────────────────────────────────────────
    init(hex: UInt32) { self.init(UIColor(hex: hex)) }
    init(light: UInt32, dark: UInt32) {
        self.init(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red:   CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >>  8) & 0xFF) / 255,
                  blue:  CGFloat( hex        & 0xFF) / 255,
                  alpha: 1)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Readable width (iPad, landscape, wide phones)
//
// The app is laid out for a phone column. On anything wider, keep content to
// a comfortable reading measure and centre it; the background still fills
// the screen. 640pt ≈ 75 characters of body text, the same measure Notes and
// Mail use on iPad.
// ─────────────────────────────────────────────────────────────────────────────

enum Layout {
    static let readableWidth: CGFloat = 640
}

extension View {
    /// Caps the view at the readable width and centres it in whatever is left.
    func readableColumn(_ maxWidth: CGFloat = Layout.readableWidth) -> some View {
        frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Document text colour
//
// Contract text is drawn in UIColor.label so it flips with the appearance.
// RTFD can't store a dynamic colour: it saves whatever label resolved to at
// the time (black in light, white in dark). Reopened in the other mode, that
// text would be black-on-black or white-on-white. So on load, any plain
// black / white / missing text colour goes back to .label. Coloured text
// (links, purple) is left alone.
// ─────────────────────────────────────────────────────────────────────────────

extension NSMutableAttributedString {
    func adaptTextColorsToAppearance() {
        let whole = NSRange(location: 0, length: length)
        var fixes: [NSRange] = []
        enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
            guard let color = value as? UIColor else { fixes.append(range); return }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
            let grey = abs(r - g) < 0.03 && abs(g - b) < 0.03
            if grey && (r < 0.2 || r > 0.85) { fixes.append(range) }
        }
        for range in fixes { addAttribute(.foregroundColor, value: UIColor.label, range: range) }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Field boxes drawn before dark mode
//
// Unfilled Signature / Date boxes are images inside the document. Ones saved
// before dark mode had a see-through 6% purple wash, which on a black page is
// dark purple on black. They're placeholders, not content, so on load swap in
// a freshly drawn box (opaque wash, SignatureFieldViews) — same kind, same
// spot, same size.
// ─────────────────────────────────────────────────────────────────────────────

extension NSMutableAttributedString {
    func redrawSignatureFieldBoxes() {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            for field in signatureFields() {
                addAttribute(.attachment, value: SignatureField.makeAttachment(field.kind), range: field.range)
            }
        }
    }
}
