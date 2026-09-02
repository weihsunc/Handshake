import SwiftUI
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Chat Bar
// Compact pill by default; expands to a rounded-rect card when text wraps.
// ─────────────────────────────────────────────────────────────────────────────

struct ChatBar: View {
    @Binding var prompt: String
    var placeholder: String = "Chat with HandShake"
    var onSend: () -> Void
    /// Reflects whether the text field is focused — drives template visibility in HomeView
    var onFocusChange: ((Bool) -> Void)? = nil

    @FocusState private var isFocused: Bool

    // Expand once the text would wrap past ~1 line on a phone screen
    private var isExpanded: Bool {
        prompt.count > 50 || prompt.contains("\n")
    }

    var body: some View {
        Group {
            if isExpanded {
                expandedBar
            } else {
                compactBar
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: isExpanded)
        .onChange(of: isFocused) { _, focused in
            onFocusChange?(focused)
        }
    }

    // ── Compact: single-line pill ─────────────────────────────────────────
    private var compactBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color(.label))
                .frame(width: 36, height: 36)

            TextField(placeholder, text: $prompt)
                .font(.system(size: 17))
                .foregroundStyle(Color(.label))
                .tint(Color(.label))
                .focused($isFocused)

            Spacer(minLength: 0)

            if prompt.trimmingCharacters(in: .whitespaces).isEmpty {
                Image(systemName: "mic")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color(.label))
                    .frame(width: 36, height: 36)
            } else {
                sendCircle
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.regularMaterial)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.10), radius: 20, x: 0, y: 8)
    }

    // ── Expanded: multi-line card ─────────────────────────────────────────
    private var expandedBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Growing text area
            TextField(placeholder, text: $prompt, axis: .vertical)
                .font(.system(size: 17))
                .foregroundStyle(Color(.label))
                .tint(Color(.label))
                .lineLimit(1...8)
                .focused($isFocused)
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .padding(.bottom, 8)

            // Bottom action row — matches Figma: [+] [mic] [spacer] [→ send]
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color(.label))
                    .frame(width: 36, height: 36)

                Image(systemName: "mic")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color(.label))
                    .frame(width: 36, height: 36)

                Spacer()

                sendCircle
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.10), radius: 20, x: 0, y: 8)
    }

    // ── Shared send button ────────────────────────────────────────────────
    private var sendCircle: some View {
        Button(action: onSend) {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0.298, green: 0, blue: 1),
                                 Color(red: 0.149, green: 0.024, blue: 0.365)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Template Card
// Tappable suggestion cards shown above the chat bar when keyboard appears.
// ─────────────────────────────────────────────────────────────────────────────

struct TemplateCard: View {
    let emoji: String
    let title: String
    let description: String
    var onTap: () -> Void

    // Figma tokens:
    //   Title  — SF Pro Semibold 17/22, tracking -0.43, #1e1e1e
    //   Body   — SF Pro Regular  17/22, tracking -0.43, #757575
    //   Card   — #F4F4F5 bg, 24 pt corner radius, 16 pt padding, 280 pt wide

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 16) {

                // ── Header: emoji + title ──────────────────────────────────
                HStack(alignment: .center, spacing: 6) {
                    // Plain Text, not the old EmojiView UILabel bridge — that
                    // pinned the font to "AppleColorEmoji", which stopped
                    // resolving on iOS 26 and rendered every card's icon as a
                    // [?] tofu box. Text picks up the system emoji fallback.
                    Text(verbatim: emoji)
                        .font(.system(size: 20))

                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .tracking(-0.43)
                        .foregroundStyle(Color(red: 30/255, green: 30/255, blue: 30/255))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // ── Body ───────────────────────────────────────────────────
                Text(description)
                    .font(.system(size: 17, weight: .regular))
                    .tracking(-0.43)
                    .foregroundStyle(Color(red: 117/255, green: 117/255, blue: 117/255))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Fixed card width — no maxWidth: .infinity inside a horizontal ScrollView
            // (that causes children to escape the card boundary).
            .frame(width: 248, alignment: .leading) // 280 − 2×16 padding
            .padding(16)
            .background(Color(red: 0.957, green: 0.957, blue: 0.961)) // #F4F4F5
            .clipShape(RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(.plain)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Glass Icon Button
// Icon buttons for navigation bars.
//
// Deliberately NO background of its own. On iOS 26 every ToolbarItem is already
// wrapped in the system's Liquid Glass capsule; painting a second capsule
// inside it produced two stacked pills with mismatched geometry — the seam and
// pale ring §6 of HANDOFF describes. The system capsule is the pill now.
// ─────────────────────────────────────────────────────────────────────────────

struct GlassIconButton: View {
    let systemName: String
    var action: (() -> Void)? = nil

    var body: some View {
        Button(action: { action?() }) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(.label))
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Toolbar Pill Button  (Send)
// The purple primary action when it lives in a navigation bar.
//
// Uses the iOS 26 prominent glass style with the brand purple as tint, so the
// system's own toolbar capsule IS the filled pill — nothing custom to ring.
// PurplePillButton (custom gradient) is for full-width actions outside
// toolbars, where there's no system container to fight.
// ─────────────────────────────────────────────────────────────────────────────

struct ToolbarPillButton: View {
    let title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.glassProminent)
        .tint(Color(red: 76/255, green: 0, blue: 255/255))   // #4C00FF
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Purple Pill Button  (Send)
// ─────────────────────────────────────────────────────────────────────────────

struct PurplePillButton: View {
    let title: String
    /// Stretches the pill to fill its container — used for the primary action on
    /// the signing screen. Toolbar usages keep the default hug-to-content width.
    var fullWidth: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .medium))
                // mix-blend-plus-lighter from Figma — gives the text a slight glow
                // against the dark gradient background
                .blendMode(.plusLighter)
                .foregroundStyle(.white)
                // An iOS 26 toolbar clamps its item to a 44pt glass container and
                // will wrap the label to fit it — "Send" came out as "S/e" on two
                // lines. fixedSize makes the text refuse to be compressed.
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 14)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .frame(height: fullWidth ? 52 : 44)   // 44 matches glass button height exactly
                .background(
                    LinearGradient(
                        colors: [Color(red: 76/255, green: 0/255,  blue: 255/255),   // #4C00FF
                                 Color(red: 38/255, green: 6/255,  blue:  93/255)],  // #26065D
                        startPoint: UnitPoint(x: 0.08, y: 0),
                        endPoint:   UnitPoint(x: 1.47, y: 1)
                    ),
                    in: Capsule()
                )
                .shadow(color: .black.opacity(0.12), radius: 20, x: 0, y: 8)
        }
        .buttonStyle(.plain)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Black Pill Button  (Save)
// ─────────────────────────────────────────────────────────────────────────────

struct BlackPillButton: View {
    let title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.black)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Format Action
// Exhaustive list of editor operations the FormattingToolbar can emit.
// ─────────────────────────────────────────────────────────────────────────────

enum FormatAction {
    case bold, italic, underline
    case heading1, heading2
    case bulletList, numberedList
    case alignLeft, alignCenter, alignRight
    case insertImage, insertAttachment, insertSignature
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Purple Circle Button  (share / send action in nav bar)
//
// Mirrors GlassIconButton's layout exactly (36 pt icon · 44 pt tall · 4 pt
// horizontal padding → 44×44 capsule = circle) but fills with the purple
// gradient instead of .regularMaterial, so the iOS 26 liquid-glass button-
// group container sees a solid purple surface and shows no white ring.
// ─────────────────────────────────────────────────────────────────────────────

struct PurpleCircleButton: View {
    let systemName: String
    var action: () -> Void

    var body: some View {
        Button(action: { action() }) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
        }
        .frame(height: 44)
        .padding(.horizontal, 4)
        .background(
            LinearGradient(
                colors: [Color(red: 76/255, green: 0,     blue: 255/255),
                         Color(red: 38/255, green: 6/255, blue:  93/255)],
                startPoint: UnitPoint(x: 0.08, y: 0),
                endPoint:   UnitPoint(x: 1.47, y: 1)
            ),
            in: Capsule()
        )
        .buttonStyle(.plain)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Activity View  (UIActivityViewController bridge)
// SwiftUI's ShareLink can't be used as a toolbar button label without getting
// its intrinsic size clamped to a square. This wrapper lets us trigger the
// native iOS share sheet from a plain Button instead.
// ─────────────────────────────────────────────────────────────────────────────

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil
    /// Reports whether the user actually completed a share. Needed because the
    /// share sheet is a dead end otherwise — the caller can't tell a real send
    /// from a dismissal.
    var onFinish: ((Bool) -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: applicationActivities
        )
        vc.completionWithItemsHandler = { _, completed, _, _ in
            onFinish?(completed)
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController,
                                context: Context) {}
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Formatting Toolbar
//
// A single scrollable glass pill — matches Figma node 2021-1799 "Button Group 1".
// Floats above the keyboard, transparent outside the pill.
// Order: eSignature · text style · headings · lists · alignment · insert
// ─────────────────────────────────────────────────────────────────────────────

struct FormattingToolbar: View {
    var onAction: (FormatAction) -> Void

    var body: some View {
        // Outer row: pill left-aligned with 8 pt side insets (matches Figma px-[8])
        HStack {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {

                    // ── eSignature — first per design ─────────────────────────
                    toolBtn("signature")        { onAction(.insertSignature) }

                    sep

                    // ── Text style ────────────────────────────────────────────
                    toolBtn("bold")             { onAction(.bold) }
                    toolBtn("italic")           { onAction(.italic) }
                    toolBtn("underline")        { onAction(.underline) }

                    sep

                    // ── Headings ──────────────────────────────────────────────
                    labelBtn("H1")              { onAction(.heading1) }
                    labelBtn("H2")              { onAction(.heading2) }

                    sep

                    // ── Lists ─────────────────────────────────────────────────
                    toolBtn("list.bullet")      { onAction(.bulletList) }
                    toolBtn("list.number")      { onAction(.numberedList) }

                    sep

                    // ── Alignment ─────────────────────────────────────────────
                    toolBtn("text.alignleft")   { onAction(.alignLeft) }
                    toolBtn("text.aligncenter") { onAction(.alignCenter) }
                    toolBtn("text.alignright")  { onAction(.alignRight) }

                    sep

                    // ── Insert ────────────────────────────────────────────────
                    toolBtn("photo")            { onAction(.insertImage) }
                    toolBtn("paperclip")        { onAction(.insertAttachment) }
                }
                .padding(.horizontal, 10)   // Figma: px-[10] inside the pill
            }
            .frame(height: 48)              // Figma: h-[48px]
            .background(.regularMaterial)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.12), radius: 20, x: 0, y: 8)
        }
        .padding(.horizontal, 8)            // Figma: outer px-[8]
        .padding(.vertical, 4)
    }

    // ── A thin capsule divider between groups ─────────────────────────────────
    private var sep: some View {
        Capsule()
            .fill(Color(.separator).opacity(0.6))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 4)
    }

    // ── SF Symbol button — 36 × 36 tap target ────────────────────────────────
    private func toolBtn(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color(.label))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
    }

    // ── Short text button for H1 / H2 ────────────────────────────────────────
    private func labelBtn(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(.label))
                .frame(width: 30, height: 36)
        }
        .buttonStyle(.plain)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Handshake Illustration
// Home screen empty-state graphic.
// Drop "oc-handshake" PNG into Assets.xcassets to use the real Figma asset;
// the two-hand SF Symbol fallback renders automatically otherwise.
// ─────────────────────────────────────────────────────────────────────────────

struct HandshakeIllustration: View {
    var body: some View {
        if UIImage(named: "oc-handshake") != nil {
            // ── Real Figma asset ─────────────────────────────────────
            // Floating icons are already part of the PNG — no overlay needed.
            Image("oc-handshake")
                .resizable()
                .scaledToFit()
                .frame(width: 280)
        } else {
            // ── SF Symbol fallback ───────────────────────────────────
            ZStack {
                // Document — top center, slight tilt
                Image(systemName: "doc.text")
                    .font(.system(size: 26, weight: .thin))
                    .foregroundStyle(Color(.secondaryLabel).opacity(0.70))
                    .rotationEffect(.degrees(-8))
                    .offset(x: 4, y: -84)

                // Chat bubble — left
                Image(systemName: "bubble.left")
                    .font(.system(size: 22, weight: .thin))
                    .foregroundStyle(Color(.secondaryLabel).opacity(0.68))
                    .offset(x: -90, y: -6)

                // Envelope — lower right
                Image(systemName: "envelope")
                    .font(.system(size: 22, weight: .thin))
                    .foregroundStyle(Color(.secondaryLabel).opacity(0.62))
                    .offset(x: 88, y: 32)

                // Motion lines above the clasp
                HStack(spacing: 6) {
                    ForEach(0..<3) { _ in
                        Capsule()
                            .frame(width: 2, height: 11)
                            .foregroundStyle(Color(.secondaryLabel).opacity(0.45))
                    }
                }
                .offset(x: 0, y: -44)

                // Left hand — fingers pointing right, thumb on top
                Image(systemName: "hand.raised")
                    .font(.system(size: 56, weight: .thin))
                    .foregroundStyle(Color(.label).opacity(0.80))
                    .rotationEffect(.degrees(-90))
                    .scaleEffect(x: -1, y: 1)
                    .offset(x: -26, y: 4)

                // Right hand — fingers pointing left, thumb on top
                Image(systemName: "hand.raised")
                    .font(.system(size: 56, weight: .thin))
                    .foregroundStyle(Color(.label).opacity(0.80))
                    .rotationEffect(.degrees(-90))
                    .offset(x: 26, y: 4)
            }
            .frame(width: 240, height: 220)
        }
    }
}

// ───────────────────────────────────────────────────────────────────────────
// MARK: - Message Bubble  (AI panel chat rows)
//
// Recovered from the deleted ChatSheetView.swift — that screen was dead, but
// ContractWorkspaceView's AI panel still renders its message rows with this.
// ───────────────────────────────────────────────────────────────────────────

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.isUser { Spacer(minLength: 60) }

            Group {
                if let attr = try? AttributedString(markdown: message.content) {
                    Text(attr)
                } else {
                    Text(message.content)
                }
            }
            .font(.system(size: 17))
            .lineSpacing(3)
            .foregroundStyle(message.isUser ? .white : Color(.label))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(message.isUser ? Color(.label) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 18))

            if !message.isUser { Spacer(minLength: 60) }
        }
    }
}
