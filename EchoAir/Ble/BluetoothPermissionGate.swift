import Foundation
@preconcurrency import CoreBluetooth

/// Forces iOS to evaluate `NSBluetoothAlwaysUsageDescription` and fire
/// the system permission prompt before any BLE scan starts, then
/// **tears its own `CBCentralManager` down before returning** so the
/// SDK's `KBeaconsMgr` is the only CB instance live in process during
/// the production scan.
///
/// **Why this exists** — iOS 13+ separates radio state from app-level
/// authorization. `CBCentralManager.state == .poweredOn` reflects the
/// system radio; it can be true even when `CBManager.authorization ==
/// .notDetermined`. In that mixed state, `startScanning()` returns
/// without error, but `didDiscoverPeripheral` callbacks never fire —
/// scans silently return nothing. (Original Phase 5 symptom.)
///
/// **Why transient (PR #13)** — keeping the gate's `CBCentralManager`
/// alive alongside the SDK's `KBeaconsMgr` CBCentralManager caused a
/// follow-on symptom observed on real hardware: iOS delivered a
/// peripheral's System-slot advertisement to our diagnostic
/// CBCentralManager (third one in process, kept alive on purpose) and
/// to the gate's (when it was kept alive), but NOT to the SDK's. The
/// diagnostic panel showed `MATCH ✓` on the target MAC; the
/// production scanner timed out at 25s with `.missing`. Tearing the
/// gate's CB down after the prompt resolves (via `defer` inside
/// `waitForReady`) gives the SDK sole ownership of the radio scan
/// path. The diagnostic CBCentralManager is itself temporary and
/// will be removed in the diagnostic-cleanup follow-up PR once
/// discovery is confirmed working.
///
/// **Usage** — call `try await BluetoothPermissionGate.shared.waitForReady()`
/// before any path that touches the SDK's scanner. On the first call
/// ever (authorization == `.notDetermined`), this instantiates
/// `CBCentralManager` to trigger the prompt, awaits the state
/// callback, then deallocates the CB before returning. Subsequent
/// calls hit a process-wide `CBCentralManager.authorization`
/// fast path that never creates a CB instance at all.
///
/// Throws `.denied` / `.restricted` if the user previously refused
/// (Settings → Echo Air → Bluetooth); `.poweredOff` only via the
/// first-call delegate path (subsequent calls hand radio-off
/// detection to the SDK's own `centralBLEState` pre-check inside
/// `KBeaconScanner.discover`); `.unsupported` on simulators / hardware
/// without BLE; and a generic `.unknown` for `@unknown default` cases.
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

    /// Transient CBCentralManager — created ONLY when iOS authorization
    /// is `.notDetermined` (on the very first call ever), kept alive
    /// only long enough for the system prompt to fire and the delegate
    /// callback to resolve, then torn down via `releaseCentralManager()`
    /// from `waitForReady`'s defer. Nil at every other moment in the
    /// app's lifetime. We do NOT scan with this instance — the SDK's
    /// `KBeaconsMgr` owns the actual scanning manager. This one exists
    /// purely to drive the authorization prompt.
    private var centralManager: CBCentralManager?
    private var waiter: CheckedContinuation<Void, Error>?

    /// Returns once Bluetooth authorization has resolved to
    /// `.allowedAlways`. Throws if the user has denied / the OS
    /// restricts / hardware doesn't support BLE / `@unknown default`.
    /// Safe to call repeatedly — once authorization is granted,
    /// every subsequent call is a process-wide constant-time check
    /// that creates no CB instance.
    func waitForReady() async throws {
        // Always tear down our CBCentralManager before this function
        // returns, by any path (success, throw). See
        // `releaseCentralManager()` and the file-level docstring for
        // the multi-CB interference rationale.
        defer { releaseCentralManager() }

        // Fast path — `CBCentralManager.authorization` is a class
        // property that survives any individual CBCentralManager
        // being deallocated. After the very first call grants
        // permission, every subsequent call resolves here without
        // creating a CB instance at all, so iOS sees zero CBs from
        // the gate once the SDK's own scan kicks in.
        switch CBCentralManager.authorization {
        case .allowedAlways:
            return
        case .denied:
            throw GateError.denied
        case .restricted:
            throw GateError.restricted
        case .notDetermined:
            break    // fall through to the prompt path below
        @unknown default:
            throw GateError.unknown(state: "auth=\(CBCentralManager.authorization.rawValue)")
        }

        // Slow path — first call ever, authorization is undetermined.
        // Create our CBCentralManager so iOS evaluates Info.plist's
        // NSBluetoothAlwaysUsageDescription and fires the system
        // prompt. Await the delegate callback to learn the outcome.
        // The `defer` above tears the CB down before we return, so
        // it doesn't outlive this call. Subsequent calls will hit
        // the fast path above and never reach this point again.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            precondition(self.waiter == nil, "BluetoothPermissionGate.waitForReady called concurrently")
            self.waiter = cont
            // `queue: nil` => main queue, which is required for the
            // system prompt to surface on the foreground window.
            self.centralManager = CBCentralManager(delegate: self, queue: nil)
        }
    }

    /// Sole owner of the CBCentralManager teardown. Sets the delegate
    /// to nil first so any in-flight delegate dispatches from the SDK
    /// queue land in a no-op (delegate methods route through `self`
    /// only while the delegate property points to us), then drops the
    /// strong reference so ARC deallocates the instance and iOS
    /// reclaims its slot in the per-process active-CB pool. Called
    /// from `waitForReady`'s defer; idempotent — no-op on entry when
    /// `centralManager` is already nil (the fast path never creates
    /// one).
    private func releaseCentralManager() {
        if let mgr = centralManager {
            mgr.delegate = nil
            centralManager = nil
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
