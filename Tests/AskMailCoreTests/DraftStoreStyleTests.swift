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
}
