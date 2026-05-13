import Foundation

/// The four languages the app ships translations for. Order here
/// controls the order in the language picker.
///
/// `displayCode` is what the home-screen language pill renders next to
/// the globe icon — Latin abbreviation for Latin-script locales, the
/// language's own native character for the CJK pair so it reads
/// natural to a speaker glancing at the chip.
///
/// Translated 1:1 from
/// `app/src/main/kotlin/app/suply/echoair/ui/locale/AppLocale.kt`.
enum AppLocale: String, CaseIterable, Identifiable {
    case english = "en"
    case spanish = "es"
    case chinese = "zh"
    case japanese = "ja"

    var id: String { rawValue }

    /// IETF BCP 47 language tag — matches both Android's resource
    /// qualifier and iOS's `.lproj` directory name.
    var tag: String { rawValue }

    /// Pill-rendered display code — Latin for Latin-script locales,
    /// native character for CJK.
    var displayCode: String {
        switch self {
        case .english:  return "EN"
        case .spanish:  return "ES"
        case .chinese:  return "中"
        case .japanese: return "日"
        }
    }

    /// Localized-string key holding the language's own native name
    /// (e.g. `language_name_en` resolves to "English" in the English
    /// catalogue, "Inglés" in the Spanish catalogue, etc.).
    var nativeNameKey: String { "language_name_\(tag)" }

    static let `default`: AppLocale = .english

    /// Tag → AppLocale, normalising region variants (es-MX → .spanish,
    /// zh-Hans-CN → .chinese). Case-insensitive.
    static func fromTag(_ tag: String?) -> AppLocale? {
        guard let tag, !tag.isEmpty else { return nil }
        let base = tag.components(separatedBy: "-").first?.lowercased() ?? ""
        guard !base.isEmpty else { return nil }
        return allCases.first { $0.tag == base }
    }

    /// What the device's default locale maps to, or nil if unsupported.
    /// Uses `Locale.preferredLanguages.first` to honour the user's
    /// language priority list (the OS-level "Preferred Languages" UI).
    static func fromSystemDefault() -> AppLocale? {
        let preferred = Locale.preferredLanguages.first ?? Locale.current.identifier
        return fromTag(preferred)
    }
}
