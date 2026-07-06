import AppKit
import AskMailCore
import Foundation

/// Single owner of Ollama runtime health for the app: publishes the status the
/// Settings engine section renders, and performs the one-click fixes (start
/// the daemon, pull a model). All derivation logic lives in AskMailCore
/// (`OllamaStatus` / `OllamaStatusReporter`); this class is the thin glue.
@MainActor
final class OllamaEngine: ObservableObject {
    static let shared = OllamaEngine()

    /// nil while the first check is in flight, so the UI shows "checking"
    /// instead of flashing a wrong state.
    @Published private(set) var status: OllamaStatus?
    /// What /api/tags reports; feeds the model pickers.
    @Published private(set) var installedModels: [InstalledModel] = []
    /// Non-nil while a pull streams; drives the progress bar.
    @Published private(set) var pullProgress: PullProgress?
    @Published private(set) var pullingModel: String?
    /// Outcome of the last action (start/pull), honest about failures.
    @Published private(set) var message: String = ""

    private let control: any OllamaControlling
    private var isStarting = false

    init(control: any OllamaControlling = OllamaControl()) {
        self.control = control
    }

    /// Re-derives the status from the daemon + disk. Cheap; call on Settings
    /// appear and after every action.
    func refresh() async {
        let snapshot = await OllamaStatusReporter.snapshot(
            control: control,
            binaryPresent: OllamaInstallLocator.binaryPresent(),
            requiredEmbeddingModel: SettingsStore.shared.embeddingModel)
        status = snapshot.status
        installedModels = snapshot.installedModels
    }

    /// Opens the official download page — installing is the one step that has
    /// to happen outside the app (bundling the runtime is out of scope).
    func openDownloadPage() {
        if let url = URL(string: "https://ollama.com/download") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Launches Ollama.app when present (it manages its own daemon), else
    /// spawns the located CLI with `serve`, then polls until the daemon
    /// answers. Reports honestly if nothing came up.
    func startOllama() async {
        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        message = ""

        if let app = OllamaInstallLocator.appURL() {
            NSWorkspace.shared.openApplication(at: app,
                                               configuration: NSWorkspace.OpenConfiguration(),
                                               completionHandler: nil)
        } else if let cli = OllamaInstallLocator.cliURL() {
            let process = Process()
            process.executableURL = cli
            process.arguments = ["serve"]
            // Keep the daemon's chatter out of our stdout. The daemon outlives
            // us if AskMail quits, which matches what the user asked for by
            // starting it.
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                message = "Couldn\u{2019}t start ollama serve: \(error.localizedDescription)"
                return
            }
        } else {
            message = "No Ollama install found to start."
            await refresh()
            return
        }

        // The daemon needs a moment to bind its port; poll briefly instead of
        // claiming success on launch alone.
        for _ in 0..<20 {
            if await control.reachable() { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        await refresh()
        if await !control.reachable() {
            message = "Ollama didn\u{2019}t come up. Try starting Ollama.app manually."
        }
    }

    /// Streams an `/api/pull` for a user-initiated download, publishing
    /// progress. Never called without an explicit click (multi-hundred-MB+
    /// downloads are always user-initiated).
    func pull(model: String) async {
        guard pullingModel == nil else { return }
        pullingModel = model
        pullProgress = PullProgress(status: "starting\u{2026}")
        message = ""
        defer {
            pullingModel = nil
            pullProgress = nil
        }

        do {
            var succeeded = false
            for try await progress in control.pull(model) {
                pullProgress = progress
                if progress.isSuccess { succeeded = true }
            }
            if succeeded {
                message = "Downloaded \(model)."
                RollingLog.shared.log("pulled Ollama model \(model)", level: .info)
            } else {
                // Stream ended without the success line — don't claim it landed.
                message = "Download of \(model) ended without confirmation. Check and retry."
                RollingLog.shared.log("pull of \(model) ended without success line", level: .error)
            }
        } catch {
            message = "Download of \(model) failed: \(error)"
            RollingLog.shared.log("pull of \(model) FAILED: \(error)", level: .error)
        }
        await refresh()
    }
}
