import Foundation

/// What the first-run card needs to know about the embedding backend, in a
/// form that doesn't care which runtime it is.
public enum EmbeddingBackendReadiness: Sendable, Equatable {
    /// The first health check hasn't landed yet; claims nothing.
    case checking
    case ollama(OllamaStatus)
    /// A local OpenAI-compatible server: did it answer, and does it list the
    /// chosen embedding model.
    case server(reachable: Bool, modelAvailable: Bool)
}

/// First-run setup state: the five steps between a fresh install and a
/// searchable mailbox, in fix-it order. Pure derivation from already-existing
/// detections (Full Disk Access probe, account selection, the embedding
/// backend's readiness, vectorization watermark) so the Settings card just
/// renders it; each row's fix button reuses the section that owns that concern.
public struct OnboardingChecklist: Sendable, Equatable {
    public let fullDiskAccess: Bool
    public let accountPicked: Bool
    /// The embedding backend (Ollama or a local server) is reachable.
    public let backendRunning: Bool
    public let embeddingModelInstalled: Bool
    public let firstVectorizationDone: Bool

    /// When everything is green the card disappears — setup is not news.
    public var allDone: Bool {
        fullDiskAccess && accountPicked && backendRunning
            && embeddingModelInstalled && firstVectorizationDone
    }

    public init(fullDiskAccess: Bool, accountPicked: Bool, backendRunning: Bool,
                embeddingModelInstalled: Bool, firstVectorizationDone: Bool) {
        self.fullDiskAccess = fullDiskAccess
        self.accountPicked = accountPicked
        self.backendRunning = backendRunning
        self.embeddingModelInstalled = embeddingModelInstalled
        self.firstVectorizationDone = firstVectorizationDone
    }

    public static func derive(fullDiskAccess: Bool,
                              accountPicked: Bool,
                              embeddingBackend: EmbeddingBackendReadiness,
                              hasVectorized: Bool) -> OnboardingChecklist {
        let running: Bool
        let modelInstalled: Bool
        switch embeddingBackend {
        case .checking:
            running = false
            modelInstalled = false
        case .ollama(let status):
            switch status {
            case .ready:
                running = true
                modelInstalled = true
            case .runningModelMissing:
                running = true
                modelInstalled = false
            case .notInstalled, .stopped:
                running = false
                modelInstalled = false
            }
        case .server(let reachable, let modelAvailable):
            running = reachable
            modelInstalled = reachable && modelAvailable
        }
        return OnboardingChecklist(fullDiskAccess: fullDiskAccess,
                                   accountPicked: accountPicked,
                                   backendRunning: running,
                                   embeddingModelInstalled: modelInstalled,
                                   firstVectorizationDone: hasVectorized)
    }

    /// Ollama-only convenience; `ollamaStatus` nil means the first health check
    /// hasn't landed yet, treated as not-running so the card never claims green
    /// it hasn't seen.
    public static func derive(fullDiskAccess: Bool,
                              accountPicked: Bool,
                              ollamaStatus: OllamaStatus?,
                              hasVectorized: Bool) -> OnboardingChecklist {
        derive(fullDiskAccess: fullDiskAccess, accountPicked: accountPicked,
               embeddingBackend: ollamaStatus.map(EmbeddingBackendReadiness.ollama) ?? .checking,
               hasVectorized: hasVectorized)
    }
}
