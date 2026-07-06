import AppKit
import AskMailCore
import SwiftUI

/// One source rendered as "N  domain (date): subject" — shared by the on-screen
/// row and the clipboard export so the two presentations never drift.
func formatSource(_ number: Int, _ ref: SourceRef) -> String {
    "\(number)  \(MailHeader.domain(fromSender: ref.sender)) "
        + "(\(PromptAssembler.ymd(ref.dateUnix))): \(MailHeader.decode(ref.subject))"
}

/// The model answers in Markdown (`**bold**`, `*italic*`, `` `code` ``). Parse
/// it inline-only so emphasis renders while newlines are preserved verbatim —
/// block reflow would fight the streamed, line-oriented answer.
func answerMarkdown(_ text: String) -> AttributedString {
    (try? AttributedString(
        markdown: text,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text)
}

/// Retrieval relevance per source number, normalized 0–100% against the
/// strongest source in this answer (the raw RRF score has no meaningful
/// absolute scale — it only ranks). Empty when no source carries a score.
func relevancePercents(_ sources: [(number: Int, ref: SourceRef)]) -> [Int: Int] {
    guard let top = sources.compactMap({ $0.ref.relevance }).max(), top > 0 else { return [:] }
    return sources.reduce(into: [:]) { out, source in
        if let score = source.ref.relevance {
            out[source.number] = Int((score / top * 100).rounded())
        }
    }
}

/// One source: the accent-coloured, clickable, selectable line and a relevance
/// bar. Hovering the row (or the bar) reveals the exact figure within 250 ms —
/// faster than the system tooltip, which `.help()` can't speed up — worded
/// plainly as "Relevance score: NN%".
private struct SourceRow: View {
    let number: Int
    let ref: SourceRef
    let percent: Int?
    @State private var hovering = false
    @State private var showScore = false

    var body: some View {
        HStack(spacing: 8) {
            Text(line)
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let percent {
                RelevanceBar(fraction: Double(percent) / 100)
            }
        }
        .contentShape(Rectangle())  // whole row (incl. gaps) is the hover target
        .overlay(alignment: .trailing) {
            if showScore, let percent {
                Text("Relevance score: \(percent)%")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .onHover { inside in
            hovering = inside
            if inside {
                // Reveal after a quarter second of sustained hover.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if hovering { withAnimation(.easeOut(duration: 0.1)) { showScore = true } }
                }
            } else {
                withAnimation(.easeOut(duration: 0.1)) { showScore = false }
            }
        }
    }

    /// Accent-coloured line with a `message://` link, so it opens on click yet
    /// still selects and copies as text.
    private var line: AttributedString {
        var line = AttributedString(formatSource(number, ref))
        line.foregroundColor = Theme.accent
        line.link = CitationRenderer.messageURL(messageID: ref.messageID)
        return line
    }
}

/// A thin capsule meter filled to `fraction` (0–1) of the strongest source, in
/// the system accent. A floor keeps a weak-but-present source visible.
private struct RelevanceBar: View {
    let fraction: Double
    var body: some View {
        Capsule()
            .fill(Theme.hairline)
            .frame(width: 54, height: 5)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 54 * min(1, max(0.06, fraction)), height: 5)
            }
            .accessibilityLabel("Relevance \(Int((fraction * 100).rounded())) percent")
    }
}

@MainActor
final class AskViewModel: ObservableObject {
    @Published var question = ""
    @Published var answer = ""
    @Published var sources: [(number: Int, ref: SourceRef)] = []
    @Published var warning: String?
    @Published var isStreaming = false

    private var queryService: QueryService?
    private var currentTask: Task<Void, Never>?

    func submit() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        answer = ""
        sources = []
        warning = nil
        isStreaming = true

        currentTask = Task {
            do {
                let service = try service()
                let result = try await service.ask(text, settings: SettingsStore.shared.querySettings())
                var raw = ""
                for try await event in result.events {
                    switch event {
                    case .token(let token):
                        raw += token
                        answer = raw  // stream verbatim; superscripts land on completion
                    case .fallback(let provider, _):
                        raw = ""
                        answer = ""
                        warning = "Cloud provider failed; answered by \(provider) instead."
                    case .done:
                        break
                    }
                }
                // Post-process the completed answer, not mid-stream
                // (docs/prompt-contract.md §6).
                let rendered = CitationRenderer.render(answer: raw, sourceMap: result.sourceMap)
                for dropped in rendered.droppedMarkers {
                    RollingLog.shared.log("citation marker [\(dropped)] had no source; dropped", level: .debug)
                }
                answer = rendered.text
                sources = rendered.sources
            } catch let error as ProviderError {
                RollingLog.shared.log("query failed: \(error)", level: .error)
                // The missing-model message is already a full, actionable
                // sentence — show it as-is rather than burying it after a prefix.
                if case .ollamaModelMissing = error {
                    warning = "\(error)"
                } else {
                    warning = "Query failed: \(error)"
                }
            } catch {
                RollingLog.shared.log("query failed: \(error)", level: .error)
                warning = "Query failed: \(error)"
            }
            isStreaming = false
        }
    }

    /// The answer plus a plain-text source list, for the clipboard. Mirrors the
    /// card: the answer (with its citation superscripts), a blank line, then
    /// "Sources" and one "N  domain (date): subject" line per source.
    func clipboardText() -> String {
        var out = String(answerMarkdown(answer).characters)  // strip ** etc.
        if !sources.isEmpty {
            let pct = relevancePercents(sources)
            out += "\n\n\(Defaults.sourcesListLabel)\n"
            out += sources.map { source in
                let line = formatSource(source.number, source.ref)
                // The exact relevance figure travels with the pasted text.
                return pct[source.number].map { "\(line)  \u{00B7} \($0)% relevant" } ?? line
            }.joined(separator: "\n")
        }
        return out
    }

    func endSession() {
        currentTask?.cancel()
        queryService?.clearSession()
        question = ""
        answer = ""
        sources = []
        warning = nil
        isStreaming = false
    }

    /// The service holds its embedder, so a cached instance goes stale when the
    /// embedding-model setting changes; rebuild on change (FR-9: settings apply
    /// on the next query). The session buffer resets with it, which is right —
    /// prior turns were retrieved under the old model.
    private var serviceEmbeddingModel = ""

    private func service() throws -> QueryService {
        let model = SettingsStore.shared.embeddingModel
        if let queryService, serviceEmbeddingModel == model { return queryService }
        let store = try SQLiteStore(path: SettingsStore.databasePath)
        let service = QueryService(store: store, embedder: OllamaEmbedder(model: model))
        queryService = service
        serviceEmbeddingModel = model
        return service
    }
}

struct AskView: View {
    @ObservedObject var model: AskViewModel
    var onDismiss: () -> Void = {}

    @State private var answerHeight: CGFloat = 0
    @State private var copied = false
    private let maxAnswerHeight: CGFloat = 320

    var body: some View {
        // The card hugs its content at the top of a clear window; everything
        // below stays transparent, so an empty question bar is just that — no
        // material dead space under the hairline.
        VStack(spacing: 0) {
            card
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(24)
        .onExitCommand { onDismiss() }   // Esc dismisses (and clears the session)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Ask your email\u{2026}", text: $model.question)
                    .textFieldStyle(.plain)
                    .font(.system(size: 21, weight: .light))  // ephemeral, light weight
                    .foregroundStyle(.primary)                // adapts light/dark
                    .onSubmit { model.submit() }
                    .overlay(alignment: .trailing) { copiedToast }

                AnimatedHairline(active: model.isStreaming)
            }

            if let warning = model.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)  // color-blind-safe warning hue
            }

            // Present only when there's something to show — otherwise the card
            // ends at the hairline. Grows with content up to a cap, then scrolls.
            // Text is selectable and the source lines carry link attributes, so
            // they stay clickable; each source also gets a relevance bar.
            if !model.answer.isEmpty || !model.sources.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !model.answer.isEmpty {
                            Text(styledAnswer)
                                .font(.system(size: 14))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !model.sources.isEmpty {
                            Divider()
                            Text(Defaults.sourcesListLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            let pct = relevancePercents(model.sources)
                            ForEach(model.sources, id: \.number) { source in
                                SourceRow(number: source.number, ref: source.ref,
                                          percent: pct[source.number])
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contextMenu { Button("Copy") { copyOutput() } }
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                    })
                }
                .frame(height: min(answerHeight, maxAnswerHeight))
                .onPreferenceChange(ContentHeightKey.self) { answerHeight = $0 }
                // Auto-copy the finished response; the toast confirms it.
                .onChange(of: model.isStreaming) { _, streaming in
                    if !streaming, !model.answer.isEmpty { copyOutput() }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.28), radius: 20, x: 0, y: 10)
    }

    /// The Markdown answer with its citation superscripts tinted to the system
    /// accent — the same colour as the source links.
    private var styledAnswer: AttributedString {
        var out = answerMarkdown(model.answer)
        for index in out.characters.indices where Self.superscriptDigits.contains(out.characters[index]) {
            out[index..<out.characters.index(after: index)].foregroundColor = Theme.accent
        }
        return out
    }

    /// Transient "Copied to clipboard" pill at the trailing end of the prompt,
    /// in the system accent, shown after an auto-copy or a manual copy, then it
    /// fades on its own. Non-interactive so it never blocks the field.
    @ViewBuilder
    private var copiedToast: some View {
        if copied {
            Text("Copied to clipboard")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
                .allowsHitTesting(false)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
    }

    private func copyOutput() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.clipboardText(), forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.easeIn(duration: 0.3)) { copied = false }
        }
    }

    private static let superscriptDigits: Set<Character> =
        ["\u{2070}", "\u{00b9}", "\u{00b2}", "\u{00b3}", "\u{2074}",
         "\u{2075}", "\u{2076}", "\u{2077}", "\u{2078}", "\u{2079}"]
}

/// Reports the intrinsic height of the answer/sources stack so the scroll area
/// can hug short answers and only scroll once they exceed the cap.
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

#Preview("Light \u{2014} empty (hugs the bar)") {
    AskView(model: AskViewModel())
        .frame(width: 640, height: 460)
        .background(Color.teal.opacity(0.35))  // stand-in for the desktop behind
        .preferredColorScheme(.light)
}

#Preview("Dark \u{2014} answered") {
    let model = AskViewModel()
    model.question = "when is the Henderson contract due?"
    model.answer = "The Henderson contract is due Fri, Jul 11 \u{2014} Legal flagged a 3-day review window."
    return AskView(model: model)
        .frame(width: 640, height: 460)
        .background(Color.indigo.opacity(0.45))
        .preferredColorScheme(.dark)
}
