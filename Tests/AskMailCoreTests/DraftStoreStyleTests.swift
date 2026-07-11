import XCTest
@testable import AskMailCore

/// Direct CRUD tests for the Phase 3 `DraftStore` additions, mirroring
/// `DraftStoreJobTests.swift`'s scope (store-level plumbing; `StyleLearner`
/// orchestration itself is covered in `StyleLearnerTests.swift`).
final class DraftStoreStyleTests: XCTestCase {

    // MARK: draftsAwaitingStyleLearning

    func testDraftsAwaitingStyleLearningFiltersByCutoffAndUnlearnedOnly() throws {
        let store = try DraftStore.inMemory()
        let old = try store.insertDraft(threadID: "t1", latestMessageID: "m1", sender: "a@x", subject: "s",
                                        draftText: "d1", generatedAt: 100, status: .ready)
        _ = try store.insertDraft(threadID: "t2", latestMessageID: "m2", sender: "a@x", subject: "s",
                                  draftText: "d2", generatedAt: 500, status: .ready)
        let alreadyLearned = try store.insertDraft(threadID: "t3", latestMessageID: "m3", sender: "a@x", subject: "s",
                                                   draftText: "d3", generatedAt: 50, status: .ready)
        try store.markStyleLearned(pk: alreadyLearned, at: 999)

        let candidates = try store.draftsAwaitingStyleLearning(olderThanGeneratedAt: 200, limit: 10)
        XCTAssertEqual(candidates.map(\.pk), [old], "only the unlearned draft at/under the cutoff must be returned")
    }

    func testDraftsAwaitingStyleLearningOrdersOldestGeneratedFirstAndRespectsLimit() throws {
        let store = try DraftStore.inMemory()
        let p3 = try store.insertDraft(threadID: "t3", latestMessageID: "m", sender: "a@x", subject: "s",
                                       draftText: "d", generatedAt: 300, status: .ready)
        let p1 = try store.insertDraft(threadID: "t1", latestMessageID: "m", sender: "a@x", subject: "s",
                                       draftText: "d", generatedAt: 100, status: .ready)
        let p2 = try store.insertDraft(threadID: "t2", latestMessageID: "m", sender: "a@x", subject: "s",
                                       draftText: "d", generatedAt: 200, status: .ready)

        let all = try store.draftsAwaitingStyleLearning(olderThanGeneratedAt: 1000, limit: 10)
        XCTAssertEqual(all.map(\.pk), [p1, p2, p3])

        let limited = try store.draftsAwaitingStyleLearning(olderThanGeneratedAt: 1000, limit: 2)
        XCTAssertEqual(limited.map(\.pk), [p1, p2])
    }

    // MARK: markStyleLearned

    func testMarkStyleLearnedRemovesDraftFromFutureCandidateLists() throws {
        let store = try DraftStore.inMemory()
        let pk = try store.insertDraft(threadID: "t1", latestMessageID: "m1", sender: "a@x", subject: "s",
                                       draftText: "d", generatedAt: 1, status: .ready)
        XCTAssertEqual(try store.draftsAwaitingStyleLearning(olderThanGeneratedAt: 1000, limit: 10).map(\.pk), [pk])

        try store.markStyleLearned(pk: pk, at: 500)
        XCTAssertTrue(try store.draftsAwaitingStyleLearning(olderThanGeneratedAt: 1000, limit: 10).isEmpty)
    }

    // MARK: style_profiles

    func testStyleProfileRoundTripsAndUpsertOverwrites() throws {
        let store = try DraftStore.inMemory()
        XCTAssertNil(try store.styleProfile(scope: "global"), "no profile before any write")

        try store.upsertStyleProfile(scope: "global", profileText: "Terse, no greeting.", sampleCount: 1, updatedAt: 100)
        let first = try XCTUnwrap(try store.styleProfile(scope: "global"))
        XCTAssertEqual(first.profileText, "Terse, no greeting.")
        XCTAssertEqual(first.sampleCount, 1)
        XCTAssertEqual(first.updatedAt, 100)

        try store.upsertStyleProfile(scope: "global", profileText: "Terse, signs off with initials.",
                                     sampleCount: 2, updatedAt: 200)
        let second = try XCTUnwrap(try store.styleProfile(scope: "global"))
        XCTAssertEqual(second.profileText, "Terse, signs off with initials.")
        XCTAssertEqual(second.sampleCount, 2, "sample count must reflect the new write, not accumulate automatically")
        XCTAssertEqual(second.updatedAt, 200)
    }

    func testStyleProfilesAtDifferentScopesAreIndependent() throws {
        let store = try DraftStore.inMemory()
        try store.upsertStyleProfile(scope: "global", profileText: "global text", sampleCount: 1, updatedAt: 1)
        try store.upsertStyleProfile(scope: "domain:acme", profileText: "domain text", sampleCount: 1, updatedAt: 1)
        try store.upsertStyleProfile(scope: "address:a@acme.com", profileText: "address text", sampleCount: 1, updatedAt: 1)

        XCTAssertEqual(try store.styleProfile(scope: "global")?.profileText, "global text")
        XCTAssertEqual(try store.styleProfile(scope: "domain:acme")?.profileText, "domain text")
        XCTAssertEqual(try store.styleProfile(scope: "address:a@acme.com")?.profileText, "address text")
    }

    // MARK: allStyleProfiles / deleteStyleProfiles (Phase 6 Settings surfacing)

    func testAllStyleProfilesReturnsEveryScopeMostRecentlyUpdatedFirst() throws {
        let store = try DraftStore.inMemory()
        try store.upsertStyleProfile(scope: "global", profileText: "g", sampleCount: 3, updatedAt: 100)
        try store.upsertStyleProfile(scope: "domain:acme", profileText: "d", sampleCount: 1, updatedAt: 300)
        try store.upsertStyleProfile(scope: "address:a@acme.com", profileText: "a", sampleCount: 2, updatedAt: 200)

        let all = try store.allStyleProfiles()
        XCTAssertEqual(all.map(\.scope), ["domain:acme", "address:a@acme.com", "global"])
    }

    func testAllStyleProfilesIsEmptyWhenNothingLearnedYet() throws {
        let store = try DraftStore.inMemory()
        XCTAssertTrue(try store.allStyleProfiles().isEmpty)
    }

    func testDeleteStyleProfilesWithNilScopeDeletesEverything() throws {
        let store = try DraftStore.inMemory()
        try store.upsertStyleProfile(scope: "global", profileText: "g", sampleCount: 1, updatedAt: 1)
        try store.upsertStyleProfile(scope: "domain:acme", profileText: "d", sampleCount: 1, updatedAt: 1)

        let deleted = try store.deleteStyleProfiles()
        XCTAssertEqual(deleted, 2)
        XCTAssertTrue(try store.allStyleProfiles().isEmpty)
    }

    func testDeleteStyleProfilesWithAScopeOnlyDeletesThatOne() throws {
        let store = try DraftStore.inMemory()
        try store.upsertStyleProfile(scope: "global", profileText: "g", sampleCount: 1, updatedAt: 1)
        try store.upsertStyleProfile(scope: "domain:acme", profileText: "d", sampleCount: 1, updatedAt: 1)

        let deleted = try store.deleteStyleProfiles(scope: "domain:acme")
        XCTAssertEqual(deleted, 1)
        XCTAssertNotNil(try store.styleProfile(scope: "global"))
        XCTAssertNil(try store.styleProfile(scope: "domain:acme"))
    }

    /// Resetting must not resurrect already-`markStyleLearned` draft rows
    /// for re-examination -- their evidence is gone, so guidance stays nil
    /// until genuinely *new* Sent replies are learned from (Phase 6 DoD).
    func testDeleteStyleProfilesDoesNotResetAlreadyLearnedDraftMarkers() throws {
        let store = try DraftStore.inMemory()
        let pk = try store.insertDraft(threadID: "t1", latestMessageID: "m1", sender: "a@x", subject: "s",
                                       draftText: "d", generatedAt: 1, status: .ready)
        try store.markStyleLearned(pk: pk, at: 500)
        try store.upsertStyleProfile(scope: "global", profileText: "g", sampleCount: 1, updatedAt: 500)

        try store.deleteStyleProfiles()

        XCTAssertNil(try store.styleProfile(scope: "global"))
        XCTAssertTrue(try store.draftsAwaitingStyleLearning(olderThanGeneratedAt: 1000, limit: 10).isEmpty,
                      "an already-learned draft must not become re-examinable just because the profile was reset")
    }

    // MARK: styleProfilesEpoch

    func testStyleProfilesEpochStartsAtZero() throws {
        let store = try DraftStore.inMemory()
        XCTAssertEqual(try store.styleProfilesEpoch(), 0)
    }

    func testDeleteStyleProfilesBumpsTheEpoch() throws {
        let store = try DraftStore.inMemory()
        try store.upsertStyleProfile(scope: "global", profileText: "g", sampleCount: 1, updatedAt: 1)

        try store.deleteStyleProfiles()
        XCTAssertEqual(try store.styleProfilesEpoch(), 1)

        try store.deleteStyleProfiles()
        XCTAssertEqual(try store.styleProfilesEpoch(), 2, "every reset must bump the epoch, even an empty one")
    }

    func testDeleteStyleProfilesBumpsTheEpochEvenForAScopedDelete() throws {
        let store = try DraftStore.inMemory()
        try store.deleteStyleProfiles(scope: "domain:acme")
        XCTAssertEqual(try store.styleProfilesEpoch(), 1,
                       "any reset must be able to invalidate an in-flight learner write, regardless of scope")
    }

    // MARK: deleteReadyDrafts (Phase 4 Regenerate: replace, don't duplicate)

    func testDeleteReadyDraftsRemovesOnlyReadyRowsForThatThread() throws {
        let store = try DraftStore.inMemory()
        let readyPk = try store.insertDraft(threadID: "t1", latestMessageID: "m1", sender: "a@x", subject: "s",
                                            draftText: "d1", generatedAt: 1, status: .ready)
        _ = try store.insertDraft(threadID: "t1", latestMessageID: "m2", sender: "a@x", subject: "s",
                                  draftText: "d2", generatedAt: 2, status: .pending)
        let otherThreadPk = try store.insertDraft(threadID: "t2", latestMessageID: "m3", sender: "a@x", subject: "s",
                                                   draftText: "d3", generatedAt: 3, status: .ready)

        let deleted = try store.deleteReadyDrafts(threadID: "t1")
        XCTAssertEqual(deleted, 1)
        XCTAssertNil(try store.latestDraft(threadID: "t1").flatMap { $0.pk == readyPk ? $0 : nil })
        XCTAssertNotNil(try store.latestDraft(threadID: "t2"))
        XCTAssertEqual(try store.latestDraft(threadID: "t2")?.pk, otherThreadPk)
    }

    func testDeleteReadyDraftsIsANoOpWhenThereIsNothingToDelete() throws {
        let store = try DraftStore.inMemory()
        XCTAssertEqual(try store.deleteReadyDrafts(threadID: "nonexistent"), 0)
    }
}
