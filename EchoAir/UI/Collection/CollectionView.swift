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

                    // TEMPORARY diagnostic panel — visible in TestFlight
                    // so a tester without USB / Console can see what
                    // iOS actually receives on the air. Remove once
                    // discovery is fixed.
                    DiagnosticSection(scanner: vm.diagnostic)
                        .padding(.top, 24)
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
        .onDisappear {
            // Stop the diagnostic radio when leaving the screen so
            // nothing scans in the background after the user is done.
            vm.stopDiagnostic()
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

// MARK: - Diagnostic panel (temporary; TestFlight-visible)
//
// On-screen dump of what `BleDiagnosticScanner` sees. Designed to be
// readable on a phone screen without scrolling-to-the-side: monospace
// caption2 for hex strings, multi-line on overflow, matches first,
// most-recent next. Verbatim English copy (not localised) because
// this is a diagnostic that ships briefly and is removed once
// discovery works.

private struct DiagnosticSection: View {
    @ObservedObject var scanner: BleDiagnosticScanner

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: "BLE diagnostic")
                    .font(.subheadline)
                    .fontWeight(.bold)
                Spacer()
                Text(verbatim: "\(scanner.discoveries.count) seen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: "State: \(stateLabel)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if scanner.targets.isEmpty {
                Text(verbatim: "Targets: (none — shipment has no devices with a MAC)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(verbatim: "Targets (\(scanner.targets.count)):")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(scanner.targets, id: \.self) { mac in
                    Text(verbatim: "  • \(mac)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()
                .padding(.top, 4)

            if scanner.discoveries.isEmpty {
                Text(verbatim: "No advertisements received yet. If this stays empty after 10s with the phone near the devices, iOS isn't delivering ANY discovery callbacks — investigate radio / permission state, not the SDK.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(orderedDiscoveries) { d in
                    DiagnosticDiscoveryRow(discovery: d)
                    Divider()
                }
            }

            // Connect log — temporary, removed in the cleanup PR.
            if !scanner.connectLog.isEmpty {
                Divider().padding(.top, 4)
                Text(verbatim: "Connect log (\(scanner.connectLog.count) lines):")
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .padding(.top, 4)
                ForEach(Array(scanner.connectLog.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(12)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private var stateLabel: String {
        switch scanner.state {
        case .idle:                       return "idle"
        case .waitingForRadio:            return "waiting for radio…"
        case .scanning:                   return "scanning (allowDuplicates=true)"
        case .stopped(let reason):        return "stopped — \(reason)"
        }
    }

    /// Matches first, then most-recent. The match-first ordering
    /// makes the panel useful at a glance: if any target's bytes
    /// appear in any discovery, that discovery pins to the top.
    private var orderedDiscoveries: [BleDiagnosticScanner.Discovery] {
        scanner.discoveries.sorted { a, b in
            if !a.matches.isEmpty && b.matches.isEmpty { return true }
            if a.matches.isEmpty && !b.matches.isEmpty { return false }
            return a.lastSeen > b.lastSeen
        }
    }
}

private struct DiagnosticDiscoveryRow: View {
    let discovery: BleDiagnosticScanner.Discovery

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(verbatim: idLabel)
                    .font(.caption)
                    .fontWeight(discovery.matches.isEmpty ? .regular : .semibold)
                Spacer()
                Text(verbatim: "rssi=\(discovery.rssi)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if !discovery.matches.isEmpty {
                    Text(verbatim: "MATCH")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(.green)
                }
            }
            if let ln = discovery.localName, !ln.isEmpty {
                Text(verbatim: "localName=\(ln)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !discovery.serviceUUIDs.isEmpty {
                Text(verbatim: "svcUUIDs=\(discovery.serviceUUIDs.joined(separator: ","))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if !discovery.manufacturerDataHex.isEmpty {
                Text(verbatim: "mfg=\(discovery.manufacturerDataHex)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            ForEach(discovery.serviceDataHex.sorted(by: { $0.key < $1.key }), id: \.key) { uuid, hex in
                Text(verbatim: "svcData[\(uuid)]=\(hex)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if !discovery.advKeys.isEmpty {
                Text(verbatim: "advKeys=\(discovery.advKeys.joined(separator: ","))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            ForEach(discovery.matches, id: \.self) { match in
                Text(verbatim: "→ \(match.targetMac) in \(match.field) (\(match.direction))")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 4)
    }

    private var idLabel: String {
        let short = String(discovery.id.prefix(8))
        let name = discovery.name ?? "(no name)"
        return "\(short) \(name)"
    }
}
