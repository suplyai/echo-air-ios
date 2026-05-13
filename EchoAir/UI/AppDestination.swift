import Foundation

/// Navigation destinations pushed onto the root `NavigationStack`.
/// `.collection` carries no payload — the resolved shipment lives on
/// the shared `CaptureViewModel`'s `state.shipment` and is read by
/// `CollectionView` directly. When the user nav-pops out of Collection
/// the VM clears, releasing the shipment.
enum AppDestination: Hashable {
    case awbEntry
    case containerEntry
    case qrScan
    case collection
}
