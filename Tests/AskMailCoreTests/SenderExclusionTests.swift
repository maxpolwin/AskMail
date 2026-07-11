import XCTest
@testable import AskMailCore

final class SenderExclusionTests: XCTestCase {

    func testExactAddressMatchIsExcluded() {
        XCTAssertTrue(SenderExclusion.isExcluded("Spam Bot <spam@bigcorp.com>", excluded: ["spam@bigcorp.com"]))
    }

    func testExactAddressMatchIsCaseInsensitive() {
        XCTAssertTrue(SenderExclusion.isExcluded("Spam Bot <Spam@BigCorp.com>", excluded: ["spam@bigcorp.com"]))
    }

    func testBareDomainMatchesAnyAddressAtThatHost() {
        XCTAssertTrue(SenderExclusion.isExcluded("Newsletter <news@bigcorp.com>", excluded: ["bigcorp.com"]))
    }

    func testBareDomainMatchesASubdomain() {
        XCTAssertTrue(SenderExclusion.isExcluded("Updates <updates@news.bigcorp.com>", excluded: ["bigcorp.com"]))
    }

    func testBareDomainDoesNotMatchAnUnrelatedHostThatMerelySharesASuffix() {
        // "notbigcorp.com" must not match an exclusion of "bigcorp.com" --
        // only an exact host or a proper subdomain (".bigcorp.com") should.
        XCTAssertFalse(SenderExclusion.isExcluded("x@notbigcorp.com", excluded: ["bigcorp.com"]))
    }

    func testUnrelatedSenderIsNotExcluded() {
        XCTAssertFalse(SenderExclusion.isExcluded("Alice <alice@example.com>", excluded: ["bigcorp.com", "spam@x.com"]))
    }

    func testBlankAndWhitespaceEntriesAreIgnored() {
        XCTAssertFalse(SenderExclusion.isExcluded("alice@example.com", excluded: ["", "   "]))
    }

    func testSenderWithNoParseableAddressIsNeverExcluded() {
        XCTAssertFalse(SenderExclusion.isExcluded("Just A Display Name", excluded: ["bigcorp.com"]))
    }

    func testEmptyExclusionListExcludesNothing() {
        XCTAssertFalse(SenderExclusion.isExcluded("anyone@anywhere.com", excluded: []))
    }
}
