import Foundation

/// Parses QR payloads scanned by the device-QR camera flow into one of
/// three outcomes:
///
///   • `.device(identifier:)` — payload contains `MAC:…,SERIAL:…;`
///     markers. The SERIAL value is extracted as the identifier passed
///     to `/api/devices/lookup`.
///   • `.awb(awbNumber:)` — payload canonicalises to a valid AWB shape
///     (11 digits, optionally hyphenated). Passed to
///     `/api/vision/identify-shipment`.
///   • `.unknown` — anything else. The capture VM surfaces
///     `Failure.unrecognisedQr`.
///
/// Vendored on iOS from the shape documented in `CaptureViewModel.kt`'s
/// `onQrPayload` comment — the Kotlin parser source wasn't shared. This
/// is a best-effort translation; verify on first scan against a real
/// device QR before assuming the SERIAL-as-identifier choice matches
/// the Android side.
enum QrPayloadParser {
    enum Parsed: Equatable {
        case device(identifier: String)
        case awb(awbNumber: String)
        case unknown
    }

    static func parse(_ payload: String) -> Parsed {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unknown }

        // Device QR — extract the value after `SERIAL:` up to the next
        // separator (comma, semicolon, or end-of-string).
        if let serial = extractValue(in: trimmed, forKey: "SERIAL:"), !serial.isEmpty {
            return .device(identifier: serial)
        }

        // Label QR — bare AWB number. Reuse the validator's canonicaliser
        // so the same shape rules (11 digits, optional hyphen) apply.
        if let canonical = Awb.canonicalise(trimmed) {
            return .awb(awbNumber: canonical)
        }

        return .unknown
    }

    /// Extracts the value for `key` from a `KEY:value` segment in a
    /// comma/semicolon-separated payload. Returns nil if the key isn't
    /// present.
    private static func extractValue(in payload: String, forKey key: String) -> String? {
        guard let keyRange = payload.range(of: key) else { return nil }
        let after = payload[keyRange.upperBound...]
        let terminators: Set<Character> = [",", ";"]
        let endIndex = after.firstIndex(where: { terminators.contains($0) }) ?? after.endIndex
        let value = after[after.startIndex..<endIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }
}
