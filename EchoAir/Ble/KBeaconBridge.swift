import Foundation
import kbeaconlib2

// STATUS: SCAFFOLDED REMOTELY, NOT YET COMPILED.
//
// This file compiles only after `pod install` brings in kbeaconlib2 1.2.x
// AND the engineer verifies the SDK selectors below against the installed
// pod. Method signatures are best-effort against the API surface listed in
// the Android repo's `docs/ios-port-handoff.md` §1; sites needing
// confirmation are tagged `// TODO(spike): verify`.
//
// What MUST stay correct regardless of selector spelling (handoff §3.10):
//   • syncUtcTime = false       (preserve device clock drift for the
//                                backend's `device_clock_offset_seconds`)
//   • readCommPara = true       (MTU + common config at connect time)
//   • readSensorPara = true     (required for sensor-history reads)
//   • readTriggerPara = false   (not used by Echo Air)
//   • readSlotPara    = false   (not used by Echo Air)
//   • Sensor type     = HTHumidity (S23 + S23H both use this)
//   • Read option     = NormalOrder (single-use devices, full history,
//                                    do NOT advance the unread pointer)
//   • Initial cursor  = 0 (Int64), NOT KBRecordDataRsp.INVALID_DATA_RECORD_POS
//   • End-of-data sentinel = INVALID_DATA_RECORD_POS (returned by SDK
//                                                    when no more records)
//   • Batch size      = 200 records per readSensorRecord call
//   • Connect timeout = 20_000 ms
//
// Reference (Android side): `BleConnectionManager.attemptDownload` Step 2
// in suplyai/echo-air. The firmware quirk that makes initial cursor `0`
// the only working value is documented in that file's long comment.

@MainActor
final class KBeaconBridge {
    enum BridgeError: Error {
        case notConnected
        case connectFailed(Error?)
        case readInfoFailed(Error?)
        case readRecordFailed(Error?)
    }

    /// One temperature/humidity sample. `humidity` is 0 / NaN on temp-only
    /// S23 variants — the record class is shared with S23H.
    struct Reading: Equatable {
        let utcTime: Int64
        let temperature: Double
        let humidity: Double
    }

    private let beacon: KBeacon

    init(beacon: KBeacon) {
        self.beacon = beacon
    }

    /// Connect with the §3.10 connect parameters set explicitly. Treat the
    /// param values here as load-bearing — flipping any of them changes
    /// the data we collect or the device's RTC.
    func connect(password: String, timeoutMs: Int = 20_000) async throws {
        let para = KBConnPara()
        para.syncUtcTime = false
        para.readCommPara = true
        para.readSensorPara = true
        para.readTriggerPara = false
        para.readSlotPara = false

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // TODO(spike): verify exact connectEnhanced signature in 1.2.x.
            // Closure shape is documented in handoff §1 as
            // `(Bool, Response?, Exception?) -> Void` for read calls;
            // connectEnhanced may instead deliver a state enum + error.
            beacon.connectEnhanced(password, timeout: Int32(timeoutMs), connPara: para) { state, error in
                if let error {
                    cont.resume(throwing: BridgeError.connectFailed(error))
                    return
                }
                if state == KBStateConnected {
                    cont.resume(returning: ())
                }
                // Transient states (connecting, disconnecting) are noise
                // here; only resolve on terminal states.
            }
        }
    }

    /// Read the device's sensor-data summary (record count, oldest /
    /// newest cursors). Used by the spike to confirm the device has data.
    func readSensorDataInfo() async throws -> KBSensorDataInfoRsp {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<KBSensorDataInfoRsp, Error>) in
            // TODO(spike): verify call shape — likely
            //   readSensorDataInfo(KBSensorType.HTHumidity, callback: { ... })
            beacon.readSensorDataInfo(KBSensorType.HTHumidity) { success, response, error in
                if !success || response == nil {
                    cont.resume(throwing: BridgeError.readInfoFailed(error))
                } else {
                    cont.resume(returning: response!)
                }
            }
        }
    }

    /// One paged batch of records starting at `cursor`. End-of-data is
    /// signalled by the SDK returning `INVALID_DATA_RECORD_POS` as the
    /// next cursor — callers stop the loop on that sentinel.
    func readNextPage(cursor: Int64, batchSize: Int = 200) async throws -> KBRecordDataRsp {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<KBRecordDataRsp, Error>) in
            // TODO(spike): verify readSensorRecord parameter labels.
            beacon.readSensorRecord(
                KBSensorType.HTHumidity,
                option: KBSensorReadOption.NormalOrder,
                cursor: cursor,
                count: Int32(batchSize)
            ) { success, response, error in
                if !success || response == nil {
                    cont.resume(throwing: BridgeError.readRecordFailed(error))
                } else {
                    cont.resume(returning: response!)
                }
            }
        }
    }

    /// Drives the full paged read against §3.10's invariants. This is the
    /// spike's primary pass criterion: it must terminate, return non-zero
    /// readings from a real S23H, and never hang.
    func readAllRecords(batchSize: Int = 200) async throws -> [Reading] {
        var cursor: Int64 = 0   // CRITICAL: 0, NOT INVALID_DATA_RECORD_POS.
                                // KKM's own demo confirms; firmware quirk.
        var readings: [Reading] = []

        while true {
            let rsp = try await readNextPage(cursor: cursor, batchSize: batchSize)

            // TODO(spike): verify accessor names — likely `rsp.records`
            // (typed as [KBRecordHumidity] for HTHumidity sensor) and
            // `rsp.readDataNextPos` (Int64 cursor for the next page).
            let page = (rsp.records as? [KBRecordHumidity]) ?? []
            for record in page {
                readings.append(Reading(
                    utcTime: record.utcTime,
                    temperature: Double(record.temperature),
                    humidity: Double(record.humidity)
                ))
            }

            let next = rsp.readDataNextPos
            if next == KBRecordDataRsp.INVALID_DATA_RECORD_POS || next <= cursor {
                break
            }
            cursor = next
        }
        return readings
    }
}
