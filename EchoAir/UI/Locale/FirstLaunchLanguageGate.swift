import SwiftUI

/// Wraps `content` and presents the first-launch language confirmation
/// dialog when no stored choice exists yet. Detects the system locale,
/// maps to an `AppLocale` (defaults to English on unsupported), and
/// renders the dialog in that locale.
///
/// User flow:
///   • "Yes, continue" → apply detected, mark confirmed → content.
///   • "Change language" → open `LanguagePickerView` → user picks →
///     apply chosen, mark confirmed → content.
///
/// **iOS limitation**: if the user picks a language different from the
/// detected one at first launch, the current session keeps rendering in
/// the detected language; the chosen language only takes effect on the
/// next launch. iOS doesn't gracefully support runtime locale changes
/// for `NSLocalizedString`. Documented in `LocaleManager.swift`. Phase
/// 5+ may introduce a custom Bundle wrapper if pilot feedback shows
/// this is friction.
struct FirstLaunchLanguageGate<Content: View>: View {
    @ViewBuilder let content: () -> Content

    @State private var showAlert: Bool
    @State private var showPicker: Bool = false
    private let detected: AppLocale

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
        let detected = AppLocale.fromSystemDefault() ?? .default
        self.detected = detected
        self._showAlert = State(initialValue: !LocaleManager.hasConfirmedFirstLaunch)
    }

    var body: some View {
        content()
            .alert(
                Text("language_first_launch_question"),
                isPresented: $showAlert
            ) {
                Button(String(localized: "language_first_launch_yes")) {
                    LocaleManager.apply(detected)
                    LocaleManager.markFirstLaunchConfirmed()
                }
                Button(String(localized: "language_first_launch_change")) {
                    showPicker = true
                }
            } message: {
                // detected.nativeNameKey is a runtime String, so use
                // NSLocalizedString (accepts non-literal keys) rather
                // than LocalizedStringResource (StaticString-only).
                Text(
                    String(
                        format: String(localized: "language_first_launch_set_to"),
                        NSLocalizedString(detected.nativeNameKey, comment: "")
                    )
                )
            }
            .sheet(isPresented: $showPicker) {
                LanguagePickerView(
                    onSelect: { locale in
                        LocaleManager.apply(locale)
                        LocaleManager.markFirstLaunchConfirmed()
                        showPicker = false
                    },
                    onDismiss: { showPicker = false }
                )
            }
    }
}
