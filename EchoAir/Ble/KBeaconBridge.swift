import Foundation
@preconcurrency import kbeaconlib2

// SDK reference: github.com/kkmhogen/kbeaconlib2 (1.2.x), source verified.
// Demo for usage patterns: github.com/kkmhogen/KBeaconProDemo_Ios — the
// demo uses KBSensorReadOption.NewRecord; we use NormalOrder because Echo
// Air devices are single-use and we always want full history (handoff §3.10).
//
// Threading: the SDK's CoreBluetooth callbacks land on the main queue
// (KBeaconsMgr inits CBCentralManager without a custom queue). The
// ConnStateDelegate implementation below assumes single-threaded access
// to `connectContinuation`.
//
// Swift 6 strict-concurrency: kbeaconlib2 is imported `@preconcurrency`
// since the SDK predates Sendable annotations. The boundary types we
// pass across `async` boundaries — `SensorInfo`, `RecordPage`, `Reading`
// — are pure Sendable value types built INSIDE the SDK's callback queue
// from the SDK's non-Sendable response objects, so the data crossing
// `await` is always Sendable. `BridgeError` likewise carries only
// `String`s (no SDK exception types as associated values).
//
// §3.10 invariants encoded structurally below — engineers calling this
// bridge cannot accidentally drift on them:
//   • KBSensorReadOption.NormalOrder   (read full history, leave unread pointer alone)
//   • Initial cursor 0 (UInt32), NOT KBRecordDataRsp.INVALID_DATA_RECORD_POS
//   • 200-record batch via `max:`
//   • KBConnPara: syncUtcTime=false, readCommPara=true, readSensorPara=true,
//     readTriggerPara=false, readSlotPara=false  (NOT the SDK's defaults —
//     SDK defaults syncUtcTime=true and readSensorPara=false, both wrong for us)
//   • KBSensorType.HTHumidity (Int = 0x2)
//   • End-of-data via INVALID_DATA_RECORD_POS sentinel on rsp.readDataNextPos
final class KBeaconBridge: NSObject {
    enum BridgeError: Error, CustomStringConvertible {
        case requestRejected
        /// `reason` is `String(describing:)` of the SDK's `KBConnEvtReason`
        /// captured at the failure site — we don't carry SDK enum types
        /// across the `async` boundary.
        case connectFailed(reason: String)
        /// `detail` is the SDK exception's `errorDescription` captured at
        /// the failure site.
        case readInfoFailed(detail: String?)
        case readRecordFailed(detail: String?)

        var description: String {
            switch self {
            case .requestRejected:
                return "connectEnhanced rejected request — password must be 8-16 chars and timeout > 3s"
            case .connectFailed(let reason):
                return "connect failed: reason=\(reason)"
            case .readInfoFailed(let detail):
                return "readSensorDataInfo failed: \(detail ?? "n/a")"
            case .readRecordFailed(let detail):
                return "readSensorRecord failed: \(detail ?? "n/a")"
            }
        }
    }

    /// One temperature/humidity sample. Types match the SDK's KBRecordHumidity
    /// (utcTime UInt32, temperature/humidity Float). `humidity` is 0 / NaN on
    /// temp-only S23 variants — the record class is shared with S23H.
    /// Pure value type → implicit Sendable.
    struct Reading: Equatable, CustomStringConvertible, Sendable {
        let utcTime: UInt32
        let temperature: Float
        let humidity: Float

        var description: String {
            String(format: "utc=%u t=%.2f h=%.2f", utcTime, temperature, humidity)
        }
    }

    /// Sendable mirror of `KBRecordInfoRsp` — built inside the SDK's
    /// callback queue from the non-Sendable response, then shipped
    /// across the `async` boundary.
    struct SensorInfo: Equatable, Sendable {
        let sensorType: Int
        let totalRecordNumber: UInt32
        let unreadRecordNumber: UInt32
        let readInfoUtcSeconds: UInt32
    }

    /// Sendable mirror of one paged `KBRecordDataRsp` — the readings are
    /// already extracted into Sendable `Reading` values, and `nextCursor`
    /// is the raw `readDataNextPos`. End-of-data sentinel handling lives
    /// in the caller (`readAllRecords`).
    struct RecordPage: Equatable, Sendable {
        let readings: [Reading]
        let nextCursor: UInt32
    }

    private let beacon: KBeacon
    private var connectContinuation: CheckedContinuation<Void, Error>?

    init(beacon: KBeacon) {
        self.beacon = beacon
        super.init()
    }

    /// Connect with §3.10 parameters. Throws `.requestRejected` synchronously
    /// if the SDK refuses (bad password length, timeout below 3s), otherwise
    /// awaits the connection lifecycle through ConnStateDelegate.
    func connect(password: String, timeoutMs: Int = 20_000) async throws {
        // SDK silently returns false from connectEnhanced if password isn't
        // 8-16 chars or timeout isn't > 3s — no callback fires. Guard up
        // front so callers throw rather than hang.
        let timeoutSec = Double(timeoutMs) / 1000.0
        guard password.count >= 8, password.count <= 16, timeoutSec > 3.0 else {
            throw BridgeError.requestRejected
        }

        let para = KBConnPara()
        para.syncUtcTime = false       // §3.10: preserve device clock drift
        para.readCommPara = true       // MTU + common-cfg at connect time
        para.readSensorPara = true     // SDK default is false; required for sensor reads
        para.readTriggerPara = false
        para.readSlotPara = false

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.connectContinuation = cont
            let accepted = beacon.connectEnhanced(
                password,
                timeout: timeoutSec,
                connPara: para,
                delegate: self
            )
            if !accepted {
                self.connectContinuation = nil
                cont.resume(throwing: BridgeError.requestRejected)
            }
            // Otherwise the connect resolves via onConnStateChange below.
        }
    }

    /// Reads the device's sensor-data summary: sensorType, totalRecordNumber,
    /// unreadRecordNumber, readInfoUtcSeconds.
    func readSensorDataInfo() async throws -> SensorInfo {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SensorInfo, Error>) in
            beacon.readSensorDataInfo(KBSensorType.HTHumidity) { result, infoRsp, error in
                if result, let info = infoRsp {
                    // Extract Sendable values inside the SDK callback queue
                    // BEFORE crossing the `await` boundary, so we never send
                    // the non-Sendable `KBRecordInfoRsp` through the
                    // continuation.
                    let captured = SensorInfo(
                        sensorType: info.sensorType,
                        totalRecordNumber: info.totalRecordNumber,
                        unreadRecordNumber: info.unreadRecordNumber,
                        readInfoUtcSeconds: info.readInfoUtcSeconds
                    )
                    cont.resume(returning: captured)
                } else {
                    cont.resume(throwing: BridgeError.readInfoFailed(detail: error?.errorDescription))
                }
            }
        }
    }

    /// Reads one paged batch of records starting at `cursor`. End-of-data is
    /// signalled by the SDK returning `INVALID_DATA_RECORD_POS` as
    /// `nextCursor` — callers (or `readAllRecords` below) stop on that
    /// sentinel.
    func readNextPage(cursor: UInt32, batchSize: Int = 200) async throws -> RecordPage {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RecordPage, Error>) in
            beacon.readSensorRecord(
                KBSensorType.HTHumidity,
                number: cursor,
                option: KBSensorReadOption.NormalOrder,
                max: batchSize
            ) { result, recordRsp, error in
                if result, let rsp = recordRsp {
                    // Extract readings inside the SDK callback queue so the
                    // non-Sendable `KBRecordDataRsp` / `KBRecordHumidity`
                    // objects never cross the `await` boundary.
                    let records = (rsp.readDataRspList as? [KBRecordHumidity]) ?? []
                    let readings = records.map { record in
                        Reading(
                            utcTime: record.utcTime,
                            temperature: record.temperature,
                            humidity: record.humidity
                        )
                    }
                    let page = RecordPage(readings: readings, nextCursor: rsp.readDataNextPos)
                    cont.resume(returning: page)
                } else {
                    cont.resume(throwing: BridgeError.readRecordFailed(detail: error?.errorDescription))
                }
            }
        }
    }

    /// Drives the full paged read against §3.10's invariants. This is the
    /// spike's primary pass criterion: it must terminate, return non-zero
    /// readings from a real S23H, and never hang.
    func readAllRecords(batchSize: Int = 200) async throws -> [Reading] {
        // CRITICAL (handoff §3.10): start at 0, NOT INVALID_DATA_RECORD_POS.
        // KKM's own demo confirms; firmware quirk documented in Android
        // BleConnectionManager.attemptDownload step 2.
        var cursor: UInt32 = 0
        var readings: [Reading] = []

        while true {
            let page = try await readNextPage(cursor: cursor, batchSize: batchSize)
            readings.append(contentsOf: page.readings)

            let next = page.nextCursor
            if next == KBRecordDataRsp.INVALID_DATA_RECORD_POS {
                break    // SDK end-of-data sentinel.
            }
            if next <= cursor {
                break    // Defensive: cursor didn't advance, avoid an infinite loop.
            }
            cursor = next
        }
        return readings
    }
}

extension KBeaconBridge: ConnStateDelegate {
    func onConnStateChange(_ beacon: KBeacon, state: KBConnState, evt: KBConnEvtReason) {
        guard let cont = connectContinuation else {
            // Post-connect state change (e.g. unexpected disconnect during a
            // read). The in-flight read's callback will fire with an error;
            // we just log for visibility here.
            print("[KBeaconBridge] post-connect state=\(state.rawValue) evt=\(evt.rawValue)")
            return
        }

        switch state {
        case .Connecting:
            // Initial .ConnNull notification fires synchronously inside
            // connectEnhanced — ignore, wait for a terminal state.
            return
        case .Connected:
            connectContinuation = nil
            cont.resume(returning: ())
        case .Disconnecting, .Disconnected:
            connectContinuation = nil
            // Capture the reason as a String at the failure site so the
            // SDK enum type doesn't cross the `async` boundary.
            cont.resume(throwing: BridgeError.connectFailed(reason: String(describing: evt)))
        @unknown default:
            connectContinuation = nil
            cont.resume(throwing: BridgeError.connectFailed(reason: String(describing: evt)))
        }
    }
}
