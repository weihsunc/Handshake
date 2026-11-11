import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Paper plane doodle
//
// The owner's hand-drawn paper plane ("paper plane.svg", 400×400) drawn in as
// if by pen — the outline, then the fold, then the little tail — and then
// tossed: a short hop up and to the right that springs back. Same ink and
// round strokes as the handshake mark, so the Sent page reads as one hand.
//
// The paths are the SVG's, in its own space. The drawing only fills the
// middle of the file, so it's framed to the box around it (`crop`) rather
// than the whole 400 points.
// ─────────────────────────────────────────────────────────────────────────────

struct PaperPlaneDoodle: View {
    var size: CGFloat = 76
    var color: Color = .ink

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var outline: CGFloat = 0
    @State private var fold: CGFloat = 0
    @State private var tail: CGFloat = 0
    @State private var tossed = false
    @State private var landed = false

    var body: some View {
        // The handshake's pen at the Sent page's size (84), in proportion
        // at any other size.
        let stroke = StrokeStyle(lineWidth: HandshakeDoodle.pen * size / 84,
                                 lineCap: .round, lineJoin: .round)
        ZStack {
            PlanePath(part: .outline).trim(from: 0, to: outline).stroke(color, style: stroke)
            PlanePath(part: .fold).trim(from: 0, to: fold).stroke(color, style: stroke)
            PlanePath(part: .tail).trim(from: 0, to: tail).stroke(color, style: stroke)
        }
        .frame(width: size, height: size)
        // The toss: up and to the right, nose lifting, then back down.
        .rotationEffect(.degrees(tossed && !landed ? -8 : 0))
        .offset(x: tossed && !landed ? size * 0.12 : 0,
                y: tossed && !landed ? -size * 0.12 : 0)
        .accessibilityElement()
        .accessibilityLabel(Text("Sent"))
        .onAppear(perform: draw)
    }

    private func draw() {
        guard !reduceMotion else { outline = 1; fold = 1; tail = 1; return }
        // Starts once the page has faded in (0.25 s).
        let start = 0.2
        withAnimation(.easeInOut(duration: 0.6).delay(start))         { outline = 1 }
        withAnimation(.easeInOut(duration: 0.4).delay(start + 0.5))   { fold = 1 }
        withAnimation(.easeOut(duration: 0.15).delay(start + 0.85))   { tail = 1 }
        withAnimation(.easeOut(duration: 0.22).delay(start + 1.0))    { tossed = true }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.5).delay(start + 1.22)) { landed = true }
    }
}

private struct PlanePath: Shape {
    enum Part { case outline, fold, tail }
    let part: Part

    /// The drawing's own bounds in the SVG (about 92…306 × 120…283), squared
    /// and padded so the strokes' round ends aren't clipped.
    static let crop = CGRect(x: 80, y: 82, width: 240, height: 240)

    func path(in rect: CGRect) -> Path {
        let c = Self.crop
        let s = min(rect.width, rect.height) / c.width
        let ox = rect.midX - (c.midX) * s, oy = rect.midY - (c.midY) * s
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }

        var path = Path()
        switch part {
        case .outline:
            path.move(to: p(138.428, 194.168))
            path.addCurve(to: p(95.1067, 166.118), control1: p(132.823, 193.515), control2: p(92.6669, 168.574))
            path.addCurve(to: p(265.287, 136.236), control1: p(95.5732, 165.647), control2: p(235.401, 146.283))
            path.addCurve(to: p(304.959, 121.035), control1: p(269.462, 134.835), control2: p(303.291, 120.195))
            path.addCurve(to: p(291.471, 148.236), control1: p(306.019, 121.569), control2: p(292.192, 145.628))
            path.addCurve(to: p(258.861, 279.097), control1: p(271.97, 218.741),  control2: p(259.324, 282.809))
            path.addCurve(to: p(190.709, 225.84),  control1: p(257.918, 271.486), control2: p(207.496, 239.383))
        case .fold:
            path.move(to: p(281.949, 138.636))
            path.addCurve(to: p(235.931, 161.837), control1: p(265.387, 144.131), control2: p(251.195, 153.444))
            path.addCurve(to: p(159.766, 201.041), control1: p(222.011, 169.495), control2: p(169.029, 194.033))
            path.addCurve(to: p(159.766, 209.041), control1: p(157.518, 202.74),  control2: p(159.488, 207.082))
            path.addCurve(to: p(170.079, 265.041), control1: p(163.901, 238.222), control2: p(169.707, 265.325))
            path.addCurve(to: p(185.947, 220.239), control1: p(179.121, 258.205), control2: p(173.583, 228.554))
            path.addCurve(to: p(292.262, 132.236), control1: p(225.091, 193.928), control2: p(267.31, 174.175))
        case .tail:
            path.move(to: p(170.949, 265.352))
            path.addCurve(to: p(204.994, 241.863), control1: p(182.286, 256.842), control2: p(193.084, 247.534))
        }
        return path
    }
}

#Preview {
    PaperPlaneDoodle()
        .padding(40)
        .background(Color.pageBackground)
}
