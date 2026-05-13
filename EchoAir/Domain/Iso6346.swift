import Foundation

/// ISO 6346 ocean shipping container number parsing + validation.
///
/// Format: `OOOO U SSSSSS C`
///   - 4-letter owner code (3 letters + category identifier U/J/Z)
///   - 6-digit serial
///   - 1-digit check digit
///
/// Example: `EITU 317174 1` → owner EITU, serial 317174, check 1
///
/// Check digit algorithm:
///   1. Each of the first 10 characters maps to a numeric value. Digits
///      map to themselves; letters start at 10 and skip every multiple
///      of 11 (A=10, B=12, …, K=21, L=23, …, U=32, V=34, …, Z=38).
///   2. Multiply each value by `2^position` (position 0..9 leftmost first).
///   3. Sum products, take `mod 11`. If the result is 10, the check digit
///      is 0 — known quirk of the standard. Most generators avoid such
///      numbers but a few legit ones exist; we must accept them or block
///      legitimate cargo.
///
/// Spec example verified: "EITU3171741" → sum=4929, 4929 mod 11 = 1 ✓
///
/// Vendored (not via SPM) per Phase 3 decision — the algorithm is ~50
/// lines, fully specified, no transitive dependencies. Cross-referenced
/// against `app/src/main/kotlin/app/suply/echoair/domain/Iso6346.kt`.
enum Iso6346 {

    /// Coerce `input` into canonical 11-char form by stripping
    /// non-alphanumerics and uppercasing. Returns the cleaned string
    /// regardless of length so the UI can run `isWellFormed` against it
    /// and surface format errors inline; use `isValid` for the full check.
    static func canonicalise(_ input: String) -> String {
        input.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// True iff `canonical` is exactly 4 uppercase letters followed by 7 digits.
    static func isWellFormed(_ canonical: String) -> Bool {
        canonical.wholeMatch(of: wellFormed) != nil
    }

    /// Two-stage validation: well-formed AND the trailing digit matches
    /// the check digit computed from the first 10 characters. Inputs that
    /// fail `isWellFormed` short-circuit to false so callers can use this
    /// for the final accept/reject decision.
    static func isValid(_ canonical: String) -> Bool {
        guard isWellFormed(canonical) else { return false }
        guard let expected = computedCheckDigit(canonical) else { return false }
        guard let actual = canonical.last?.wholeNumberValue else { return false }
        return expected == actual
    }

    /// Expected check digit (0-9) for `canonical`'s first 10 characters,
    /// or nil if those 10 aren't a valid prefix (4 letters + 6 digits).
    /// Useful for inline hinting while the user types the trailing digit.
    static func computedCheckDigit(_ canonical: String) -> Int? {
        guard canonical.count >= 10 else { return nil }
        let prefix = canonical.prefix(10)
        guard String(prefix).wholeMatch(of: prefixPattern) != nil else { return nil }

        var sum: Int64 = 0
        for (i, c) in prefix.enumerated() {
            guard let v = charValue(c) else { return nil }
            sum += Int64(v) << i    // 2^i
        }
        // The mod-10 wrap is the standard's quirk: raw 10 collapses to 0.
        return Int((sum % 11) % 10)
    }

    private static func charValue(_ c: Character) -> Int? {
        if let digit = c.wholeNumberValue, c.isASCII, digit < 10 {
            return digit
        }
        // ASCII uppercase letter? 'A'..'Z' = 65..90.
        if let ascii = c.asciiValue, (65...90).contains(ascii) {
            return letterValues[Int(ascii) - 65]
        }
        return nil
    }

    /// Letter values per ISO 6346: A starts at 10, every multiple of 11
    /// (11, 22, 33) is skipped. Indexed by `c - 'A'`.
    private static let letterValues: [Int] = [
        10, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 23, 24,
        25, 26, 27, 28, 29, 30, 31, 32, 34, 35, 36, 37, 38
    ]

    private static let wellFormed = /^[A-Z]{4}\d{7}$/
    private static let prefixPattern = /^[A-Z]{4}\d{6}$/
}
