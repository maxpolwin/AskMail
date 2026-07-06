import Foundation

/// First-run setup state: the five steps between a fresh install and a
/// searchable mailbox, in fix-it order. Pure derivation from already-existing
/// detections (Full Disk Access probe, account selection, `OllamaStatus`,
/// vectorization watermark) so the Settings card just renders it; each row's
/// fix button reuses the section that owns that concern.
public struct OnboardingChecklist: Sendable, Equatable {
    public let fullDiskAccess: Bool
    public let accountPicked: Bool
    public let ollamaRunning: Bool
    public let embeddingModelInstalled: Bool
    public let firstVectorizationDone: Bool

    /// When everything is green the card disappears — setup is not news.
    public var allDone: Bool {
        fullDiskAccess && accountPicked && ollamaRunning
            && embeddingModelInstalled && firstVectorizationDone
    }

    public init(fullDiskAccess: Bool, accountPicked: Bool, ollamaRunning: Bool,
                embeddingModelInstalled: Bool, firstVectorizationDone: Bool) {
        self.fullDiskAccess = fullDiskAccess
        self.accountPicked = accountPicked
        self.ollamaRunning = ollamaRunning
        self.embeddingModelInstalled = embeddingModelInstalled
        self.firstVectorizationDone = firstVectorizationDone
    }

    /// `ollamaStatus` nil means the first health check hasn't landed yet;
    /// treated as not-running so the card never claims green it hasn't seen.
    public static func derive(fullDiskAccess: Bool,
                              accountPicked: Bool,
                              ollamaStatus: OllamaStatus?,
                              hasVectorized: Bool) -> OnboardingChecklist {
        let running: Bool
        let modelInstalled: Bool
        switch ollamaStatus {
        case .ready:
            running = true
            modelInstalled = true
        case .runningModelMissing:
            running = true
            modelInstalled = false
        case .notInstalled, .stopped, nil:
            running = false
            modelInstalled = false
        }
        return OnboardingChecklist(fullDiskAccess: fullDiskAccess,
                                   accountPicked: accountPicked,
                                   ollamaRunning: running,
                                   embeddingModelInstalled: modelInstalled,
                                   firstVectorizationDone: hasVectorized)
    }
}
