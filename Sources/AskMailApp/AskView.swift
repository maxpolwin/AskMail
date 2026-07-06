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
            out += "\n\n\(Defaults.sourcesListLabel)\n"
            out += sources.map { formatSource($0.number, $0.ref) }.joined(separator: "\n")
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

                AnimatedHairline(active: model.isStreaming)
            }

            if let warning = model.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)  // color-blind-safe warning hue
            }

            // Present only when there's something to show — otherwise the card
            // ends at the hairline. Grows with content up to a cap, then scrolls.
            // Answer and sources are one selectable Text so a drag-selection can
            // span both and ⌘C grabs everything; the source lines carry link
            // attributes, so they stay clickable.
            if !model.answer.isEmpty || !model.sources.isEmpty {
                ScrollView {
                    Text(combinedOutput)
                        .font(.system(size: 14))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contextMenu { Button("Copy") { copyOutput() } }
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                        })
                }
                .frame(height: min(answerHeight, maxAnswerHeight))
                .onPreferenceChange(ContentHeightKey.self) { answerHeight = $0 }
                .overlay(alignment: .topTrailing) { copiedToast }
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

    /// Answer + sources as one selectable, partly-linked string. The answer's
    /// citation superscripts are tinted to the system accent; the "Sources"
    /// heading is a quiet caption; each source line is accent-coloured and
    /// carries a `message://` link, so it opens on click yet still selects and
    /// copies as text.
    private var combinedOutput: AttributedString {
        var out = answerMarkdown(model.answer)
        for index in out.characters.indices where Self.superscriptDigits.contains(out.characters[index]) {
            out[index..<out.characters.index(after: index)].foregroundColor = Theme.accent
        }
        guard !model.sources.isEmpty else { return out }

        out += AttributedString("\n\n")
        var heading = AttributedString(Defaults.sourcesListLabel + "\n")
        heading.font = .caption.weight(.semibold)
        heading.foregroundColor = .secondary
        out += heading

        for (offset, source) in model.sources.enumerated() {
            var line = AttributedString(formatSource(source.number, source.ref))
            line.font = .callout
            line.foregroundColor = Theme.accent
            line.link = CitationRenderer.messageURL(messageID: source.ref.messageID)
            out += line
            if offset < model.sources.count - 1 { out += AttributedString("\n") }
        }
        return out
    }

    /// Transient "Copied" pill in the top-right of the output, shown after an
    /// auto-copy or a manual copy, then it fades on its own.
    @ViewBuilder
    private var copiedToast: some View {
        if copied {
            Text("Copied")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
                .padding(6)
                .transition(.opacity.combined(with: .move(edge: .top)))
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
