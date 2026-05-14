import SwiftUI

struct ContentView: View {
    @StateObject private var captureVM = CaptureViewModel()
    @StateObject private var localization = LocalizationController.shared
    @State private var navPath: [AppDestination] = []
    @State private var showLanguagePicker = false

    var body: some View {
        NavigationStack(path: $navPath) {
            HomeView(
                path: $navPath,
                showLanguagePicker: $showLanguagePicker,
                currentLocale: localization.currentLocale
            )
            .navigationDestination(for: AppDestination.self) { dest in
                switch dest {
                case .awbEntry:
                    AwbEntryView(
                        captureVM: captureVM,
                        onConfirmShipment: { navPath.append(.collection) }
                    )
                case .containerEntry:
                    ContainerEntryView(
                        captureVM: captureVM,
                        onConfirmShipment: { navPath.append(.collection) }
                    )
                case .qrScan:
                    QRScanView(
                        captureVM: captureVM,
                        onConfirmShipment: { navPath.append(.collection) }
                    )
                case .collection:
                    if let shipment = captureVM.state.shipment {
                        CollectionView(
                            shipment: shipment,
                            onFinish: {
                                // Pop back to Home and forget the
                                // resolved shipment. `.onDisappear`
                                // would clear captureVM too, but
                                // routing the dismiss through an
                                // explicit closure keeps the nav-stack
                                // mutation owned by the parent.
                                navPath = []
                                captureVM.clear()
                            }
                        )
                    } else {
                        // Defensive — shouldn't happen since .collection
                        // is only pushed after a successful confirm.
                        Text("collection_finding_devices")
                            .onAppear { navPath = [] }
                    }
                }
            }
        }
        // Force the entire NavigationStack subtree to re-init on language
        // change. SwiftUI re-evaluates view bodies — and therefore re-
        // looks up `Text(LocalizedStringKey)` values via the swapped
        // `Bundle.main` — giving immediate (in-session) translation.
        // Trade-off: @State below this point resets, so if the user is
        // mid-entry on AwbEntryView when they change language, their
        // typed digits clear. Acceptable: language switches are rare,
        // and the alternative (custom LocalizedText view across every
        // string site) is a whole-codebase refactor for the same end.
        //
        // `.environment(\.locale, ...)` is the second half of the
        // mid-session locale story. SwiftUI Text consults the
        // environment locale for plural / inflection / sometimes string
        // resolution; without this, transitions to non-system locales
        // (e.g. Spanish on an en_US device) appear to "stick" at the
        // Bundle level but not in the rendered UI. With both the
        // environment locale AND the Bundle.main class swap in place,
        // every locale renders correctly mid-session.
        .environment(\.locale, Locale(identifier: localization.currentLocale.tag))
        .id(localization.currentLocale.tag)
        .sheet(isPresented: $showLanguagePicker) {
            LanguagePickerView(
                onSelect: { locale in
                    #if DEBUG
                    print("[Localization] picker onSelect(\(locale.tag)) — about to call applyLanguage")
                    #endif
                    localization.applyLanguage(locale)
                    #if DEBUG
                    print("[Localization] picker onSelect(\(locale.tag)) — dismissing sheet")
                    #endif
                    showLanguagePicker = false
                },
                onDismiss: { showLanguagePicker = false }
            )
        }
    }
}

#Preview {
    ContentView()
}
