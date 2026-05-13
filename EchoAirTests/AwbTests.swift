import XCTest
@testable import EchoAir

final class AwbTests: XCTestCase {

    // MARK: - canonicalise

    func testCanonicalisePreservesAlreadyCanonical() {
        XCTAssertEqual(Awb.canonicalise("145-12863723"), "145-12863723")
    }

    func testCanonicaliseStripsNoise() {
        XCTAssertEqual(Awb.canonicalise("14512863723"), "145-12863723")
        XCTAssertEqual(Awb.canonicalise("145 12863723"), "145-12863723")
        XCTAssertEqual(Awb.canonicalise("AWB: 145-12863723"), "145-12863723")
        XCTAssertEqual(Awb.canonicalise("145.12863723"), "145-12863723")
    }

    func testCanonicaliseRejectsWrongDigitCount() {
        XCTAssertNil(Awb.canonicalise(""))
        XCTAssertNil(Awb.canonicalise("145-1286372"))    // 10 digits
        XCTAssertNil(Awb.canonicalise("145-128637234"))  // 12 digits
        XCTAssertNil(Awb.canonicalise("abc"))             // no digits
    }

    // MARK: - isValid (the canonical case)

    func testCanonicalExampleIsValid() {
        // 1286372 % 7 = 3
        XCTAssertTrue(Awb.isValid("145-12863723"))
    }

    func testCanonicalExampleWithWrongCheckDigitIsInvalid() {
        XCTAssertFalse(Awb.isValid("145-12863724"))
    }

    func testHyphenIsOptional() {
        // Verbatim from Kotlin: AWB_PATTERN allows the hyphen to be absent.
        XCTAssertTrue(Awb.isValid("14512863723"))
    }

    func testCheckDigitCanOnlyBeZeroToSix() {
        // Mod-7 by construction; 7/8/9 are impossible as legitimate check
        // digits, so any AWB with one of those as the 8th digit is invalid.
        XCTAssertFalse(Awb.isValid("145-12863727"))
        XCTAssertFalse(Awb.isValid("145-12863728"))
        XCTAssertFalse(Awb.isValid("145-12863729"))
    }

    func testMalformedFails() {
        XCTAssertFalse(Awb.isValid(""))
        XCTAssertFalse(Awb.isValid("145"))
        XCTAssertFalse(Awb.isValid("12-12863723"))      // 2-digit prefix
        XCTAssertFalse(Awb.isValid("145-1286372"))      // 7-digit serial
    }

    // MARK: - expectedCheckDigit

    func testExpectedCheckDigitForSevenDigits() {
        XCTAssertEqual(Awb.expectedCheckDigit("1286372"), 3)
    }

    func testExpectedCheckDigitForFullSerial() {
        // 8 digits is also accepted — the function only uses the first 7.
        XCTAssertEqual(Awb.expectedCheckDigit("12863723"), 3)
        XCTAssertEqual(Awb.expectedCheckDigit("12863729"), 3) // last digit is ignored
    }

    func testExpectedCheckDigitRejectsBadInput() {
        XCTAssertNil(Awb.expectedCheckDigit(""))
        XCTAssertNil(Awb.expectedCheckDigit("12345"))       // too short
        XCTAssertNil(Awb.expectedCheckDigit("123456789"))   // too long
        XCTAssertNil(Awb.expectedCheckDigit("1234abc"))     // non-digit
    }

    // MARK: - split

    func testSplitWithHyphen() {
        let result = Awb.split("145-12863723")
        XCTAssertEqual(result?.0, "145")
        XCTAssertEqual(result?.1, "12863723")
    }

    func testSplitWithoutHyphen() {
        let result = Awb.split("14512863723")
        XCTAssertEqual(result?.0, "145")
        XCTAssertEqual(result?.1, "12863723")
    }

    func testSplitMalformedReturnsNil() {
        XCTAssertNil(Awb.split("123"))
        XCTAssertNil(Awb.split("145-1234"))
        XCTAssertNil(Awb.split("ABC-12345678"))   // letters in prefix
        XCTAssertNil(Awb.split("145-1234567A"))   // letter in serial
    }
}
