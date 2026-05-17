import Foundation
@preconcurrency import CoreBluetooth
@preconcurrency import kbeaconlib2

/// Promoted from "diagnostic-only panel scanner" (PR #10/#11) to the
/// production discovery path (PR #14). Owns its own `CBCentralManager`,
/// scans `withServices: nil + allowDuplicates: true`, and serves two
/// callers from the same scan session:
///
/// 1. The on-screen diagnostic panel — `@Published` `discoveries` and
///    `state`, rendered by `DiagnosticSection` in `CollectionView`.
///    The panel exists to surface what iOS is actually receiving so
///    the user (and us) can compare against what reaches the device
///    rows. **Kept in for this round** as the safety net; removed in
///    the diagnostic-cleanup follow-up PR once the device rows reach
///    `.collected` on TestFlight.
///
/// 2. The production peripheral-finder — `findPeripheral(matching:)`
///    awaitable. Used by `KBeaconScanner.discover` after we found,
///    across 8+ TestFlight rounds, that the SDK's `KBeaconsMgr`-based
///    scan does not reliably deliver KKM devices on iOS even when
///    every parsing detail downstream is correct. Our raw-CB scan
///    *does* reliably see them and we already know how to extract
///    the MAC from the advertisement payload — the SDK's connect /
///    GATT-read path then works fine on a `KBeacon` we construct and
///    attach ourselves.
///
/// **Architecture (post-PR #14):** ours is the only CBCentralManager
/// in process that does any scanning. The SDK's `KBeaconsMgr`
/// CBCentralManager is lazy-created during `KBeaconBridge.connect` and
/// is used only for the connect + GATT operations. The
/// `BluetoothPermissionGate`'s CBCentralManager is created only on the
/// very first permission round-trip (PR #13) and torn down before
/// returning. So during the production scan, exactly one CB is alive;
/// during the connect phase, two CBs are alive but only one (the
/// SDK's) is doing GATT work. No multi-CB-while-scanning interference
/// to worry about anymore.
@MainActor
final class BleDiagnosticScanner: NSObject, ObservableObject {

    /// Active scanner instance. Set by `start(targets:)` and cleared
    /// by `stop()`. Read by `KBeaconScanner.discover` to access the
    /// raw-CB discovery pipeline without `CollectionViewModel` needing
    /// to pass the instance down through KBeaconScanner's constructor
    /// — keeps the orchestrator (`CollectionViewModel.attemptCollect`)
    /// signature unchanged.
    ///
    /// Single-active-scanner invariant matches the single-instance
    /// `CollectionViewModel` lifecycle (one Collection screen at a
    /// time in the nav stack).
    static private(set) var current: BleDiagnosticScanner?

    /// One row in the on-screen panel. Updated in-place per peripheral
    /// (keyed by `identifier`) as iOS re-delivers the advertisement
    /// during a sustained scan — RSSI refreshes, advertisement bytes
    /// usually stay the same.
    struct Discovery: Identifiable, Equatable {
        let id: String
        var name: String?
        var rssi: Int
        var lastSeen: Date
        var localName: String?
        var isConnectable: Bool?
        var txPower: Int?
        var serviceUUIDs: [String]
        var manufacturerDataHex: String
        var serviceDataHex: [String: String]
        var advKeys: [String]
        var matches: [TargetMatch]
        /// Strict-parsed MAC from the Eddystone-encapsulated
        /// `KBAdvType.System` packet (FEAA service data, byte 0 ==
        /// 0x22, MAC at bytes 3-8). nil when no System packet was
        /// present in this advertisement update. Uppercase,
        /// colon-separated, same format the SDK's
        /// `KBAdvPacketSystem.parseAdvPacket` produces. This is the
        /// authoritative match key for production discovery (separate
        /// from the liberal-substring `matches` array which feeds
        /// only the diagnostic UI).
        var systemMac: String?
    }

    struct TargetMatch: Equatable, Hashable {
        /// Raw verbatim value from `ShipmentDeviceDto.mac`. Format
        /// unspecified by the backend; observed format is uppercase
        /// hex with no colons, e.g. `"BC57291CD6AC"`. **Do not
        /// assume colon-separated.** Compare against parsed System
        /// packet MACs via `BleDiagnosticScanner.normalizeMac(_:)`,
        /// never via direct string equality.
        let targetMac: String
        /// `"mfg"` | `"svc:<uuid>"` | `"localName"`.
        let field: String
        /// `"fwd"` | `"rev"`.
        let direction: String
    }

    enum State: Equatable {
        case idle
        case waitingForRadio
        case scanning
        case stopped(reason: String)
    }

    /// Errors thrown by `findPeripheral(matching:timeoutSec:)`. The
    /// timeout case is translated into `KBeaconScanner.ScannerError
    /// .discoveryTimeout(seconds:)` upstream so the orchestrator's
    /// existing `.missing` mapping still fires.
    enum FindError: Error, CustomStringConvertible {
        case timeout(target: String, seconds: Int)
        case scannerStopped(reason: String)

        var description: String {
            switch self {
            case .timeout(let target, let seconds):
                return "no peripheral with System-packet MAC \(target) within \(seconds)s"
            case .scannerStopped(let reason):
                return "scanner stopped before a match was found: \(reason)"
            }
        }
    }

    /// Production discovery result: the matched peripheral plus the
    /// advertisement state we captured when we matched it. Both are
    /// fed to `KBeacon.attach2Device(peripheral:beaconMgr:)` and
    /// `KBeacon.parseAdvPacket(advData:rssi:uuid:)` respectively so
    /// the constructed `KBeacon` ends up in the same internal state
    /// the SDK's own `didDiscover` would have produced.
    ///
    /// `@unchecked Sendable`: held on MainActor, never crosses actor
    /// boundaries beyond the continuation resume that produced it
    /// (same actor, same MainActor caller).
    struct MatchedPeripheral: @unchecked Sendable {
        let peripheral: CBPeripheral
        let advertisementData: [String: Any]
        let rssi: Int
    }

    @Published private(set) var discoveries: [Discovery] = []
    @Published private(set) var state: State = .idle
    @Published private(set) var targets: [String] = []
    /// Connect-attempt log. Lines appended by `KBeaconScanner.discover`
    /// and `KBeaconBridge.connect` (+ its `onConnStateChange` delegate)
    /// via `BleDiagnosticScanner.log(_:)`. Surfaces on the on-screen
    /// diagnostic panel so TestFlight testers can see what's happening
    /// after discovery succeeds — answers questions like "is
    /// `retrievePeripherals` returning the SDK-rooted peripheral or
    /// the fallback?", "is `connectEnhanced` returning true?", "what
    /// state changes are coming back?". FIFO-capped at 200 lines so
    /// the panel stays readable across multiple device attempts.
    /// **Temporary** — removed in the diagnostic-cleanup PR alongside
    /// the rest of this scanner.
    @Published private(set) var connectLog: [String] = []

    private var needles: [(target: String, fwd: String, rev: String)] = []

    /// Per-peripheral cache of the most-recent matched advertisement
    /// state. Keyed by `peripheral.identifier.uuidString`. We need
    /// both the peripheral and the advertisement bytes to hand to
    /// the SDK's `KBeacon.attach2Device` and
    /// `KBeacon.parseAdvPacket`. Held on the MainActor; non-Sendable
    /// CBPeripheral never crosses actor boundaries after capture in
    /// `ingest`.
    private var peripherals: [String: PeripheralCacheEntry] = [:]

    private struct PeripheralCacheEntry {
        let peripheral: CBPeripheral
        var advertisementData: [String: Any]
        var rssi: Int
    }

    /// In-flight `findPeripheral(matching:)` awaiters. Serial in
    /// practice (`CollectionViewModel.collectDevice` loops one device
    /// at a time) but kept as an array so a future parallel-collection
    /// path doesn't have to refactor.
    private var pendingMatches: [PendingMatch] = []

    private final class PendingMatch {
        /// Already passed through `BleDiagnosticScanner.normalizeMac`
        /// at construction time, so any comparison against this
        /// must be on a value normalised the same way.
        let targetMacNormalized: String
        let continuation: CheckedContinuation<MatchedPeripheral, Error>
        var timeoutTask: Task<Void, Never>?

        init(targetMacNormalized: String,
             continuation: CheckedContinuation<MatchedPeripheral, Error>) {
            self.targetMacNormalized = targetMacNormalized
            self.continuation = continuation
        }
    }

    private var central: CBCentralManager?

    /// Start scanning all BLE peripherals. Idempotent.
    func start(targets: [String]) {
        Self.current = self
        // Early-init the SDK's CBCentralManager (PR #15). Accessing
        // `KBeaconsMgr.sharedBeaconManager` here triggers its lazy
        // `init()` which creates the SDK-owned `cbBeaconMgr`
        // CBCentralManager. CBCentralManager init is synchronous
        // but its state transition to `.poweredOn` is async via
        // the `centralManagerDidUpdateState` callback, typically
        // a few hundred ms after init. Kicking it off here in
        // parallel with our raw scan startup means by the time
        // `KBeaconScanner.discover` calls
        // `cbBeaconMgr.retrievePeripherals(withIdentifiers:)`, the
        // SDK's CB has had ample time to power up and learn about
        // peripherals in iOS's system-wide cache (including those
        // discovered by OUR diagnostic CB). Without this early
        // touch, the SDK's CB on the first device's `discover()`
        // call would be in `.unknown` state and `retrievePeripherals`
        // might return empty, forcing the cross-manager fallback
        // that Apple's `connect(_:options:)` contract doesn't
        // guarantee will work.
        _ = KBeaconsMgr.sharedBeaconManager
        self.targets = targets
        self.needles = targets.map { mac in
            let stripped = mac.replacingOccurrences(of: ":", with: "").lowercased()
            let reversed = String(stride(from: 0, to: stripped.count, by: 2).reversed().map { idx -> String in
                let start = stripped.index(stripped.startIndex, offsetBy: idx)
                let end = stripped.index(start, offsetBy: 2, limitedBy: stripped.endIndex) ?? stripped.endIndex
                return String(stripped[start..<end])
            }.joined())
            return (target: mac, fwd: stripped, rev: reversed)
        }
        if central == nil {
            state = .waitingForRadio
            central = CBCentralManager(delegate: self, queue: nil)
        } else if let central, central.state == .poweredOn {
            beginScan(on: central)
        }
    }

    /// Stop scanning. Discoveries remain in `@Published` so the UI
    /// keeps showing what was seen. Any in-flight awaiters are
    /// failed with `.scannerStopped`.
    func stop() {
        central?.stopScan()
        state = .stopped(reason: "view dismissed")
        if Self.current === self {
            Self.current = nil
        }
        // Fail any in-flight findPeripheral awaiters so callers
        // (which are awaiting them inside KBeaconScanner.discover)
        // unblock cleanly when the screen disappears mid-collection.
        let inflight = pendingMatches
        pendingMatches.removeAll()
        for pending in inflight {
            pending.timeoutTask?.cancel()
            pending.continuation.resume(throwing: FindError.scannerStopped(reason: "view dismissed"))
        }
    }

    // MARK: - Production discovery (PR #14)

    /// Awaitable: returns the `CBPeripheral` whose advertisement
    /// contains a KKM-System-packet-encoded MAC matching `targetMac`,
    /// or throws `.timeout` after `timeoutSec` seconds.
    ///
    /// Match is on the STRICT System-packet MAC (FEAA service data
    /// bytes 3-8 when byte 0 == 0x22), not the liberal substring
    /// matcher that feeds the diagnostic panel — devices may have
    /// MAC bytes appear in unrelated payloads, and we want
    /// production discovery to only match what the SDK would
    /// authoritatively recognise.
    ///
    /// Fast path: if a matching peripheral has already been
    /// discovered (cached in `discoveries`/`peripherals`), returns
    /// it synchronously without registering an awaiter. Slow path:
    /// registers an awaiter that resolves on the next matching
    /// discovery, or fires the timeout error.
    func findPeripheral(
        matching targetMac: String,
        timeoutSec: TimeInterval
    ) async throws -> MatchedPeripheral {
        // Normalise once at the entry. Every downstream comparison
        // — cache lookup, awaiter dispatch — works on the
        // normalised form so format-mismatch can't silently fail
        // the match. See `normalizeMac(_:)` docstring for the bug
        // this prevents (PR #15).
        let targetNormalized = Self.normalizeMac(targetMac)

        if let cached = findCachedMatch(targetMacNormalized: targetNormalized) {
            return cached
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<MatchedPeripheral, Error>) in
            let pending = PendingMatch(targetMacNormalized: targetNormalized, continuation: cont)
            pendingMatches.append(pending)
            // Timeout dispatch as a child Task — cancelled when the
            // awaiter resolves via a normal discovery.
            pending.timeoutTask = Task { @MainActor [weak self, weak pending] in
                let nanos = UInt64(timeoutSec * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                guard let self, let pending else { return }
                guard let idx = self.pendingMatches.firstIndex(where: { $0 === pending }) else {
                    return    // already resolved by a discovery match
                }
                self.pendingMatches.remove(at: idx)
                pending.continuation.resume(throwing: FindError.timeout(
                    target: targetNormalized,
                    seconds: Int(timeoutSec)
                ))
            }
        }
    }

    private func findCachedMatch(targetMacNormalized: String) -> MatchedPeripheral? {
        for discovery in discoveries {
            guard let systemMac = discovery.systemMac else { continue }
            guard Self.normalizeMac(systemMac) == targetMacNormalized else { continue }
            if let entry = peripherals[discovery.id] {
                return MatchedPeripheral(
                    peripheral: entry.peripheral,
                    advertisementData: entry.advertisementData,
                    rssi: entry.rssi
                )
            }
        }
        return nil
    }

    private func dispatchAwaiters(forSystemMac mac: String, peripheralIdentifier: String) {
        let normalized = Self.normalizeMac(mac)
        guard let entry = peripherals[peripheralIdentifier] else { return }
        let matched = MatchedPeripheral(
            peripheral: entry.peripheral,
            advertisementData: entry.advertisementData,
            rssi: entry.rssi
        )
        // Iterate a snapshot so we can mutate the array as we resolve.
        let snapshot = pendingMatches
        for pending in snapshot where pending.targetMacNormalized == normalized {
            if let idx = pendingMatches.firstIndex(where: { $0 === pending }) {
                pendingMatches.remove(at: idx)
            }
            pending.timeoutTask?.cancel()
            pending.continuation.resume(returning: matched)
        }
    }

    /// Strict parser — same algorithm as `KBAdvPacketSystem
    /// .parseAdvPacket` runs on the same bytes:
    ///   • Eddystone service (FEAA) data present
    ///   • Length >= `KBAdvPacketSystem.MIN_ADV_PACKET_LEN` (11)
    ///   • Byte 0 == 0x22 (System packet via Eddystone framing)
    ///   • MAC at bytes 3-8, formatted "%02X:..." uppercase
    private static func parseSystemMac(fromAdvertisement advData: [String: Any]) -> String? {
        guard let svc = advData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] else {
            return nil
        }
        let eddystoneUUID = CBUUID(string: "FEAA")
        guard let data = svc[eddystoneUUID], data.count >= 11, data[0] == 0x22 else {
            return nil
        }
        return String(format: "%02X:%02X:%02X:%02X:%02X:%02X",
                      data[3], data[4], data[5], data[6], data[7], data[8])
    }

    /// Diagnostic logger usable from any thread/actor. Dispatches to
    /// MainActor and appends to the active scanner's `connectLog`.
    /// Silent no-op when no scanner is active (e.g. when called
    /// outside the Collection screen's lifetime). Caller doesn't need
    /// to be `async`. **Temporary** — removed alongside this scanner
    /// in the diagnostic-cleanup PR.
    nonisolated static func log(_ line: String) {
        Task { @MainActor in
            current?.appendConnectLog(line)
        }
    }

    private func appendConnectLog(_ line: String) {
        let stamp = Self.logFormatter.string(from: Date())
        connectLog.append("[\(stamp)] \(line)")
        if connectLog.count > 200 {
            connectLog.removeFirst(connectLog.count - 200)
        }
    }

    private static let logFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Canonicalise a MAC for production-path comparison. Strips
    /// every colon and uppercases the rest — collapses every
    /// observed-in-the-wild MAC notation (with colons, without,
    /// hyphenated, mixed case) onto one comparable form.
    ///
    /// **Why this exists (PR #15).** `parseSystemMac` always emits
    /// colon-separated uppercase (`"BC:57:29:1C:D6:AC"`) — the
    /// SDK's `KBAdvPacketSystem.parseAdvPacket` produces that
    /// format via `String(format: "%02X:%02X:…")`. But
    /// `ShipmentDeviceDto.mac` comes from the backend in
    /// hex-no-colons (`"BC57291CD6AC"`, observed via the diagnostic
    /// panel). Direct string equality between the two fails
    /// silently — production scanner times out at 25s while the
    /// diagnostic panel (which uses substring matching on hex)
    /// shows MATCH. Both sides must be normalised before
    /// comparison. Public so `KBeaconScanner` can normalise on its
    /// side too if it ever does direct MAC comparison.
    static func normalizeMac(_ mac: String) -> String {
        mac.replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .uppercased()
    }

    // MARK: - Scan internals

    private func beginScan(on central: CBCentralManager) {
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        state = .scanning
    }

    private func ingest(
        peripheral: CBPeripheral,
        identifier: String,
        name: String?,
        rssi: Int,
        advertisementData: [String: Any]
    ) {
        // Keep the peripheral reference + most-recent advertisement
        // so the production path can hand both to the SDK via
        // KBeacon.attach2Device + KBeacon.parseAdvPacket.
        peripherals[identifier] = PeripheralCacheEntry(
            peripheral: peripheral,
            advertisementData: advertisementData,
            rssi: rssi
        )

        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let txPower = (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue
        let isConn = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue

        var serviceUUIDs: [String] = []
        if let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            serviceUUIDs = uuids.map { $0.uuidString }
        }

        var mfgHex = ""
        if let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            mfgHex = mfg.map { String(format: "%02x", $0) }.joined()
        }

        var svcHex: [String: String] = [:]
        if let svc = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            for (uuid, data) in svc {
                svcHex[uuid.uuidString] = data.map { String(format: "%02x", $0) }.joined()
            }
        }

        let advKeys = advertisementData.keys.sorted()

        // Liberal substring match across every possible carrier —
        // feeds the diagnostic UI only.
        var matches: [TargetMatch] = []
        let lowerLocalName = (localName ?? "").lowercased().replacingOccurrences(of: ":", with: "")
        for needle in needles {
            if mfgHex.contains(needle.fwd) {
                matches.append(TargetMatch(targetMac: needle.target, field: "mfg", direction: "fwd"))
            } else if mfgHex.contains(needle.rev) {
                matches.append(TargetMatch(targetMac: needle.target, field: "mfg", direction: "rev"))
            }
            for (uuid, hex) in svcHex {
                if hex.contains(needle.fwd) {
                    matches.append(TargetMatch(targetMac: needle.target, field: "svc:\(uuid)", direction: "fwd"))
                } else if hex.contains(needle.rev) {
                    matches.append(TargetMatch(targetMac: needle.target, field: "svc:\(uuid)", direction: "rev"))
                }
            }
            if !lowerLocalName.isEmpty {
                if lowerLocalName.contains(needle.fwd) {
                    matches.append(TargetMatch(targetMac: needle.target, field: "localName", direction: "fwd"))
                } else if lowerLocalName.contains(needle.rev) {
                    matches.append(TargetMatch(targetMac: needle.target, field: "localName", direction: "rev"))
                }
            }
        }

        // Strict System-packet MAC — production match key.
        let systemMac = Self.parseSystemMac(fromAdvertisement: advertisementData)

        let discovery = Discovery(
            id: identifier,
            name: name,
            rssi: rssi,
            lastSeen: Date(),
            localName: localName,
            isConnectable: isConn,
            txPower: txPower,
            serviceUUIDs: serviceUUIDs,
            manufacturerDataHex: mfgHex,
            serviceDataHex: svcHex,
            advKeys: advKeys,
            matches: matches,
            systemMac: systemMac
        )
        if let index = discoveries.firstIndex(where: { $0.id == identifier }) {
            discoveries[index] = discovery
        } else {
            discoveries.insert(discovery, at: 0)
            if discoveries.count > 50 {
                discoveries.removeLast(discoveries.count - 50)
            }
        }

        // Production dispatch: if this advertisement carried a System
        // packet, fire any awaiters whose target matches its MAC.
        if let systemMac {
            dispatchAwaiters(forSystemMac: systemMac, peripheralIdentifier: identifier)
        }
    }
}

extension BleDiagnosticScanner: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let stateRaw = central.state.rawValue
        Task { @MainActor in
            guard let cb = CBManagerState(rawValue: stateRaw) else { return }
            switch cb {
            case .poweredOn:
                self.beginScan(on: central)
            case .poweredOff:
                self.state = .stopped(reason: "radio off")
            case .unauthorized:
                self.state = .stopped(reason: "unauthorised — permission denied at app level")
            case .unsupported:
                self.state = .stopped(reason: "device does not support BLE")
            case .resetting:
                self.state = .stopped(reason: "radio resetting")
            case .unknown:
                self.state = .waitingForRadio
            @unknown default:
                self.state = .stopped(reason: "unknown state raw=\(stateRaw)")
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let identifier = peripheral.identifier.uuidString
        let name = peripheral.name
        let rssi = RSSI.intValue
        // CBPeripheral is not Sendable, but: (a) it's held in process
        // for the radio session, (b) the hop is from the manager queue
        // to MainActor — both single-threaded contexts in practice
        // (we passed `queue: nil` so callbacks arrive on main). Wrap
        // in an @unchecked Sendable shim alongside the advertisement
        // dict, same pattern as before.
        struct DiscoveryShim: @unchecked Sendable {
            let peripheral: CBPeripheral
            let dict: [String: Any]
        }
        let shim = DiscoveryShim(peripheral: peripheral, dict: advertisementData)
        Task { @MainActor in
            self.ingest(
                peripheral: shim.peripheral,
                identifier: identifier,
                name: name,
                rssi: rssi,
                advertisementData: shim.dict
            )
        }
    }
}
