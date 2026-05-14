import Foundation
@preconcurrency import CoreBluetooth

/// On-screen BLE diagnostic scanner. Runs in parallel with the SDK's
/// `KBeaconsMgr`-based scan, with our own `CBCentralManager`, and
/// publishes the **raw** `CBAdvertisementData` dictionary for every
/// peripheral iOS hands us. The Collection screen renders the
/// published `discoveries` so a TestFlight tester can see, without
/// USB / Console, exactly what their phone is and isn't picking up.
///
/// **Why we need this.** Three physical KBeacon devices known good
/// (working on Android simultaneously) aren't being discovered or
/// matched by the iOS production scan path even after the permission
/// gate fix (PR #9, merged) restored Bluetooth permission. The next
/// diagnostic step is to read what iOS actually sees in the
/// advertisement payload — the SDK's `KBeacon.mac` is computed from
/// parsed advertisement bytes, and if those bytes aren't where the
/// SDK expects them, the match silently fails. This scanner dumps
/// everything so we can compare the targets we're hunting against the
/// raw bytes coming off the air.
///
/// **Intentionally not `#if DEBUG`**. We can't side-load a Debug
/// build right now — the scanner needs to run in TestFlight. We will
/// remove this file (and its UI in `CollectionView`) once discovery
/// is fixed.
///
/// **One CBCentralManager per app concern.** Apple supports multiple
/// `CBCentralManager` instances per process. The
/// `BluetoothPermissionGate` instance (one) and the SDK's
/// `KBeaconsMgr` instance (another) plus this one (a third) all
/// share `CBManager.authorization` (process-wide) and the radio.
/// iOS multiplexes scans internally; no conflict in practice.
@MainActor
final class BleDiagnosticScanner: NSObject, ObservableObject {

    /// One row in the on-screen panel. Updated in-place per peripheral
    /// (keyed by `identifier`) as iOS re-delivers the advertisement
    /// during a sustained scan — RSSI refreshes, advertisement bytes
    /// usually stay the same.
    struct Discovery: Identifiable, Equatable {
        /// `CBPeripheral.identifier.uuidString`. Used as the dedup key.
        let id: String
        /// `CBPeripheral.name` — iOS may return nil even when the
        /// advertisement contains a local name (different cache).
        var name: String?
        var rssi: Int
        var lastSeen: Date
        /// `kCBAdvDataLocalName` from the advertisement dict, if any.
        var localName: String?
        /// `kCBAdvDataIsConnectable` from the advertisement dict.
        var isConnectable: Bool?
        /// `kCBAdvDataTxPowerLevel` from the advertisement dict.
        var txPower: Int?
        /// Service UUIDs the peripheral advertises (`CBUUID` -> String).
        var serviceUUIDs: [String]
        /// Lowercase hex of `kCBAdvDataManufacturerData` (no separator).
        /// Empty when manufacturer data wasn't included.
        var manufacturerDataHex: String
        /// Per-service-UUID hex of `kCBAdvDataServiceData`.
        var serviceDataHex: [String: String]
        /// All keys present in the advertisement dict, for completeness
        /// (in case a key we don't explicitly extract is what carries
        /// the MAC bytes on this device firmware).
        var advKeys: [String]
        /// One per target MAC — where this discovery's bytes were
        /// found containing that MAC's hex (and in what direction).
        /// Empty array = no match against any target.
        var matches: [TargetMatch]
    }

    /// Where a target MAC's bytes were found inside a discovery.
    /// `field` is one of "mfg", "svc:<uuid>", or "localName" so the
    /// fix author can see which advertisement field to parse.
    /// `Hashable` so the panel can use `id: \.self` in `ForEach`.
    struct TargetMatch: Equatable, Hashable {
        let targetMac: String      // "BC:57:29:1C:D6:AC" — verbatim from the shipment DTO
        let field: String          // "mfg" / "svc:<uuid>" / "localName"
        let direction: String      // "fwd" / "rev"
    }

    /// State enum so the UI can tell "haven't started yet" from
    /// "scanning, just no results" from "permission/radio issue".
    enum State: Equatable {
        case idle
        case waitingForRadio
        case scanning
        case stopped(reason: String)
    }

    @Published private(set) var discoveries: [Discovery] = []
    @Published private(set) var state: State = .idle
    /// Target MACs (uppercased, colon-separated) we're matching
    /// against. Set once from `CollectionViewModel.shipment.devices`.
    /// Exposed `private(set)` so the diagnostic panel can render
    /// them alongside the discovery list.
    @Published private(set) var targets: [String] = []
    /// Pre-computed (forward + reverse) hex needles, lowercased,
    /// colon-stripped, for each target. Lowercased because all hex
    /// dumps below are lowercased so the substring search is
    /// case-consistent.
    private var needles: [(target: String, fwd: String, rev: String)] = []

    private var central: CBCentralManager?

    /// Start scanning all BLE peripherals (nil services). Idempotent.
    /// Discoveries accumulate via the delegate. Captures the targets
    /// for substring matching at the same time.
    func start(targets: [String]) {
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

    /// Stop scanning. Discoveries remain in the @Published array so
    /// the UI keeps showing what was seen.
    func stop() {
        central?.stopScan()
        state = .stopped(reason: "view dismissed")
    }

    private func beginScan(on central: CBCentralManager) {
        // CBCentralManagerScanOptionAllowDuplicatesKey = true so we
        // see RSSI updates over time even from peripherals we've
        // already cataloged. Necessary to confirm a device is still
        // present and to spot RSSI drift.
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        state = .scanning
    }

    private func ingest(
        identifier: String,
        name: String?,
        rssi: Int,
        advertisementData: [String: Any]
    ) {
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

        // Target-byte substring search across every possible carrier.
        // The SDK's KBeacon.mac parser expects specific framing
        // (KBAdvType.System packet); we're looking BENEATH that to
        // confirm the bytes are actually present somewhere, even if
        // the SDK didn't recognise the format.
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

        // Update-in-place by identifier; insert at front when new so
        // the panel shows most-recent-seen first when sorted by
        // lastSeen. Dedup is critical because allowDuplicates=true
        // means iOS spams the callback per peripheral.
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
            matches: matches
        )
        if let index = discoveries.firstIndex(where: { $0.id == identifier }) {
            // Preserve the original lastSeen so the row position stays
            // stable if RSSI ticks; only the data refresh matters.
            discoveries[index] = discovery
        } else {
            discoveries.insert(discovery, at: 0)
            // Cap to a sane upper bound so a noisy environment
            // (airport, mall, etc.) doesn't run the panel off-screen.
            if discoveries.count > 50 {
                discoveries.removeLast(discoveries.count - 50)
            }
        }
    }
}

extension BleDiagnosticScanner: CBCentralManagerDelegate {
    // CBCentralManagerDelegate is @objc; iOS dispatches on the manager's
    // queue. We passed nil (main queue) so callbacks already arrive on
    // main, but mark nonisolated and hop back via Task @MainActor for
    // strict-concurrency cleanliness — same pattern used in
    // BluetoothPermissionGate and KBeaconScanner.
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let stateRaw = central.state.rawValue
        Task { @MainActor in
            guard let cb = CBManagerState(rawValue: stateRaw) else { return }
            switch cb {
            case .poweredOn:
                // Re-bind the manager we got back so beginScan() uses
                // the same instance the delegate fired from.
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
        // Extract Sendable copies on the delegate queue before the
        // hop. CBPeripheral and the advertisement dict's CBUUID
        // values aren't Sendable; we surface only Strings / Ints /
        // Data-derived hex.
        let identifier = peripheral.identifier.uuidString
        let name = peripheral.name
        let rssi = RSSI.intValue
        // The advertisementData dict has mixed value types
        // (String / NSNumber / Data / [CBUUID] / [CBUUID: Data]) — we
        // need to keep the original dict for the ingest helper to
        // parse keys it knows about. The dict itself isn't Sendable
        // but its mutation is single-threaded (one dispatch queue);
        // bridge with an @unchecked Sendable shim.
        struct AdvShim: @unchecked Sendable {
            let dict: [String: Any]
        }
        let shim = AdvShim(dict: advertisementData)
        Task { @MainActor in
            self.ingest(
                identifier: identifier,
                name: name,
                rssi: rssi,
                advertisementData: shim.dict
            )
        }
    }
}
