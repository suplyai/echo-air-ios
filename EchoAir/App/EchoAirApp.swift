import SwiftUI

@main
struct EchoAirApp: App {
    init() {
        // Must run BEFORE any SwiftUI view body evaluates so the first
        // frame is in the right language. No-op on first launch (no
        // stored choice yet) — the system locale is used until the
        // first-launch gate confirms.
        LocaleManager.restore()
        // Warm the IATA prefix cache so the first user keystroke on
        // the AWB prefix field hits a loaded map.
        IataCarriers.warmup()
    }

    var body: some Scene {
        WindowGroup {
            FirstLaunchLanguageGate {
                ContentView()
            }
        }
    }
}
