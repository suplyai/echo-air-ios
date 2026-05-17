import Foundation

/// Production-path KBeacon device password.
///
/// **Not a secret.** This is the public KKM factory default applied
/// to every KBeacon device ever shipped — identical across the
/// production fleet and every test device that works with the
/// off-the-shelf KBeacon Pro app from the App Store. Hardcoded here
/// in source, the same way Android's consignee app hardcodes it as
/// `KBeaconIds.DEFAULT_PASSWORD`. No re-provisioning per shipment.
///
/// **Why this is hardcoded and not plumbed through `Info.plist` (PR
/// #17).** PR #5 originally wired the password through Local.xcconfig
/// → Info.plist `$(SPIKE_DEVICE_PASSWORD)` substitution, on the
/// assumption that production passwords were secrets to be kept out
/// of source. They aren't. The result was that the release manager's
/// build machine had no `Local.xcconfig` filled in, so every
/// production archive shipped with an empty password string — every
/// `connectEnhanced` call got rejected at the SDK's 8-16-char guard
/// inside `KBeaconBridge.connect` (`BridgeError.requestRejected`).
/// Moving the value into source code matches Android's approach,
/// guarantees the password is in every build regardless of who built
/// it, and reflects that the value is non-secret.
///
/// **Why sixteen zeros, not ten.** The original `SPIKE_DEVICE_PASSWORD`
/// example value in `Local.xcconfig.template` was `"0000000000"` (ten
/// zeros). That passes the SDK's 8-16 char length gate but is the
/// wrong value — the actual KKM factory default is sixteen ASCII
/// zeros. Verified against the Android consignee app's
/// `KBeaconIds.DEFAULT_PASSWORD` constant, which connects to the same
/// devices the iOS app is trying to reach. The ten-zero value was a
/// guess that wasn't.
///
/// `SpikeConfig.devicePassword` (`#if DEBUG`-only) still reads from
/// `SPIKE_DEVICE_PASSWORD` in Local.xcconfig — kept as a developer
/// override so the spike harness can be pointed at a re-provisioned
/// or non-factory-default device for testing. Production connect
/// (`CollectionViewModel` → `KBeaconBridge.connect` →
/// `KBeaconCredentials.password`) never touches that xcconfig path.
enum KBeaconCredentials {
    /// KKM factory default — sixteen ASCII zeros. Matches Android's
    /// `KBeaconIds.DEFAULT_PASSWORD` byte-for-byte.
    static let password = "0000000000000000"
}
