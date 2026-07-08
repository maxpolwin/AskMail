import Foundation

/// Scope keys for `style_profiles`, most specific first. Mirrors
/// docs/draft-contract.md §5's "per-scope (global / domain / address)"
/// learned-style hook, implemented here.
public enum StyleScope {
    public static let global = "global"

    /// `MailHeader.domain(fromSender:)`'s normalized organisation label
    /// (e.g. `"domain:bundesbank"` for `noreply@newsletter.bundesbank.de`).
    public static func domain(_ sender: String) -> String {
        "domain:\(MailHeader.domain(fromSender: sender))"
    }

    /// The bare address, when the sender header carries one; nil otherwise
    /// (a display-name-only header has no address-level scope to key).
    public static func address(_ sender: String) -> String? {
        guard let address = MailHeader.address(fromSender: sender) else { return nil }
        return "address:\(address)"
    }
}

/// Learns how the user actually writes by comparing a Draft-Modus draft
/// against the real Sent reply that eventually followed it, folding the
/// delta into per-scope `style_profiles` rows (`DraftStore`) that
/// `DraftAssembler`'s `styleGuidance` hook (docs/draft-contract.md §5) reads
/// back on the next draft to the same correspondent.
///
/// Deliberately a background signal, not a required one: `guidance` returns
/// nil until at least one sample has been learned, and drafting proceeds
/// identically either way (Phase 1's assembler already treats nil
/// `styleGuidance` as "no style block").
public enum StyleLearner {

    /// A draft is only examined once it is at least this old — long enough
    /// that a real Sent reply, if the user is going to write one, plausibly
    /// exists by now. Checking a same-day draft would mostly find nothing
    /// and waste an LLM call.
    public static let minAgeSeconds: Int64 = 3 * 86400

    /// Bounds local-LLM work per learning pass; style learning is a
    /// background nice-to-have, never a reason for a tick to run long.
    public static let defaultMaxPerTick = 5

    private static let lastRunMetaKey = "style_learn_last_run_unix"

    /// Runs at most once per 24h (mirrors `DraftJobProcessor.purgeIfDue`'s
    /// gate). Finds up to `maxPerTick` not-yet-learned drafts old enough to
    /// check, and for each, looks for the account's own real Sent reply in
    /// the same thread dated after the draft was generated. A draft with no
    /// such reply yet is left unmarked and re-examined on a later pass —
    /// bounded not by a separate timeout but by `DraftJobProcessor`'s
    /// existing 14-day retention purge, which deletes it either way once
    /// it's old enough.
    public static func learnIfDue(draftStore: DraftStore, askStore: SQLiteStore, chatProvider: ChatProvider,
                                  accountEmail: String, maxPerTick: Int = defaultMaxPerTick,
                                  now: Date = Date()) async throws {
        // Can't identify which thread member is "the account's own reply"
        // without a configured account email — fail closed (skip learning
        // entirely this pass), never treat every sender as a match. Checked
        // *before* the daily gate below (and never advances it) so that the
        // first tick after the user finally configures an account email can
        // learn immediately, instead of waiting out up to 24h of a gate that
        // advanced while there was nothing to learn from anyway. This check
        // is cheap (no query), so re-running it every tick until an account
        // email exists costs nothing worth gating.
        guard !accountEmail.isEmpty else { return }

        let nowUnix = Int64(now.timeIntervalSince1970)
        let lastRun = Int64(try draftStore.meta(lastRunMetaKey) ?? "0") ?? 0
        guard nowUnix - lastRun >= 86400 else { return }
        try draftStore.setMeta(lastRunMetaKey, value: String(nowUnix))

        let cutoff = nowUnix - minAgeSeconds
        let candidates = try draftStore.draftsAwaitingStyleLearning(olderThanGeneratedAt: cutoff, limit: maxPerTick)
        for draft in candidates {
            do {
                try await learn(from: draft, draftStore: draftStore, askStore: askStore,
                                chatProvider: chatProvider, accountEmail: accountEmail, now: nowUnix)
            } catch {
                RollingLog.shared.log("style learning failed for draft pk=\(draft.pk): \(error)", level: .error)
            }
        }
    }

    /// The best-available learned style guidance for a reply to `sender`:
    /// address-scoped first, then domain-scoped, then global, else nil
    /// (Phase 1's `DraftAssembler` treats nil identically to "no learner exists").
    public static func guidance(forRecipient sender: String, draftStore: DraftStore) throws -> String? {
        if let addressScope = StyleScope.address(sender),
           let profile = try draftStore.styleProfile(scope: addressScope), !profile.profileText.isEmpty {
            return profile.profileText
        }
        if let profile = try draftStore.styleProfile(scope: StyleScope.domain(sender)), !profile.profileText.isEmpty {
            return profile.profileText
        }
        if let profile = try draftStore.styleProfile(scope: StyleScope.global), !profile.profileText.isEmpty {
            return profile.profileText
        }
        return nil
    }

    // MARK: Learning one candidate

    /// Keyed by thread id: the message id of the real Sent reply this thread
    /// last folded into its profiles. Lets a second draft row in the same
    /// thread (e.g. two inbound messages each got their own draft before the
    /// user sent one real reply covering both) recognize "this exact
    /// evidence was already learned from" and skip re-merging it, instead of
    /// double-counting the same sample under a different `draftText`.
    private static func dedupeMetaKey(threadID: String) -> String { "style_learned_reply:\(threadID)" }

    /// Finds the account's earliest real Sent reply in `draft`'s thread dated
    /// after `draft` was generated (oldest-first, so `.first` is literally
    /// "the first thing the user actually sent afterward"), and — only if
    /// one exists and hasn't already been folded in via a sibling draft in
    /// the same thread — folds the (draft, actual) pair into every applicable
    /// scope's profile via a local-LLM merge call.
    ///
    /// All-or-nothing: every scope's merge call must succeed before any of
    /// them is persisted. A mid-loop failure (e.g. the local LLM drops
    /// partway through) previously could leave an earlier scope's update
    /// already written while the draft stayed unmarked for retry — the next
    /// retry then re-merged that same evidence into the already-updated
    /// scope a second time. Collecting every scope's result first and
    /// persisting only after all succeed makes a failed attempt a clean,
    /// fully-reversible no-op instead.
    private static func learn(from draft: DraftRecord, draftStore: DraftStore, askStore: SQLiteStore,
                              chatProvider: ChatProvider, accountEmail: String, now: Int64) async throws {
        guard let sentReply = try askStore.threadMessages(threadID: draft.threadID).first(where: {
            $0.dateUnix > draft.generatedAt && $0.sender.localizedCaseInsensitiveContains(accountEmail)
        }) else {
            return  // no real reply yet; leave unmarked for a later pass
        }

        let dedupeKey = dedupeMetaKey(threadID: draft.threadID)
        if try draftStore.meta(dedupeKey) == sentReply.messageID {
            try draftStore.markStyleLearned(pk: draft.pk, at: now)
            return
        }

        var scopes = [StyleScope.global, StyleScope.domain(draft.sender)]
        if let addressScope = StyleScope.address(draft.sender) { scopes.append(addressScope) }

        var updates: [(scope: String, profileText: String, sampleCount: Int)] = []
        for scope in scopes {
            let existing = try draftStore.styleProfile(scope: scope)
            let prompt = buildMergePrompt(existingProfile: existing?.profileText,
                                         draftText: draft.draftText, actualText: sentReply.bodyText)
            var updated = ""
            for try await token in chatProvider.stream(ChatRequest(
                system: Defaults.defaultStyleLearningSystemPrompt, user: prompt,
                maxTokens: Defaults.styleProfileMaxTokens, temperature: 0.2)) {
                updated += token
            }
            let trimmed = updated.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            updates.append((scope, trimmed, (existing?.sampleCount ?? 0) + 1))
        }

        // An all-empty pass (e.g. every stream came back empty without
        // throwing) leaves the draft eligible for retry on a later pass
        // instead of silently losing the sample.
        guard !updates.isEmpty else { return }

        for update in updates {
            try draftStore.upsertStyleProfile(scope: update.scope, profileText: update.profileText,
                                              sampleCount: update.sampleCount, updatedAt: now)
        }
        try draftStore.markStyleLearned(pk: draft.pk, at: now)
        try draftStore.setMeta(dedupeKey, value: sentReply.messageID)
    }

    /// Pure prompt assembly for the merge call — directly testable without a
    /// `ChatProvider`.
    static func buildMergePrompt(existingProfile: String?, draftText: String, actualText: String) -> String {
        let profileBlock = (existingProfile?.isEmpty == false) ? existingProfile! : "(none yet)"
        return """
        CURRENT PROFILE:
        \(profileBlock)

        DRAFT (what was auto-drafted):
        \(draftText)

        ACTUAL (what the person actually sent):
        \(actualText)
        """
    }
}
