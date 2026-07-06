import Foundation

/// Single source of truth for concrete starting values, mirroring docs/defaults.md.
/// Everything here is a starting point to validate during the B11 spikes.
public enum Defaults {
    // MARK: Models
    public static let embeddingModel = "nomic-embed-text"
    public static let localChatModel = "qwen2.5:7b"
    /// Shown before a user-initiated download so the size is never a surprise
    /// (the actual `/api/pull` is ~274 MB for nomic-embed-text).
    public static let embeddingModelApproxMB = 275
    public static let cloudChatModel = "qwen3.5:cloud"
    public static let mistralChatModel = "mistral-large-latest"
    public static let ollamaLocalHost = URL(string: "http://localhost:11434")!
    public static let ollamaCloudHost = URL(string: "https://ollama.com")!

    // MARK: Retrieval (quality-critical, tune during spike B11 #3)
    /// ~512 tokens at the ~4 chars/token approximation used throughout.
    public static let chunkChars = 2048
    /// ~64 tokens overlap.
    public static let overlapChars = 256
    public static let vectorTopN = 30
    public static let keywordTopN = 30
    public static let rrfK = 60.0
    public static let finalTopK = 8
    /// Relevance floor on the fused score; below this the no-match message is
    /// returned instead of forcing a weak answer. Tune empirically (B11 #3).
    public static let relevanceFloor = 0.0

    // MARK: Generation
    public static let contextTokenLimit = 4096
    public static let answerTokenLimit = 800
    public static let temperature = 0.2
    public static let sessionTurnCap = 3
    /// How long a cloud primary gets before ProviderRouter starts racing
    /// local alongside it (FR-4 extension), so a slow cloud response doesn't
    /// force the user to wait out its full worst-case timeout.
    public static let providerRaceTimeout: Duration = .seconds(5)

    // MARK: Ingestion
    /// Apple Mail's container: `~/Library/Mail`. TCC-protected — reading it (or
    /// anything under it) requires Full Disk Access.
    static let mailContainer = URL(
        fileURLWithPath: NSString(string: "~/Library/Mail").expandingTildeInPath,
        isDirectory: true)

    /// Apple Mail data root; each account lives in a UUID-named subdirectory,
    /// with the shared index/plist under `MailData`.
    ///
    /// Apple bumps the schema-versioned subdirectory (`V9`, `V10`, `V11`, …)
    /// with major macOS releases and keeps live mail only under the newest one,
    /// so we resolve it at runtime rather than pinning a version a future macOS
    /// will break. Computed on each access so that granting Full Disk Access and
    /// hitting "Reload accounts" picks up the real directory without a restart.
    public static var mailRoot: URL { resolveMailRoot() }

    /// Highest-numbered `V<n>` directory under `container`, or `V10` when the
    /// container can't be listed (no Full Disk Access yet, or Mail not set up)
    /// so derived paths stay well-formed. Injectable for tests.
    static func resolveMailRoot(container: URL = mailContainer) -> URL {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: container,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        let newest = entries
            .compactMap { url -> (Int, URL)? in
                let name = url.lastPathComponent
                guard name.hasPrefix("V"), let n = Int(name.dropFirst()) else { return nil }
                return (n, url)
            }
            .max { $0.0 < $1.0 }?.1
        return newest ?? container.appendingPathComponent("V10", isDirectory: true)
    }

    /// Maps account UUIDs to names/emails for the account picker (MailAccounts).
    ///
    /// Mail no longer ships a per-version `Accounts.plist` (verified absent on a
    /// live macOS 15 install, spike B11 #1) — account name/email now live in the
    /// system-wide Internet Accounts store, keyed by the same UUID that names
    /// each `~/Library/Mail/V<n>/<uuid>` directory.
    public static var accountsDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Accounts/Accounts4.sqlite")
    }
    public static var envelopeIndexPath: String {
        mailRoot.appendingPathComponent("MailData/Envelope Index").path
    }
    /// Add to envelope-index date_sent/date_received for Unix time.
    public static let cocoaEpochOffset: Int64 = 978_307_200
    /// Chunks embedded per Ollama request. Kept small: 128 × an 8k context per
    /// item spiked memory and OOM-killed the local daemon mid-run (observed as
    /// a cascade of -1004 "could not connect" failures). 16 keeps peak memory
    /// modest without meaningfully slowing throughput.
    public static let embedBatchSize = 16
    /// Context window requested per embed. Our chunks are ~512 tokens
    /// (`chunkChars` ≈ 2048 chars), so 4096 is ample headroom; the old 8192
    /// just multiplied the KV-cache allocation with no quality benefit.
    public static let embedNumCtx = 4096
    public static let maxAttachmentBytes = 25 * 1024 * 1024

    // MARK: Logging
    public static let logRetentionHours: Double = 12

    // MARK: Keychain
    public static let keychainServiceOllamaCloud = "askmail.ollama-cloud"
    public static let keychainServiceMistral = "askmail.mistral"
    public static let keychainAccount = "api-key"

    // MARK: UI copy (English-only in v1 per A8)
    public static let noMatchMessage =
        "No matching emails found. Try different terms or a wider date range."
    public static let sourcesListLabel = "Sources"

    /// Default system prompt per docs/prompt-contract.md §1. User-editable at
    /// runtime (FR-9); this is the shipped default.
    public static let defaultSystemPrompt = """
    You are an assistant that answers questions about the user's own email.

    Rules:
    1. Answer ONLY from the CONTEXT provided below. The context is a set of
       excerpts retrieved from the user's mailbox. Do not use outside knowledge.
    2. If the answer is not in the context, say so plainly (in the user's
       language) and do not guess. Suggest what the user might search for
       instead. Never fabricate senders, dates, amounts, or quotes.
    3. Answer in the SAME LANGUAGE as the QUESTION, regardless of the language
       of the emails.
    4. Be concise and direct. Lead with the answer. Do not restate the question.
    5. Every factual claim, figure, date, or quote must be traceable to a
       specific source. Immediately after each such claim, cite the source by
       its number in square brackets, e.g. [1] or [2]. The app renders these
       as superscript numbers linked to the source. Place the citation right
       after the claim it supports, not bunched at the end. Cite the minimum
       sources needed per claim.
    6. When the context contains conflicting information (e.g. a plan changed
       across emails), surface the most recent and note the change, citing both.
    7. Do not output source numbers as prose (never write "source 1 says").
       Only use them inside the bracketed citation markers.
    8. Formatting: write in plain prose. You may use **bold** or *italic*
       sparingly and strategically to highlight a single key term, name, or
       figure, but never enough to clutter the answer. Do not use headings,
       tables, or bullet lists.
    """
}
