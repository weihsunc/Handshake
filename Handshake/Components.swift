import SwiftUI
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Haptics
// Imperative on purpose: the moments that deserve feedback (signed, sent) are
// often followed straight away by a dismiss, and a .sensoryFeedback modifier
// on a view that's leaving never gets to fire.
// ─────────────────────────────────────────────────────────────────────────────

enum Haptics {
    /// Something finished: signed, sent.
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    /// Something landed in the document: a signature or date box.
    static func place()   { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Chat Bar
// Compact pill by default; expands to a rounded-rect card when text wraps.
// ─────────────────────────────────────────────────────────────────────────────

/// What the chat bar's "+" can add. Only offered where there's a document to
/// add it to (the workspace); Home passes nil and the button is hidden.
enum ChatAttachment { case photo, file }

struct ChatBar: View {
    @Binding var prompt: String
    var placeholder: String = String(localized: "Start with HandShake")
    var onSend: () -> Void
    /// Reflects whether the text field is focused — drives template visibility in HomeView
    var onFocusChange: ((Bool) -> Void)? = nil
    /// nil hides "+". Both icons were inert images before; a new user taps
    /// the mic first and expects something to happen.
    var onAttach: ((ChatAttachment) -> Void)? = nil
    /// Open into the card (text on top, buttons below) as soon as it's
    /// tapped, not only once the text wraps. The contract screen uses it:
    /// tapping the bar there is the start of a message.
    var expandsOnFocus: Bool = false

    @FocusState private var isFocused: Bool
    @State private var speech = SpeechInput()
    /// Icon squares grow with the user's text size so they stay tappable.
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 36
    /// Text that was already typed when dictation started; transcription is
    /// cumulative, so the field shows prefix + latest transcription.
    @State private var dictationPrefix = ""

    /// Width of the single-line field in the compact pill, measured once it's
    /// on screen. The hidden measurer below lays the prompt out at this width
    /// to decide whether it would wrap — so the decision is the same in both
    /// layouts and the bar can't flip-flop between them.
    @State private var compactFieldWidth: CGFloat = 0
    @State private var wraps = false

    /// Expand the moment the text no longer fits on one line (or has a
    /// newline). The card then grows line by line with the text.
    private var isExpanded: Bool { wraps || prompt.contains("\n") || (expandsOnFocus && isFocused) }

    @Namespace private var ns

    var body: some View {
        bar
            .background(wrapMeasurer)
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: isExpanded)
            .onChange(of: isFocused) { _, focused in
                onFocusChange?(focused)
            }
            .alert("Can't use the microphone",
                   isPresented: Binding(get: { speech.errorText != nil },
                                        set: { if !$0 { speech.errorText = nil } })) {
                Button("OK", role: .cancel) { speech.errorText = nil }
            } message: { Text(speech.errorText ?? "") }
    }

    // ── One bar that morphs between the pill and the card ─────────────────
    // The text field is the same node in both layouts, so the switch keeps
    // focus, caret and text; only the buttons move (matchedGeometryEffect
    // slides them to the bottom row). Two separate views here tore the field
    // down and rebuilt it, which showed as a flicker mid-word.
    //   compact   [+] [field………………] [mic | →]          Figma 2160:6641
    //   expanded  [field…………………………………]
    //             [+] [mic]            [→]
    private var bar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if !isExpanded {
                    attachButton
                        .matchedGeometryEffect(id: "attach", in: ns)
                }

                field

                if !isExpanded {
                    Spacer(minLength: 0)
                    // While recording the mic stays as the stop control even
                    // though the field is no longer empty — otherwise it would
                    // vanish behind the send button mid-sentence.
                    if speech.isRecording || prompt.trimmingCharacters(in: .whitespaces).isEmpty {
                        micButton.matchedGeometryEffect(id: "mic", in: ns)
                    } else {
                        sendCircle.matchedGeometryEffect(id: "send", in: ns)
                    }
                }
            }

            if isExpanded {
                HStack(spacing: 4) {
                    attachButton.matchedGeometryEffect(id: "attach", in: ns)
                    micButton.matchedGeometryEffect(id: "mic", in: ns)
                    Spacer()
                    sendCircle.matchedGeometryEffect(id: "send", in: ns)
                }
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, isExpanded ? 12 : 16)
        .padding(.top, 14)
        .padding(.bottom, isExpanded ? 10 : 14)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: isExpanded ? 24 : 32, style: .continuous))
        .shadow(color: .black.opacity(0.10), radius: 20, x: 0, y: 8)
    }

    // ── The text field, with the brand-gradient placeholder ───────────────
    // A TextField can't style its own placeholder (Figma 2160:6641 wants the
    // purple gradient), so overlay one while empty.
    private var field: some View {
        ZStack(alignment: .leading) {
            if prompt.isEmpty {
                Text(placeholder)
                    .font(.body.weight(.medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.brand,
                                     Color.brandTextDeep],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .allowsHitTesting(false)
            }
            TextField("", text: $prompt, axis: .vertical)
                .font(.body)
                .foregroundStyle(Color(.label))
                .tint(Color(.label))
                .lineLimit(1...8)
                .focused($isFocused)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
                    // Only the compact width matters to the wrap decision.
                    if !isExpanded, w > 0 { compactFieldWidth = w }
                }
        }
        // A vertical-axis TextField hugs its text, so empty it is a sliver
        // behind the placeholder and a tap on the bar hit nothing. Fill the
        // row and make the whole area focus the field.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .padding(.horizontal, isExpanded ? 4 : 0)
    }

    // ── Hidden: would the prompt wrap in the compact field? ───────────────
    private var wrapMeasurer: some View {
        let lineH = UIFont.preferredFont(forTextStyle: .body).lineHeight
        return Text(prompt.isEmpty ? " " : prompt)
            .font(.body)
            .frame(width: max(compactFieldWidth, 1), alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                wraps = compactFieldWidth > 0 && h > lineH * 1.5
            }
    }

    // ── "+" attach menu (only where there's a document) ───────────────────
    @ViewBuilder
    private var attachButton: some View {
        if let onAttach {
            Menu {
                Button { onAttach(.photo) } label: { Label("Photo", systemImage: "photo") }
                Button { onAttach(.file)  } label: { Label("File",  systemImage: "paperclip") }
            } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color(.label))
                    .frame(width: iconSize, height: iconSize)
            }
            .accessibilityLabel("Add photo or file")
        }
    }

    // ── Mic: tap to dictate, tap again to stop ────────────────────────────
    private var micButton: some View {
        Button {
            if speech.isRecording {
                speech.stop()
            } else {
                let existing = prompt.trimmingCharacters(in: .whitespaces)
                dictationPrefix = existing.isEmpty ? "" : existing + " "
                speech.start { text in prompt = dictationPrefix + text }
            }
        } label: {
            Image(systemName: speech.isRecording ? "mic.fill" : "mic")
                .font(.body.weight(.medium))
                .foregroundStyle(speech.isRecording
                                 ? Color.brand
                                 : Color(.label))
                .frame(width: iconSize, height: iconSize)
                .symbolEffect(.pulse, isActive: speech.isRecording)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(speech.isRecording ? "Stop dictation" : "Dictate")
    }

    // ── Shared send button ────────────────────────────────────────────────
    private var sendCircle: some View {
        Button(action: onSend) {
            Image(systemName: "arrow.up")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: iconSize, height: iconSize)
                .background(
                    LinearGradient(
                        colors: [Color.brandFill,
                                 Color.brandDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        // The card can be open with nothing typed yet (expandsOnFocus).
        .disabled(isEmpty)
        .opacity(isEmpty ? 0.35 : 1)
        .accessibilityLabel("Send")
    }

    private var isEmpty: Bool { prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Template Card
// Example / suggestion cards on Home. Figma "Snackbar" (2160:6680):
//   stone/100 #F5F5F4 · radius 24 · padding 16 · 16 between title and body
//   Title  SF Pro Semibold 17/22, tracking -0.43, #1E1E1E — emoji inline
//   Body   SF Pro Regular  17/22, tracking -0.43, #757575
// Fills the width of its container; the list decides the horizontal inset.
// ─────────────────────────────────────────────────────────────────────────────

struct TemplateCard: View {
    let emoji: String
    let title: String
    let description: String
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 16) {
                Text(verbatim: "\(emoji) \(title)")
                    .font(.body.weight(.semibold))
                    .tracking(-0.43)
                    .foregroundStyle(Color.primaryInk)
                    .lineLimit(2)

                Text(description)
                    .font(.body)
                    .tracking(-0.43)
                    .foregroundStyle(Color.secondaryInk)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                Color.cardFill,   // stone/100
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
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
    /// What VoiceOver reads — the icon alone says nothing.
    var label: String
    var action: (() -> Void)? = nil

    var body: some View {
        Button(action: { action?() }) {
            Image(systemName: systemName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color(.label))
        }
        .accessibilityLabel(label)
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
                .font(.body.weight(.medium))
                // Prominent glass picks a dark label on a tint in dark mode;
                // the brand purple always wants white.
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.glassProminent)
        .tint(Color.brandFill)
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
    /// 44 matches the glass toolbar button height at the default text size;
    /// both scale with Dynamic Type so the label never clips.
    @ScaledMetric(relativeTo: .body) private var barH:  CGFloat = 44
    @ScaledMetric(relativeTo: .body) private var fullH: CGFloat = 52

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.medium))
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
                .frame(height: fullWidth ? fullH : barH)
                .background(
                    LinearGradient(
                        colors: [Color.brandFill,   // #4C00FF
                                 Color.brandDeep],  // #26065D
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
                .font(.body.weight(.medium))
                .foregroundStyle(Color(.systemBackground))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(.label))
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
    case insertImage, insertAttachment, insertSignature, insertDate
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
    var label: String
    var action: () -> Void
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 36

    var body: some View {
        Button(action: { action() }) {
            Image(systemName: systemName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: iconSize, height: iconSize)
        }
        .frame(height: 44)
        .padding(.horizontal, 4)
        .background(
            LinearGradient(
                colors: [Color.brandFill,
                         Color.brandDeep],
                startPoint: UnitPoint(x: 0.08, y: 0),
                endPoint:   UnitPoint(x: 1.47, y: 1)
            ),
            in: Capsule()
        )
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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
    /// Same, with which activity it was — "Copy" completes too, but nothing
    /// was sent, and a caller that says "Sent ✓" needs to tell them apart.
    var onFinishActivity: ((Bool, UIActivity.ActivityType?) -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: applicationActivities
        )
        vc.completionWithItemsHandler = { type, completed, _, _ in
            onFinish?(completed)
            onFinishActivity?(completed, type)
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
    @ScaledMetric(relativeTo: .callout) private var barH:     CGFloat = 48
    @ScaledMetric(relativeTo: .callout) private var iconSize: CGFloat = 36
    @ScaledMetric(relativeTo: .callout) private var labelW:   CGFloat = 30

    var body: some View {
        // Outer row: pill left-aligned with 8 pt side insets (matches Figma px-[8])
        HStack {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {

                    // ── eSignature — first per design ─────────────────────────
                    toolBtn("signature", String(localized: "Add signature box")) { onAction(.insertSignature) }
                    toolBtn("calendar",  String(localized: "Add date box"))      { onAction(.insertDate) }

                    sep

                    // ── Text style ────────────────────────────────────────────
                    toolBtn("bold",      String(localized: "Bold"))      { onAction(.bold) }
                    toolBtn("italic",    String(localized: "Italic"))    { onAction(.italic) }
                    toolBtn("underline", String(localized: "Underline")) { onAction(.underline) }

                    sep

                    // ── Headings ──────────────────────────────────────────────
                    labelBtn("H1", String(localized: "Heading 1")) { onAction(.heading1) }
                    labelBtn("H2", String(localized: "Heading 2")) { onAction(.heading2) }

                    sep

                    // ── Lists ─────────────────────────────────────────────────
                    toolBtn("list.bullet", String(localized: "Bulleted list")) { onAction(.bulletList) }
                    toolBtn("list.number", String(localized: "Numbered list")) { onAction(.numberedList) }

                    sep

                    // ── Alignment ─────────────────────────────────────────────
                    toolBtn("text.alignleft",   String(localized: "Align left"))   { onAction(.alignLeft) }
                    toolBtn("text.aligncenter", String(localized: "Align center")) { onAction(.alignCenter) }
                    toolBtn("text.alignright",  String(localized: "Align right"))  { onAction(.alignRight) }

                    sep

                    // ── Insert ────────────────────────────────────────────────
                    toolBtn("photo",     String(localized: "Insert photo")) { onAction(.insertImage) }
                    toolBtn("paperclip", String(localized: "Attach file"))  { onAction(.insertAttachment) }
                }
                .padding(.horizontal, 10)   // Figma: px-[10] inside the pill
            }
            .frame(height: barH)            // Figma: h-[48px] at the default text size
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
    private func toolBtn(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.callout.weight(.medium))
                .foregroundStyle(Color(.label))
                .frame(width: iconSize, height: iconSize)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // ── Short text button for H1 / H2 ────────────────────────────────────────
    private func labelBtn(_ text: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(.label))
                .frame(width: labelW, height: iconSize)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Handshake Illustration
// Home screen empty-state graphic.
// Drop "oc-handshake" PNG into Assets.xcassets to use the real Figma asset;
// the two-hand SF Symbol fallback renders automatically otherwise.
// ─────────────────────────────────────────────────────────────────────────────

struct HandshakeIllustration: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if UIImage(named: "oc-handshake") != nil {
            // ── Real Figma asset ─────────────────────────────────────
            // Floating icons are already part of the PNG — no overlay needed.
            let art = Image("oc-handshake")
                .resizable()
                .scaledToFit()
                .frame(width: 280)
            // Black line art on transparent is invisible on a black page.
            // Inverted, the hands draw in white and the grey icons stay grey.
            if colorScheme == .dark {
                art.colorInvert()
            } else {
                art
            }
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
            .font(.body)
            .lineSpacing(3)
            .foregroundStyle(message.isUser ? Color.white : Color(.label))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(message.isUser ? Color.userBubble : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 18))

            if !message.isUser { Spacer(minLength: 60) }
        }
    }
}
