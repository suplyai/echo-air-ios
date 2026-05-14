import Foundation
@preconcurrency import kbeaconlib2

/// Per-device row state surfaced by `CollectionViewModel`. The view
/// reads `status` directly to pick the localised state string and the
/// status pill colour. `attempt` is 1-based and only meaningful while
/// the orchestrator is mid-retry. `response` is captured on the last
/// successful upload — the orchestrator uses the final response
/// across all devices to drive the post-collection completion banner.
///
/// Plain `Sendable` value type — all stored properties are themselves
/// Sendable, so no actor isolation is required. The owning
/// `CollectionViewModel` (`@MainActor`) is what serialises access.
struct DeviceCollectionState: Identifiable, Equatable, Sendable {
    let device: ShipmentDeviceDto
    var id: String { device.deviceId }

    enum Status: Equatable {
        case idle
        case searching      // scanning for advert
        case connecting     // GATT connect in progress
        case reading        // reading sensor info + paging records
        case uploading      // POST /api/echo-scan in flight
        case collected      // success — response captured
        case missing        // discovery timed out (no advert within ceiling)
        case failed         // 3 attempts exhausted with non-discovery errors
    }

    var status: Status = .idle
    var attempt: Int = 0
    var lastError: String? = nil
    var response: EchoScanResponse? = nil
}

/// Drives per-device scan → connect → read → upload for the resolved
/// shipment, serially. Phase 5 scope (handoff §3.10 + Phase 5 plan):
///
/// • Serial, not parallel. Android collects up to 4 concurrently
///   (`MAX_CONCURRENT = 4`); on iOS Phase 5 keeps it serial to de-risk
///   the first BLE-in-real-UI cut. Parallel deferred to a later phase.
/// • Up to 3 attempts per device. `.missing` (discovery timeout) does
///   NOT retry — the device isn't in range. Other errors retry with a
///   500ms inter-attempt delay.
/// • Explicit `beacon.disconnect()` after each device. Load-bearing
///   per the v0.7.0 builder — leaving connections open across devices
///   has caused stalls on Android in the past.
/// • One POST `/api/echo-scan` per device. `device_clock_offset_seconds`
///   is `phoneUtc - device.readInfoUtcSeconds` captured at the moment
///   we read sensor-info (handoff §3.10 / `syncUtcTime=false`).
/// • Location capture deferred to P6 — `location` is sent as `nil`.
/// • No offline upload queue — a failed upload means that device's
///   data is lost and must be re-collected (acknowledged P5 gap;
///   queue lands in P6).
@MainActor
final class CollectionViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case running
        case finished
    }

    @Published private(set) var devices: [DeviceCollectionState]
    @Published private(set) var phase: Phase = .idle
    /// The most recent successful upload response. `allScanned`,
    /// `temperatureAlert`, etc. drive the post-collection screen state.
    @Published private(set) var lastResponse: EchoScanResponse? = nil

    /// On-screen BLE diagnostic. Runs in parallel with the SDK's
    /// scanner so a TestFlight tester can see what iOS actually
    /// receives on the air, without needing USB / Console. Started in
    /// `start()` after the permission gate resolves; stopped when the
    /// Collection view disappears. **Temporary** — remove once
    /// discovery is fixed.
    let diagnostic = BleDiagnosticScanner()

    let shipment: ShipmentDto
    private let api: APIClient

    /// §3.10 default; per-attempt connect ceiling in ms.
    private let connectTimeoutMs: Int = 20_000
    /// §3.10 default; records per `readSensorRecord` call.
    private let batchSize: Int = 200
    private let maxAttempts: Int = 3
    private let interAttemptDelayMs: UInt64 = 500

    init(shipment: ShipmentDto, api: APIClient = .shared) {
        self.shipment = shipment
        self.api = api
        self.devices = shipment.devices.map { DeviceCollectionState(device: $0) }
    }

    /// Entry point — call once when the collection screen appears.
    /// Idempotent: re-entry while `.running` is a no-op.
    func start() async {
        guard phase != .running else { return }
        phase = .running

        // Force the iOS Bluetooth permission prompt BEFORE touching the
        // SDK's CBCentralManager. Without this, iOS lets startScanning()
        // succeed against an un-prompted CB instance and silently
        // suppresses discovery callbacks — the symptom is a 15s scan
        // ceiling with zero devices and no error. See
        // BluetoothPermissionGate's docstring for the full quirk.
        //
        // If the user denies (or has previously denied) Bluetooth, mark
        // every device with the gate's error message and bail out of
        // the device loop. Retrying the scan won't help — only the user
        // re-enabling in Settings → Echo Air → Bluetooth can.
        do {
            try await BluetoothPermissionGate.shared.waitForReady()
        } catch {
            let message = String(describing: error)
            for index in devices.indices {
                updateDevice(at: index) { state in
                    state.status = .failed
                    state.attempt = 1
                    state.lastError = message
                }
            }
            phase = .finished
            return
        }

        // Kick off the diagnostic scanner alongside the real device
        // loop. Targets are every device on the shipment that has a
        // MAC; devices without a MAC can't be matched and are already
        // surfaced as `.failed` by `attemptCollect`. The diagnostic
        // runs continuously until `stopDiagnostic()` is called from
        // the view's `.onDisappear`.
        diagnostic.start(targets: shipment.devices.compactMap { $0.mac })

        for index in devices.indices {
            await collectDevice(at: index)
        }

        phase = .finished
    }

    /// Stop the diagnostic scan. Called from the Collection view's
    /// `.onDisappear` so the radio isn't left hot after the user
    /// navigates back. Discoveries remain in the @Published array so
    /// the panel preserves its content if the view momentarily
    /// re-appears (e.g. during a navigation animation).
    func stopDiagnostic() {
        diagnostic.stop()
    }

    // MARK: - Per-device retry loop

    private func collectDevice(at index: Int) async {
        for attempt in 1...maxAttempts {
            updateDevice(at: index) { state in
                state.attempt = attempt
                state.status = .searching
                state.lastError = nil
            }

            let outcome = await attemptCollect(index: index)

            switch outcome {
            case .collected(let response):
                updateDevice(at: index) { state in
                    state.status = .collected
                    state.response = response
                    state.lastError = nil
                }
                lastResponse = response
                return

            case .missing:
                // No advert within the scan ceiling — the device isn't
                // in range. Retrying immediately won't help; surface as
                // .missing and move on. Source the display seconds
                // from `KBeaconScanner.defaultTimeoutSec` so this
                // message can't drift if the timeout is retuned later.
                updateDevice(at: index) { state in
                    state.status = .missing
                    state.lastError = String(describing: KBeaconScanner.ScannerError.discoveryTimeout(
                        seconds: Int(KBeaconScanner.defaultTimeoutSec)
                    ))
                }
                return

            case .failed(let error):
                let message = String(describing: error)
                if attempt < maxAttempts {
                    updateDevice(at: index) { state in
                        state.status = .failed
                        state.lastError = message
                    }
                    try? await Task.sleep(nanoseconds: interAttemptDelayMs * 1_000_000)
                    continue
                }
                updateDevice(at: index) { state in
                    state.status = .failed
                    state.lastError = message
                }
                return
            }
        }
    }

    // MARK: - One attempt

    private enum AttemptOutcome {
        case collected(EchoScanResponse)
        case missing
        case failed(Error)
    }

    private func attemptCollect(index: Int) async -> AttemptOutcome {
        let device = devices[index].device

        guard let mac = device.mac, !mac.isEmpty else {
            // Backend hands us devices without a MAC on legacy fleet
            // entries; treat as a permanent failure so the row reports
            // a usable error rather than spinning through 3 retries.
            return .failed(CollectionError.missingMac(deviceId: device.deviceId))
        }

        let scanner = KBeaconScanner()
        let beacon: KBeacon
        do {
            beacon = try await scanner.discover(mac: mac)
        } catch let error as KBeaconScanner.ScannerError {
            if case .discoveryTimeout = error {
                return .missing
            }
            return .failed(error)
        } catch {
            return .failed(error)
        }

        // Disconnect once we're done with this beacon, regardless of
        // outcome. Load-bearing for multi-device sequencing — leaving
        // a stale connection open has caused subsequent scans to stall
        // on Android (handoff). `disconnect()` is a no-op when the
        // beacon never reached the connected state.
        defer { beacon.disconnect() }

        let bridge = KBeaconBridge(beacon: beacon)

        updateDevice(at: index) { $0.status = .connecting }
        do {
            try await bridge.connect(
                password: KBeaconCredentials.password,
                timeoutMs: connectTimeoutMs
            )
        } catch {
            return .failed(error)
        }

        updateDevice(at: index) { $0.status = .reading }
        let info: KBeaconBridge.SensorInfo
        let readings: [KBeaconBridge.Reading]
        do {
            info = try await bridge.readSensorDataInfo()
            readings = try await bridge.readAllRecords(batchSize: batchSize)
        } catch {
            return .failed(error)
        }

        // Capture phone UTC at the moment we have sensor-info in hand
        // — matches Android's offset definition for the §3.10 fusion
        // layer. Use Int64 arithmetic so a device clock ahead of the
        // phone (negative offset) doesn't underflow UInt32.
        let phoneUtcSec = UInt32(Date().timeIntervalSince1970)
        let offsetSec = Int64(phoneUtcSec) - Int64(info.readInfoUtcSeconds)

        let request = EchoScanRequest(
            deviceId: device.deviceId,
            temperatureRecords: readings.map { reading in
                ReadingDto(
                    temperature: Double(reading.temperature),
                    // Temp-only S23 variants return NaN here — the
                    // wire format uses null, not NaN (JSON rejects NaN
                    // and the backend expects an absent humidity).
                    humidity: reading.humidity.isNaN ? nil : Double(reading.humidity),
                    // KBeacon utcTime is UInt32 *seconds*. Android
                    // sends millis (Java/Kotlin convention) — same
                    // here, ×1000. FLAGGED: ReadingDto.timestamp unit
                    // is unverified against Android wire output;
                    // confirm before mass rollout.
                    timestamp: Int(reading.utcTime) * 1000
                )
            },
            deviceClockOffsetSeconds: Int(offsetSec),
            location: nil    // P6: capture one-shot fix here.
        )

        updateDevice(at: index) { $0.status = .uploading }
        do {
            let response = try await api.submitEchoScan(request)
            return .collected(response)
        } catch {
            return .failed(error)
        }
    }

    // MARK: - Mutation helper

    /// Mutates one row in-place and republishes the array. Using a
    /// closure (rather than passing `inout` across the actor boundary)
    /// keeps Swift 6 happy and keeps the mutation atomic from SwiftUI's
    /// diffing perspective.
    private func updateDevice(at index: Int, _ mutate: (inout DeviceCollectionState) -> Void) {
        guard devices.indices.contains(index) else { return }
        var copy = devices[index]
        mutate(&copy)
        devices[index] = copy
    }
}

/// Orchestrator-level errors. Bridge / scanner / API errors flow
/// through unchanged; this enum only covers conditions the orchestrator
/// itself originates.
enum CollectionError: Error, CustomStringConvertible {
    case missingMac(deviceId: String)

    var description: String {
        switch self {
        case .missingMac(let id):
            return "device \(id) has no MAC address on file"
        }
    }
}
