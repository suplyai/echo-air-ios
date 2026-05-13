import SwiftUI

@main
struct EchoAirApp: App {
    init() {
        // Persistence-layer restore — writes the stored choice (if any)
        // into AppleLanguages so cold-start NSLocalizedString resolves
        // correctly even before the bundle override is installed.
        LocaleManager.restore()
        // Force LocalizationController.shared to initialise NOW (its
        // init installs `Bundle.installLanguageOverride` for the
        // effective locale) BEFORE any SwiftUI view body evaluates, so
        // the first frame already renders in the chosen language.
        _ = LocalizationController.shared
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
