import AskMailCore
import SwiftUI

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
                    RollingLog.shared.log("citation marker [\(dropped)] had no source; dropped")
                }
                answer = rendered.text
                sources = rendered.sources
            } catch {
                RollingLog.shared.log("query failed: \(error)")
                warning = "Query failed: \(error)"
            }
            isStreaming = false
        }
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

    private func service() throws -> QueryService {
        if let queryService { return queryService }
        let store = try SQLiteStore(path: SettingsStore.databasePath)
        let service = QueryService(store: store, embedder: OllamaEmbedder())
        queryService = service
        return service
    }
}

struct AskView: View {
    @ObservedObject var model: AskViewModel
    var onDismiss: () -> Void = {}

    @State private var answerHeight: CGFloat = 0
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
            if !model.answer.isEmpty || !model.sources.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !model.answer.isEmpty {
                            Text(model.answer)
                                .font(.system(size: 14))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !model.sources.isEmpty {
                            Divider()
                            Text(Defaults.sourcesListLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(model.sources, id: \.number) { source in
                                sourceRow(source.number, source.ref)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                    })
                }
                .frame(height: min(answerHeight, maxAnswerHeight))
                .onPreferenceChange(ContentHeightKey.self) { answerHeight = $0 }
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

    @ViewBuilder
    private func sourceRow(_ number: Int, _ ref: SourceRef) -> some View {
        if let url = CitationRenderer.messageURL(messageID: ref.messageID) {
            Link(destination: url) {
                Text("\(number)  \(ref.subject) \u{2014} \(ref.sender), \(PromptAssembler.ymd(ref.dateUnix))")
                    .font(.callout)
                    .lineLimit(1)
            }
        }
    }
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
