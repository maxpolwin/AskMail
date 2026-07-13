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

    /// Auto-start entry point: refreshes status and, only when Ollama is
    /// installed but not answering (`.stopped`), calls `startOllama()` on the
    /// caller's behalf. A no-op when already reachable (`.ready`/
    /// `.runningModelMissing`) or when nothing is installed to start
    /// (`.notInstalled` still needs the user to visit the download page) --
    /// this exists purely to spare the user the manual Settings "Start"
    /// click on the common "Ollama.app isn't currently running" path, at app
    /// launch and before every Draft-Modus tick.
    func ensureRunning() async {
        await refresh()
        if status == .stopped {
            await startOllama()
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
            // H-20: `/usr/local/bin` is admin-writable without root on many
            // Macs, so a planted `ollama` binary there must never run just
            // because a file with the right name exists at a candidate path.
            // Refuse anything that isn't Apple-signed or Developer-ID-signed.
            if let refusal = Self.launchRefusalReason(for: cli) {
                message = refusal
                RollingLog.shared.log(
                    "refused to launch untrusted Ollama binary at \(cli.path) (H-20)",
                    level: .error)
                await refresh()
                return
            }
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

    /// Actionable refusal message for launching `cli`, or `nil` if it's safe
    /// to spawn (H-20). Split out from `startOllama()`'s control flow, and
    /// the trust check itself is injected, so a test can assert the refusal
    /// path — including the exact message text — without touching the real
    /// Security framework or spawning a process. `nonisolated` (unlike the
    /// rest of this `@MainActor` class): it touches no actor-isolated state,
    /// so a plain synchronous unit test can call it directly.
    nonisolated static func launchRefusalReason(
        for cli: URL,
        isTrusted: (URL) -> Bool = BinarySignature.isTrusted
    ) -> String? {
        guard !isTrusted(cli) else { return nil }
        return "The Ollama binary at \(cli.path) failed signature verification " +
            "and won\u{2019}t be started. Reinstall Ollama from ollama.com or via " +
            "Homebrew (`brew install ollama`), then try again."
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
