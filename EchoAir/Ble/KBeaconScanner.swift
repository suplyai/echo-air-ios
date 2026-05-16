import Foundation
@preconcurrency import kbeaconlib2
@preconcurrency import CoreBluetooth

/// Production peripheral discovery + KBeacon construction.
///
/// **PR #14 architecture change.** Prior versions of this scanner
/// drove the SDK's `KBeaconsMgr.startScanning()` and observed
/// `KBeaconMgrDelegate.onBeaconDiscovered` to find peripherals by
/// `KBeacon.mac`. Across 8+ TestFlight rounds we proved that the SDK's
/// discovery path does not reliably deliver KKM devices on iOS — even
/// when permission is granted, the scan filter matches KKM's own demo,
/// and the device's System slot is correctly broadcasting bytes the
/// SDK's parser would recognise. Our own raw-CB scanner
/// (`BleDiagnosticScanner`) sees the same devices reliably every time.
///
/// So this scanner now:
///   1. Asks `BleDiagnosticScanner.current` (already running, started
///      by `CollectionViewModel.start()` after the permission gate
///      resolves) for a `CBPeripheral` whose advertisement contains a
///      KKM System-packet-encoded MAC matching the target.
///   2. Defensively retrieves an SDK-rooted handle to that peripheral
///      via `KBeaconsMgr.sharedBeaconManager.cbBeaconMgr
///      .retrievePeripherals(withIdentifiers:)`, so the SDK's
///      `CBCentralManager` has its own reference. Falls back to our
///      original peripheral if `retrievePeripherals` returns empty
///      (CBPeripheral identity is system-wide; iOS should accept
///      either, but the SDK-rooted handle eliminates cross-manager
///      ambiguity in `connect`).
///   3. Constructs a `KBeacon`, calls the SDK's public
///      `attach2Device(peripheral:beaconMgr:)` and `parseAdvPacket(
///      advData:rssi:uuid:)`, registers in `KBeaconsMgr.beacons`
///      so any SDK-internal lookups by uuid work, and returns the
///      `KBeacon` to the caller.
///
/// The SDK's `KBeaconBridge.connect` / `readSensorDataInfo` /
/// `readSensorRecord` path takes that `KBeacon` and works without
/// modification. Only SDK *discovery* was broken; connect + GATT
/// reads are fine.
@MainActor
final class KBeaconScanner: NSObject {

    /// Errors thrown by `discover(mac:)`. Existing cases preserved so
    /// `CollectionViewModel.attemptCollect`'s `.discoveryTimeout` →
    /// `.missing` mapping still works. `scanRefused` /
    /// `bleStateChangedMidScan` are no longer thrown post-PR #14
    /// (we don't drive the SDK's scan anymore) but the cases are kept
    /// for binary compatibility with the orchestrator's catch ladder.
    enum ScannerError: Error, CustomStringConvertible {
        case bleUnavailable(state: String)
        case scanRefused
        case discoveryTimeout(seconds: Int)
        case bleStateChangedMidScan(state: String)
        /// PR #14 new — raw scanner wasn't running when `discover` was
        /// called (someone invoked the production scanner outside the
        /// Collection-screen lifecycle). Reflects a programming error,
        /// not a runtime BLE issue.
        case rawScannerUnavailable

        var description: String {
            switch self {
            case .bleUnavailable(let s):
                return "BLE unavailable (state=\(s))"
            case .scanRefused:
                return "raw scanner refused to start"
            case .discoveryTimeout(let s):
                return "target device not discovered within \(s)s"
            case .bleStateChangedMidScan(let s):
                return "BLE state changed mid-scan: \(s)"
            case .rawScannerUnavailable:
                return "raw scanner not active — BleDiagnosticScanner.start() was not called before discover()"
            }
        }
    }

    /// Per-attempt scan ceiling. Carried over from PR #12 (widened
    /// from 15s to 25s). Still sized for the SDK's batched-delegate
    /// timing rather than the raw scanner's instantaneous match,
    /// because (a) the device may not be in range at the moment the
    /// orchestrator asks for it (allow some time for the radio to
    /// catch an advertisement), and (b) `CollectionViewModel`'s
    /// `.missing` display string sources from this constant — keep
    /// the user-facing copy consistent.
    static let defaultTimeoutSec: TimeInterval = 25

    /// Scan until a peripheral with `mac` is discovered (matched by
    /// strict System-packet parse), then construct + return a
    /// `KBeacon` attached to that peripheral. Throws
    /// `.discoveryTimeout` if no match within `timeoutSec`,
    /// `.rawScannerUnavailable` if the raw scanner isn't running.
    ///
    /// Caller owns the returned `KBeacon` — disconnect via
    /// `beacon.disconnect()` when finished. The `KBeacon` is also
    /// registered in `KBeaconsMgr.sharedBeaconManager.beacons` for
    /// any SDK-internal lookups by uuid (e.g. delegate routing).
    func discover(mac: String, timeoutSec: TimeInterval = KBeaconScanner.defaultTimeoutSec) async throws -> KBeacon {
        guard let rawScanner = BleDiagnosticScanner.current else {
            throw ScannerError.rawScannerUnavailable
        }

        // 1. Discover via raw-CB scan + strict System-packet MAC
        //    match. Returns the peripheral plus the advertisement
        //    state captured when we matched it.
        let matched: BleDiagnosticScanner.MatchedPeripheral
        do {
            matched = try await rawScanner.findPeripheral(
                matching: mac,
                timeoutSec: timeoutSec
            )
        } catch BleDiagnosticScanner.FindError.timeout {
            throw ScannerError.discoveryTimeout(seconds: Int(timeoutSec))
        } catch BleDiagnosticScanner.FindError.scannerStopped(let reason) {
            throw ScannerError.bleStateChangedMidScan(state: reason)
        }

        // 2. Cross-manager safety net — retrieve the peripheral via
        //    the SDK's CBCentralManager so connect() satisfies
        //    Apple's contract ("the peripheral must have been
        //    discovered by THIS manager or retrieved via
        //    retrievePeripherals / retrieveConnectedPeripherals").
        //    `cbBeaconMgr` is `@objc public var` on KBeaconsMgr
        //    (verified against the SDK source).
        //
        //    Brief poll-wait for the SDK's CB to reach `.poweredOn`
        //    before calling retrievePeripherals (PR #15). The SDK's
        //    CB was early-initialised in
        //    `BleDiagnosticScanner.start(...)` so it normally
        //    finishes powering up well before the first device
        //    discovery completes; this wait is insurance for the
        //    cold-path case where the very first advertisement
        //    arrives faster than the SDK's CB state callback.
        //    Calling retrievePeripherals on a `.unknown`-state CB
        //    returns an empty array, which would force the
        //    cross-manager-fallback path that Apple's connect()
        //    contract doesn't guarantee will work. 100 ms × up to
        //    10 attempts = 1 s ceiling; after that we proceed
        //    regardless. On every device after the first, this
        //    loop exits immediately because state is already
        //    `.poweredOn`.
        let sdkMgr = KBeaconsMgr.sharedBeaconManager.cbBeaconMgr
        for _ in 0..<10 {
            if sdkMgr.state == .poweredOn { break }
            try? await Task.sleep(nanoseconds: 100_000_000)    // 100 ms
        }
        //
        //    If retrievePeripherals still returns empty after the
        //    wait (peripheral not in iOS's cache, or the SDK's CB
        //    is genuinely stuck), we fall back to our scanner's
        //    CBPeripheral. That's undocumented territory and may
        //    not work; if connect later times out from that
        //    fallback path, the next step is the GATT-layer
        //    rewrite flagged in PR #14.
        let sdkPeripheral = sdkMgr
            .retrievePeripherals(withIdentifiers: [matched.peripheral.identifier])
            .first ?? matched.peripheral

        // 3. Construct the KBeacon and run the same init sequence the
        //    SDK's own didDiscover would have run on a successful
        //    parse:
        //      (a) attach2Device — sets the KBeacon as the
        //          peripheral's delegate and stores the manager ref
        //      (b) parseAdvPacket — populates name + rssi + the
        //          internal mAdvPacketMgr's per-advType packets,
        //          including the System packet whose macAddress is
        //          what `KBeacon.mac` returns via fallback path 1
        //    Calling both keeps the KBeacon in the same internal
        //    state the SDK's connect / GATT-read code expects.
        let beacon = KBeacon()
        beacon.attach2Device(
            peripheral: sdkPeripheral,
            beaconMgr: KBeaconsMgr.sharedBeaconManager
        )
        let rssiInt8: Int8 = Int8(clamping: matched.rssi)
        _ = beacon.parseAdvPacket(
            advData: matched.advertisementData,
            rssi: rssiInt8,
            uuid: sdkPeripheral.identifier.uuidString
        )

        // 4. Register in the SDK's public `beacons` dict by uuid.
        //    Some SDK paths consult this dict; keeping it populated
        //    mirrors what the SDK's own didDiscover does after a
        //    successful parseAdvPacket. `@objc public var beacons`
        //    is a public mutable dict on KBeaconsMgr.
        let uuidString = sdkPeripheral.identifier.uuidString
        if KBeaconsMgr.sharedBeaconManager.beacons[uuidString] == nil {
            KBeaconsMgr.sharedBeaconManager.beacons[uuidString] = beacon
        }

        return beacon
    }
}
