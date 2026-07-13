import Foundation

/// Matches a macOS Services-menu pasteboard selection back to a stored,
/// `ready` Draft-Modus draft (Phase 4, docs/draft-modus-plan.md).
///
/// A live-Mac spike (see the plan) established what a Mail.app Services
/// invocation actually hands the provider: the selected text/RTF from the
/// compose window -- never a message id or any AppleScript-level identifier.
/// In practice that selection is the auto-inserted reply quote, whose first
/// line is Mail's standard `"On <date>, <Name> <<email>> wrote:"` header
/// followed by the quoted original body verbatim. This is the only
/// identifying signal available without Phase 5's Automation grant.
public enum DraftServiceMatcher {

    public enum MatchError: Error, CustomStringConvertible, Equatable {
        /// No email address found in the selection -- the user likely
        /// selected something other than Mail's quoted-reply header/body.
        case noSenderFound
        /// A sender address was found, but no `ready` draft exists for it.
        case noDraftForSender

        public var description: String {
            switch self {
            case .noSenderFound:
                return "Select the quoted original message (including the \u{201C}On \u{2026} wrote:\u{201D} line) before invoking this service."
            case .noDraftForSender:
                return "No stored AskMail draft was found for this correspondent."
            }
        }
    }

    /// Extracts the quoted sender's email address from the selection.
    ///
    /// `NSSendTypes` (plain text/RTF) are generic pasteboard types, so these
    /// Services are technically invocable from a text selection made in
    /// *any* app, not just Mail's compose window -- there is no way to
    /// verify the selection actually came from Mail. To keep that from
    /// matching incidental email addresses (a signature block selected in
    /// Notes, a copied contact card, ...), this requires the *specific
    /// structural shape* of Mail's own quote header rather than "an email
    /// exists somewhere in the selection": the address must be angle-
    /// bracket-wrapped (`<addr>`) and appear on the selection's first line
    /// -- exactly matching the verbatim `"On <date>, <Name> <<email>> wrote:"`
    /// format the live-Mac spike observed. This substantially narrows, but
    /// (being a heuristic over plain text) can't fully eliminate, the
    /// cross-app false-positive risk.
    public static func quotedSenderEmail(in text: String) -> String? {
        let firstLine = text.prefix(while: { !$0.isNewline }).prefix(300)
        guard let ltIndex = firstLine.firstIndex(of: "<"),
              let gtIndex = firstLine[firstLine.index(after: ltIndex)...].firstIndex(of: ">") else {
            return nil
        }
        let candidate = firstLine[firstLine.index(after: ltIndex)..<gtIndex]
        guard candidate.range(of: #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#,
                              options: .regularExpression) != nil else {
            return nil
        }
        return String(candidate).lowercased()
    }

    /// Hard cap on how much of the selection `match` ever processes.
    /// `insertDraft` runs synchronously on the calling thread by necessity
    /// (Services insertion requires writing replacement data back before the
    /// method returns), and `NSSendTypes` being generic means this can be
    /// invoked against an arbitrarily large or adversarial pasteboard
    /// payload from any source -- this bounds the worst-case work
    /// regardless of selection size.
    private static let maxSelectionLength = 20_000

    /// Whitespace-collapsed, lowercased form used for the disambiguation
    /// overlap check below -- tolerant of the reflowing Mail's RTF/plain-text
    /// pasteboard conversion can introduce, since it compares content, not
    /// exact formatting.
    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The best-matching `ready` draft for a Services selection.
    ///
    /// 1. Extracts the quoted sender's email address.
    /// 2. Filters `draftStore`'s ready drafts to that sender (case-insensitive).
    /// 3. If more than one candidate remains (the same correspondent has
    ///    several open threads), narrows using `askStore`: whichever
    ///    candidate's own original-message body has the longest normalized
    ///    prefix contained in the selection wins. Ties (or no candidate
    ///    clearing that bar) fall back to the most recently generated --
    ///    a reasonable default rather than a hard failure, since the
    ///    alternative is refusing to act on an unambiguous single-thread
    ///    correspondent just because a same-sender edge case exists elsewhere.
    public static func match(selectionText: String, draftStore: DraftStore,
                             askStore: SQLiteStore) throws -> DraftRecord {
        let boundedSelection = String(selectionText.prefix(maxSelectionLength))
        guard let email = quotedSenderEmail(in: boundedSelection) else { throw MatchError.noSenderFound }
        let allReady = try draftStore.readyDrafts(limit: 200)
        // Exact address equality only -- a substring/`contains` check here
        // would false-positive-match, e.g., "smith@corp.com" against a
        // stored "jblacksmith@corp.com" draft (silently inserting/
        // regenerating the wrong correspondent's reply).
        let candidates = allReady.filter { draft in
            MailHeader.address(fromSender: draft.sender)?.lowercased() == email
        }
        guard !candidates.isEmpty else { throw MatchError.noDraftForSender }
        guard candidates.count > 1 else { return candidates[0] }

        let normalizedSelection = normalized(boundedSelection)
        var bestMatch: DraftRecord?
        var bestOverlapLength = 0
        for candidate in candidates {
            guard let resolved = try? askStore.messageByMessageID(candidate.latestMessageID),
                  let threadID = resolved.threadID,
                  let thread = try? askStore.threadMessages(threadID: threadID),
                  let original = thread.first(where: { $0.messageID == candidate.latestMessageID }) else {
                continue
            }
            let normalizedBody = normalized(original.bodyText)
            guard !normalizedBody.isEmpty else { continue }
            let prefixLength = min(80, normalizedBody.count)
            let prefix = String(normalizedBody.prefix(prefixLength))
            guard prefixLength >= 20, normalizedSelection.contains(prefix) else { continue }
            if prefixLength > bestOverlapLength {
                bestOverlapLength = prefixLength
                bestMatch = candidate
            }
        }
        if let bestMatch { return bestMatch }
        return candidates.max(by: { $0.generatedAt < $1.generatedAt }) ?? candidates[0]
    }
}
