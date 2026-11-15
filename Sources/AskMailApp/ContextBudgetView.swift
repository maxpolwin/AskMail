import AskMailCore
import SwiftUI

/// Settings panel that makes the trade-off between excerpts per answer, the
/// email (context) budget and the answer length visible: one bar for a single
/// question's model window, three controls, and a status line. Arithmetic
/// lives in `ContextBudget` (AskMailCore, unit-tested); this view only draws it.
///
/// Never relies on colour alone: each segment has its own fill pattern, its
/// own icon and a text legend, and the bar and gauge carry spoken summaries.
struct ContextBudgetView: View {
    @Binding var excerpts: Int
    @Binding var context: Int
    @Binding var answer: Int

    /// Per-excerpt token cost, measured from the index when it has chunks.
    let tokensPerExcerpt: Int
    let isMeasured: Bool
    /// What the selected model plus its window costs against this Mac's GPU
    /// limit; nil when the model's architecture isn't known.
    let memory: ModelMemory?
    /// Window a local OpenAI-compatible server reports, when it reports one.
    let serverWindowTokens: Int?
    let recommended: TokenAdvisor.Recommendation
    let rationale: String

    @ScaledMetric(relativeTo: .body) private var barHeight: CGFloat = 26

    private var budget: ContextBudget {
        ContextBudget(excerpts: excerpts, contextTokens: context, answerTokens: answer,
                      tokensPerExcerpt: tokensPerExcerpt,
                      memory: memory,
                      serverWindowTokens: serverWindowTokens)
    }

    var body: some View {
        let budget = budget
        VStack(alignment: .leading, spacing: 12) {
            Text("What fits in one question")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            WindowBar(budget: budget)
                .frame(height: barHeight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.summary(for: budget))

            legend(for: budget)

            Divider()

            controlRow("Excerpts per answer", value: $excerpts, range: Defaults.excerptRange,
                       step: 1, detail: isMeasured
                           ? "about \(tokensPerExcerpt) tokens each in your mailbox"
                           : "about \(tokensPerExcerpt) tokens each (estimate)")
            controlRow("Context tokens", value: $context, range: Defaults.contextTokenRange,
                       step: 512, detail: "the most email text read into an answer")
            controlRow("Answer tokens", value: $answer, range: Defaults.answerTokenRange,
                       step: 100, detail: "the longest reply")

            if let estimated = budget.estimatedMemoryGB, let limit = budget.gpuLimitGB {
                MemoryGauge(estimatedGB: estimated, limitGB: limit)
            }

            StatusLine(status: budget.status, tokensPerExcerpt: tokensPerExcerpt,
                       excerpts: excerpts)

            Text("An excerpt is a piece of an email, so two excerpts from one email show as one entry in Sources.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(rationale)
                .font(.caption)
                .foregroundStyle(.secondary)

            if excerpts != recommended.excerpts || context != recommended.contextTokens
                || answer != recommended.answerTokens {
                HStack(spacing: 8) {
                    Text("Recommended: \(recommended.excerpts) excerpts, \(recommended.contextTokens.formatted()) context, \(recommended.answerTokens.formatted()) answer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Use recommended") {
                        excerpts = recommended.excerpts
                        context = recommended.contextTokens
                        answer = recommended.answerTokens
                    }
                    .font(.caption)
                }
            }
        }
    }

    // MARK: Legend

    private func legend(for budget: ContextBudget) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading),
                            GridItem(.flexible(), alignment: .topLeading)],
                  alignment: .leading, spacing: 8) {
            legendItem("text.bubble", "Prompt and chat", budget.promptTokens, "reserved")
            legendItem("envelope", "Email used", budget.emailUsedTokens,
                       "\(excerpts) excerpt\(excerpts == 1 ? "" : "s")")
            legendItem("rectangle.dashed", "Email budget unused", budget.emailUnusedTokens,
                       "not filled by excerpts")
            legendItem("pencil", "Answer", budget.answerTokens, "reserved for the reply")
        }
    }

    private func legendItem(_ symbol: String, _ title: String, _ tokens: Int, _ note: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.medium))
                Text("\(tokens.formatted()) tokens \u{00B7} \(note)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Controls

    /// A slider plus a typeable field for one budget value. Both write through
    /// a clamping binding, so neither the slider nor typed text can leave `range`.
    private func controlRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>,
                            step: Int, detail: String) -> some View {
        let clamped = Binding<Int>(
            get: { value.wrappedValue },
            set: { value.wrappedValue = Defaults.clamp($0, to: range) })
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Text(title)
                    .frame(width: 140, alignment: .leading)
                // Continuous slider snapped to `step` in the setter: passing
                // `step:` would draw a tick mark per step, hundreds of them
                // across the wide context range.
                Slider(value: Binding(get: { Double(clamped.wrappedValue) },
                                      set: { clamped.wrappedValue = Self.snapped($0, step: step, in: range) }),
                       in: Double(range.lowerBound)...Double(range.upperBound))
                    .accessibilityLabel(title)
                TextField(title, value: clamped, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                    .accessibilityLabel("\(title), type a value")
            }
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 150)
        }
    }

    /// Rounds a slider position to the nearest `step` (anchored at the range's
    /// lower bound) and keeps it inside `range`.
    static func snapped(_ value: Double, step: Int, in range: ClosedRange<Int>) -> Int {
        let base = Double(range.lowerBound)
        let steps = ((value - base) / Double(step)).rounded()
        return Defaults.clamp(Int(base + steps * Double(step)), to: range)
    }

    // MARK: Spoken summary

    static func summary(for budget: ContextBudget) -> String {
        "Window of \(budget.windowTokens.formatted()) tokens: "
            + "\(budget.promptTokens.formatted()) prompt and chat, "
            + "\(budget.emailUsedTokens.formatted()) email used, "
            + "\(budget.emailUnusedTokens.formatted()) email budget unused, "
            + "\(budget.answerTokens.formatted()) answer."
    }
}

// MARK: - Bar

/// The request window as proportional segments. Static, no animation (also the
/// Reduce Motion behaviour). Fill patterns, not just colours, tell segments apart.
private struct WindowBar: View {
    let budget: ContextBudget

    var body: some View {
        Canvas { context, size in
            let total = Double(max(1, budget.windowTokens))
            let segments: [(tokens: Int, kind: Kind)] = [
                (budget.promptTokens, .prompt),
                (budget.emailUsedTokens, .used),
                (budget.emailUnusedTokens, .unused),
                (budget.answerTokens, .answer),
            ]
            var x: CGFloat = 0
            for segment in segments where segment.tokens > 0 {
                let width = CGFloat(Double(segment.tokens) / total) * size.width
                let rect = CGRect(x: x, y: 0, width: max(0, width - 1), height: size.height)
                draw(segment.kind, in: rect, context: &context)
                x += width
            }
        }
    }

    private enum Kind { case prompt, used, unused, answer }

    private func draw(_ kind: Kind, in rect: CGRect, context: inout GraphicsContext) {
        guard rect.width > 0 else { return }
        let shape = Path(roundedRect: rect, cornerRadius: 3)
        let ink = Color.primary.opacity(0.55)
        switch kind {
        case .prompt:
            context.fill(shape, with: .color(Color.gray.opacity(0.55)))
        case .used:
            context.fill(shape, with: .color(Theme.accent))
        case .unused:
            context.stroke(shape, with: .color(ink), lineWidth: 1)
            var clipped = context
            clipped.clip(to: shape)
            var step = rect.minX - rect.height
            while step < rect.maxX {
                var line = Path()
                line.move(to: CGPoint(x: step, y: rect.maxY))
                line.addLine(to: CGPoint(x: step + rect.height, y: rect.minY))
                clipped.stroke(line, with: .color(ink), lineWidth: 1)
                step += 7
            }
        case .answer:
            context.fill(shape, with: .color(Color.gray.opacity(0.28)))
            var clipped = context
            clipped.clip(to: shape)
            var dotX = rect.minX + 4
            while dotX < rect.maxX {
                var dotY = rect.minY + 4
                while dotY < rect.maxY {
                    clipped.fill(Path(ellipseIn: CGRect(x: dotX - 1, y: dotY - 1, width: 2, height: 2)),
                                 with: .color(ink))
                    dotY += 6
                }
                dotX += 6
            }
        }
    }
}

// MARK: - Memory gauge

private struct MemoryGauge: View {
    let estimatedGB: Double
    let limitGB: Double

    var body: some View {
        let estimate = estimatedGB.formatted(.number.precision(.fractionLength(1)))
        let limit = limitGB.formatted(.number.precision(.fractionLength(0)))
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Model memory with this window")
                Spacer()
                Text("about \(estimate) GB")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Canvas { context, size in
                let scale = max(limitGB * 1.15, estimatedGB * 1.05, 0.1)
                let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4)
                context.fill(track, with: .color(Color.gray.opacity(0.18)))
                let fill = CGRect(x: 0, y: 0,
                                  width: min(1, estimatedGB / scale) * size.width, height: size.height)
                context.fill(Path(roundedRect: fill, cornerRadius: 4), with: .color(Color.primary.opacity(0.55)))
                let tickX = min(1, limitGB / scale) * size.width
                var tick = Path()
                tick.move(to: CGPoint(x: tickX, y: -2))
                tick.addLine(to: CGPoint(x: tickX, y: size.height + 2))
                context.stroke(tick, with: .color(.primary), lineWidth: 2)
            }
            .frame(height: 12)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Model memory gauge")
            .accessibilityValue("about \(estimate) gigabytes; this Mac lets the GPU use about \(limit)")

            Text("The marker is what this Mac lets the GPU use, about \(limit) GB. The estimate comes from this model\u{2019}s size and window and ran 3% to 15% above measured sizes in testing, never below.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Status

private struct StatusLine: View {
    let status: ContextBudget.Status
    let tokensPerExcerpt: Int
    let excerpts: Int

    var body: some View {
        let content = Self.content(for: status)
        // Text stays in the primary colour for contrast on any surface; the
        // symbol and the words carry the warning, the tint only reinforces it.
        Label {
            Text(content.message)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: content.symbol)
                .foregroundStyle(content.warns ? Color.orange : Color.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    static func content(for status: ContextBudget.Status) -> (symbol: String, message: String, warns: Bool) {
        switch status {
        case .fits:
            return ("checkmark.circle", "Fits. Excerpts fill most of the email budget.", false)
        case .needsMoreBudget(let needed):
            return ("info.circle",
                    "The excerpts need about \(needed.formatted()) tokens, more than the email budget. The lowest-ranked ones are dropped. Raise the context to keep them.",
                    false)
        case .mostlyUnused(let percent):
            return ("info.circle",
                    "Excerpts fill \(percent)% of the email budget. Add excerpts to use more of it, or lower the context to save memory.",
                    false)
        case .aboveMemory(let estimated, let limit):
            return ("exclamationmark.triangle",
                    "This model with this window needs about \(estimated.formatted(.number.precision(.fractionLength(1)))) GB, close to or past the \(limit.formatted(.number.precision(.fractionLength(0)))) GB this Mac lets the GPU use. Ollama then moves part of the model to the CPU, which is much slower.",
                    true)
        case .aboveModelWindow(let maxTokens):
            return ("exclamationmark.triangle",
                    "Larger than the \(maxTokens.formatted())-token window this model was built for. Lower the context or choose a model with a longer window.",
                    true)
        case .aboveServerWindow(let server):
            return ("exclamationmark.triangle",
                    "Larger than the \(server.formatted())-token window your server reports. Raise the model\u{2019}s context length in the server app, or lower these values.",
                    true)
        }
    }
}
