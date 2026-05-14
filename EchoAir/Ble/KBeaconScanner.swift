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

    /// Per-attempt scan ceiling. Widened from 15s to 25s so the
    /// SDK has time to: (1) deliver enough `didDiscover` callbacks
    /// for the device's System advertisement slot to arrive on the
    /// air (KKM devices round-robin slots; the System slot is one
    /// of several), AND (2) fire its internal batched
    /// `delayReportAdvTimer` so our `onBeaconDiscovered` delegate
    /// gets called with the KBeacon in its System-parsed state.
    /// 15s was on the edge in practice on real hardware.
    static let defaultTimeoutSec: TimeInterval = 25

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
    func discover(mac: String, timeoutSec: TimeInterval = KBeaconScanner.defaultTimeoutSec) async throws -> KBeacon {
        targetMacUppercased = mac.uppercased()
        let mgr = KBeaconsMgr.sharedBeaconManager

        // startScanning() returns false silently on off / unauthorized /
        // unknown — without this pre-check, that path would surface as
        // "device not present" rather than "BLE off".
        guard mgr.centralBLEState == .PowerOn else {
            throw ScannerError.bleUnavailable(state: String(describing: mgr.centralBLEState))
        }

        mgr.delegate = self
        // Match KKM's own working demo
        // (github.com/kkmhogen/KBeaconProDemo_Ios, RootViewController.swift)
        // exactly: `startScanning()` with the SDK's default
        // PARCE_UUID_KB_EXT_DATA + PARCE_UUID_EDDYSTONE service-UUID
        // filter. PR #9 originally switched this to
        // `startScanningAllDevice()` (nil services) on the theory that
        // wider scans strictly dominate filtered scans for discovery.
        // That reasoning is wrong on iOS: with nil services CoreBluetooth
        // coalesces / drops scan-response packets differently, so the
        // secondary advertisement carrying KKM's `KBAdvType.System`
        // payload (the only place `KBeacon.mac` is parsed from
        // pre-connect) may not reach `parseAdvPacket` intact. Filtered
        // mode tells iOS to wait for and bundle the scan response with
        // the primary, which is what the SDK's MAC parser needs. KKM's
        // production-quality demo uses the filtered form; we match it.
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
        // Read the parsed System packet's `macAddress` directly via
        // the SDK's public `getAvPacketByType(_:)` accessor, rather
        // than relying on `KBeacon.mac`.
        //
        // Why bypass `KBeacon.mac`: it has a four-path fallback chain
        // in the SDK (path 1 = System packet macAddress, path 2 =
        // mAdvPacketMgr.mAdvMacAddress set in the EXT_DATA service
        // branch under specific byte signatures, path 3 = connectionMac
        // post-connect, path 4 = KBPreferance cache). Path 1 is
        // `if let sysAdvPacket = ... as? KBAdvPacketSystem { return
        // sysAdvPacket.macAddress }` — it returns whatever macAddress
        // is, INCLUDING NIL, and never falls through to path 2 when
        // a System packet exists but its macAddress is nil. We hit
        // exactly this case on factory-default Echo Air devices with
        // a System slot configured: the SDK parses System bytes
        // correctly into `macAddress`, but timing between batched
        // advert delivery and the `onBeaconDiscovered` delegate fire
        // can produce moments where `getAvPacket(System)` returns a
        // KBAdvPacketSystem whose `macAddress` is still nil — and
        // `KBeacon.mac` returns nil in those moments instead of
        // falling through.
        //
        // Directly reading the System packet's macAddress lets us
        // match on the first delegate call after the System bytes
        // have been parsed (per `KBAdvPacketSystem.parseAdvPacket`,
        // which sets macAddress unconditionally on the same line it
        // reads bytes 3-8). Captured as `String?` before the actor
        // hop because KBeacon isn't Sendable.
        //
        // Empty `beacons` arrays from the SDK are tolerated: `.map`
        // returns [], `.first(where:)` returns nil, the guard fails,
        // we `return` without resuming the continuation, and the
        // outer scan continues until either a non-empty match or the
        // discovery timer fires.
        let entries: [(uuid: String, sysMac: String?)] = beacons.map { beacon in
            let sysMac = (beacon.getAvPacketByType(KBAdvType.System) as? KBAdvPacketSystem)?
                .macAddress
            return (beacon.uuidString ?? "", sysMac)
        }
        Task { @MainActor in
            let target = self.targetMacUppercased
            guard let match = entries.first(where: { $0.sysMac?.uppercased() == target }) else {
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
