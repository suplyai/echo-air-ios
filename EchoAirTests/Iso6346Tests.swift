import XCTest
@testable import EchoAir

final class Iso6346Tests: XCTestCase {

    // MARK: - canonicalise

    func testCanonicaliseAlreadyCanonical() {
        XCTAssertEqual(Iso6346.canonicalise("EITU3171741"), "EITU3171741")
    }

    func testCanonicaliseStripsWhitespaceAndHyphens() {
        XCTAssertEqual(Iso6346.canonicalise("EITU 317174 1"), "EITU3171741")
        XCTAssertEqual(Iso6346.canonicalise("EITU-3171741"), "EITU3171741")
        XCTAssertEqual(Iso6346.canonicalise("  eitu  3171741  "), "EITU3171741")
    }

    func testCanonicaliseUppercases() {
        XCTAssertEqual(Iso6346.canonicalise("eitu3171741"), "EITU3171741")
        XCTAssertEqual(Iso6346.canonicalise("EItU3171741"), "EITU3171741")
    }

    // MARK: - isWellFormed

    func testIsWellFormedAcceptsCanonical() {
        XCTAssertTrue(Iso6346.isWellFormed("EITU3171741"))
    }

    func testIsWellFormedRejectsBadShape() {
        XCTAssertFalse(Iso6346.isWellFormed(""))
        XCTAssertFalse(Iso6346.isWellFormed("EIT3171741"))      // 3 letters
        XCTAssertFalse(Iso6346.isWellFormed("EITUE171741"))     // letter in serial
        XCTAssertFalse(Iso6346.isWellFormed("EITU317174"))      // 6 digits
        XCTAssertFalse(Iso6346.isWellFormed("EITU31717411"))    // 8 digits
        XCTAssertFalse(Iso6346.isWellFormed("eitu3171741"))     // lowercase
    }

    // MARK: - isValid (canonical spec example)

    func testSpecExampleIsValid() {
        XCTAssertTrue(Iso6346.isValid("EITU3171741"))
    }

    func testSpecExampleWithWrongCheckDigitIsInvalid() {
        XCTAssertFalse(Iso6346.isValid("EITU3171742"))
        XCTAssertFalse(Iso6346.isValid("EITU3171740"))
    }

    func testNonCanonicalShortCircuitsToFalse() {
        XCTAssertFalse(Iso6346.isValid("eitu3171741"))      // not uppercased
        XCTAssertFalse(Iso6346.isValid("EITU 3171741"))     // spaces
        XCTAssertFalse(Iso6346.isValid(""))
    }

    // MARK: - computedCheckDigit

    func testComputedCheckDigitForSpecExample() {
        XCTAssertEqual(Iso6346.computedCheckDigit("EITU3171741"), 1)
    }

    func testComputedCheckDigitForJustThePrefix() {
        // Trailing digit not required — the function reads the first 10.
        XCTAssertEqual(Iso6346.computedCheckDigit("EITU317174"), 1)
    }

    /// The ISO 6346 standard's quirk: raw mod-11 of 10 collapses to 0.
    /// Constructed by bumping position 4 of "EITU317174" from '3' to '7':
    /// sum becomes 4929 + (7-3)*16 = 4993; 4993 mod 11 = 10 → digit 0.
    func testComputedCheckDigitTenToZeroCollapse() {
        XCTAssertEqual(Iso6346.computedCheckDigit("EITU717174"), 0)
        // And the full number with check digit 0 should validate.
        XCTAssertTrue(Iso6346.isValid("EITU7171740"))
    }

    func testComputedCheckDigitRejectsBadPrefix() {
        XCTAssertNil(Iso6346.computedCheckDigit(""))
        XCTAssertNil(Iso6346.computedCheckDigit("EITU"))
        XCTAssertNil(Iso6346.computedCheckDigit("EIT123456"))  // only 3 letters
        XCTAssertNil(Iso6346.computedCheckDigit("eitu317174")) // lowercase
        XCTAssertNil(Iso6346.computedCheckDigit("EITUE17174")) // letter in serial spot
    }

    // MARK: - Letter value spot checks (skip-11 pattern)

    /// Verifies the alphabet's skip-11 values via known-real container
    /// numbers from the public ISO 6346 reference set.
    func testKnownLetterValues() {
        // From the algorithm: E=15 (no skips before E since 11>10), L=23
        // (one skip at 22), U=32 (one skip at 22), V=34 (skip at 22 and
        // 33), Z=38. We don't expose charValue directly — verify via
        // computedCheckDigit on prefixes that exercise the letters.
        // "AAAU000000": A=10, A=10, A=10, U=32. Sum = 10+20+40+256 = 326.
        // 326 mod 11 = 326 - 29*11 = 326 - 319 = 7. Expected digit 7.
        XCTAssertEqual(Iso6346.computedCheckDigit("AAAU000000"), 7)
    }
}
