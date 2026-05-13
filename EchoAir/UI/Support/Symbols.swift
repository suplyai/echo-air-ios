import Foundation

/// SF Symbol vocabulary used across the app for transport-mode
/// iconography. Centralised so iOS-version availability guards don't
/// scatter through view code.
enum Symbols {
    /// Air-transport route icon — iOS 16 baseline, no guard needed.
    static let airRoute = "airplane"

    /// Ocean-transport route icon. Prefers iOS 17+ `ferry` (commercial
    /// vessel, reads as container shipping); falls back to `sailboat`
    /// on iOS 16 since SF Symbols 4 has no commercial-shipping option.
    /// `sailboat` reads as a yacht, which is wrong for container
    /// shipping — surfaced in pilot review of the v0.7.0 build.
    static var oceanRoute: String {
        if #available(iOS 17.0, *) { return "ferry" }
        return "sailboat"
    }
}
