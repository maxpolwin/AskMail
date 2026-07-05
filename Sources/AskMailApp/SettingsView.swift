import AppKit
import AskMailCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var ollamaCloudKey = ""
    @State private var mistralKey = ""
    @State private var keysStatus = ""
    @State private var showCopyLogsWarning = false
    @State private var showRebuildConfirmation = false
    @State private var vectorizeProgress: IngestProgress?
    @State private var statusMessage = ""
    @State private var accounts: [MailAccount] = []

    var body: some View {
        Form {
            Section("Mailbox") {
                if accounts.isEmpty {
                    Text("No Apple Mail accounts found under ~/Library/Mail/V10. Make sure Mail is set up and AskMail has Full Disk Access, then reload.")
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
                Button("Reload accounts") { loadAccounts() }
                Text("Pick the Apple Mail account to index. Changing it scopes future ingestion to that account only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Vectorization") {
                LabeledContent("Last vectorized") {
                    Text(settings.lastVectorized.map {
                        $0.formatted(date: .abbreviated, time: .shortened)
                    } ?? "never")
                }
                if let progress = vectorizeProgress {
                    ProgressView(value: Double(progress.processed),
                                 total: Double(max(progress.total, 1))) {
                        Text("Vectorizing \(progress.processed)/\(progress.total)")
                    }
                }
                HStack {
                    Button("Vectorize now") { vectorizeNow() }
                        .disabled(vectorizeProgress != nil)
                    Button("Delete & rebuild\u{2026}", role: .destructive) {
                        showRebuildConfirmation = true
                    }
                }
                if !statusMessage.isEmpty {
                    Text(statusMessage).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Generation") {
                Picker("Provider", selection: $settings.provider) {
                    Text("Ollama (local)").tag(ProviderChoice.ollamaLocal)
                    Text("Ollama Cloud").tag(ProviderChoice.ollamaCloud)
                    Text("Mistral API").tag(ProviderChoice.mistral)
                }
                Stepper("Context tokens: \(settings.contextTokenLimit)",
                        value: $settings.contextTokenLimit, in: 512...16384, step: 512)
                Stepper("Answer tokens: \(settings.answerTokenLimit)",
                        value: $settings.answerTokenLimit, in: 100...4000, step: 100)
            }

            Section("API keys (stored in Keychain, never in files)") {
                SecureField("Ollama Cloud key", text: $ollamaCloudKey)
                SecureField("Mistral key", text: $mistralKey)
                Button("Save keys") { saveKeys() }
                if !keysStatus.isEmpty {
                    Text(keysStatus).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("System prompt") {
                TextEditor(text: $settings.systemPrompt)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 160)
                Button("Reset to default") {
                    settings.systemPrompt = Defaults.defaultSystemPrompt
                }
            }

            Section("Debug") {
                Button("Copy logs (last 12 h)") { showCopyLogsWarning = true }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
        .onAppear { loadAccounts() }
        .alert("Copy debug logs?", isPresented: $showCopyLogsWarning) {
            Button("Copy", role: .destructive) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(RollingLog.shared.recentText(), forType: .string)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Logs contain your questions, answers, and email excerpts from the last 12 hours. Only share them with someone you trust.")
        }
        .confirmationDialog("Delete the vector database and rebuild from scratch?",
                            isPresented: $showRebuildConfirmation) {
            Button("Delete & rebuild", role: .destructive) { deleteAndRebuild() }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Writes only the non-empty fields, verifies each Keychain write, and
    /// reports the real outcome next to the button. Never claims success when
    /// nothing was entered or when SecItemAdd fails.
    private func saveKeys() {
        var saved: [String] = []
        var failed: [String] = []

        func store(_ value: String, service: String, label: String, clear: () -> Void) {
            guard !value.isEmpty else { return }
            if Keychain.setAPIKey(value, service: service) {
                saved.append(label)
                clear()
            } else {
                failed.append(label)
                RollingLog.shared.log("keychain write FAILED for service \(service)")
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
        } else {
            let ok = saved.isEmpty ? "" : "Saved: \(saved.joined(separator: ", ")). "
            keysStatus = "\(ok)Failed: \(failed.joined(separator: ", ")). See Keychain Access / logs."
        }
    }

    /// Discovers Apple Mail accounts for the picker. Keeps a previously chosen
    /// account visible even if its directory is gone (so the picker never shows
    /// a blank selection), and back-fills the email for a migrated selection.
    private func loadAccounts() {
        var found = MailAccountsReader.list()
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

    /// Manual trigger: runs regardless of power state (FR-6).
    private func vectorizeNow() {
        guard let directory = settings.accountDirectoryURL else {
            statusMessage = "Select an account first."
            return
        }
        let storageKey = settings.accountStorageKey
        vectorizeProgress = IngestProgress(processed: 0, total: 0)
        statusMessage = ""
        Task {
            do {
                let store = try SQLiteStore(path: SettingsStore.databasePath)
                let ingestor = MailboxIngestor(store: store,
                                               embedder: OllamaEmbedder(),
                                               account: storageKey)
                let files = EmlxLocator.index(accountDirectory: directory)
                    .values.sorted { $0.path < $1.path }
                let summary = try await ingestor.ingest(files: files) { progress in
                    Task { @MainActor in vectorizeProgress = progress }
                }
                await MainActor.run {
                    settings.lastVectorized = Date()
                    statusMessage = "Done: \(summary.ingested) ingested, \(summary.failed) failed."
                    vectorizeProgress = nil
                }
            } catch {
                RollingLog.shared.log("manual vectorize failed: \(error)")
                await MainActor.run {
                    statusMessage = "Vectorization failed: \(error)"
                    vectorizeProgress = nil
                }
            }
        }
    }

    private func deleteAndRebuild() {
        do {
            let store = try SQLiteStore(path: SettingsStore.databasePath)
            try store.deleteAll()
            settings.lastVectorized = nil
            statusMessage = "Database wiped. Run \"Vectorize now\" to rebuild."
            RollingLog.shared.log("vector DB deleted by user; watermark reset")
        } catch {
            statusMessage = "Delete failed: \(error)"
        }
    }
}
