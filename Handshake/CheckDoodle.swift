import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Check doodle
//
// The hand-drawn check in a circle ("check circle.svg", the owner's doodle,
// 400×400) drawn in as if by pen: the loop first, then the tick, then a small
// settle. Same ink and round strokes as the handshake mark. Used on the
// recipient's Signed screen (SigningView); the sender's Sent page has the paper plane.
//
// The paths are the SVG's, in its own 400-point space, scaled to the frame.
// The tick is reversed from the file (which runs tip → stem) so it's drawn
// the way a hand draws one: down into the dip, then up and out.
// ─────────────────────────────────────────────────────────────────────────────

struct CheckDoodle: View {
    var size: CGFloat = 88
    var color: Color = .ink
    /// What VoiceOver says for it.
    var label: String = String(localized: "Signed")

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var loop: CGFloat = 0
    @State private var tick: CGFloat = 0
    @State private var settled = false

    var body: some View {
        let stroke = StrokeStyle(lineWidth: 16 * size / 400, lineCap: .round, lineJoin: .round)
        ZStack {
            DoodlePath(part: .loop).trim(from: 0, to: loop).stroke(color, style: stroke)
            DoodlePath(part: .tick).trim(from: 0, to: tick).stroke(color, style: stroke)
        }
        .frame(width: size, height: size)
        .scaleEffect(settled ? 1 : 0.94)
        .accessibilityElement()
        .accessibilityLabel(Text(label))
        .onAppear(perform: draw)
    }

    private func draw() {
        guard !reduceMotion else { loop = 1; tick = 1; settled = true; return }
        // Starts once the page has faded in (0.25 s), so the first stroke
        // isn't drawn on a half-visible page.
        let start = 0.2
        // A pen speeds up into a loop and eases off the end of it.
        withAnimation(.easeInOut(duration: 0.55).delay(start)) { loop = 1 }
        // The tick is quicker and more decisive — a flick.
        withAnimation(.easeOut(duration: 0.3).delay(start + 0.5)) { tick = 1 }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.45).delay(start + 0.78)) { settled = true }
    }
}

private struct DoodlePath: Shape {
    enum Part { case loop, tick }
    let part: Part

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 400
        let ox = rect.midX - 200 * s, oy = rect.midY - 200 * s
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }

        var path = Path()
        switch part {
        case .loop:
            path.move(to: p(133.939, 87.4096))
            path.addCurve(to: p(268.309, 72.1791), control1: p(178.195, 56.5296), control2: p(221.393, 47.5426))
            path.addCurve(to: p(182.313, 341.383), control1: p(394.5, 138.439),   control2: p(339.462, 364.235))
            path.addCurve(to: p(101.694, 125.506), control1: p(96.7463, 328.936), control2: p(11.1442, 221.4))
        case .tick:
            path.move(to: p(138, 204.479))
            path.addCurve(to: p(327, 80), control1: p(185.25, 328.957), control2: p(153.606, 281.722))
        }
        return path
    }
}

#Preview {
    CheckDoodle()
        .padding(40)
        .background(Color.pageBackground)
}
