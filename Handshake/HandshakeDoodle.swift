import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Handshake doodle
//
// The handshake mark (handshake-glyph.svg — the app icon and chat-bar mark),
// drawn in as if by pen, the way the check and paper-plane doodles are:
// the sleeves, then the hands, then the fingers. Then a small pump, like a
// handshake, and a few sparkles twinkle at the sides. Home's hero.
//
// Plays once per launch; after that it appears drawn (the hero comes and goes
// as the chat bar takes focus, and a replay every time would wear thin). Tap
// it to play again. Reduce Motion: drawn and still, sparkles shown, no twinkle.
//
// The paths are the SVG's, in its own 340 × 162 space (viewBox 30 122 …),
// scaled to the frame.
// ─────────────────────────────────────────────────────────────────────────────

struct HandshakeDoodle: View {
    var width: CGFloat = 210
    var color: Color = .ink

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn: [CGFloat] = Array(repeating: 0, count: HandshakeStroke.count)
    @State private var pumped = false
    @State private var sparkles = false
    private static var hasPlayed = false

    private var height: CGFloat { width * 162 / 340 }

    var body: some View {
        // The mark is 16 wide; a little lighter at hero size.
        let line = StrokeStyle(lineWidth: 13 * width / 340, lineCap: .round, lineJoin: .round)
        ZStack {
            ForEach(0..<HandshakeStroke.count, id: \.self) { i in
                HandshakeStroke(index: i)
                    .trim(from: 0, to: drawn[i])
                    .stroke(color.opacity(HandshakeStroke.opacity[i]), style: line)
            }
        }
        .frame(width: width, height: height)
        // A handshake's pump: down and back, twice.
        .offset(y: pumped ? 3 : 0)
        .rotationEffect(.degrees(pumped ? 1.5 : 0))
        .overlay { sparkleLayer }
        .padding(.horizontal, 28)
        .contentShape(Rectangle())
        .onTapGesture { play() }
        .accessibilityHidden(true)       // decoration; the greeting below says it
        .onAppear {
            if reduceMotion || Self.hasPlayed { show() } else { play() }
        }
    }

    // ── Sparkles ────────────────────────────────────────────────────────────

    /// Three small four-point stars around the hands, each twinkling on its
    /// own beat so they don't pulse together.
    private var sparkleLayer: some View {
        ZStack {
            twinkle(size: 18, x: -0.10, y: 0.12, period: 1.3)
            twinkle(size: 26, x: 1.08, y: -0.04, period: 1.7)
            twinkle(size: 13, x: 1.13, y: 0.42, period: 1.1)
        }
        .frame(width: width, height: height)
    }

    private func twinkle(size: CGFloat, x: CGFloat, y: CGFloat, period: Double) -> some View {
        Sparkle()
            .stroke(color, style: StrokeStyle(lineWidth: max(1.5, size / 9), lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .phaseAnimator(reduceMotion || !sparkles ? [true] : [false, true]) { star, bright in
                star.scaleEffect(bright ? 1 : 0.7).opacity(bright ? 1 : 0.45)
            } animation: { _ in .easeInOut(duration: period) }
            .scaleEffect(sparkles ? 1 : 0.2)
            .opacity(sparkles ? 1 : 0)
            .position(x: width * x, y: height * y)
    }

    // ── Timing ──────────────────────────────────────────────────────────────

    private func show() {
        drawn = Array(repeating: 1, count: HandshakeStroke.count)
        sparkles = true
    }

    private func play() {
        guard !reduceMotion else { show(); return }
        Self.hasPlayed = true
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            drawn = Array(repeating: 0, count: HandshakeStroke.count)
            pumped = false
            sparkles = false
        }
        // Sleeves first, then the hand outlines, then the fingers and marks —
        // each stroke a beat after the last, quick like a pen.
        var start = 0.15
        for i in 0..<HandshakeStroke.count {
            let duration = HandshakeStroke.opacity[i] < 1 ? 0.32 : (i == 2 ? 0.45 : 0.16)
            withAnimation(.easeInOut(duration: duration).delay(start)) { drawn[i] = 1 }
            start += duration * 0.7
        }
        withAnimation(.easeInOut(duration: 0.14).repeatCount(4, autoreverses: true).delay(start + 0.1)) {
            pumped = true
        }
        // repeatCount(4) with autoreverse ends displaced; settle back.
        withAnimation(.easeOut(duration: 0.12).delay(start + 0.1 + 0.14 * 4)) { pumped = false }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.55).delay(start + 0.35)) { sparkles = true }
    }
}

/// A four-point star with pinched sides, like a doodled glint.
private struct Sparkle: Shape {
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY)
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: c.y), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x, y: r.maxY), control: c)
        p.addQuadCurve(to: CGPoint(x: r.minX, y: c.y), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x, y: r.minY), control: c)
        p.closeSubpath()
        return p
    }
}

/// One stroke of handshake-glyph.svg.
private struct HandshakeStroke: Shape {
    static let count = 12
    /// The sleeves are drawn lighter in the mark.
    static let opacity: [Double] = [0.5, 0.5, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]
    let index: Int

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width / 340, rect.height / 162)
        let ox = rect.midX - 170 * s, oy = rect.midY - 81 * s
        func q(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + (x - 30) * s, y: oy + (y - 122) * s) }

        var p = Path()
        switch index {
        case 0:
            p.move(to: q(82.5152, 134.811))
            p.addCurve(to: q(135.419, 165.926), control1: q(91.6847, 143.082), control2: q(131.789, 155.582))
            p.addCurve(to: q(95.7744, 241.416), control1: q(135.664, 166.623), control2: q(100.375, 240.649))
            p.addCurve(to: q(38, 223.9), control1: q(76.525, 244.62), control2: q(57.0225, 229.323))
        case 1:
            p.move(to: q(346.544, 130))
            p.addCurve(to: q(316.568, 139.307), control1: q(325.728, 136.001), control2: q(335.709, 132.868))
            p.addCurve(to: q(277.369, 154.432), control1: q(306.441, 142.717), control2: q(285.915, 148.687))
            p.addCurve(to: q(279.674, 164.907), control1: q(273.877, 156.784), control2: q(278.842, 162.383))
            p.addCurve(to: q(299.275, 249.841), control1: q(283.817, 177.441), control2: q(295.566, 249.215))
            p.addCurve(to: q(361.532, 231.222), control1: q(318.521, 253.079), control2: q(343.743, 237.208))
        case 2:
            p.move(to: q(268.22, 160.121))
            p.addCurve(to: q(195.015, 160.121), control1: q(251.702, 160.121), control2: q(209.674, 149.177))
            p.addCurve(to: q(188.069, 207.372), control1: q(186.617, 166.396), control2: q(172.596, 203.524))
            p.addCurve(to: q(218.166, 187.782), control1: q(199.04, 210.104), control2: q(208.829, 189.641))
            p.addCurve(to: q(273.732, 216.595), control1: q(226.341, 186.155), control2: q(268.498, 209.649))
        case 3:
            p.move(to: q(273.731, 220.204))
            p.addCurve(to: q(253.78, 256.192), control1: q(273.957, 233.976), control2: q(256.781, 253.237))
            p.addCurve(to: q(217.205, 269.515), control1: q(248.737, 261.173), control2: q(241.585, 266.508))
        case 4:
            p.move(to: q(142.258, 228.496))
            p.addCurve(to: q(153.143, 241.185), control1: q(150.944, 226.46), control2: q(154.573, 230.69))
            p.addCurve(to: q(135.817, 236.986), control1: q(146.371, 256.474), control2: q(125.492, 252.543))
        case 5:
            p.move(to: q(175.336, 234.23))
            p.addCurve(to: q(178.397, 253.572), control1: q(183.472, 232.714), control2: q(184.492, 239.161))
            p.addCurve(to: q(161.062, 245.956), control1: q(172.721, 268.148), control2: q(158.074, 261.511))
        case 6:
            p.move(to: q(191.97, 246.041))
            p.addCurve(to: q(203.973, 262.697), control1: q(199.972, 246.041), control2: q(203.973, 251.593))
            p.addCurve(to: q(182.324, 258.284), control1: q(203.041, 274.374), control2: q(182.324, 278.634))
        case 7:
            p.move(to: q(184.731, 177.056))
            p.addCurve(to: q(156.464, 174.51), control1: q(176.394, 177.004), control2: q(167.123, 174.318))
            p.addCurve(to: q(129.406, 178.109), control1: q(145.804, 174.703), control2: q(139.376, 176.305))
        case 8:
            p.move(to: q(253, 230))
            p.addCurve(to: q(263, 235), control1: q(257.105, 232.806), control2: q(262.021, 235))
        case 9:
            p.move(to: q(242, 247))
            p.addCurve(to: q(251.622, 253.014), control1: q(246.724, 251.009), control2: q(249.931, 253.014))
        case 10:
            p.move(to: q(226, 260))
            p.addCurve(to: q(235.622, 266.014), control1: q(230.724, 264.009), control2: q(233.931, 266.014))
        case 11:
            p.move(to: q(128.204, 237.042))
            p.addCurve(to: q(102.58, 233.434), control1: q(114.813, 234.636), control2: q(106.271, 233.434))
            p.addCurve(to: q(128.204, 237.042), control1: q(98.888, 233.434), control2: q(107.429, 234.636))
            p.closeSubpath()
        default: break
        }
        return p
    }
}

#Preview {
    HandshakeDoodle()
        .padding(40)
        .background(Color.pageBackground)
}
