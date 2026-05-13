import UIKit

/// Cross-screen haptic vocabulary mirroring Android's `EchoHaptics`.
///
/// • `softTap` — soft confirmation. Fired when an inline match resolves
///   without commitment (e.g. AWB airline prefix matched a known carrier).
/// • `tick` — primary CTA committed (Continue, Start scanning).
///
/// Inlined on iOS rather than ported from Kotlin since the surface is
/// just two `UIImpactFeedbackGenerator` invocations. Generators are
/// created at call time — short-lived UI events don't need the
/// `prepare()` optimisation for cached actuator warmup.
enum EchoHaptics {
    static func softTap() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    static func tick() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
