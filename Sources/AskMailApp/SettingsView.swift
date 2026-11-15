import AppKit
import AskMailCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var vectorizer = Vectorizer.shared
    @ObservedObject private var engine = OllamaEngine.shared
    @ObservedObject private var remote = RemoteModelDirectory.shared
    @ObservedObject private var draftEngine = DraftEngine.shared
    @State private var ollamaCloudKey = ""
    @State private var mistralKey = ""
    @State private var keysStatus = ""
    /// Keychain services with a stored key, for the "Saved" indicator. Reflects
    /// presence only — the secret is never read back into the fields.
    @State private var savedKeyServices: Set<String> = []
    @State private var showExportLogsWarning = false
    @State private var logsStatus = ""
    @State private var showRebuildConfirmation = false
    /// Sampled average chunk length of the index, for the budget panel's
    /// tokens-per-excerpt figure; nil until measured or when the index is empty.
    @State private var averageChunkChars: Int?
    /// Architecture and size of the selected local chat model, for the budget
    /// panel's memory gauge and recommendation; nil until Ollama answers.
    @State private var modelInfo: OllamaModelInfo?
    @State private var statusMessage = ""
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var accounts: [MailAccount] = []
    @State private var accessStatus: MailAccessStatus = .ok
    @State private var showSystemPromptEditor = false
    @State private var showEmbeddingSwapConfirmation = false
    /// New sender/domain entry field for the Draft-Modus exclusion list
    /// editor (Phase 6, docs/draft-modus-plan.md).
    @State private var newExcludedSender = ""
    @State private var showResetStyleConfirmation = false
    /// The in-flight embedding-model change awaiting rebuild consent; `from`
    /// restores the picker on cancel.
    @State private var embeddingSwap: (from: EmbeddingConfig, to: EmbeddingConfig, messages: Int)?
    /// Suppresses the swap prompt while the picker is being programmatically
    /// reverted after a cancel.
    @State private var revertingEmbeddingConfig = false
    /// Scales with System Settings ▸ Accessibility ▸ Display ▸ Text Size
    /// instead of staying pinned at 12pt.
    @ScaledMetric(relativeTo: .caption) private var systemPromptFontSize: CGFloat = 12

    /// Setup steps derived from the same detections the sections use; the
    /// card vanishes once everything is green.
    private var checklist: OnboardingChecklist {
        OnboardingChecklist.derive(
            fullDiskAccess: accessStatus != .permissionDenied,
            accountPicked: !settings.accountID.isEmpty,
            embeddingBackend: embeddingReadiness,
            hasVectorized: settings.lastVectorized != nil)
    }

    /// Readiness of whichever runtime serves embeddings (not the chat provider).
    private var embeddingReadiness: EmbeddingBackendReadiness {
        switch settings.embeddingBackend {
        case .ollama:
            return engine.status.map(EmbeddingBackendReadiness.ollama) ?? .checking
        case .localServer:
            guard let reachable = remote.embeddingServerReachable else { return .checking }
            return .server(reachable: reachable,
                           modelAvailable: remote.embeddingServerModels.contains(settings.embeddingModel))
        }
    }

    var body: some View {
        Form {
            if !checklist.allDone {
                Section("Getting started") {
                    checklistRow(checklist.fullDiskAccess, "Grant Full Disk Access") {
                        Button("Open settings\u{2026}") { openFullDiskAccessSettings() }
                    }
                    checklistRow(checklist.accountPicked, "Pick a Mail account") {
                        Text("Choose under Mailbox")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    checklistRow(checklist.backendRunning,
                                 settings.embeddingBackend == .ollama
                                     ? "Ollama running" : "Embedding server running") {
                        switch settings.embeddingBackend {
                        case .ollama:
                            switch engine.status {
                            case .notInstalled:
                                Button("Download Ollama\u{2026}") { engine.openDownloadPage() }
                            case .stopped:
                                Button("Start") { Task { await engine.startOllama() } }
                            default:
                                EmptyView()
                            }
                        case .localServer:
                            Button("Check again") { refreshEmbeddingServer() }
                                .disabled(embeddingServerURLProblem != nil)
                        }
                    }
                    checklistRow(checklist.embeddingModelInstalled, "Embedding model installed") {
                        if checklist.backendRunning {
                            if settings.embeddingBackend == .ollama {
                                Button("Download") {
                                    Task { await engine.pull(model: settings.embeddingModel) }
                                }
                                .disabled(engine.pullingModel != nil)
                            } else {
                                Text("Load it in your server")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    checklistRow(checklist.firstVectorizationDone, "First vectorization") {
                        if checklist.embeddingModelInstalled && checklist.accountPicked {
                            Button("Vectorize now") { Task { await vectorizer.run(.manual) } }
                                .disabled(vectorizer.progress != nil)
                        }
                    }
                }
            }

            Section("Mailbox") {
                if accounts.isEmpty {
                    Text(mailboxEmptyMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Account", selection: $settings.accountID) {
                        Text("Select an account\u{2026}").tag("")
                        ForEach(accounts) { account in
                            Text(account.label).tag(account.id)
                        }
                    }
                    .onChange(of: settings.accountID) { _, newID in
                        settings.accountEmail = accounts.first { $0.id == newID }?.email ?? ""
                    }
                }
                if accessStatus == .permissionDenied {
                    Button("Open Full Disk Access settings\u{2026}") { openFullDiskAccessSettings() }
                }
                Button("Reload accounts") { loadAccounts() }
                Text("Pick the Apple Mail account to index. Changing it scopes future ingestion to that account only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Shortcut") {
                LabeledContent("Open AskMail") {
                    ShortcutField(keyCode: $settings.hotkeyKeyCode,
                                  carbonModifiers: $settings.hotkeyModifiers,
                                  label: $settings.hotkeyKeyLabel)
                }
                Button("Reset to \(ShortcutSymbols.display(carbonModifiers: ShortcutSymbols.defaultModifiers, keyLabel: ShortcutSymbols.defaultKeyLabel))") {
                    settings.hotkeyKeyCode = ShortcutSymbols.defaultKeyCode
                    settings.hotkeyModifiers = ShortcutSymbols.defaultModifiers
                    settings.hotkeyKeyLabel = ShortcutSymbols.defaultKeyLabel
                }
                Text("Click the shortcut, then press a new combination. Include \u{2318}, \u{2325}, \u{2303}, or \u{21E7}.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Open AskMail at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                Text("Runs AskMail automatically when you log in, so the hotkey and hourly vectorization are always available. Requires the packaged app (not \u{201C}swift run\u{201D}).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Vectorization") {
                LabeledContent("Last vectorized") {
                    Text(settings.lastVectorized.map {
                        $0.formatted(date: .abbreviated, time: .shortened)
                    } ?? "never")
                }
                if let progress = vectorizer.progress {
                    VStack(alignment: .leading, spacing: 6) {
                        if progress.total == 0 {
                            // File count not known yet: indeterminate, same hairline
                            // language as the ask panel's "thinking" state.
                            Text("Preparing\u{2026}")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            AnimatedHairline(active: true, highContrast: settings.highContrastEnabled)
                        } else {
                            Text("Vectorizing \(progress.processed)/\(progress.total)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ProgressView(value: Double(progress.processed),
                                         total: Double(max(progress.total, 1)))
                        }
                    }
                }
                HStack {
                    Button("Vectorize now") { Task { await vectorizer.run(.manual) } }
                        .disabled(vectorizer.progress != nil)
                    if vectorizer.failedCount > 0 {
                        Button("Retry \(vectorizer.failedCount) failed\u{2026}") {
                            Task { await vectorizer.retryFailed() }
                        }
                        .disabled(vectorizer.progress != nil)
                    }
                    Button("Delete & rebuild\u{2026}", role: .destructive) {
                        showRebuildConfirmation = true
                    }
                }
                if !vectorizer.status.isEmpty {
                    Text(vectorizer.status).font(.caption).foregroundStyle(.secondary)
                }
                if !statusMessage.isEmpty {
                    Text(statusMessage).font(.caption).foregroundStyle(.secondary)
                }
                Text("New mail is vectorized automatically every hour while on power. Only new or changed messages are processed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Draft-Modus") {
                Toggle("Draft-Modus", isOn: $settings.draftModeEnabled)
                if settings.draftModeEnabled {
                    Toggle("Allow while on battery", isOn: $settings.draftAllowOnBattery)
                    Text(draftStatusLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    DisclosureGroup("Never draft for (\(settings.draftExcludedSenders.count))") {
                        senderExclusionEditor
                    }
                }
                Text("Quietly drafts replies to ordinary inbox mail in the background, using only the local model \u{2014} never a cloud provider, regardless of the Q&A provider chosen above. A draft is never sent, inserted, or written into Apple Mail automatically: open \u{201C}Drafts\u{201D} from the menu bar to review, copy, or discard one yourself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settings.draftModeEnabled {
                Section("Draft-Modus: learned style") {
                    if draftEngine.styleProfiles.isEmpty {
                        Text("AskMail hasn\u{2019}t learned a writing style yet. It compares each auto-drafted reply against what you actually send and gradually adapts \u{2014} check back after a few real replies.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(draftEngine.styleProfiles, id: \.scope) { profile in
                            HStack(alignment: .firstTextBaseline) {
                                Text(Self.styleScopeLabel(profile.scope))
                                    .font(.caption)
                                Spacer()
                                Text("learned from \(profile.sampleCount) repl\(profile.sampleCount == 1 ? "y" : "ies") \u{00B7} "
                                     + Date(timeIntervalSince1970: TimeInterval(profile.updatedAt))
                                        .formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Reset learned style\u{2026}", role: .destructive) {
                        showResetStyleConfirmation = true
                    }
                    .disabled(draftEngine.styleProfiles.isEmpty)
                    Text("Drafts are grounded in your real writing style once AskMail has learned from a few of your replies \u{2014} the most specific correspondent match wins. Resetting clears everything learned so far; new drafts fall back to a neutral tone until new replies teach it again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Models") {
                // Engine status first — models are downloaded and run through
                // it — then the provider and model pickers that depend on it.
                engineStatusRow
                if let progress = engine.pullProgress, let model = engine.pullingModel {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Downloading \(model) \u{2014} \(progress.status)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let fraction = progress.fraction {
                            ProgressView(value: fraction)
                        } else {
                            AnimatedHairline(active: true, highContrast: settings.highContrastEnabled)
                        }
                    }
                }
                if !engine.message.isEmpty {
                    Text(engine.message).font(.caption).foregroundStyle(.secondary)
                }
                // Only true on the local provider — an API provider receives the
                // query and matching email excerpts, so say so plainly.
                if settings.provider == .ollamaLocal {
                    Label("AskMail runs models locally with Ollama. Your email never leaves this Mac.",
                          systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if settings.provider == .localServer {
                    Label("Answers come from a model server running on this Mac (loopback only). Your email never leaves this Mac.",
                          systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Indexing and search stay on this Mac, but \(providerName) writes the answer \u{2014} so your question and the matching email excerpts are sent to it. Choose Ollama (local) to keep everything on-device.",
                          systemImage: "arrow.up.forward")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Divider()

                Picker("Provider", selection: $settings.provider) {
                    Text("Ollama (local)").tag(ProviderChoice.ollamaLocal)
                    Text("Ollama Cloud").tag(ProviderChoice.ollamaCloud)
                    Text("Mistral API").tag(ProviderChoice.mistral)
                    Text("Local server (LM Studio, llama.cpp, MLX\u{2026})").tag(ProviderChoice.localServer)
                }

                switch settings.provider {
                case .ollamaLocal:
                    modelPicker(title: "Chat model", kind: .chat,
                                selection: $settings.localChatModel)
                    Text("Runs on this Mac via Ollama.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .ollamaCloud:
                    remotePicker(title: "Cloud model",
                                 models: remote.cloudModels,
                                 selection: $settings.cloudChatModel,
                                 note: remote.cloudNote)
                    modelPicker(title: "Fallback model", kind: .chat,
                                selection: $settings.localChatModel)
                    Text("The local model answers when the cloud provider fails.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .mistral:
                    remotePicker(title: "Mistral model",
                                 models: remote.mistralModels.map {
                                     InstalledModel(name: $0, sizeBytes: 0)
                                 },
                                 selection: $settings.mistralModel,
                                 note: remote.mistralNote)
                    modelPicker(title: "Fallback model", kind: .chat,
                                selection: $settings.localChatModel)
                    Text("The local model answers when the cloud provider fails.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .localServer:
                    localServerControls
                }

                Picker("Embedding backend", selection: $settings.embeddingBackend) {
                    Text("Ollama").tag(EmbeddingBackend.ollama)
                    Text("Local server (LM Studio, llama.cpp\u{2026})").tag(EmbeddingBackend.localServer)
                }
                switch settings.embeddingBackend {
                case .ollama:
                    modelPicker(title: "Embedding model", kind: .embedding,
                                selection: $settings.embeddingModel)
                case .localServer:
                    embeddingServerControls
                }
                Text("Used to index and search your email. Switching runtime or model keeps your index when the new one produces matching vectors (AskMail checks this); otherwise it asks to re-index.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                let advice = tokenAdvice
                ContextBudgetView(
                    excerpts: $settings.excerptsPerAnswer,
                    context: $settings.contextTokenLimit,
                    answer: $settings.answerTokenLimit,
                    tokensPerExcerpt: ContextBudget.tokensPerExcerpt(averageChunkChars: averageChunkChars),
                    isMeasured: averageChunkChars != nil,
                    memory: modelMemory,
                    serverWindowTokens: settings.provider == .localServer ? remote.contextLength : nil,
                    recommended: advice,
                    rationale: advice.rationale)

                // Folded away by default — the relevance bar is self-explanatory;
                // this is only for those who want to know what it measures.
                DisclosureGroup {
                    Text("Each answer's sources carry a relevance bar. AskMail ranks emails with Reciprocal Rank Fusion (RRF): it runs a semantic (vector) search and a keyword search, then blends the two rankings — each list contributes 1/(k + rank), so an email near the top of both ranks highest. Bars are scaled to the strongest match in that answer; hover a bar for the exact figure.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } label: {
                    Text("How sources are ranked").font(.caption)
                }
            }

            Section("API keys (stored in Keychain, never in files)") {
                keyField("Ollama Cloud key", text: $ollamaCloudKey,
                         service: Defaults.keychainServiceOllamaCloud)
                keyField("Mistral key", text: $mistralKey,
                         service: Defaults.keychainServiceMistral)
                Button("Save keys") { saveKeys() }
                if !keysStatus.isEmpty {
                    Text(keysStatus).font(.caption).foregroundStyle(.secondary)
                } else if !savedKeyServices.isEmpty {
                    Text("Leave a field blank to keep its saved key; type to replace it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("System prompt") {
                // Collapsed by default: the editor is an advanced, rarely-used
                // control and its 160 pt of monospaced text otherwise dominates
                // the settings window.
                DisclosureGroup(isExpanded: $showSystemPromptEditor) {
                    TextEditor(text: $settings.systemPrompt)
                        .font(.system(size: systemPromptFontSize, design: .monospaced))
                        .frame(minHeight: 160)
                    Button("Reset to default") {
                        settings.systemPrompt = Defaults.defaultSystemPrompt
                    }
                } label: {
                    LabeledContent("Edit system prompt") {
                        if settings.systemPrompt != Defaults.defaultSystemPrompt {
                            Text("customized")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Accessibility") {
                Toggle("Speak answer aloud", isOn: $settings.speakAnswerEnabled)
                Text("Adds a \u{201C}Speak\u{201D} button to the ask panel that reads the answer aloud on-device (no network) via AVSpeechSynthesizer. When VoiceOver is running, it borrows VoiceOver\u{2019}s own voice and rate instead of talking over it. Also keeps the panel\u{2019}s Close button and citation links reachable by keyboard, Switch Control, and Voice Control instead of mouse-hover only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Higher-contrast panel", isOn: $settings.highContrastEnabled)
                Text("Strengthens the hairline divider and streaming indicator in both light and dark mode, closer to what macOS\u{2019}s system Increase Contrast setting expects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // H-11's auditable half: the live panel indicator shows an egress
            // as it happens; this table answers "what left, when, to whom"
            // after the fact. Session-scoped and memory-only, mirroring the
            // rolling debug log's posture.
            Section("Cloud egress (this session)") {
                let events = EgressLog.shared.events().suffix(20).reversed()
                if events.isEmpty {
                    Text("Nothing has left this Mac. Egress only happens when a cloud provider is selected; each send is your question plus the retrieved email excerpts for that one query.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                        HStack(alignment: .firstTextBaseline) {
                            Text(event.date, format: .dateTime.month().day().hour().minute())
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text("\(event.host) \u{00B7} \(event.model)")
                                .font(.caption)
                            Spacer()
                            Text("\(event.promptChars) chars")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Each row is one request that carried your question and retrieved email excerpts to the named host (recorded when the request started, even if a local answer won the race).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Diagnostics") {
                Picker("Log level", selection: $settings.logLevel) {
                    ForEach(RollingLog.LogLevel.allCases, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                Text("Debug is the most verbose and includes retrieval scores and provider timing. Errors only keeps the log small.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Export logs (.md)\u{2026}") { showExportLogsWarning = true }
                if !logsStatus.isEmpty {
                    Text(logsStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)   // let the frosted surface show through
        .frame(width: 520, height: 640)
        .background(.ultraThinMaterial)      // same frosted family as the ask panel
        .tint(Theme.accent)                  // one shared system accent
        .onAppear {
            loadAccounts()
            refreshSavedKeys()
            launchAtLogin = LoginItem.isEnabled   // reflect external changes
            vectorizer.refreshFailedCount()
            draftEngine.refreshCounts()
            Task { await engine.refresh() }
            refreshRemoteModels()
            measureChunkSize()
            refreshModelInfo()
        }
        .onChange(of: settings.localChatModel) { _, _ in refreshModelInfo() }
        .onChange(of: settings.provider) { _, _ in
            refreshRemoteModels()
        }
        .onChange(of: settings.embeddingConfig) { old, new in
            handleEmbeddingConfigChange(from: old, to: new)
            if new.backend == .localServer { refreshEmbeddingServer() }
        }
        .confirmationDialog(
            "Switching the embedding model re-indexes your mail",
            isPresented: $showEmbeddingSwapConfirmation) {
            Button("Delete index & re-embed \(embeddingSwap?.messages ?? 0) messages",
                   role: .destructive) { confirmEmbeddingSwap() }
            Button("Cancel", role: .cancel) { cancelEmbeddingSwap() }
        } message: {
            Text("Vectors from different models can\u{2019}t be mixed. \u{2018}\(embeddingSwap?.to.label ?? "")\u{2019} produces vectors that don\u{2019}t match the current index, so switching deletes it and re-embeds everything, which can take a while. Cancel keeps \u{2018}\(embeddingSwap?.from.label ?? "")\u{2019}.")
        }
        .alert("Export debug logs?", isPresented: $showExportLogsWarning) {
            Button("Export\u{2026}", role: .destructive) { exportLogs() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Logs contain your questions, answers, and email excerpts from the last 12 hours. Only share the file with someone you trust.")
        }
        .confirmationDialog("Delete the vector database and rebuild from scratch?",
                            isPresented: $showRebuildConfirmation) {
            Button("Delete & rebuild", role: .destructive) { deleteAndRebuild() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Reset learned writing style?",
                            isPresented: $showResetStyleConfirmation) {
            Button("Reset", role: .destructive) { resetLearnedStyle() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes everything AskMail has learned about how you write. Future drafts use a neutral tone until new replies teach it again.")
        }
    }

    /// Status + one-click fix for the local Ollama runtime, mirroring the Full
    /// Disk Access pattern: each state renders guidance and the button that
    /// resolves it. Derivation lives in AskMailCore (`OllamaStatus`).
    @ViewBuilder
    private var engineStatusRow: some View {
        switch engine.status {
        case nil:
            Text("Checking Ollama\u{2026}")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .notInstalled:
            Text("Ollama isn\u{2019}t installed. It runs the local models AskMail uses for search and answers.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Download Ollama\u{2026}") { engine.openDownloadPage() }
                Button("Check again") { Task { await engine.refresh() } }
            }
        case .stopped:
            Text("Ollama is installed but not running.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Start Ollama") { Task { await engine.startOllama() } }
        case .runningModelMissing(let model):
            Text("Ollama is running, but the embedding model \u{2018}\(model)\u{2019} isn\u{2019}t installed. AskMail needs it to index your email.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Download \(model) (~\(Defaults.embeddingModelApproxMB) MB)") {
                Task { await engine.pull(model: model) }
            }
            .disabled(engine.pullingModel != nil)
        case .ready(let count):
            Label("Ollama ready \u{00B7} \(count) model\(count == 1 ? "" : "s") installed",
                  systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// One model picker: selectable rows are the merge of the curated catalog
    /// with what's actually installed (grouping logic in `ModelCatalog`,
    /// unit-tested); recommended-but-missing models get an in-place download
    /// row with size + guidance blurb instead of a dead picker entry.
    @ViewBuilder
    private func modelPicker(title: String, kind: ModelOption.Kind,
                             selection: Binding<String>) -> some View {
        let groups = ModelCatalog.pickerGroups(kind: kind,
                                               installed: engine.installedModels,
                                               selected: selection.wrappedValue)
        Picker(title, selection: selection) {
            ForEach(groups.selectable) { choice in
                Text(choice.label).tag(choice.id)
            }
        }
        // Not-yet-installed recommendations stay folded away so the defaults
        // read clean; they open on their own only when nothing is selectable
        // yet, since then the user has to download one to proceed.
        if !groups.downloadable.isEmpty {
            ModelDownloadDisclosure(
                options: groups.downloadable,
                isPulling: engine.pullingModel != nil,
                mustChoose: groups.selectable.isEmpty,
                onDownload: { model in Task { await engine.pull(model: model) } })
        }
    }

    /// The recommended-but-not-installed models, tucked behind a disclosure so
    /// the picker keeps to its default. Opens by default only when `mustChoose`
    /// — i.e. there's no installed model to select, so a download is required.
    private struct ModelDownloadDisclosure: View {
        let options: [ModelOption]
        let isPulling: Bool
        let onDownload: (String) -> Void
        @State private var expanded: Bool

        init(options: [ModelOption], isPulling: Bool, mustChoose: Bool,
             onDownload: @escaping (String) -> Void) {
            self.options = options
            self.isPulling = isPulling
            self.onDownload = onDownload
            _expanded = State(initialValue: mustChoose)
        }

        var body: some View {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(options, id: \.id) { option in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.id).font(.caption)
                            Text(option.blurb).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Download (\(option.sizeLabel))") { onDownload(option.id) }
                            .disabled(isPulling)
                    }
                }
            } label: {
                Text("Download other models (\(options.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A remote provider's picker: rows come straight from the provider's live
    /// model list (ollama.com tags / Mistral /v1/models); the current choice
    /// stays visible and flagged when it's absent from that list.
    @ViewBuilder
    private func remotePicker(title: String, models: [InstalledModel],
                              selection: Binding<String>, note: String) -> some View {
        let groups = ModelCatalog.pickerGroups(kind: .chat, catalog: [],
                                               installed: models,
                                               selected: selection.wrappedValue,
                                               unavailableSuffix: "not in the current list")
        Picker(title, selection: selection) {
            ForEach(groups.selectable) { choice in
                Text(choice.label).tag(choice.id)
            }
        }
        if !note.isEmpty {
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// A secure key field with a "Saved" badge when a key for `service` already
    /// exists in the Keychain — so the user knows not to re-enter it. The field
    /// stays empty (the secret is never read back); a saved key is only replaced
    /// when they type a new value.
    @ViewBuilder
    private func keyField(_ label: String, text: Binding<String>, service: String) -> some View {
        HStack {
            SecureField(label, text: text)
            if savedKeyServices.contains(service) {
                Label("Saved", systemImage: "checkmark.seal.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    /// Recommended budgets for the current provider and model. Recomputed on
    /// each render so it tracks provider/model changes.
    private var tokenAdvice: TokenAdvisor.Recommendation {
        let perExcerpt = ContextBudget.tokensPerExcerpt(averageChunkChars: averageChunkChars)
        switch settings.provider {
        case .localServer:
            return TokenAdvisor.recommendLocalServer(serverContextTokens: remote.contextLength,
                                                     tokensPerExcerpt: perExcerpt)
        case .ollamaLocal:
            return TokenAdvisor.recommendLocal(parameterBillions: modelInfo?.parameterBillions,
                                               memory: modelMemory, tokensPerExcerpt: perExcerpt)
        case .ollamaCloud, .mistral:
            return TokenAdvisor.recommendCloud(tokensPerExcerpt: perExcerpt)
        }
    }

    /// The selected local chat model's memory cost, when Ollama reported its
    /// architecture; nil otherwise (cloud providers, unknown models), in which
    /// case the panel shows no memory figure at all.
    private var modelMemory: ModelMemory? {
        guard settings.provider == .ollamaLocal, let architecture = modelInfo?.architecture,
              let installed = engine.installedModels.first(where: { $0.name == settings.localChatModel }),
              installed.sizeBytes > 0 else { return nil }
        return ModelMemory(weightsBytes: installed.sizeBytes, architecture: architecture,
                           gpuLimitBytes: GPUMemory.limitBytes)
    }

    /// Reads the selected local model's architecture and size from Ollama.
    private func refreshModelInfo() {
        let model = settings.localChatModel
        Task {
            let info = try? await OllamaControl().showModel(model)
            if model == settings.localChatModel { modelInfo = info }
        }
    }

    /// Draft-Modus's background-activity line (DM-12 status surfacing):
    /// queued / drafted / skipped, plus failed only when non-zero so a
    /// healthy run doesn't show a permanent "Failed 0".
    private var draftStatusLine: String {
        var line = "Queued \(draftEngine.pendingCount) \u{00B7} Drafted \(draftEngine.readyCount) \u{00B7} Skipped \(draftEngine.skippedCount)"
        if draftEngine.failedCount > 0 {
            line += " \u{00B7} Failed \(draftEngine.failedCount)"
        }
        return line
    }

    /// Sender/domain exclusion-list editor (Phase 6, docs/draft-modus-plan.md):
    /// no existing list-editor pattern in this codebase to build on, so this
    /// is a minimal one -- a removable row per entry plus an add field.
    @ViewBuilder
    private var senderExclusionEditor: some View {
        ForEach(settings.draftExcludedSenders, id: \.self) { entry in
            HStack {
                Text(entry).font(.caption)
                Spacer()
                Button {
                    settings.draftExcludedSenders.removeAll { $0 == entry }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        HStack {
            TextField("email@domain.com or domain.com", text: $newExcludedSender)
                .font(.caption)
                .onSubmit { addExcludedSender() }
            Button("Add") { addExcludedSender() }
                .disabled(newExcludedSender.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        Text("Senders or domains listed here are never drafted for, even if they\u{2019}d otherwise look like personal mail.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func addExcludedSender() {
        let trimmed = newExcludedSender.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, !settings.draftExcludedSenders.contains(trimmed) else {
            newExcludedSender = ""
            return
        }
        settings.draftExcludedSenders.append(trimmed)
        newExcludedSender = ""
    }

    /// Reads a human label out of a `style_profiles` scope key
    /// (`StyleScope`'s `"global"` / `"domain:<label>"` / `"address:<addr>"`).
    private static func styleScopeLabel(_ scope: String) -> String {
        if scope == StyleScope.global { return "Overall" }
        if scope.hasPrefix("domain:") { return "Domain: \(scope.dropFirst("domain:".count))" }
        if scope.hasPrefix("address:") { return String(scope.dropFirst("address:".count)) }
        return scope
    }

    private func resetLearnedStyle() {
        guard let store = try? DraftStore(path: SettingsStore.draftsDatabasePath) else { return }
        do {
            try store.deleteStyleProfiles()
            draftEngine.refreshCounts()
        } catch {
            RollingLog.shared.log("reset learned style failed: \(error)", level: .error)
        }
    }

    /// Human-readable name of the selected provider, for the privacy note.
    private var providerName: String {
        switch settings.provider {
        case .ollamaLocal: return "Ollama (local)"
        case .ollamaCloud: return "Ollama Cloud"
        case .mistral: return "Mistral"
        case .localServer: return "Local server"
        }
    }

    /// Refreshes the remote/local-server model list for the current provider.
    private func refreshRemoteModels() {
        let provider = settings.provider
        let url = settings.localServerURL
        Task {
            await remote.refresh(for: provider, localServerURL: url)
            // First use: adopt the server's first model so the picker is never blank.
            if provider == .localServer, settings.localServerModel.isEmpty,
               let first = remote.localServerModels.first {
                settings.localServerModel = first
            }
        }
    }

    /// Why the URL field's current text can't be used, or nil when it can.
    private var localServerURLProblem: String? {
        Self.urlProblem(settings.localServerURL)
    }

    private static func urlProblem(_ raw: String) -> String? {
        do {
            _ = try LocalServerEndpoint.validate(raw)
            return nil
        } catch let error as ProviderError {
            if case .egressBlocked = error {
                return "Only this Mac is allowed (localhost or 127.0.0.1). Remote servers are blocked so your email can\u{2019}t leave the device."
            }
            if case .invalidEndpoint(let reason) = error { return reason }
            return "\(error)"
        } catch {
            return "\(error)"
        }
    }

    @ViewBuilder
    private var localServerControls: some View {
        TextField("Server URL", text: $settings.localServerURL)
            .autocorrectionDisabled()
            .onSubmit { refreshRemoteModels() }
        if let problem = localServerURLProblem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        HStack {
            Button("Refresh models") { refreshRemoteModels() }
                .disabled(localServerURLProblem != nil)
            Button(remote.isDetecting ? "Looking\u{2026}" : "Detect servers") {
                Task { await remote.detectLocalServers() }
            }
            .disabled(remote.isDetecting)
        }
        ForEach(remote.detectedServers) { info in
            Button {
                settings.localServerURL = info.baseURL.absoluteString
                settings.localServerModel = info.models.first ?? ""
                refreshRemoteModels()
            } label: {
                Label("\(info.label) \u{00B7} \(info.baseURL.absoluteString) \u{00B7} \(info.models.count) model(s)",
                      systemImage: "server.rack")
            }
        }
        if remote.localServerModels.isEmpty {
            if !remote.localServerNote.isEmpty {
                Text(remote.localServerNote).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            remotePicker(title: "Model",
                         models: remote.localServerModels.map { InstalledModel(name: $0, sizeBytes: 0) },
                         selection: $settings.localServerModel,
                         note: remote.localServerNote)
        }
        let needed = TokenAdvisor.minimumServerContext(context: settings.contextTokenLimit,
                                                       answer: settings.answerTokenLimit)
        Text("Set the model\u{2019}s context length in your server to at least \(needed) tokens"
             + (remote.contextLength.map { " (it reports \($0))." } ?? "."))
            .font(.caption)
            .foregroundStyle(.secondary)
        Text("Indexing uses the embedding backend below. Draft-Modus replies still use Ollama.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// Why the embedding server URL can't be used, or nil when it can.
    private var embeddingServerURLProblem: String? {
        Self.urlProblem(settings.embeddingServerURL)
    }

    private func refreshEmbeddingServer() {
        let url = settings.embeddingServerURL
        Task { await remote.refreshEmbeddingServer(url: url) }
    }

    @ViewBuilder
    private var embeddingServerControls: some View {
        TextField("Embedding server URL", text: $settings.embeddingServerURL)
            .autocorrectionDisabled()
            .onSubmit { refreshEmbeddingServer() }
        if let problem = embeddingServerURLProblem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        Button("Refresh models") { refreshEmbeddingServer() }
            .disabled(embeddingServerURLProblem != nil)
        remotePicker(title: "Embedding model",
                     models: remote.embeddingServerModels.map { InstalledModel(name: $0, sizeBytes: 0) },
                     selection: $settings.embeddingModel,
                     note: remote.embeddingServerNote)
        Text("The server must serve an embedding model (llama-server: --embeddings). The list shows every model the server reports, including chat models.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func refreshSavedKeys() {
        var present: Set<String> = []
        for service in [Defaults.keychainServiceOllamaCloud, Defaults.keychainServiceMistral]
        where Keychain.hasAPIKey(service: service) {
            present.insert(service)
        }
        savedKeyServices = present
    }

    /// Writes only the non-empty fields, verifies each Keychain write, and
    /// reports the real outcome next to the button. Never claims success when
    /// nothing was entered or when SecItemAdd fails.
    private func saveKeys() {
        var saved: [String] = []
        var failed: [String] = []
        var lastReason: String?

        func store(_ value: String, service: String, label: String, clear: () -> Void) {
            guard !value.isEmpty else { return }
            do {
                try Keychain.setAPIKey(value, service: service)
                saved.append(label)
                clear()
            } catch {
                failed.append(label)
                lastReason = "\(error)"
                RollingLog.shared.log("keychain write FAILED for service \(service): \(error)", level: .error)
            }
        }

        store(ollamaCloudKey, service: Defaults.keychainServiceOllamaCloud,
              label: "Ollama Cloud") { ollamaCloudKey = "" }
        store(mistralKey, service: Defaults.keychainServiceMistral,
              label: "Mistral") { mistralKey = "" }

        if saved.isEmpty && failed.isEmpty {
            keysStatus = "Enter a key first \u{2014} nothing to save."
        } else if failed.isEmpty {
            keysStatus = "Saved to Keychain: \(saved.joined(separator: ", "))."
            refreshSavedKeys()   // light up the "Saved" badges immediately
            // A fresh key may unlock the remote model list for the current
            // provider's picker.
            refreshRemoteModels()
        } else {
            let ok = saved.isEmpty ? "" : "Saved: \(saved.joined(separator: ", ")). "
            // Show the real OSStatus reason; a stale item from an earlier build's
            // code signature typically reports "item already exists" and is fixed
            // by deleting it in Keychain Access.
            let reason = lastReason.map { " \($0)" } ?? ""
            keysStatus = "\(ok)Failed: \(failed.joined(separator: ", ")).\(reason)"
            refreshSavedKeys()   // reflect any that did save
        }
    }

    /// Discovers Apple Mail accounts for the picker. Keeps a previously chosen
    /// account visible even if its directory is gone (so the picker never shows
    /// a blank selection), and back-fills the email for a migrated selection.
    /// Records why discovery came up empty (`accessStatus`) so the empty state
    /// can guide the user instead of guessing.
    private func loadAccounts() {
        let discovery = MailAccountsReader.discover()
        accessStatus = discovery.status
        var found = discovery.accounts
        let selected = settings.accountID
        if !selected.isEmpty, !found.contains(where: { $0.id == selected }) {
            found.append(MailAccount(
                id: selected,
                email: settings.accountEmail,
                displayName: "",
                directory: Defaults.mailRoot.appendingPathComponent(selected, isDirectory: true)))
        }
        if settings.accountEmail.isEmpty,
           let match = found.first(where: { $0.id == selected }), !match.email.isEmpty {
            settings.accountEmail = match.email
        }
        accounts = found
    }

    /// Empty-state guidance tailored to why no accounts showed up: a Full Disk
    /// Access block is the common first-run cause and needs a different fix than
    /// Mail simply not being set up.
    private var mailboxEmptyMessage: String {
        switch accessStatus {
        case .permissionDenied:
            return "AskMail can\u{2019}t read your Mail folder. Grant it Full Disk Access in System Settings, then reload."
        case .notFound:
            return "No Apple Mail data found under ~/Library/Mail. Make sure Mail is set up and has downloaded messages, then reload."
        case .ok:
            return "No Apple Mail accounts found. Make sure Mail is set up, then reload."
        }
    }

    /// Opens System Settings ▸ Privacy & Security ▸ Full Disk Access so the user
    /// can add AskMail. macOS remembers where it left off; the user still has to
    /// toggle AskMail on and hit "Reload accounts".
    private func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFilesAccess") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Applies the launch-at-login toggle, reverting the switch if macOS rejects
    /// the change so the UI never claims a state that didn't take.
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
        } catch {
            RollingLog.shared.log("login item change failed: \(error)", level: .error)
            statusMessage = "Couldn't \(enabled ? "enable" : "disable") open-at-login: \(error.localizedDescription)"
            launchAtLogin = LoginItem.isEnabled
        }
    }

    /// Writes the retained log window straight to a `.md` file the user
    /// picks, so sharing a bug report no longer requires copy-pasting out of
    /// the clipboard into an editor (FR-11).
    private func exportLogs() {
        let panel = NSSavePanel()
        panel.title = "Export Debug Logs"
        panel.nameFieldStringValue = "AskMail-Debug-Log-\(Self.exportFilenameFormatter.string(from: Date())).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try RollingLog.shared.markdownDocument().write(to: url, atomically: true, encoding: .utf8)
            logsStatus = "Exported to \(url.lastPathComponent)."
        } catch {
            logsStatus = "Export failed: \(error)"
        }
    }

    private static let exportFilenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    /// One "Getting started" row: state icon + title, with the fix control
    /// shown only while the step is open. The icon shape (not just color)
    /// distinguishes done from open.
    private func checklistRow(_ done: Bool, _ title: String,
                              @ViewBuilder fix: () -> some View) -> some View {
        HStack {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
            Text(title)
            Spacer()
            if !done { fix() }
        }
    }

    /// Gate on an embedding backend/model change. An empty index changes for
    /// free. With indexed content, the new embedder is checked against the
    /// index's canary baseline: matching vectors (the same model behind
    /// another runtime) keep the index; a real mismatch asks before the
    /// required rebuild; a backend that can't answer changes nothing and
    /// leaves the index untouched (ingest refuses until it can be verified).
    /// URL-only edits are not checked here — the next ingest run verifies.
    private func handleEmbeddingConfigChange(from old: EmbeddingConfig, to new: EmbeddingConfig) {
        if revertingEmbeddingConfig {
            revertingEmbeddingConfig = false
            return
        }
        guard old.backend != new.backend || old.model != new.model else { return }
        guard let store = try? SQLiteStore(path: SettingsStore.databasePath),
              let messages = try? store.messageCount(), messages > 0 else { return }
        Task {
            switch await EmbeddingCanary.assess(store: store, embedder: EmbedderFactory.make(new)) {
            case .emptyIndex:
                break
            case .compatible:
                statusMessage = "\(new.label) produces vectors compatible with your index \u{2014} no re-index needed."
            case .noBaseline:
                // Index from before canaries existed: only the model name can
                // vouch for it, as before.
                if let stamp = try? store.embeddingStamp(),
                   OllamaStatus.modelName(stamp.model, matches: new.model) {
                    return
                }
                promptEmbeddingSwap(from: old, to: new, messages: messages)
            case .incompatible:
                promptEmbeddingSwap(from: old, to: new, messages: messages)
            case .unverifiable(let error):
                statusMessage = "Couldn\u{2019}t check whether \(new.label) matches your index (\(error)). "
                    + "Your index is untouched; indexing pauses until it can be checked."
            }
        }
    }

    private func promptEmbeddingSwap(from old: EmbeddingConfig, to new: EmbeddingConfig, messages: Int) {
        embeddingSwap = (from: old, to: new, messages: messages)
        showEmbeddingSwapConfirmation = true
    }

    private func confirmEmbeddingSwap() {
        embeddingSwap = nil
        deleteAndRebuild()
        Task { await vectorizer.run(.manual) }
    }

    private func cancelEmbeddingSwap() {
        guard let swap = embeddingSwap else { return }
        embeddingSwap = nil
        revertingEmbeddingConfig = true
        settings.embeddingConfig = swap.from
    }

    /// Samples the index off the main actor; any failure just leaves the
    /// budget panel on its estimate.
    private func measureChunkSize() {
        Task.detached(priority: .utility) {
            let measured = (try? SQLiteStore(path: SettingsStore.databasePath))
                .flatMap { try? $0.averageChunkChars() }
            await MainActor.run { averageChunkChars = measured }
        }
    }

    private func deleteAndRebuild() {
        do {
            let store = try SQLiteStore(path: SettingsStore.databasePath)
            try store.deleteAll()
            settings.lastVectorized = nil
            statusMessage = "Database wiped. Run \"Vectorize now\" to rebuild."
            RollingLog.shared.log("vector DB deleted by user; watermark reset", level: .info)
            vectorizer.refreshFailedCount()
        } catch {
            statusMessage = "Delete failed: \(error)"
        }
    }
}

#Preview("Settings \u{2014} light") {
    SettingsView().preferredColorScheme(.light)
}

#Preview("Settings \u{2014} dark") {
    SettingsView().preferredColorScheme(.dark)
}
