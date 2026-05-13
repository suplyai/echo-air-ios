import Foundation

/// Per-app locale persistence — the durable side of the language story.
///
/// `LocaleManager` owns the UserDefaults entry that persists the user's
/// language choice across launches and the `AppleLanguages` sync that
/// lets iOS pick up the right locale on cold start. It does NOT touch
/// the running `Bundle.main` — mid-session re-rendering of localised
/// strings is `LocalizationController`'s job (it calls
/// `Bundle.installLanguageOverride` on top of these persistence writes).
///
/// Two-layer split:
///   • `LocaleManager` — persistence + first-launch flag.
///   • `LocalizationController` — runtime Bundle swap + `@Published`
///     `currentLocale` for SwiftUI observation.
///
/// Both layers cooperate: `LocalizationController.applyLanguage` calls
/// `LocaleManager.apply` to persist the choice, then installs the
/// bundle override, then publishes the change.
///
/// Translated from the `LocaleManager` companion in
/// `app/src/main/kotlin/app/suply/echoair/ui/locale/AppLocale.kt`.
enum LocaleManager {

    private enum Key {
        static let chosenTag       = "chosen_language_tag"
        static let firstLaunchDone = "first_launch_confirmed"
        /// The system key NSLocalizedString reads on next launch.
        static let appleLanguages  = "AppleLanguages"
    }

    private static var defaults: UserDefaults { .standard }

    // MARK: - State

    /// The locale the user last chose, or nil if they haven't chosen yet.
    static func storedLocale() -> AppLocale? {
        guard let tag = defaults.string(forKey: Key.chosenTag) else { return nil }
        return AppLocale.fromTag(tag)
    }

    /// True once the user has confirmed (or picked) a language on first
    /// launch. Persisted across app launches.
    static var hasConfirmedFirstLaunch: Bool {
        defaults.bool(forKey: Key.firstLaunchDone)
    }

    /// What language should the app render right now?
    /// Precedence: explicit user choice → detected system default → English.
    static func effectiveLocale() -> AppLocale {
        if let stored = storedLocale() { return stored }
        if let system = AppLocale.fromSystemDefault() { return system }
        return .default
    }

    // MARK: - Effects

    /// Save the user's choice + sync `AppleLanguages` so subsequent
    /// `NSLocalizedString` lookups resolve against the chosen bundle on
    /// next launch. Caller is responsible for prompting relaunch if a
    /// mid-session switch should take effect immediately.
    static func apply(_ locale: AppLocale) {
        defaults.set(locale.tag, forKey: Key.chosenTag)
        defaults.set([locale.tag], forKey: Key.appleLanguages)
    }

    /// Mark the first-launch confirmation as complete. Called from the
    /// first-launch dialog after the user accepts the detected language
    /// or picks a different one.
    static func markFirstLaunchConfirmed() {
        defaults.set(true, forKey: Key.firstLaunchDone)
    }

    /// Re-apply the stored choice to `AppleLanguages` at app start.
    /// **Must be called from `EchoAirApp.init()` BEFORE any view
    /// renders** so the first frame is in the right language. No-op
    /// when no stored choice exists (first launch, before the dialog).
    static func restore() {
        guard let stored = storedLocale() else { return }
        defaults.set([stored.tag], forKey: Key.appleLanguages)
    }
}
