import Foundation

/// IATA Air Waybill (AWB) number parsing + validation.
///
/// Format (industry-standard): `XXX-XXXXXXXX`
///   - 3-digit airline prefix (IATA carrier numeric code, e.g. 057 = Air France)
///   - 8-digit serial; last digit is a mod-7 check digit on the first 7.
///
/// Reference: IATA Cargo-XML / Resolution 600a. By construction the
/// check digit can only be 0-6; any AWB that parses cleanly but has
/// an 8th digit of 7-9 is invalid.
///
/// Example: `145-12863723`
///   prefix: 145, serial: 12863723, first-7: 1286372, 1286372 % 7 = 3 ✓
///
/// Translated 1:1 from `app/src/main/kotlin/app/suply/echoair/domain/Awb.kt`.
enum Awb {

    /// Coerce `input` into canonical `XXX-XXXXXXXX` form by extracting
    /// digits. Accepts `"145-12863723"`, `"14512863723"`, `"145 12863723"`,
    /// `"AWB: 145-12863723"`, etc. Returns nil if the input doesn't
    /// contain exactly 11 digits.
    static func canonicalise(_ input: String) -> String? {
        let digits = input.filter(\.isNumber)
        guard digits.count == 11 else { return nil }
        let prefix = digits.prefix(3)
        let serial = digits.dropFirst(3)
        return "\(prefix)-\(serial)"
    }

    /// True iff `awb` matches the pattern AND the check digit matches.
    /// **Note:** the hyphen is optional per the Kotlin reference — both
    /// `"145-12863723"` and `"14512863723"` pass.
    static func isValid(_ awb: String) -> Bool {
        guard let (_, serial) = split(awb) else { return false }
        guard serial.count == 8 else { return false }
        guard let actual = serial.last?.wholeNumberValue else { return false }
        return checkDigit(of: serial) == actual
    }

    /// Returns the expected check digit for `serial`'s first 7 digits, or
    /// nil if `serial` isn't 7 or 8 pure digits. Useful while the user is
    /// typing — the UI can surface the expected digit inline.
    static func expectedCheckDigit(_ serial: String) -> Int? {
        guard (7...8).contains(serial.count),
              serial.allSatisfy(\.isNumber) else {
            return nil
        }
        return checkDigit(of: serial)
    }

    /// Splits `XXX-XXXXXXXX` (hyphen optional) into `(prefix, serial)`, or nil.
    static func split(_ awb: String) -> (String, String)? {
        guard let match = awb.wholeMatch(of: pattern) else { return nil }
        return (String(match.output.1), String(match.output.2))
    }

    private static func checkDigit(of serial: String) -> Int {
        // First 7 digits fit in Int (max 9_999_999) on all targets.
        Int(serial.prefix(7))! % 7
    }

    /// `Regex<Output>` isn't `Sendable` in Swift 6, but this pattern is
    /// initialised once at type-load time and only read after that.
    /// `nonisolated(unsafe)` opts out of strict-concurrency checking for
    /// this single property; safe because the value is immutable.
    nonisolated(unsafe) private static let pattern = /^(\d{3})-?(\d{8})$/
}
