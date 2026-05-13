import Foundation

/// O(1) lookup of IATA carrier name from a zero-padded 3-digit airline
/// prefix (e.g. "145" → "Lan Cargo"). Backed by the `iata_prefixes.json`
/// asset bundled at build time.
///
/// Why bundled rather than fetched:
///   • Resolves instantly as the user types the third digit; no network.
///   • Works offline — warehouses have patchy signal.
///   • ~8KB asset, negligible bundle bloat.
///   • Prefix drift is roughly annual; app-release refresh is fine.
///   • Non-authoritative / informational — doesn't gate submission.
///
/// Load once at app init via `warmup()`; thereafter `carrierName(prefix:)`
/// is a pure dictionary lookup. Lookup failure returns nil — callers
/// surface "Unknown airline prefix" without blocking the user
/// (unknown prefix ≠ error).
///
/// Translated 1:1 from
/// `app/src/main/kotlin/app/suply/echoair/domain/IataCarriers.kt`.
/// Asset path matches Android: `iata_prefixes.json`.
enum IataCarriers {

    /// Returns the carrier name for `prefix`, or nil if not catalogued.
    static func carrierName(prefix: String) -> String? {
        prefixes[prefix]
    }

    /// Pre-warm the cache from app launch so the first user keystroke
    /// on the AWB prefix field hits a loaded map. Safe to call multiple
    /// times — Swift static-let initialization is dispatch-once.
    static func warmup() {
        _ = prefixes
    }

    private static let prefixes: [String: String] = {
        guard let url = Bundle.main.url(forResource: "iata_prefixes", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            print("[IataCarriers] iata_prefixes.json missing from app bundle")
            return [:]
        }
        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            print("[IataCarriers] iata_prefixes.json decode failed: \(error)")
            return [:]
        }
    }()
}
