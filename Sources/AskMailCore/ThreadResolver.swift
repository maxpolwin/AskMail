import Foundation

/// Resolves each ingested message to a thread, keyed by the root message's
/// own `message_id` (Draft-Modus §3). Single-hop propagation only — adequate
/// given the Inbox/Sent-only ingestion scope keeps most threads short.
public enum ThreadResolver {

    /// Determines the thread id for a message being ingested and reconciles
    /// out-of-order arrival (a reply ingested before its parent).
    ///
    /// 1. Forward: `inReplyTo`, then each `references` token nearest-parent
    ///    first, is looked up against already-ingested messages; the first
    ///    hit's thread id is adopted.
    /// 2. No forward hit: this message becomes its own thread root
    ///    (`thread_id = messageID`).
    /// 3. Reverse/merge: if any already-ingested message already points at
    ///    *this* message id under a different thread id (it arrived first,
    ///    as an orphaned child), every message in that group is reassigned
    ///    to this message's resolved thread id.
    public static func resolveThread(messageID: String, inReplyTo: String?, references: [String],
                                     store: SQLiteStore) throws -> String {
        let resolvedThreadID = try forwardLookup(inReplyTo: inReplyTo, references: references, store: store)
            ?? messageID

        for referencer in try store.candidateReferencers(referencingMessageID: messageID)
            where referencer.threadID != resolvedThreadID {
            try store.mergeThreads(from: referencer.threadID, to: resolvedThreadID)
        }

        return resolvedThreadID
    }

    /// Nearest parent first: `inReplyTo` is the immediate parent when
    /// present; `references` is checked oldest-to-newest per RFC 5322 §3.6.4
    /// convention, so reverse it to check the nearest (most recent) ancestor
    /// first.
    private static func forwardLookup(inReplyTo: String?, references: [String],
                                      store: SQLiteStore) throws -> String? {
        var candidates: [String] = []
        if let inReplyTo, !inReplyTo.isEmpty { candidates.append(inReplyTo) }
        candidates.append(contentsOf: references.reversed())

        for candidate in candidates {
            if let existing = try store.messageByMessageID(candidate), let threadID = existing.threadID {
                return threadID
            }
        }
        return nil
    }
}
