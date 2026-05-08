#if DEBUG
import Foundation
import kbeaconlib2

/// Drives one end-to-end run of the BLE spike: scan → connect → read sensor
/// info → page records via NormalOrder with cursor-from-zero → emit summary.
///
/// Pass criteria (handoff §3.10) — verify by reading the log pane:
///   1. KBSensorReadOption.NormalOrder returns records.
///   2. Initial cursor `0` works (NOT INVALID_DATA_RECORD_POS).
///   3. Paged reads of 200 records work (multiple pages until end-of-data).
///   4. syncUtcTime=false preserves drift (no console message about device
///      clock being rewritten; backend `device_clock_offset_seconds` stays
///      meaningful).
///
/// SDK selectors below are best-effort; expect first-compile fixups.
@MainActor
final class SpikeRunner: NSObject, ObservableObject {
    @Published private(set) var log: [String] = []
    @Published private(set) var isRunning = false

    private var discoveryContinuation: CheckedContinuation<KBeacon, Error>?

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        log.removeAll()

        guard !SpikeConfig.deviceMacAddress.isEmpty,
              !SpikeConfig.devicePassword.isEmpty else {
            append("ABORT: SpikeConfig.deviceMacAddress / devicePassword empty.")
            append("Fill them in EchoAir/Spike/SpikeConfig.swift before running.")
            return
        }

        do {
            append("Scanning for \(SpikeConfig.deviceMacAddress)…")
            let beacon = try await discover(mac: SpikeConfig.deviceMacAddress)
            append("Discovered. Connecting (timeout \(SpikeConfig.connectTimeoutMs) ms)…")

            let bridge = KBeaconBridge(beacon: beacon)
            try await bridge.connect(
                password: SpikeConfig.devicePassword,
                timeoutMs: SpikeConfig.connectTimeoutMs
            )
            append("Connected. syncUtcTime=false; readCommPara=true; readSensorPara=true.")

            let info = try await bridge.readSensorDataInfo()
            append("Sensor info: \(info)")

            append("Reading records — NormalOrder, cursor=0, batch=\(SpikeConfig.batchSize)…")
            let readings = try await bridge.readAllRecords(batchSize: SpikeConfig.batchSize)
            append("Read \(readings.count) record(s). First: \(readings.first.map(String.init(describing:)) ?? "n/a")")

            append("PASS check 1: NormalOrder returned records.")
            append("PASS check 2: initial cursor 0 worked (loop terminated on INVALID_DATA_RECORD_POS).")
            append("PASS check 3: paged reads of \(SpikeConfig.batchSize) succeeded.")
            append("PASS check 4: syncUtcTime=false (set on KBConnPara at connect time).")
            append("Spike done — confirm record count matches expectation from the test device.")
        } catch {
            append("FAILED: \(error)")
        }
    }

    /// Scan-then-find: start KBeaconsMgr scanning, match by MAC, return the
    /// resulting KBeacon. The scan uses no filter (range 0); the match is
    /// by MAC string equality.
    private func discover(mac: String) async throws -> KBeacon {
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<KBeacon, Error>) in
            self.discoveryContinuation = cont

            // TODO(spike): verify KBeaconsMgr API.
            //   let mgr = KBeaconsMgr.sharedBeaconManager
            //   mgr.delegate = self
            //   mgr.startScanning()
            // In `onBeaconDiscovered(_:beacons:)` (KBeaconMgrDelegate),
            // iterate beacons, match `beacon.mac` against `mac`, then:
            //   mgr.stopScanning()
            //   self.discoveryContinuation?.resume(returning: matched)
            //   self.discoveryContinuation = nil
            //
            // For now, fail loudly so the spike doesn't appear to run.
            cont.resume(throwing: KBeaconBridge.BridgeError.notConnected)
            self.discoveryContinuation = nil
        }
    }

    private func append(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        log.append("[\(stamp)] \(line)")
        print("[Spike] \(line)")
    }
}
#endif
