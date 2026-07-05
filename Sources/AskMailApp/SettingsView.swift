import AppKit
import AskMailCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var ollamaCloudKey = ""
    @State private var mistralKey = ""
    @State private var keysStatus = ""
    @State private var showCopyLogsWarning = false
    @State private var showRebuildConfirmation = false
    @State private var vectorizeProgress: IngestProgress?
    @State private var statusMessage = ""

    var body: some View {
        Form {
            Section("Mailbox") {
                HStack {
                    TextField("Account mail directory", text: $settings.accountDirectory)
                        .truncationMode(.middle)
                    Button("Choose\u{2026}") { chooseAccountDirectory() }
                }
                Text("Select the account folder under ~/Library/Mail/V10. Changing it scopes future ingestion to that account only.")
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

    private func chooseAccountDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: NSString(string: "~/Library/Mail/V10").expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url {
            settings.accountDirectory = url.path
        }
    }

    /// Manual trigger: runs regardless of power state (FR-6).
    private func vectorizeNow() {
        let directory = settings.accountDirectory
        guard !directory.isEmpty else {
            statusMessage = "Select an account mail directory first."
            return
        }
        vectorizeProgress = IngestProgress(processed: 0, total: 0)
        statusMessage = ""
        Task {
            do {
                let store = try SQLiteStore(path: SettingsStore.databasePath)
                let ingestor = MailboxIngestor(store: store,
                                               embedder: OllamaEmbedder(),
                                               account: directory)
                let files = EmlxLocator.index(accountDirectory: URL(fileURLWithPath: directory))
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
