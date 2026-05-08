#if DEBUG
import Foundation

/// Spike-only configuration. Values below are placeholders — fill them in
/// before running the spike on real hardware.
///
/// Per handoff §3.10, the device password is `KBeaconIds.DEFAULT_PASSWORD`
/// on Android. Same value on iOS. Ask the Android Echo Air builder for it.
/// Do NOT commit the real password (or the test device's MAC) to public
/// history — these stay in this file as local edits, never pushed.
enum SpikeConfig {
    /// MAC address of the test S23H, e.g. "AA:BB:CC:DD:EE:FF".
    static let deviceMacAddress: String = "" // TODO: replace with real test device MAC

    /// KBeacon device password.
    /// TODO: replace with the value of `KBeaconIds.DEFAULT_PASSWORD` from
    /// the Android repo. Do not commit.
    static let devicePassword: String = ""

    /// Per-attempt connect ceiling (ms). Handoff §3.10: CONNECT_TIMEOUT_MS = 20_000.
    static let connectTimeoutMs: Int = 20_000

    /// Records per readSensorRecord call. Handoff §3.10: BATCH_SIZE = 200.
    static let batchSize: Int = 200
}
#endif
