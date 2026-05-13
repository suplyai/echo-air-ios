#if DEBUG
import Foundation

/// Spike-only configuration. Values come from `Config/Local.xcconfig`
/// (gitignored) via Info.plist `$(VAR)` substitution — keeping test
/// credentials in one gitignored place rather than scattered across
/// source files.
///
/// To run the spike, fill in `SPIKE_DEVICE_MAC` and `SPIKE_DEVICE_PASSWORD`
/// in `Config/Local.xcconfig`. Both default to empty in Shared.xcconfig,
/// so missing/unset values just disable the spike (SpikeRunner aborts
/// with an empty-config message rather than connecting to nothing).
///
/// Per handoff §3.10, the device password is `KBeaconIds.DEFAULT_PASSWORD`
/// on Android — same value on iOS. Ask the Android Echo Air builder.
enum SpikeConfig {
    /// MAC address of the test S23H, e.g. "AA:BB:CC:DD:EE:FF". Sourced
    /// from `SPIKE_DEVICE_MAC` in Local.xcconfig.
    static var deviceMacAddress: String {
        infoDictionaryString("SPIKE_DEVICE_MAC")
    }

    /// KBeacon device password. Sourced from `SPIKE_DEVICE_PASSWORD` in
    /// Local.xcconfig.
    static var devicePassword: String {
        infoDictionaryString("SPIKE_DEVICE_PASSWORD")
    }

    /// Per-attempt connect ceiling (ms). Handoff §3.10: CONNECT_TIMEOUT_MS = 20_000.
    static let connectTimeoutMs: Int = 20_000

    /// Records per readSensorRecord call. Handoff §3.10: BATCH_SIZE = 200.
    static let batchSize: Int = 200

    private static func infoDictionaryString(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
    }
}
#endif
