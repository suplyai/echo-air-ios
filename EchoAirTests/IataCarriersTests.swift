import XCTest
@testable import EchoAir

final class IataCarriersTests: XCTestCase {

    /// Smoke test: asset loads from the bundle and known prefixes resolve.
    /// Catches packaging regressions (e.g. xcodegen failing to add the
    /// JSON to the resources phase, or pod install reshuffling resources).
    func testKnownPrefixesResolve() {
        XCTAssertEqual(IataCarriers.carrierName(prefix: "057"), "Air France")
        XCTAssertEqual(IataCarriers.carrierName(prefix: "145"), "Lan Cargo")
        XCTAssertEqual(IataCarriers.carrierName(prefix: "999"), "Air China Limited")
    }

    func testUnknownPrefixesReturnNil() {
        // Gaps in the catalogue (e.g. 002, 003 not present).
        XCTAssertNil(IataCarriers.carrierName(prefix: "002"))
        XCTAssertNil(IataCarriers.carrierName(prefix: "003"))
        // Garbage input — caller surfaces "Unknown airline prefix", not error.
        XCTAssertNil(IataCarriers.carrierName(prefix: ""))
        XCTAssertNil(IataCarriers.carrierName(prefix: "abc"))
        XCTAssertNil(IataCarriers.carrierName(prefix: "9999"))
    }
}
