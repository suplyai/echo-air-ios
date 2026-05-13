import XCTest
@testable import EchoAir

final class CommodityAccentTests: XCTestCase {

    func testCanonicalCategoriesResolve() {
        XCTAssertEqual(CommodityAccent.forCategory("flowers"), .flowers)
        XCTAssertEqual(CommodityAccent.forCategory("seafood"), .seafood)
        XCTAssertEqual(CommodityAccent.forCategory("pharma"),  .pharma)
        XCTAssertEqual(CommodityAccent.forCategory("fruit"),   .produce)
        XCTAssertEqual(CommodityAccent.forCategory("meat"),    .meat)
        XCTAssertEqual(CommodityAccent.forCategory("dairy"),   .dairy)
    }

    func testCaseInsensitive() {
        XCTAssertEqual(CommodityAccent.forCategory("FLOWERS"), .flowers)
        XCTAssertEqual(CommodityAccent.forCategory("Beef"),    .meat)
        XCTAssertEqual(CommodityAccent.forCategory("CITRUS"),  .produce)
    }

    func testFuzzyMatchingViaContains() {
        // Legacy freeform rows from the dashboard.
        XCTAssertEqual(CommodityAccent.forCategory("cut flowers"),     .flowers)
        XCTAssertEqual(CommodityAccent.forCategory("fresh seafood"),   .seafood)
        XCTAssertEqual(CommodityAccent.forCategory("citrus fruit"),    .produce)
        XCTAssertEqual(CommodityAccent.forCategory("frozen poultry"),  .meat)
        XCTAssertEqual(CommodityAccent.forCategory("milk and cheese"), .dairy)
        XCTAssertEqual(CommodityAccent.forCategory("vaccine"),         .pharma)
    }

    func testFloralSpecialCase() {
        // The Android source has `key == "floral"` as a strict equality
        // case in addition to the `contains("flower")` rule.
        XCTAssertEqual(CommodityAccent.forCategory("floral"), .flowers)
    }

    func testFallbackForEmptyOrUnknown() {
        XCTAssertEqual(CommodityAccent.forCategory(nil),           .fallback)
        XCTAssertEqual(CommodityAccent.forCategory(""),            .fallback)
        XCTAssertEqual(CommodityAccent.forCategory("   "),         .fallback)
        XCTAssertEqual(CommodityAccent.forCategory("electronics"), .fallback)
        XCTAssertEqual(CommodityAccent.forCategory("textiles"),    .fallback)
    }
}
