import Foundation
import Combine

/// Drives mid-session language switching. SwiftUI views observe via
/// `@StateObject` / `@ObservedObject` / `.environmentObject(...)`; on
/// `applyLanguage(_:)`, observing views re-render and their
/// `Text(LocalizedStringKey)` lookups pick up the new bundle.
///
/// Three things happen on apply:
///   1. `LocaleManager.apply(...)` — saves the choice in `UserDefaults`
///      and syncs `AppleLanguages` so the choice persists across launches.
///   2. `Bundle.installLanguageOverride(tag:)` — swaps `Bundle.main`'s
///      class so subsequent `localizedString(...)` calls read from the
///      chosen locale's `.lproj`.
///   3. `currentLocale` publishes the change — observing views re-render.
///
/// The class-swap pattern is well-trodden (Localize-Swift, several other
/// "in-app language switcher" libraries) and is the only iOS-supported
/// way to switch `NSLocalizedString` resolution at runtime without a
/// process relaunch. Wrapped here as `Bundle.installLanguageOverride` so
/// view code never sees the Obj-C runtime calls.
///
/// `@MainActor` because the underlying Obj-C runtime hop (`object_setClass`
/// on `Bundle.main`) is single-threaded by convention, and SwiftUI
/// re-render requires `@Published` mutations on the main actor.
@MainActor
final class LocalizationController: ObservableObject {

    static let shared = LocalizationController()

    /// The locale currently in effect. Bumped whenever `applyLanguage`
    /// installs a new bundle override; SwiftUI views observing this
    /// controller re-render and pick up the new strings.
    @Published private(set) var currentLocale: AppLocale

    private init() {
        let initial = LocaleManager.effectiveLocale()
        currentLocale = initial
        // Install the override at construction so the first frame already
        // renders in the right language. `LocalizationController.shared`
        // is bootstrapped from `EchoAirApp.init()` BEFORE any view body
        // evaluates.
        Bundle.installLanguageOverride(tag: initial.tag)
    }

    /// Apply a new language live. Persists the choice, swaps the bundle,
    /// and publishes the change so observing views re-render with the new
    /// strings. Idempotent — applying the current locale is a no-op aside
    /// from a single `objectWillChange` emission.
    func applyLanguage(_ locale: AppLocale) {
        #if DEBUG
        print("[Localization] applyLanguage(\(locale.tag)) ENTER (current=\(currentLocale.tag))")
        #endif

        LocaleManager.apply(locale)
        #if DEBUG
        print("[Localization] applyLanguage(\(locale.tag)) — LocaleManager.apply done")
        #endif

        Bundle.installLanguageOverride(tag: locale.tag)
        #if DEBUG
        print("[Localization] applyLanguage(\(locale.tag)) — Bundle.installLanguageOverride done")
        #endif

        currentLocale = locale
        #if DEBUG
        print("[Localization] applyLanguage(\(locale.tag)) — currentLocale assignment done")
        let post = NSLocalizedString("language_picker_title", comment: "")
        print("[Localization] applyLanguage(\(locale.tag)) post-swap NSLocalizedString(language_picker_title) = \"\(post)\"")
        print("[Localization] applyLanguage(\(locale.tag)) EXIT")
        #endif
    }
}
