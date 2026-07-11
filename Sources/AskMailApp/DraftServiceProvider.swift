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

    /// "Insert draft": replaces the selected quoted text with the matching
    /// thread's latest `ready` draft. Synchronous by necessity -- Services
    /// insertion works by the provider writing replacement data back to the
    /// same pasteboard before this method returns, which AppKit then reads
    /// to update the document. `DraftStore`/`SQLiteStore` reads are already
    /// synchronous, bounded SQLite calls (same as `DraftsViewModel`'s own
    /// main-thread reads), so no async hop is needed or possible here.
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
            pboard.setString(match.draftText, forType: .string)
        } catch let matchError as DraftServiceMatcher.MatchError {
            errorPtr.pointee = matchError.description as NSString
        } catch {
            RollingLog.shared.log("DraftService insert failed: \(error)", level: .error)
            errorPtr.pointee = "AskMail couldn\u{2019}t look up a draft." as NSString
        }
    }

    /// "Regenerate draft": re-runs drafting for the matched thread on
    /// demand, bypassing the scheduler's cadence, and replaces the stored
    /// draft so the next "Insert" reflects it. Genuinely asynchronous (a
    /// local-LLM call), so this declares no `NSReturnTypes` (nothing is
    /// expected back synchronously) and returns immediately after kicking
    /// the work off on a detached task -- mirroring `DraftEngine.runTick`'s
    /// own reason for hopping off the calling thread before any SQLite/LLM
    /// work, since this method (like `runTick`) is invoked on the main thread.
    @objc func regenerateDraft(_ pboard: NSPasteboard, userData: String,
                               error errorPtr: AutoreleasingUnsafeMutablePointer<NSString?>) {
        // Draft-Modus's master opt-in gate (SettingsStore.draftModeEnabled)
        // must hold for *every* path that runs mail content through the
        // local LLM, not just the scheduled tick -- DraftEngine.runTick
        // checks this as its very first line; Regenerate is the same kind
        // of background processing and must be gated identically. Insert
        // (above) is deliberately exempt: it only reads an already-
        // generated draft, the same way the always-available Drafts window
        // does, so it's fine regardless of the toggle.
        guard SettingsStore.shared.draftModeEnabled else {
            errorPtr.pointee = "Turn on Draft-Modus in AskMail Settings first." as NSString
            return
        }
        guard let selection = Self.selectionText(from: pboard) else {
            errorPtr.pointee = "Select the quoted original message first." as NSString
            return
        }
        // Snapshot on the calling (main) thread before hopping off, same
        // reasoning as DraftEngine.runTick's own snapshot-then-detach.
        let settings = SettingsStore.shared
        let localChatModel = settings.localChatModel
        let embeddingModel = settings.embeddingModel
        let excludedSenders = settings.draftExcludedSenders
        let accountEmail = settings.accountEmail

        Task.detached(priority: .userInitiated) {
            do {
                let draftStore = try DraftStore(path: SettingsStore.draftsDatabasePath)
                let askStore = try SQLiteStore(path: SettingsStore.databasePath)
                let match = try DraftServiceMatcher.match(selectionText: selection, draftStore: draftStore,
                                                          askStore: askStore)
                // The sender/domain exclusion list (Phase 6) applies here
                // too -- a correspondent the user explicitly opted out of
                // must not be re-drafted just because a stale ready draft
                // from before the exclusion was added still exists.
                guard !SenderExclusion.isExcluded(match.sender, excluded: excludedSenders) else {
                    RollingLog.shared.log("DraftService regenerate skipped: sender is excluded", level: .info)
                    return
                }
                // Local-only regardless of the configured Q&A provider,
                // matching every other Draft-Modus generation path (H-11).
                let chatProvider = OllamaClient(host: Defaults.ollamaLocalHost, model: localChatModel)
                let embedder = OllamaEmbedder(model: embeddingModel)
                let record = try await DraftJobProcessor.regenerateDraft(
                    threadID: match.threadID, draftStore: draftStore, askStore: askStore,
                    chatProvider: chatProvider, embedder: embedder, accountEmail: accountEmail)
                // This regenerate already notifies below -- advance the
                // scheduled tick's own "newly ready" cursor past this row
                // first, so the next tick's notifyNewlyReadyDrafts doesn't
                // also send a second notification for the same draft.
                DraftEngine.skipNotifying(forDraftPk: record.pk, draftStore: draftStore)
                await DraftNotifier.notify(regeneratedDraftSubject: record.subject)
                await MainActor.run { DraftEngine.shared.refreshCounts() }
            } catch let matchError as DraftServiceMatcher.MatchError {
                RollingLog.shared.log("DraftService regenerate: \(matchError.description)", level: .info)
            } catch {
                RollingLog.shared.log("DraftService regenerate failed: \(error)", level: .error)
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
