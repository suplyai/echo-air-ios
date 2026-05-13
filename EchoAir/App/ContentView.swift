import SwiftUI

struct ContentView: View {
    @StateObject private var captureVM = CaptureViewModel()
    @State private var navPath: [AppDestination] = []
    @State private var showLanguagePicker = false

    var body: some View {
        NavigationStack(path: $navPath) {
            HomeView(
                path: $navPath,
                showLanguagePicker: $showLanguagePicker,
                currentLocale: LocaleManager.effectiveLocale()
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
        .sheet(isPresented: $showLanguagePicker) {
            LanguagePickerView(
                onSelect: { locale in
                    LocaleManager.apply(locale)
                    showLanguagePicker = false
                    // UI continues in current bundle until next launch;
                    // documented limitation in LocaleManager.
                },
                onDismiss: { showLanguagePicker = false }
            )
        }
    }
}

#Preview {
    ContentView()
}
