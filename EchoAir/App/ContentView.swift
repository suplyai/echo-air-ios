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
                        CollectionView(shipment: shipment)
                            .onDisappear { captureVM.clear() }
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
