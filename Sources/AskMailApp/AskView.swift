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

    var body: some View {
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

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !model.answer.isEmpty {
                        Text(model.answer)
                            .font(.system(size: 14))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Streaming progress is signaled by AnimatedHairline, not a spinner.

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
            }
            .frame(maxHeight: .infinity)
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 420)
        .background(.ultraThinMaterial)
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

#Preview("Light \u{2014} streaming") {
    let model = AskViewModel()
    model.question = "when is the Henderson contract due?"
    model.isStreaming = true  // hairline sweeps
    return AskView(model: model)
        .preferredColorScheme(.light)
}

#Preview("Dark \u{2014} answered") {
    let model = AskViewModel()
    model.question = "when is the Henderson contract due?"
    model.answer = "The Henderson contract is due Fri, Jul 11 \u{2014} Legal flagged a 3-day review window."
    return AskView(model: model)
        .preferredColorScheme(.dark)
}
