import Foundation

/// Production-path accessor for the KBeacon device password.
///
/// Echo Air's S23H fleet ships with the KKM factory default password —
/// a single shared value applied to every device, never re-provisioned
/// per shipment. Android stores it as `KBeaconIds.DEFAULT_PASSWORD`; on
/// iOS we keep it out of source by reading the same value the spike
/// harness already plumbs through:
///
///   Config/Local.xcconfig (gitignored, holds the real password)
///   → Info.plist `$(SPIKE_DEVICE_PASSWORD)` substitution
///   → `Bundle.main.object(forInfoDictionaryKey:)` at runtime
///
/// `SpikeConfig.devicePassword` reads the same key but is gated under
/// `#if DEBUG`, so production builds can't reach it. This accessor is
/// the non-DEBUG counterpart used by the Phase 5 collection
/// orchestrator. The `SPIKE_` prefix on the underlying key is cosmetic
/// — the value is identical between test devices and the production
/// fleet (handoff §3.10 + builder confirmation 2026-05).
enum KBeaconCredentials {
    /// Sourced from `SPIKE_DEVICE_PASSWORD` in Local.xcconfig. Empty
    /// string when Local.xcconfig wasn't filled in (which will cause
    /// `KBeaconBridge.connect` to throw `.requestRejected` rather than
    /// hang — the bridge enforces the SDK's 8-16 char rule up front).
    static var password: String {
        (Bundle.main.object(forInfoDictionaryKey: "SPIKE_DEVICE_PASSWORD") as? String) ?? ""
    }
}
