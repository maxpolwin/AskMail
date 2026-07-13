import AppKit
import AskMailCore
import Foundation

/// macOS Services-menu provider for Draft-Modus (Phase 4,
/// docs/draft-modus-plan.md): "Insert" and "Regenerate", registered via
/// Packaging/Info.plist's `NSServices` array and `NSApplication.servicesProvider`
/// (AppDelegate). Standard, unprivileged Services mechanism -- no new
/// entitlement, no FDA/Automation/Accessibility prompt.
///
/// Identification of "which thread/draft" was the open question the plan
/// flagged before this shipped. A live-Mac spike found Mail hands the
/// provider only the user's current selection (text/RTF) -- never a message
/// id or any AppleScript-level identifier. `DraftServiceMatcher` (AskMailCore)
/// is the settled mechanism: the user selects Mail's auto-inserted
/// quoted-reply text (its "On … wrote:" header carries the correspondent's
/// address) and invokes either verb on that selection. Both verbs are
/// therefore no-ops with an error surfaced back to Mail's Services error
/// UI when nothing usable is selected -- see `DraftServiceMatcher.MatchError`.
final class DraftServiceProvider: NSObject {

    /// "Insert draft": prepends the matching thread's latest `ready` draft
    /// above the selected quoted text, keeping that quoted conversation
    /// intact below it (two blank lines between the two) rather than
    /// discarding it -- the selection is only ever used to *identify* the
    /// thread (`DraftServiceMatcher`), never dropped from the document.
    /// Synchronous by necessity -- Services insertion works by the provider
    /// writing replacement data back to the same pasteboard before this
    /// method returns, which AppKit then reads to update the document.
    /// `DraftStore`/`SQLiteStore` reads are already synchronous, bounded
    /// SQLite calls (same as `DraftsViewModel`'s own main-thread reads), so
    /// no async hop is needed or possible here -- unless no `ready` draft
    /// exists yet, which falls through to the on-demand path below.
    @objc func insertDraft(_ pboard: NSPasteboard, userData: String,
                           error errorPtr: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let selection = Self.selectionText(from: pboard) else {
            errorPtr.pointee = "Select the quoted original message first." as NSString
            return
        }
        do {
            let draftStore = try DraftStore(path: SettingsStore.draftsDatabasePath)
            let askStore = try SQLiteStore(path: SettingsStore.databasePath)
            let match = try DraftServiceMatcher.match(selectionText: selection, draftStore: draftStore,
                                                       askStore: askStore)
            pboard.clearContents()
            pboard.declareTypes([.string], owner: nil)
            pboard.setString(match.draftText + "\n\n\n" + selection, forType: .string)
        } catch DraftServiceMatcher.MatchError.noDraftForSender {
            // No ready draft exists -- e.g. never enqueued, or skipped by a
            // classification rule (newsletter, no-reply, exclusion list).
            // Those rules exist for *unattended* background drafting; a user
            // who explicitly clicked Insert has already supplied the consent
            // they exist to approximate, so generate on the fly instead of
            // just erroring. Can't hold this synchronous Services call open
            // for the LLM call (nor push into Mail's already-returned-from
            // compose window without Phase 5's Automation grant), so this
            // invocation can't insert *itself* -- it kicks the generation off
            // and tells the user via errorPtr (the only synchronous UI a
            // classic Service has); a completion notification follows, and
            // the next Insert click (the fast path above) picks it up.
            guard let email = DraftServiceMatcher.quotedSenderEmail(in: selection) else {
                errorPtr.pointee = "Select the quoted original message first." as NSString
                return
            }
            errorPtr.pointee =
                "Drafting a response now \u{2014} choose Insert again in a few seconds." as NSString
            Self.generateOnDemandDetached(forSenderAddress: email)
        } catch let matchError as DraftServiceMatcher.MatchError {
            errorPtr.pointee = matchError.description as NSString
        } catch {
            RollingLog.shared.log("DraftService insert failed: \(error)", level: .error)
            errorPtr.pointee = "AskMail couldn\u{2019}t look up a draft." as NSString
        }
    }

    /// "Regenerate draft": re-runs drafting for the matched thread on
    /// demand, bypassing the scheduler's cadence, and replaces the stored
    /// draft so the next "Insert" reflects it. Bypasses every auto-draft
    /// eligibility rule (Draft-Modus master toggle, sender exclusion list,
    /// newsletter/no-reply classification) for the same reason Insert's
    /// on-demand path above does -- those gate unattended background
    /// drafting, and an explicit Regenerate click is its own consent.
    /// Genuinely asynchronous (a local-LLM call), so this declares no
    /// `NSReturnTypes` (nothing is expected back synchronously) and returns
    /// immediately after kicking the work off -- mirroring
    /// `DraftEngine.runTick`'s own reason for hopping off the calling
    /// thread before any SQLite/LLM work, since this method (like
    /// `runTick`) is invoked on the main thread.
    @objc func regenerateDraft(_ pboard: NSPasteboard, userData: String,
                               error errorPtr: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let selection = Self.selectionText(from: pboard) else {
            errorPtr.pointee = "Select the quoted original message first." as NSString
            return
        }
        guard let email = DraftServiceMatcher.quotedSenderEmail(in: selection) else {
            errorPtr.pointee = "Select the quoted original message first." as NSString
            return
        }
        errorPtr.pointee =
            "Drafting a response now \u{2014} you\u{2019}ll get a notification when it\u{2019}s ready." as NSString
        Self.generateOnDemandDetached(forSenderAddress: email, preferredSelection: selection)
    }

    /// Resolves a thread for `email` and generates a fresh draft for it,
    /// unconditionally -- shared by Insert's on-demand fallback and
    /// Regenerate. `preferredSelection`, when given (Regenerate always has
    /// one; Insert's fallback only has the bare email), lets `match` reuse
    /// an existing `ready` draft's thread first (a cheap DB lookup) before
    /// falling back to `SQLiteStore.latestThreadID`, which scans the mailbox
    /// directly and is the only path available for a thread that was never
    /// drafted at all.
    private static func generateOnDemandDetached(forSenderAddress email: String, preferredSelection: String? = nil) {
        let settings = SettingsStore.shared
        let localChatModel = settings.localChatModel
        let embeddingModel = settings.embeddingModel
        let accountEmail = settings.accountEmail

        Task.detached(priority: .userInitiated) {
            do {
                let draftStore = try DraftStore(path: SettingsStore.draftsDatabasePath)
                let askStore = try SQLiteStore(path: SettingsStore.databasePath)

                let threadID: String
                if let preferredSelection,
                   let match = try? DraftServiceMatcher.match(selectionText: preferredSelection,
                                                              draftStore: draftStore, askStore: askStore) {
                    threadID = match.threadID
                } else if let resolved = try askStore.latestThreadID(fromSenderAddress: email) {
                    threadID = resolved
                } else {
                    RollingLog.shared.log("DraftService on-demand: no mailbox thread found for \(email)",
                                          level: .info)
                    return
                }

                // Same auto-start as DraftEngine.runTick -- this path calls
                // Ollama directly rather than through a scheduled tick, so it
                // needs its own guard against "daemon was quit since AskMail
                // launched" instead of failing silently.
                await OllamaEngine.shared.ensureRunning()
                // Local-only regardless of the configured Q&A provider,
                // matching every other Draft-Modus generation path (H-11).
                let chatProvider = OllamaClient(host: Defaults.ollamaLocalHost, model: localChatModel)
                let embedder = OllamaEmbedder(model: embeddingModel)
                let record = try await DraftJobProcessor.regenerateDraft(
                    threadID: threadID, draftStore: draftStore, askStore: askStore,
                    chatProvider: chatProvider, embedder: embedder, accountEmail: accountEmail)
                // This already notifies below -- advance the scheduled
                // tick's own "newly ready" cursor past this row first, so
                // the next tick's notifyNewlyReadyDrafts doesn't also send a
                // second notification for the same draft.
                DraftEngine.skipNotifying(forDraftPk: record.pk, draftStore: draftStore)
                await DraftNotifier.notify(regeneratedDraftSubject: record.subject)
                await MainActor.run { DraftEngine.shared.refreshCounts() }
            } catch {
                RollingLog.shared.log("DraftService on-demand generation failed: \(error)", level: .error)
            }
        }
    }

    /// The selection as plain text, preferring `public.utf8-plain-text`
    /// directly; falls back to decoding the RTF representation's plain
    /// string when Mail only put that on the pasteboard -- `NSSendTypes`
    /// only guarantees *one* of the declared types is actually present.
    private static func selectionText(from pboard: NSPasteboard) -> String? {
        if let string = pboard.string(forType: .string), !string.isEmpty {
            return string
        }
        guard let data = pboard.data(forType: .rtf),
              let attributed = NSAttributedString(rtf: data, documentAttributes: nil) else { return nil }
        let string = attributed.string
        return string.isEmpty ? nil : string
    }
}
