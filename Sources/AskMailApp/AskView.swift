import AppKit
import AskMailCore
import AVFoundation
import SwiftUI

/// The source body "domain (date): subject" (no number) — the shared bit the
/// on-screen row colours as primary text and the clipboard export reuses.
func sourceBody(_ ref: SourceRef) -> String {
    "\(MailHeader.domain(fromSender: ref.attributedSender)) "
        + "(\(PromptAssembler.ymd(ref.dateUnix))): \(MailHeader.decode(ref.subject))"
}

/// "N  domain (date): subject" for the clipboard export; the on-screen row
/// builds the same text but two-toned (see `SourceRow`).
func formatSource(_ number: Int, _ ref: SourceRef) -> String {
    "\(number)  \(sourceBody(ref))"
}

/// `ref.excerpt` collapsed to one line (chunk text can span paragraphs) and
/// quoted, so the clipboard's source list stays one line per source while
/// still carrying the exact text the model was shown.
func quotedExcerpt(_ ref: SourceRef) -> String? {
    let flattened = ref.excerpt
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    return flattened.isEmpty ? nil : "\"\(flattened)\""
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
/// bar. Hovering the label (domain/date/subject) shows the exact chunk text
/// the model was shown, via the system tooltip. Hovering the bar reveals the
/// relevance figure within 250 ms — faster than the system tooltip, which
/// `.help()` can't speed up — worded plainly as "Relevance score: NN%". The
/// two hover targets are independent so they never fight over the same spot.
private struct SourceRow: View {
    let number: Int
    let ref: SourceRef
    let percent: Int?
    /// Settings ▸ Accessibility ▸ "Speak answer aloud" also makes citation
    /// rows real Buttons — Tab-reachable and Return/Space-activatable —
    /// instead of a plain Text carrying a `.link` attribute that only a mouse
    /// can open.
    let accessibleLinks: Bool
    let highContrast: Bool
    @State private var hoveringBar = false
    @State private var showScore = false
    /// Routes through the same H-14 gate as every other link sink (set by
    /// AskView's `.environment(\.openURL, ...)`), even though a citation URL
    /// is always the trusted `message://` scheme today.
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 8) {
            rowLabel
                .help(ref.excerpt)
            Spacer(minLength: 8)
            if let percent {
                RelevanceBar(fraction: Double(percent) / 100, highContrast: highContrast)
                    .contentShape(Rectangle())  // hover target is the bar only
                    .overlay(alignment: .trailing) {
                        if showScore {
                            Text("Relevance score: \(percent)%")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.ultraThinMaterial, in: Capsule())
                                .overlay(Capsule().strokeBorder(Theme.hairline(highContrast: highContrast), lineWidth: 0.5))
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                    .onHover { inside in
                        hoveringBar = inside
                        if inside {
                            // Reveal after a quarter second of sustained hover.
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 250_000_000)
                                if hoveringBar { withAnimation(.easeOut(duration: 0.1)) { showScore = true } }
                            }
                        } else {
                            withAnimation(.easeOut(duration: 0.1)) { showScore = false }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var rowLabel: some View {
        if accessibleLinks {
            Button {
                if let url = CitationRenderer.messageURL(messageID: ref.messageID) {
                    openURL(url)
                }
            } label: {
                Text(styledLine)
                    .font(.callout)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Source \(number), \(sourceBody(ref))")
        } else {
            Text(line)
                .font(.callout)
                .lineLimit(1)
        }
    }

    /// The number in the system accent (matching the bar), the rest in primary
    /// text like the answer.
    private var styledLine: AttributedString {
        var num = AttributedString("\(number)")
        num.foregroundColor = Theme.accent
        var body = AttributedString("  " + sourceBody(ref))
        body.foregroundColor = .primary
        return num + body
    }

    /// `styledLine` plus a `message://` link so it opens on click yet still
    /// selects and copies as text — used only when `accessibleLinks` is off,
    /// since a plain Text's `.link` attribute only ever opens via a mouse.
    private var line: AttributedString {
        var line = styledLine
        line.link = CitationRenderer.messageURL(messageID: ref.messageID)
        return line
    }
}

/// A thin capsule meter filled to `fraction` (0–1) of the strongest source, in
/// the system accent. A floor keeps a weak-but-present source visible.
private struct RelevanceBar: View {
    let fraction: Double
    let highContrast: Bool
    var body: some View {
        Capsule()
            .fill(Theme.hairline(highContrast: highContrast))
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
final class AskViewModel: NSObject, ObservableObject {
    @Published var question = ""
    @Published var answer = ""
    @Published var sources: [(number: Int, ref: SourceRef)] = []
    @Published var warning: String?
    @Published var isStreaming = false
    /// True while `speak()`'s utterance is playing. Drives the Speak/Stop
    /// button (only shown when Settings ▸ Accessibility ▸ "Speak answer
    /// aloud" is on).
    @Published var isSpeaking = false

    private var queryService: QueryService?
    private var currentTask: Task<Void, Never>?
    /// Bumped on every submit (and on dismiss). A query task only writes state
    /// while its captured generation is still current, so a run superseded by a
    /// resubmission (or a dismiss) drops its late results silently.
    private var generation = 0
    private let speechSynthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        speechSynthesizer.delegate = self
    }

    /// Reads the answer aloud, entirely on-device (AVSpeechSynthesizer never
    /// touches the network, so this doesn't affect SECURITY.md's local-only
    /// guarantee). Only ever reachable when the user opted in via Settings ▸
    /// Accessibility ▸ "Speak answer aloud" — see AskView's speakButton.
    func speak() {
        guard !answer.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: String(answerMarkdown(answer).characters))
        // Borrow VoiceOver's own voice/rate instead of a second, differently
        // voiced synthesizer talking over it when VoiceOver is running.
        if NSWorkspace.shared.isVoiceOverEnabled {
            utterance.prefersAssistiveTechnologySettings = true
        }
        isSpeaking = true
        speechSynthesizer.speak(utterance)
    }

    func stopSpeaking() {
        speechSynthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    func submit() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if isSpeaking { stopSpeaking() }  // a resubmission shouldn't talk over the new answer
        // A resubmission supersedes any in-flight query: cancel it and rerun.
        currentTask?.cancel()
        generation += 1
        let gen = generation
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
                    guard gen == generation else { return }  // superseded by a newer run
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
                guard gen == generation else { return }
                // Post-process the completed answer, not mid-stream
                // (docs/prompt-contract.md §6).
                let rendered = CitationRenderer.render(answer: raw, sourceMap: result.sourceMap)
                for dropped in rendered.droppedMarkers {
                    RollingLog.shared.log("citation marker [\(dropped)] had no source; dropped", level: .debug)
                }
                answer = rendered.text
                sources = rendered.sources
            } catch let error as ProviderError {
                guard gen == generation else { return }  // don't surface a superseded run's error
                RollingLog.shared.log("query failed: \(error)", level: .error)
                // The missing-model message is already a full, actionable
                // sentence — show it as-is rather than burying it after a prefix.
                if case .ollamaModelMissing = error {
                    warning = "\(error)"
                } else {
                    warning = "Query failed: \(error)"
                }
            } catch {
                guard gen == generation else { return }
                RollingLog.shared.log("query failed: \(error)", level: .error)
                // A raw URLError (connection refused/timed out) means Ollama
                // isn't installed or isn't running — tell the user that
                // instead of dumping NSURLErrorDomain internals in the panel.
                if ProviderError.isConnectionFailure(error) {
                    warning = "Ollama isn\u{2019}t running. Open Settings to start or install it, then try again."
                } else {
                    warning = "Query failed: \(error)"
                }
            }
            guard gen == generation else { return }
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
                var line = formatSource(source.number, source.ref)
                // The exact relevance figure travels with the pasted text.
                if let percent = pct[source.number] {
                    line += "  \u{00B7} \(percent)% relevant"
                }
                // The exact chunk text the model was shown, so the citation
                // is checkable against its real source.
                if let quoted = quotedExcerpt(source.ref) {
                    line += "  \u{00B7} \(quoted)"
                }
                return line
            }.joined(separator: "\n")
        }
        return out
    }

    func endSession() {
        if isSpeaking { stopSpeaking() }
        currentTask?.cancel()
        generation += 1  // supersede the cancelled run so it writes nothing back
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

extension AskViewModel: AVSpeechSynthesizerDelegate {
    // AVSpeechSynthesizerDelegate callbacks aren't guaranteed to land on the
    // main actor, so hop explicitly before touching @Published state.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}

struct AskView: View {
    @ObservedObject var model: AskViewModel
    @ObservedObject private var settings = SettingsStore.shared
    var onDismiss: () -> Void = {}

    @State private var answerHeight: CGFloat = 0
    @State private var copied = false
    @State private var hoveringCard = false
    /// H-14: an `https(s)://` link found in model output (Markdown answer or,
    /// in principle, a citation) waiting on the user's explicit confirmation
    /// before AskMail opens anything outside the app. Non-nil drives the
    /// confirmation alert below.
    @State private var pendingExternalURL: URL?
    /// Height of everything in the card above the scroll area (question field,
    /// hairline, warning), measured live so `scrollCap` can subtract it.
    @State private var chromeHeight: CGFloat = 0
    private let minAnswerHeight: CGFloat = 120
    /// Scale with System Settings ▸ Accessibility ▸ Display ▸ Text Size
    /// instead of staying pinned at a fixed point size.
    @ScaledMetric(relativeTo: .title2) private var questionFontSize: CGFloat = 21
    @ScaledMetric(relativeTo: .body) private var answerFontSize: CGFloat = 14
    @Environment(\.legibilityWeight) private var legibilityWeight

    /// Settings ▸ Accessibility ▸ "Speak answer aloud" also opts this panel
    /// into keyboard/Switch Control/VoiceOver-reachable controls for the
    /// Close button and citation links, which are otherwise mouse-hover only
    /// (see closeButton and SourceRow).
    private var accessibleControlsEnabled: Bool { settings.speakAnswerEnabled }

    var body: some View {
        // The card hugs its content at the top of a clear window; everything
        // below stays transparent, so an empty question bar is just that — no
        // material dead space under the hairline. Measuring the available
        // height here (post-padding) is what lets a taller panel actually
        // reveal more of the answer instead of just growing invisible slack —
        // see `scrollCap`.
        GeometryReader { proxy in
            VStack(spacing: 0) {
                card(availableHeight: proxy.size.height)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(24)
        .onExitCommand { onDismiss() }   // Esc dismisses (and clears the session)
        // H-14: the single gate every link sink in this view routes through —
        // both the answer's rendered Markdown links (styledAnswer) and the
        // citation button's programmatic open (SourceRow, via @Environment)
        // — so a prompt-injected email can't turn model output into a
        // silently-followed arbitrary-scheme link. See LinkPolicy.
        .environment(\.openURL, OpenURLAction(handler: handleLinkOpen))
        .alert("Open Link?", isPresented: Binding(
            get: { pendingExternalURL != nil },
            set: { if !$0 { pendingExternalURL = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingExternalURL = nil }
            Button("Open") {
                if let url = pendingExternalURL { NSWorkspace.shared.open(url) }
                pendingExternalURL = nil
            }
        } message: {
            Text(pendingExternalURL?.absoluteString ?? "")
        }
    }

    /// The H-14 policy in effect: only a trusted `message://` link opens
    /// immediately; `http(s)://` waits on `pendingExternalURL`'s confirmation
    /// alert; everything else (`javascript:`, `file:`, a bare custom scheme,
    /// ...) is swallowed — the tap does nothing, and nothing is opened.
    private func handleLinkOpen(_ url: URL) -> OpenURLAction.Result {
        switch LinkPolicy.action(for: url) {
        case .open:
            NSWorkspace.shared.open(url)
        case .confirmThenOpen:
            pendingExternalURL = url
        case .block:
            // Log only the scheme, never the full URL: the destination came
            // from model output (indirectly, mail content) and shouldn't be
            // retained verbatim at a level shipped on by default.
            RollingLog.shared.log(
                "blocked answer link with scheme \u{201C}\(url.scheme ?? "(none)")\u{201D}", level: .info)
        }
        return .handled
    }

    /// The scroll area grows with the panel: taller window → more answer
    /// visible before it scrolls, not just more invisible space below the
    /// card. Floored so a very short/minimized panel still shows something.
    private func scrollCap(for availableHeight: CGFloat) -> CGFloat {
        max(minAnswerHeight, availableHeight - chromeHeight - 16 * 2 - 12)
    }

    private func card(availableHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Ask your email\u{2026}", text: $model.question)
                        .textFieldStyle(.plain)
                        // Ephemeral, light weight — except Bold Text asked for
                        // more legibility, which .light actively works against.
                        .font(.system(size: questionFontSize, weight: legibilityWeight == .bold ? .regular : .light))
                        .foregroundStyle(.primary)                // adapts light/dark
                        .onSubmit { model.submit() }
                        .overlay(alignment: .trailing) { copiedToast }

                    AnimatedHairline(active: model.isStreaming, highContrast: settings.highContrastEnabled)
                }

                if let warning = model.warning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)  // color-blind-safe warning hue
                }
            }
            .background(GeometryReader { geo in
                Color.clear.preference(key: ChromeHeightKey.self, value: geo.size.height)
            })
            .onPreferenceChange(ChromeHeightKey.self) { chromeHeight = $0 }

            // Present only when there's something to show — otherwise the card
            // ends at the hairline. Grows with content up to a cap, then scrolls.
            // Text is selectable and the source lines carry link attributes, so
            // they stay clickable; each source also gets a relevance bar.
            if !model.answer.isEmpty || !model.sources.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !model.answer.isEmpty {
                            Text(styledAnswer)
                                .font(.system(size: answerFontSize))
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
                                          percent: pct[source.number],
                                          accessibleLinks: accessibleControlsEnabled,
                                          highContrast: settings.highContrastEnabled)
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.trailing, 6)  // breathing room before the (floating) scroll indicator
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contextMenu { Button("Copy") { copyOutput() } }
                    .background(
                        ZStack {
                            OverlayScrollerStyle()
                            GeometryReader { geo in
                                Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                            }
                        }
                    )
                }
                .contentMargins(.trailing, 8, for: .scrollIndicators)
                .frame(height: min(answerHeight, scrollCap(for: availableHeight)))
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
                .strokeBorder(Theme.hairline(highContrast: settings.highContrastEnabled), lineWidth: 0.5)
        )
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 0) {
                speakButton
                closeButton
            }
        }
        .shadow(color: .black.opacity(0.28), radius: 20, x: 0, y: 10)
        .onHover { hoveringCard = $0 }
    }

    /// A quiet ✕ in the top-right corner, revealed on hover over the panel so
    /// it's obvious how to dismiss (Esc still works too). No chrome — the glyph
    /// only, in muted colour. Hidden and non-interactive until hovered — unless
    /// accessibleControlsEnabled, in which case it stays visible and
    /// hit-testable always, since hover never happens for a keyboard, Switch
    /// Control, or VoiceOver user.
    @ViewBuilder
    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
        .opacity(accessibleControlsEnabled || hoveringCard ? 1 : 0)
        .allowsHitTesting(accessibleControlsEnabled || hoveringCard)
        .animation(.easeOut(duration: 0.12), value: hoveringCard)
    }

    /// Reads the answer aloud on-device. Only rendered when Settings ▸
    /// Accessibility ▸ "Speak answer aloud" is on — otherwise this control
    /// doesn't exist at all, matching the setting's opt-in framing. Always
    /// visible/hit-testable (no hover-gating) once shown, same as closeButton
    /// under accessibleControlsEnabled.
    @ViewBuilder
    private var speakButton: some View {
        if settings.speakAnswerEnabled, !model.answer.isEmpty {
            Button {
                if model.isSpeaking { model.stopSpeaking() } else { model.speak() }
            } label: {
                Image(systemName: model.isSpeaking ? "stop.fill" : "speaker.wave.2")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isSpeaking ? "Stop speaking" : "Speak answer aloud")
        }
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
                .overlay(Capsule().strokeBorder(Theme.hairline(highContrast: settings.highContrastEnabled), lineWidth: 0.5))
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

/// Height of the card's question field + hairline + warning (everything above
/// the scroll area), so `AskView.scrollCap` can size the answer area to
/// whatever room the panel actually has left rather than a fixed constant.
private struct ChromeHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Forces the enclosing NSScrollView to macOS's slim, auto-hiding "overlay"
/// scroller style regardless of System Settings ▸ Appearance ▸ "Show scroll
/// bars" — legacy style reserves a fixed-width opaque track that always shows
/// and crowds the answer text; overlay floats a thin, translucent indicator
/// that only appears while scrolling, matching the panel's chrome-free look.
private struct OverlayScrollerStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        DispatchQueue.main.async {
            probe.enclosingScrollView?.scrollerStyle = .overlay
        }
        return probe
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
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
