import Foundation
import kbeaconlib2

// SDK reference: github.com/kkmhogen/kbeaconlib2 (1.2.x), source verified.
// Demo for usage patterns: github.com/kkmhogen/KBeaconProDemo_Ios — the
// demo uses KBSensorReadOption.NewRecord; we use NormalOrder because Echo
// Air devices are single-use and we always want full history (handoff §3.10).
//
// Threading: the SDK's CoreBluetooth callbacks land on the main queue
// (KBeaconsMgr inits CBCentralManager without a custom queue). The
// ConnStateDelegate implementation below assumes single-threaded access
// to `connectContinuation`. If SWIFT_STRICT_CONCURRENCY=complete flags
// this file, the cheapest dial-back is to set strict concurrency to
// `targeted` per Phase 1 SESSION_NOTES flag #2.
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
        case connectFailed(KBConnEvtReason)
        case readInfoFailed(KBException?)
        case readRecordFailed(KBException?)

        var description: String {
            switch self {
            case .requestRejected:
                return "connectEnhanced rejected request — password must be 8-16 chars and timeout > 3s"
            case .connectFailed(let reason):
                return "connect failed: reason=\(reason)"
            case .readInfoFailed(let error):
                return "readSensorDataInfo failed: \(error?.errorDescription ?? "n/a")"
            case .readRecordFailed(let error):
                return "readSensorRecord failed: \(error?.errorDescription ?? "n/a")"
            }
        }
    }

    /// One temperature/humidity sample. Types match the SDK's KBRecordHumidity
    /// (utcTime UInt32, temperature/humidity Float). `humidity` is 0 / NaN on
    /// temp-only S23 variants — the record class is shared with S23H.
    struct Reading: Equatable, CustomStringConvertible {
        let utcTime: UInt32
        let temperature: Float
        let humidity: Float

        var description: String {
            String(format: "utc=%u t=%.2f h=%.2f", utcTime, temperature, humidity)
        }
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
    func readSensorDataInfo() async throws -> KBRecordInfoRsp {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<KBRecordInfoRsp, Error>) in
            beacon.readSensorDataInfo(KBSensorType.HTHumidity) { result, infoRsp, error in
                if result, let info = infoRsp {
                    cont.resume(returning: info)
                } else {
                    cont.resume(throwing: BridgeError.readInfoFailed(error))
                }
            }
        }
    }

    /// Reads one paged batch of records starting at `cursor`. End-of-data is
    /// signalled by the SDK returning `INVALID_DATA_RECORD_POS` as the next
    /// cursor — callers (or `readAllRecords` below) stop the loop on that
    /// sentinel.
    func readNextPage(cursor: UInt32, batchSize: Int = 200) async throws -> KBRecordDataRsp {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<KBRecordDataRsp, Error>) in
            beacon.readSensorRecord(
                KBSensorType.HTHumidity,
                number: cursor,
                option: KBSensorReadOption.NormalOrder,
                max: batchSize
            ) { result, recordRsp, error in
                if result, let rsp = recordRsp {
                    cont.resume(returning: rsp)
                } else {
                    cont.resume(throwing: BridgeError.readRecordFailed(error))
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
            let rsp = try await readNextPage(cursor: cursor, batchSize: batchSize)

            let page = (rsp.readDataRspList as? [KBRecordHumidity]) ?? []
            for record in page {
                readings.append(Reading(
                    utcTime: record.utcTime,
                    temperature: record.temperature,
                    humidity: record.humidity
                ))
            }

            let next = rsp.readDataNextPos
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
            cont.resume(throwing: BridgeError.connectFailed(evt))
        @unknown default:
            connectContinuation = nil
            cont.resume(throwing: BridgeError.connectFailed(evt))
        }
    }
}
