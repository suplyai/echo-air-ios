import SwiftUI

/// Placeholder for the Phase 5 BLE collection screen. Renders the
/// resolved shipment header + a static "scanning will land in Phase 5"
/// message so the flow has a sensible terminus through Phase 3.
///
/// In Phase 5 this becomes the orchestrator front-end:
///   • SEARCHING / IN_RANGE / CONNECTING / SYNCING / COLLECTED / MISSING / ERROR
///     per-device state machine
///   • MPS unit grouping per handoff §3.5
///   • Proximity hint escalation per §3.9
///   • BT / Location reactive gates per §3.8
///   • Finalize + stale-session logic per §3.7
///
/// All deferred for now.
struct CollectionView: View {
    let shipment: ShipmentDto

    var body: some View {
        VStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(shipment.commodityName ?? shipment.cargoProfile?.name ?? String(localized: "confirm_fallback_commodity"))
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(referenceLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("collection_finding_devices")
                .font(.headline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(shipment.devices) { device in
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.secondary)
                        Text(String(
                            format: String(localized: "collection_row_device_id"),
                            device.deviceId
                        ))
                        .font(.subheadline)
                        Spacer()
                        Text("collection_state_searching")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            Spacer()

            Text(verbatim: "Phase 5 will wire the BLE orchestrator here — devices listed above are stub state.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .navigationTitle("collection_title_fallback")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var referenceLabel: String {
        if shipment.isOcean, let container = shipment.containerNumber {
            return container
        }
        if let awb = shipment.airwayBillNumber {
            return awb
        }
        return ""
    }
}
