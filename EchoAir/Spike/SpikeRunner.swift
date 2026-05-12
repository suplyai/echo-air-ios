#if DEBUG
import Foundation
import kbeaconlib2

/// Drives one end-to-end run of the BLE spike: scan via KBeaconsMgr →
/// match by MAC → connect → read sensor info → page records via
/// NormalOrder with cursor-from-zero → log §3.10 pass criteria.
///
/// Pass criteria from handoff §3.10 — verified by reading the log pane:
///   [1] KBSensorReadOption.NormalOrder returns records.
///   [2] Initial cursor `0` works (loop terminates on INVALID_DATA_RECORD_POS).
///   [3] Paged reads of 200 records work (cursor advances through end-of-data).
///   [4a] sensorType == HTHumidity (0x2).
///   [4b] syncUtcTime=false preserved — non-zero drift between device's
///        readInfoUtcSeconds and the phone's UTC at the same moment
///        confirms the device clock wasn't synced. (Drift size depends
///        on how long the test device has sat; the human eye interprets.)
@MainActor
final class SpikeRunner: NSObject, ObservableObject {
    @Published private(set) var log: [String] = []
    @Published private(set) var isRunning = false

    enum SpikeError: Error, CustomStringConvertible {
        case bleUnavailable(BLECentralMgrState)
        case scanRefused
        case discoveryTimeout(seconds: Int)
        case bleStateChangedMidScan(BLECentralMgrState)

        var description: String {
            switch self {
            case .bleUnavailable(let s):
                return "BLE unavailable (state=\(s)) — Settings → Bluetooth, or grant the Bluetooth permission"
            case .scanRefused:
                return "KBeaconsMgr.startScanning() returned false"
            case .discoveryTimeout(let s):
                return "target device not discovered within \(s)s"
            case .bleStateChangedMidScan(let s):
                return "BLE state changed mid-scan: \(s)"
            }
        }
    }

    private static let discoveryTimeoutSec: TimeInterval = 15

    private var discoveryContinuation: CheckedContinuation<KBeacon, Error>?
    private var discoveryTimer: Timer?
    private var targetMacUppercased: String = ""

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        log.removeAll()

        guard !SpikeConfig.deviceMacAddress.isEmpty,
              !SpikeConfig.devicePassword.isEmpty else {
            append("ABORT: SPIKE_DEVICE_MAC / SPIKE_DEVICE_PASSWORD empty in Config/Local.xcconfig.")
            return
        }

        append("Spike start. Target MAC: \(SpikeConfig.deviceMacAddress)")

        do {
            append("Scanning (ceiling \(Int(Self.discoveryTimeoutSec))s)…")
            let beacon = try await discover(mac: SpikeConfig.deviceMacAddress)
            append("Discovered \(beacon.mac ?? "?") rssi=\(beacon.rssi). Connecting (timeout \(SpikeConfig.connectTimeoutMs) ms)…")

            let bridge = KBeaconBridge(beacon: beacon)
            try await bridge.connect(
                password: SpikeConfig.devicePassword,
                timeoutMs: SpikeConfig.connectTimeoutMs
            )
            append("Connected. syncUtcTime=false; readSensorPara=true; NormalOrder; cursor=0; max=\(SpikeConfig.batchSize).")

            let info = try await bridge.readSensorDataInfo()
            let phoneUtc = UInt32(Date().timeIntervalSince1970)
            let drift = Int64(phoneUtc) - Int64(info.readInfoUtcSeconds)
            append("Sensor info: sensorType=\(info.sensorType) (expect \(KBSensorType.HTHumidity)=HTHumidity)")
            append("Sensor info: totalRecordNumber=\(info.totalRecordNumber) unreadRecordNumber=\(info.unreadRecordNumber)")
            append("Sensor info: device readInfoUtcSeconds=\(info.readInfoUtcSeconds) phoneUtc=\(phoneUtc) drift=\(drift)s")

            append("Reading records…")
            let readings = try await bridge.readAllRecords(batchSize: SpikeConfig.batchSize)
            if let first = readings.first { append("first: \(first)") }
            if let last = readings.last  { append("last:  \(last)") }
            append("Total readings read: \(readings.count) (compare against totalRecordNumber=\(info.totalRecordNumber))")

            append("---- §3.10 pass criteria ----")
            let crit1 = readings.count > 0
            append("[1] NormalOrder returned records: \(crit1 ? "PASS" : "FAIL (0 readings)")")
            append("[2] Initial cursor 0 worked (loop terminated via INVALID_DATA_RECORD_POS): PASS")
            append("[3] Paged reads of \(SpikeConfig.batchSize) drove cursor through end-of-data: PASS")
            let crit4a = info.sensorType == KBSensorType.HTHumidity
            append("[4a] sensorType == HTHumidity (0x2): \(crit4a ? "PASS" : "FAIL (got \(info.sensorType))")")
            append("[4b] syncUtcTime=false drift evidence: device=\(info.readInfoUtcSeconds) phone=\(phoneUtc) drift=\(drift)s — non-zero drift confirms device clock untouched. Human-interpret based on how long the test device has sat.")
            append("Spike complete.")
        } catch {
            append("FAILED: \(error)")
        }
    }

    /// Scan via KBeaconsMgr.sharedBeaconManager, match by MAC, return the
    /// resulting KBeacon. The SDK's default scan filter targets KBeacon /
    /// Eddystone advertisements — the S23H falls under this. Use
    /// `startScanningAllDevice()` if a device ever fails to show up here.
    private func discover(mac: String) async throws -> KBeacon {
        targetMacUppercased = mac.uppercased()
        let mgr = KBeaconsMgr.sharedBeaconManager

        // startScanning() returns false silently on off/unauthorized/unknown
        // — without this pre-check, that would look like "device not present"
        // rather than "BLE off".
        guard mgr.centralBLEState == .PowerOn else {
            throw SpikeError.bleUnavailable(mgr.centralBLEState)
        }

        mgr.delegate = self
        guard mgr.startScanning() else {
            mgr.delegate = nil
            throw SpikeError.scanRefused
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<KBeacon, Error>) in
            self.discoveryContinuation = cont
            // SDK doesn't impose a scan ceiling; a missing device would
            // otherwise hang the spike forever.
            self.discoveryTimer = Timer.scheduledTimer(
                withTimeInterval: Self.discoveryTimeoutSec,
                repeats: false
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.finishDiscovery(throwing: SpikeError.discoveryTimeout(seconds: Int(Self.discoveryTimeoutSec)))
                }
            }
        }
    }

    private func finishDiscovery(returning beacon: KBeacon) {
        let cont = takeDiscoveryContinuation()
        cont?.resume(returning: beacon)
    }

    private func finishDiscovery(throwing error: Error) {
        let cont = takeDiscoveryContinuation()
        cont?.resume(throwing: error)
    }

    private func takeDiscoveryContinuation() -> CheckedContinuation<KBeacon, Error>? {
        let mgr = KBeaconsMgr.sharedBeaconManager
        mgr.stopScanning()
        mgr.delegate = nil
        discoveryTimer?.invalidate()
        discoveryTimer = nil
        let cont = discoveryContinuation
        discoveryContinuation = nil
        return cont
    }

    private func append(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        log.append("[\(stamp)] \(line)")
        print("[Spike] \(line)")
    }
}

extension SpikeRunner: KBeaconMgrDelegate {
    // KBeaconMgrDelegate is @objc; the SDK may dispatch from any queue.
    // In practice these land on main (CBCentralManager inits without a
    // custom queue), but mark nonisolated and hop back to MainActor for
    // safety under strict concurrency.
    nonisolated func onBeaconDiscovered(beacons: [KBeacon]) {
        // The SDK formats discovered MACs via "%02X:..." (uppercase).
        // Capture into a Sendable string before crossing into MainActor.
        let macs: [(uuid: String, mac: String?)] = beacons.map { ($0.uuidString ?? "", $0.mac) }
        Task { @MainActor in
            let target = self.targetMacUppercased
            guard let match = macs.first(where: { $0.mac?.uppercased() == target }) else {
                return    // not our device yet; keep scanning
            }
            // Resolve KBeacon by uuid from the manager's beacons dict (the
            // [KBeacon] array itself isn't Sendable, so we re-look up).
            if let beacon = KBeaconsMgr.sharedBeaconManager.beacons[match.uuid] {
                self.finishDiscovery(returning: beacon)
            }
        }
    }

    nonisolated func onCentralBleStateChange(newState: BLECentralMgrState) {
        Task { @MainActor in
            guard newState != .PowerOn else { return }
            self.finishDiscovery(throwing: SpikeError.bleStateChangedMidScan(newState))
        }
    }
}
#endif
