import SwiftUI

/// Maps a commodity category string from the backend to a hero icon +
/// accent colour for the Confirm Sheet. Matching is case-insensitive and
/// tolerant of common synonyms so a single table covers canonical values
/// ("flowers", "seafood", …) and freeform text ("cut flowers", "fish", …).
///
/// When the category is nil or unknown the sheet falls back to a neutral
/// shipping-box icon so it's never visually broken.
///
/// Translated from
/// `app/src/main/kotlin/app/suply/echoair/ui/capture/CommodityAccent.kt`.
/// Iconography uses SF Symbols (closest available in iOS 16 baseline);
/// hex colours match the Android values verbatim. The fallback diverges
/// deliberately — Android uses an airplane (its air-only era); v0.7.0
/// supports ocean too so iOS uses a mode-neutral cargo box instead.
struct CommodityAccent: Equatable {
    /// SF Symbol name.
    let symbol: String
    let color: Color

    static let flowers  = CommodityAccent(symbol: "leaf.fill",            color: Color(hex: 0xD81B60))
    static let seafood  = CommodityAccent(symbol: "fish.fill",            color: Color(hex: 0x00838F))
    static let pharma   = CommodityAccent(symbol: "cross.case.fill",      color: Color(hex: 0x1565C0))
    static let produce  = CommodityAccent(symbol: "leaf",                 color: Color(hex: 0x2E7D32))
    static let meat     = CommodityAccent(symbol: "fork.knife",           color: Color(hex: 0xB71C1C))
    static let dairy    = CommodityAccent(symbol: "cup.and.saucer.fill",  color: Color(hex: 0x6D4C41))
    static let fallback = CommodityAccent(symbol: "shippingbox.fill",     color: Color(hex: 0x455A64))

    static func forCategory(_ category: String?) -> CommodityAccent {
        guard let raw = category?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return .fallback
        }
        let key = raw.lowercased()
        if key.contains("flower") || key.contains("bouquet") || key == "floral" { return .flowers }
        if key.contains("seafood") || key.contains("fish") || key.contains("shellfish") { return .seafood }
        if key.contains("pharma") || key.contains("medicin") || key.contains("vaccine") { return .pharma }
        if key.contains("fruit") || key.contains("vegetable") || key.contains("produce")
            || key.contains("citrus") || key.contains("berry") { return .produce }
        if key.contains("meat") || key.contains("beef") || key.contains("pork")
            || key.contains("lamb") || key.contains("poultry") || key.contains("chicken") { return .meat }
        if key.contains("dairy") || key.contains("milk") || key.contains("cheese")
            || key.contains("yoghurt") || key.contains("yogurt") { return .dairy }
        return .fallback
    }
}
