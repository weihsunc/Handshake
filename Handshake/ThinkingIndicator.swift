import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ThinkingIndicator
//
// What the AI panel shows while the model works — the Claude / ChatGPT
// pattern: a breathing sparkle and a status line that shimmers and steps
// through stages ("Looking for similar templates…", "Drafting the clauses…").
//
// The stages are paced by time, not by the model: the Messages API call isn't
// streamed, so there's no real progress to report. They describe what the
// request genuinely involves, advance every couple of seconds, and hold on the
// last one until the answer lands — they never loop, so a slow reply doesn't
// replay "Reading your request" as if it had started over.
//
// Reduce Motion: no shimmer, no breathing; the stages still change.
// ─────────────────────────────────────────────────────────────────────────────

struct ThinkingIndicator: View {

    enum Work {
        /// First draft from a prompt.
        case drafting
        /// A follow-up change to an existing contract.
        case editing

        var stages: [String] {
            switch self {
            case .drafting:
                return ["Reading your request",
                        "Looking for similar templates",
                        "Drafting the clauses",
                        "Adding signature and date fields",
                        "Checking the wording"]
            case .editing:
                return ["Reading the contract",
                        "Working on your changes",
                        "Updating the document"]
            }
        }
    }

    let task: Work
    /// Seconds each stage is shown before the next.
    var stageDuration: Double = 2.4

    @State private var stage = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var label: String { task.stages[min(stage, task.stages.count - 1)] + "…" }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.brand)
                .symbolEffect(.breathe, isActive: !reduceMotion)

            ShimmerText(text: label, animated: !reduceMotion)
                .id(label)                                    // crossfade on each stage
                .transition(.opacity.combined(with: .offset(y: 4)))
        }
        .animation(.easeInOut(duration: 0.35), value: stage)
        .task(id: task.stages) {
            stage = 0
            while stage < task.stages.count - 1 {
                try? await Task.sleep(for: .seconds(stageDuration))
                if Task.isCancelled { return }
                stage += 1
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ShimmerText
// A light band sweeping left to right across secondary-coloured text. Driven by
// TimelineView rather than a repeatForever animation, which would get caught up
// in the panel's own spring animations and stall or jump.
// ─────────────────────────────────────────────────────────────────────────────

struct ShimmerText: View {
    let text: String
    var animated: Bool = true
    /// Seconds for one sweep.
    var period: Double = 1.6

    var body: some View {
        let base = Text(text).font(.subheadline.weight(.medium))
        if animated {
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let phase = CGFloat((t.truncatingRemainder(dividingBy: period)) / period)   // 0 → 1
                base
                    .foregroundStyle(.secondary)
                    .overlay {
                        GeometryReader { g in
                            let band = max(g.size.width * 0.45, 60)
                            LinearGradient(colors: [.clear, Color(.label).opacity(0.85), .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: band)
                                // from fully off the left edge to fully off the right
                                .offset(x: -band + phase * (g.size.width + band))
                        }
                        .mask(base)
                        .allowsHitTesting(false)
                    }
            }
        } else {
            base.foregroundStyle(.secondary)
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 24) {
        ThinkingIndicator(task: .drafting)
        ThinkingIndicator(task: .editing)
    }
    .padding()
}
