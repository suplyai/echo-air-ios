import Foundation
@preconcurrency import kbeaconlib2

/// Production-path BLE scanner. Wraps `KBeaconsMgr.sharedBeaconManager`
/// scan + match-by-MAC + stopScanning behind a single `async` call so the
/// collection orchestrator doesn't have to repeat the delegate dance for
/// every device in the shipment.
///
/// The discovery pattern (delegate set at entry, cleared at exit; 15s
/// ceiling enforced via Timer; non-Sendable `KBeacon` re-looked-up by
/// uuid from the manager's beacons dict after a `Task @MainActor` hop)
/// is proven by `SpikeRunner` in Phase 2 — this is the same flow with
/// the `#if DEBUG` shell removed. SpikeRunner stays as a manual,
/// human-interpreted single-device probe; this scanner is the multi-
/// device call that the orchestrator uses serially.
///
/// Threading: `@MainActor` because all of the SDK's CoreBluetooth
/// callbacks land on main (KBeaconsMgr inits CBCentralManager without
/// a custom queue) and the orchestrator is also main-isolated.
/// Delegate methods are `nonisolated` and hop back via `Task @MainActor`,
/// matching SpikeRunner.
@MainActor
final class KBeaconScanner: NSObject {

    /// Same shape as `SpikeRunner.SpikeError` — associated values are
    /// `String` (not the SDK's non-Sendable `BLECentralMgrState`) so the
    /// enum stays auto-`Sendable` and can cross the `async` boundary.
    enum ScannerError: Error, CustomStringConvertible {
        case bleUnavailable(state: String)
        case scanRefused
        case discoveryTimeout(seconds: Int)
        case bleStateChangedMidScan(state: String)

        var description: String {
            switch self {
            case .bleUnavailable(let s):
                return "BLE unavailable (state=\(s))"
            case .scanRefused:
                return "KBeaconsMgr.startScanning() returned false"
            case .discoveryTimeout(let s):
                return "target device not discovered within \(s)s"
            case .bleStateChangedMidScan(let s):
                return "BLE state changed mid-scan: \(s)"
            }
        }
    }

    private var discoveryContinuation: CheckedContinuation<KBeacon, Error>?
    private var discoveryTimer: Timer?
    private var targetMacUppercased: String = ""

    /// Scan until a beacon with `mac` is discovered, then stop scanning
    /// and return it. Throws on `.bleUnavailable` (radio off / permission
    /// missing), `.scanRefused` (SDK said no), `.discoveryTimeout` (device
    /// not in range or not advertising), or `.bleStateChangedMidScan`
    /// (radio went off while we were waiting).
    ///
    /// Caller owns the returned `KBeacon` — disconnect via the bridge's
    /// underlying `beacon.disconnect()` when finished.
    func discover(mac: String, timeoutSec: TimeInterval = 15) async throws -> KBeacon {
        targetMacUppercased = mac.uppercased()
        let mgr = KBeaconsMgr.sharedBeaconManager

        // startScanning() returns false silently on off / unauthorized /
        // unknown — without this pre-check, that path would surface as
        // "device not present" rather than "BLE off".
        guard mgr.centralBLEState == .PowerOn else {
            throw ScannerError.bleUnavailable(state: String(describing: mgr.centralBLEState))
        }

        mgr.delegate = self
        guard mgr.startScanning() else {
            mgr.delegate = nil
            throw ScannerError.scanRefused
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<KBeacon, Error>) in
            self.discoveryContinuation = cont
            // The SDK doesn't impose a scan ceiling; a device that never
            // advertises would otherwise hang the orchestrator forever.
            self.discoveryTimer = Timer.scheduledTimer(
                withTimeInterval: timeoutSec,
                repeats: false
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.finishDiscovery(throwing: ScannerError.discoveryTimeout(seconds: Int(timeoutSec)))
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
}

extension KBeaconScanner: KBeaconMgrDelegate {
    // KBeaconMgrDelegate is @objc; the SDK may dispatch from any queue.
    // In practice these land on main, but mark nonisolated and hop back
    // to MainActor under strict concurrency.
    nonisolated func onBeaconDiscovered(beacons: [KBeacon]) {
        // The SDK formats discovered MACs via "%02X:..." (uppercase).
        // Capture into Sendable values before crossing into MainActor.
        let macs: [(uuid: String, mac: String?)] = beacons.map { ($0.uuidString ?? "", $0.mac) }
        Task { @MainActor in
            let target = self.targetMacUppercased
            guard let match = macs.first(where: { $0.mac?.uppercased() == target }) else {
                return    // not our device yet; keep scanning
            }
            // Re-look up the KBeacon by uuid from the manager's beacons
            // dict — the `[KBeacon]` array isn't Sendable so we can't
            // capture it across the actor hop directly.
            if let beacon = KBeaconsMgr.sharedBeaconManager.beacons[match.uuid] {
                self.finishDiscovery(returning: beacon)
            }
        }
    }

    nonisolated func onCentralBleStateChange(newState: BLECentralMgrState) {
        // Convert the non-Sendable BLECentralMgrState to Sendable values
        // BEFORE the Task @MainActor hop.
        let isPowerOn = (newState == .PowerOn)
        let stateDescription = String(describing: newState)
        Task { @MainActor in
            guard !isPowerOn else { return }
            self.finishDiscovery(throwing: ScannerError.bleStateChangedMidScan(state: stateDescription))
        }
    }
}
