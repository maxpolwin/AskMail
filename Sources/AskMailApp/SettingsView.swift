import AppKit
import AskMailCore
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var vectorizer = Vectorizer.shared
    @ObservedObject private var engine = OllamaEngine.shared
    @ObservedObject private var remote = RemoteModelDirectory.shared
    @State private var ollamaCloudKey = ""
    @State private var mistralKey = ""
    @State private var keysStatus = ""
    /// Keychain services with a stored key, for the "Saved" indicator. Reflects
    /// presence only — the secret is never read back into the fields.
    @State private var savedKeyServices: Set<String> = []
    @State private var showExportLogsWarning = false
    @State private var logsStatus = ""
    @State private var showRebuildConfirmation = false
    @State private var statusMessage = ""
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var accounts: [MailAccount] = []
    @State private var accessStatus: MailAccessStatus = .ok
    @State private var showSystemPromptEditor = false
    @State private var showEmbeddingSwapConfirmation = false
    /// The in-flight embedding-model change awaiting rebuild consent; `from`
    /// restores the picker on cancel.
    @State private var embeddingSwap: (from: String, to: String, messages: Int)?
    /// Suppresses the swap prompt while the picker is being programmatically
    /// reverted after a cancel.
    @State private var revertingEmbeddingModel = false

    /// Setup steps derived from the same detections the sections use; the
    /// card vanishes once everything is green.
    private var checklist: OnboardingChecklist {
        OnboardingChecklist.derive(
            fullDiskAccess: accessStatus != .permissionDenied,
            accountPicked: !settings.accountID.isEmpty,
            ollamaStatus: engine.status,
            hasVectorized: settings.lastVectorized != nil)
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
                    checklistRow(checklist.ollamaRunning, "Ollama running") {
                        switch engine.status {
                        case .notInstalled:
                            Button("Download Ollama\u{2026}") { engine.openDownloadPage() }
                        case .stopped:
                            Button("Start") { Task { await engine.startOllama() } }
                        default:
                            EmptyView()
                        }
                    }
                    checklistRow(checklist.embeddingModelInstalled, "Embedding model installed") {
                        if checklist.ollamaRunning {
                            Button("Download") {
                                Task { await engine.pull(model: settings.embeddingModel) }
                            }
                            .disabled(engine.pullingModel != nil)
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
                Button("Reset to \u{2303}\u{2325}Space") {
                    settings.hotkeyKeyCode = kVK_Space
                    settings.hotkeyModifiers = controlKey | optionKey
                    settings.hotkeyKeyLabel = "Space"
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
                            AnimatedHairline(active: true)
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
                            AnimatedHairline(active: true)
                        }
                    }
                }
                if !engine.message.isEmpty {
                    Text(engine.message).font(.caption).foregroundStyle(.secondary)
                }
                Text("AskMail runs models locally with Ollama. Your email never leaves this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Picker("Provider", selection: $settings.provider) {
                    Text("Ollama (local)").tag(ProviderChoice.ollamaLocal)
                    Text("Ollama Cloud").tag(ProviderChoice.ollamaCloud)
                    Text("Mistral API").tag(ProviderChoice.mistral)
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
                }

                modelPicker(title: "Embedding model", kind: .embedding,
                            selection: $settings.embeddingModel)
                Text("Used to index and search your email. Switching asks to re-index \u{2014} vectors from different models can\u{2019}t be mixed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Stepper("Context tokens: \(settings.contextTokenLimit)",
                        value: $settings.contextTokenLimit, in: 512...16384, step: 512)
                Stepper("Answer tokens: \(settings.answerTokenLimit)",
                        value: $settings.answerTokenLimit, in: 100...4000, step: 100)

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
                        .font(.system(size: 12, design: .monospaced))
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
            Task { await engine.refresh() }
            Task { await remote.refresh(for: settings.provider) }
        }
        .onChange(of: settings.provider) { _, provider in
            Task { await remote.refresh(for: provider) }
        }
        .onChange(of: settings.embeddingModel) { old, new in
            handleEmbeddingModelChange(from: old, to: new)
        }
        .confirmationDialog(
            "Switching the embedding model re-indexes your mail",
            isPresented: $showEmbeddingSwapConfirmation) {
            Button("Delete index & re-embed \(embeddingSwap?.messages ?? 0) messages",
                   role: .destructive) { confirmEmbeddingSwap() }
            Button("Cancel", role: .cancel) { cancelEmbeddingSwap() }
        } message: {
            Text("Vectors from different models can\u{2019}t be mixed. Switching to \u{2018}\(embeddingSwap?.to ?? "")\u{2019} deletes the current index and re-embeds everything, which can take a while. Cancel keeps \u{2018}\(embeddingSwap?.from ?? "")\u{2019}.")
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
            Task { await remote.refresh(for: settings.provider) }
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

    /// Gate on an embedding-model change (Phase 3): with indexed content, ask
    /// before the required rebuild; on an empty index the change is free.
    /// Flipping back to the model that built the index needs no prompt.
    private func handleEmbeddingModelChange(from old: String, to new: String) {
        if revertingEmbeddingModel {
            revertingEmbeddingModel = false
            return
        }
        guard let store = try? SQLiteStore(path: SettingsStore.databasePath),
              let messages = try? store.messageCount(), messages > 0 else { return }
        if let stamp = try? store.embeddingStamp(),
           OllamaStatus.modelName(stamp.model, matches: new) {
            return  // returning to the indexed model; nothing to rebuild
        }
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
        revertingEmbeddingModel = true
        settings.embeddingModel = swap.from
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
