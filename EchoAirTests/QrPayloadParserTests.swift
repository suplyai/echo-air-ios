import XCTest
@testable import EchoAir

final class QrPayloadParserTests: XCTestCase {

    // MARK: - Device QR (MAC:…,SERIAL:…;)

    func testDeviceQrExtractsSerial() {
        XCTAssertEqual(
            QrPayloadParser.parse("MAC:BC:57:29:1C:D6:AC,SERIAL:S23H123456;"),
            .device(identifier: "S23H123456")
        )
    }

    func testDeviceQrWithoutTrailingSemicolon() {
        XCTAssertEqual(
            QrPayloadParser.parse("MAC:BC:57:29:1C:D6:AC,SERIAL:S23H123456"),
            .device(identifier: "S23H123456")
        )
    }

    func testDeviceQrSerialFirst() {
        XCTAssertEqual(
            QrPayloadParser.parse("SERIAL:S23H123456,MAC:BC:57:29:1C:D6:AC;"),
            .device(identifier: "S23H123456")
        )
    }

    // MARK: - AWB QR (bare 11 digits)

    func testAwbQrCanonical() {
        XCTAssertEqual(QrPayloadParser.parse("145-12863723"), .awb(awbNumber: "145-12863723"))
    }

    func testAwbQrWithoutHyphen() {
        XCTAssertEqual(QrPayloadParser.parse("14512863723"), .awb(awbNumber: "145-12863723"))
    }

    func testAwbQrWithSurroundingWhitespace() {
        XCTAssertEqual(QrPayloadParser.parse("  145-12863723  "), .awb(awbNumber: "145-12863723"))
    }

    // MARK: - Unknown

    func testEmptyPayload() {
        XCTAssertEqual(QrPayloadParser.parse(""), .unknown)
        XCTAssertEqual(QrPayloadParser.parse("   "), .unknown)
    }

    func testFreeFormText() {
        XCTAssertEqual(QrPayloadParser.parse("hello world"), .unknown)
    }

    func testUrlPayload() {
        XCTAssertEqual(QrPayloadParser.parse("https://example.com/foo"), .unknown)
    }

    func testNotEnoughDigits() {
        // 10 digits — Awb.canonicalise rejects, no SERIAL: marker.
        XCTAssertEqual(QrPayloadParser.parse("1234567890"), .unknown)
    }
}
