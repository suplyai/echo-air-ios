import Foundation
@preconcurrency import CoreBluetooth

/// Forces iOS to evaluate `NSBluetoothAlwaysUsageDescription` and fire
/// the system permission prompt before any BLE scan starts.
///
/// **Why this exists** — iOS 13+ separates radio state from app-level
/// authorization. `CBCentralManager.state == .poweredOn` reflects the
/// system radio; it can be true even when `CBManager.authorization ==
/// .notDetermined`. In that mixed state, `startScanning()` returns
/// without error, but `didDiscoverPeripheral` callbacks never fire —
/// scans silently return nothing. That's exactly the symptom Phase 5
/// hit on TestFlight: 15s ceiling, zero devices, no error.
///
/// The system prompt is normally triggered when `CBCentralManager` is
/// first instantiated with the Info.plist key present **and** the app
/// is foregrounded. Relying on the SDK's lazy CBCentralManager init
/// (inside `KBeaconsMgr.sharedBeaconManager`) didn't reliably trip
/// that path in practice — the SDK may be on a non-main queue, may
/// init before the SwiftUI window is up, or use options that suppress
/// the system alert. Owning our own `CBCentralManager`, initialised
/// on `MainActor` with default options, takes that variability out.
///
/// **Usage** — call `try await BluetoothPermissionGate.shared.waitForReady()`
/// before any path that touches the SDK's scanner. On first call this
/// instantiates `CBCentralManager` and awaits the state callback; iOS
/// fires the prompt during that window. On subsequent calls it hits a
/// fast path against the already-resolved state.
///
/// Throws `.denied` / `.restricted` if the user previously refused
/// (Settings → Echo Air → Bluetooth); `.poweredOff` if the radio is
/// off; `.unsupported` on simulators / hardware without BLE; and a
/// generic `.unknown` for `@unknown default` cases.
@MainActor
final class BluetoothPermissionGate: NSObject {

    enum GateError: Error, CustomStringConvertible {
        /// User tapped "Don't Allow" on the system prompt previously,
        /// or Bluetooth is off for this app under Settings → Echo Air.
        /// Only fixable by the user re-enabling Bluetooth for the app.
        case denied
        /// Parental controls / MDM restriction. Same remediation as
        /// `.denied` but the user may not have the option.
        case restricted
        /// Radio is off at the system level. User needs to enable
        /// Bluetooth in Control Centre / Settings → Bluetooth.
        case poweredOff
        /// Bluetooth radio is mid-reset. Caller should retry shortly.
        case resetting
        /// Hardware doesn't support BLE (simulator, very old device).
        case unsupported
        /// `@unknown default` from CBManagerState or CBManagerAuthorization.
        case unknown(state: String)

        var description: String {
            switch self {
            case .denied:
                return "Bluetooth permission denied — enable under Settings → Echo Air → Bluetooth"
            case .restricted:
                return "Bluetooth restricted by device policy"
            case .poweredOff:
                return "Bluetooth is off — turn it on in Control Centre or Settings"
            case .resetting:
                return "Bluetooth is resetting — try again in a moment"
            case .unsupported:
                return "This device does not support Bluetooth Low Energy"
            case .unknown(let s):
                return "Bluetooth state could not be determined (\(s))"
            }
        }
    }

    static let shared = BluetoothPermissionGate()

    /// Owned CBCentralManager. Kept alive for the lifetime of the app
    /// so the system prompt fires exactly once and subsequent
    /// `waitForReady()` calls hit the fast path against the resolved
    /// state. We do NOT scan with this instance — the SDK's
    /// KBeaconsMgr owns the actual scanning manager. This one exists
    /// purely to drive the authorization prompt.
    private var centralManager: CBCentralManager?
    private var waiter: CheckedContinuation<Void, Error>?

    /// Returns once `CBCentralManager` has reached `.poweredOn` and
    /// `CBManager.authorization == .allowedAlways`. Throws if anything
    /// in the chain failed (permission denied, radio off, unsupported,
    /// etc.). Safe to call repeatedly — fast-path returns synchronously
    /// once resolved.
    func waitForReady() async throws {
        if let mgr = centralManager, mgr.state != .unknown {
            try Self.classify(state: mgr.state, authorization: CBCentralManager.authorization)
            return
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // Multiple waiters in flight would mean concurrent callers;
            // the orchestrator is serial so this shouldn't happen, but
            // if it does, fail loudly rather than silently dropping a
            // continuation.
            precondition(self.waiter == nil, "BluetoothPermissionGate.waitForReady called concurrently")
            self.waiter = cont
            // Create lazily on first call. `queue: nil` => main queue,
            // which is required for the system prompt to surface on
            // the foreground window.
            if self.centralManager == nil {
                self.centralManager = CBCentralManager(delegate: self, queue: nil)
            }
            // If centralManager already exists but state was .unknown
            // (very fast subsequent call before the first delegate
            // callback), the existing delegate callback will resolve
            // the new waiter.
        }
    }

    /// Pure function — same mapping used on the fast path and from the
    /// delegate callback. `notDetermined` returns without throwing
    /// because the caller is mid-await; the delegate will fire again
    /// once iOS resolves the prompt outcome.
    private static func classify(
        state: CBManagerState,
        authorization: CBManagerAuthorization
    ) throws {
        switch authorization {
        case .denied:        throw GateError.denied
        case .restricted:    throw GateError.restricted
        case .notDetermined: return    // wait for next delegate callback
        case .allowedAlways: break
        @unknown default:    throw GateError.unknown(state: "auth=\(authorization.rawValue)")
        }

        switch state {
        case .poweredOn:    return
        case .poweredOff:   throw GateError.poweredOff
        case .resetting:    throw GateError.resetting
        case .unauthorized: throw GateError.denied    // belt-and-braces; auth check above usually catches this
        case .unsupported:  throw GateError.unsupported
        case .unknown:      return    // wait for next delegate callback
        @unknown default:   throw GateError.unknown(state: "state=\(state.rawValue)")
        }
    }
}

extension BluetoothPermissionGate: CBCentralManagerDelegate {
    // CBCentralManagerDelegate is @objc; iOS dispatches on the manager's
    // queue (main in our case, since we passed nil). Mark nonisolated +
    // hop to MainActor for strict-concurrency cleanliness, matching the
    // pattern used in KBeaconScanner.
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Capture Sendable values before the actor hop — CBManagerState
        // and CBManagerAuthorization are @objc enums; the rawValue is
        // a plain Int which is Sendable.
        let stateRaw = central.state.rawValue
        let authRaw = CBCentralManager.authorization.rawValue
        Task { @MainActor in
            guard let state = CBManagerState(rawValue: stateRaw),
                  let auth = CBManagerAuthorization(rawValue: authRaw) else {
                return
            }
            // `.notDetermined` + `.unknown` means iOS hasn't decided
            // yet (e.g. prompt still on screen). Don't resolve the
            // waiter — wait for the next callback.
            if auth == .notDetermined || state == .unknown {
                return
            }
            guard let cont = self.waiter else { return }
            self.waiter = nil
            do {
                try Self.classify(state: state, authorization: auth)
                cont.resume(returning: ())
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}
