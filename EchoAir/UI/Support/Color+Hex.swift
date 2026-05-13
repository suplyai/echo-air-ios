import SwiftUI

extension Color {
    /// `Color(hex: 0xD81B60)` — Android-style hex literal initialiser.
    /// Lets us drop colour values from the Kotlin side verbatim without
    /// re-deriving R/G/B components.
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8)  & 0xFF) / 255
        let b = Double( hex        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
