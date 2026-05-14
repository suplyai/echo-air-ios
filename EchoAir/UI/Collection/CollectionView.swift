import SwiftUI

/// Phase 5 collection screen. Drives one `CollectionViewModel` against
/// the resolved shipment: serial per-device scan → connect → read →
/// upload, with up to 3 attempts per device. Surfaces a live per-device
/// status pill (searching / connecting / reading / uploading / collected
/// / missing / failed) plus a header progress counter and a finish CTA.
///
/// What this screen DOESN'T do yet (deferred to Phase 6 / later):
/// • Per-unit MPS grouping per handoff §3.5 — every device renders in
///   one flat list. The DTO carries `units`; revisit when MPS lands.
/// • Proximity hint L1/L2/L3 escalation per §3.9.
/// • Reactive BT / Location gates per §3.8 — only the BT power-on
///   pre-check inside `KBeaconScanner.discover` is wired today; if
///   the radio toggles off mid-collection, only the in-flight scan
///   fails.
/// • Stale-session / finalize logic per §3.7.
/// • Offline upload queue — `failed` status with an upload error
///   means that device's data is lost and must be re-collected.
struct CollectionView: View {
    @StateObject private var vm: CollectionViewModel
    let onFinish: () -> Void

    init(shipment: ShipmentDto, onFinish: @escaping () -> Void) {
        _vm = StateObject(wrappedValue: CollectionViewModel(shipment: shipment))
        self.onFinish = onFinish
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(vm.devices) { state in
                        DeviceRow(state: state)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }

            Divider()

            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .navigationTitle("collection_title_fallback")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await vm.start()
        }
    }

    private var header: some View {
        let collected = vm.devices.filter { $0.status == .collected }.count
        let total = vm.devices.count
        return VStack(alignment: .leading, spacing: 6) {
            Text(vm.shipment.commodityName
                 ?? vm.shipment.cargoProfile?.name
                 ?? String(localized: "confirm_fallback_commodity"))
                .font(.title3)
                .fontWeight(.semibold)
            Text(String(
                format: String(localized: "collection_collecting_n_of_m"),
                collected,
                total
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var footer: some View {
        switch vm.phase {
        case .idle, .running:
            // While running we surface the rolling "Collecting…" label
            // — the finish CTA only appears once the orchestrator has
            // walked the full device list.
            HStack {
                ProgressView()
                Text("collection_collecting_label")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        case .finished:
            // "All devices collected — finish" if every device made it;
            // "Close — N of M collected" otherwise. Pre-compute the
            // label outside the ViewBuilder so the case body stays a
            // single view expression (lets + ViewBuilder are a known
            // type-check pitfall under strict concurrency).
            FinishButton(
                allCollected: vm.devices.allSatisfy { $0.status == .collected },
                onTap: onFinish
            )
        }
    }
}

private struct FinishButton: View {
    let allCollected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(allCollected ? "collection_finish" : "collection_close_partial")
                .font(.body)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
    }
}

private struct DeviceRow: View {
    let state: DeviceCollectionState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: leadingSymbol)
                .foregroundStyle(leadingTint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(
                    format: String(localized: "collection_row_device_id"),
                    state.device.deviceId
                ))
                .font(.subheadline)
                .fontWeight(.medium)
                if let error = state.lastError,
                   state.status == .failed || state.status == .missing {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Text(statusKey)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(statusTint)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private var statusKey: LocalizedStringKey {
        switch state.status {
        case .idle, .searching:
            return "collection_state_searching"
        case .connecting:
            return "collection_state_connecting"
        case .reading, .uploading:
            return "collection_state_syncing"
        case .collected:
            return "collection_state_collected"
        case .missing:
            return "collection_state_missing"
        case .failed:
            return "collection_state_error"
        }
    }

    private var leadingSymbol: String {
        switch state.status {
        case .collected: return "checkmark.circle.fill"
        case .missing:   return "questionmark.circle"
        case .failed:    return "exclamationmark.triangle.fill"
        default:         return "antenna.radiowaves.left.and.right"
        }
    }

    private var leadingTint: Color {
        switch state.status {
        case .collected: return .green
        case .missing:   return .orange
        case .failed:    return .red
        default:         return .secondary
        }
    }

    private var statusTint: Color {
        switch state.status {
        case .collected: return .green
        case .missing:   return .orange
        case .failed:    return .red
        default:         return .secondary
        }
    }
}
