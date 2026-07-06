import AppKit
import AskMailCore
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var vectorizer = Vectorizer.shared
    @State private var ollamaCloudKey = ""
    @State private var mistralKey = ""
    @State private var keysStatus = ""
    @State private var showExportLogsWarning = false
    @State private var logsStatus = ""
    @State private var showRebuildConfirmation = false
    @State private var statusMessage = ""
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var accounts: [MailAccount] = []
    @State private var accessStatus: MailAccessStatus = .ok

    var body: some View {
        Form {
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
            launchAtLogin = LoginItem.isEnabled   // reflect external changes
            vectorizer.refreshFailedCount()
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
        } else {
            let ok = saved.isEmpty ? "" : "Saved: \(saved.joined(separator: ", ")). "
            // Show the real OSStatus reason; a stale item from an earlier build's
            // code signature typically reports "item already exists" and is fixed
            // by deleting it in Keychain Access.
            let reason = lastReason.map { " \($0)" } ?? ""
            keysStatus = "\(ok)Failed: \(failed.joined(separator: ", ")).\(reason)"
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
