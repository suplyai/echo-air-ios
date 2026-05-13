import SwiftUI

/// Language picker presented as a bottom sheet from the home screen
/// chip or the first-launch gate.
///
/// Native names render in their own script regardless of UI locale —
/// the xcstrings catalogue pre-populates `language_name_{en,es,zh,ja}`
/// identically across all four locale columns, so a plain
/// `String(localized:)` lookup always returns the native form. (The
/// Android side uses `createConfigurationContext` to achieve the same
/// effect — translated to iOS this becomes free via the catalogue.)
struct LanguagePickerView: View {
    let onSelect: (AppLocale) -> Void
    let onDismiss: () -> Void

    private let current: AppLocale? = LocaleManager.storedLocale()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("language_picker_title")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            Divider()
            ForEach(AppLocale.allCases) { locale in
                LanguageRow(
                    locale: locale,
                    selected: current == locale,
                    onTap: {
                        #if DEBUG
                        print("[Localization] LanguageRow tap(\(locale.tag)) — invoking onSelect")
                        #endif
                        onSelect(locale)
                    }
                )
                if locale != AppLocale.allCases.last {
                    Divider().padding(.leading, 20)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.medium])
    }
}

private struct LanguageRow: View {
    let locale: AppLocale
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Text(LocalizedStringKey(locale.nativeNameKey))
                    .font(.body)
                    .fontWeight(selected ? .semibold : .regular)
                    .foregroundStyle(.primary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
