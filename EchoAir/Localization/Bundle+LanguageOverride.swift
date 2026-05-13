import Foundation
import ObjectiveC

/// Mid-session language switching for `NSLocalizedString` / `Bundle.main`.
///
/// iOS doesn't natively support changing the locale of `Bundle.main`
/// without a process relaunch. The standard workaround — used by many
/// "in-app language switcher" libraries (Localize-Swift et al.) — is to
/// swap `Bundle.main`'s runtime class to a subclass that overrides
/// `localizedString(forKey:value:table:)` to read from a locale-specific
/// `.lproj` subdirectory inside the app bundle. Subsequent calls to
/// `NSLocalizedString` (and therefore SwiftUI's `Text(LocalizedStringKey)`)
/// resolve against the chosen locale.
///
/// Use via `LocalizationController.shared.applyLanguage(...)`; views
/// observing the controller re-render with the new strings.

/// Associated-object key for storing the per-locale Bundle on `Bundle.main`.
/// File-scope `var` — the address of this value is the key, the value
/// itself never mutates. `nonisolated(unsafe)` opts out of strict-
/// concurrency checking; safe because the var is never reassigned.
nonisolated(unsafe) private var bundleAssocKey: UInt8 = 0

/// Runtime Bundle subclass installed on `Bundle.main`. Routes
/// `localizedString(...)` to a locale-specific sub-bundle when one is set
/// via `objc_setAssociatedObject`; falls back to the bundle's default
/// resolution when no override is installed.
private final class RuntimeBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let override = objc_getAssociatedObject(self, &bundleAssocKey) as? Bundle {
            return override.localizedString(forKey: key, value: value, table: tableName)
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

extension Bundle {
    /// Swap `Bundle.main`'s class to `RuntimeBundle` (idempotent — subsequent
    /// calls only update the associated locale bundle) and point it at
    /// `<tag>.lproj` inside the app bundle. SwiftUI Text views re-rendered
    /// after this call will pick up the new strings.
    ///
    /// `Localizable.xcstrings` is compiled by Xcode into a generated
    /// `<tag>.lproj/Localizable.strings` for each declared locale, so
    /// pointing at the `.lproj` directory resolves correctly for the
    /// catalogue-backed strings the rest of the app uses.
    ///
    /// Falls back to the default bundle (no override installed) when no
    /// matching `.lproj` exists — e.g. on a locale tag the app doesn't
    /// actually ship translations for. The default rendering uses the
    /// source language (English) per the xcstrings `sourceLanguage` field.
    @MainActor
    static func installLanguageOverride(tag: String) {
        if !(Bundle.main is RuntimeBundle) {
            object_setClass(Bundle.main, RuntimeBundle.self)
        }
        let overrideBundle: Bundle? = Bundle.main.path(forResource: tag, ofType: "lproj")
            .flatMap { Bundle(path: $0) }
        objc_setAssociatedObject(
            Bundle.main, &bundleAssocKey, overrideBundle,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
}
