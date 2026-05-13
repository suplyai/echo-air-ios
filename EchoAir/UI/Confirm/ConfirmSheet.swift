import SwiftUI

/// Bottom-sheet identity confirmation for a resolved shipment — the
/// "trust moment". Branches its reference / route / icon rendering on
/// `shipment.isOcean` per handoff §3.4. MPS rendering per §3.5 when
/// `shipment.units.count > 1`.
///
/// Translated from
/// `app/src/main/kotlin/app/suply/echoair/ui/capture/ConfirmShipmentDialog.kt`.
struct ConfirmSheet: View {
    let shipment: ShipmentDto
    let confidence: String?
    let onConfirm: () -> Void
    let onCancel: () -> Void

    /// Prefer the root-level commodity fields (newer backend shape);
    /// fall back to nested `cargo_profile` for older deployments.
    private var commodityName: String? {
        shipment.commodityName ?? shipment.cargoProfile?.name
    }
    private var commodityCategory: String? {
        shipment.commodityCategory ?? shipment.cargoProfile?.category
    }
    private var accent: CommodityAccent {
        CommodityAccent.forCategory(commodityCategory)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if confidence == "low" || confidence == "medium" {
                    Text("confirm_heading_low_confidence")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }

                hero
                Divider()
                referenceRow
                routeRow
                Divider()
                deviceCountSection

                HStack(spacing: 12) {
                    Button(role: .cancel, action: onCancel) {
                        Text("common_cancel")
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)

                    Button(action: onConfirm) {
                        Text("confirm_start_scanning")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .padding(.top, 16)
        }
    }

    // MARK: - Sections

    private var hero: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(accent.color.opacity(0.14))
                Image(systemName: accent.symbol)
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(accent.color)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 2) {
                Text(commodityName ?? String(localized: "confirm_fallback_commodity"))
                    .font(.system(size: 26, weight: .semibold))
                if let category = commodityCategory, !category.isEmpty {
                    Text(category.prefix(1).uppercased() + category.dropFirst())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var referenceRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shipment.isOcean ? "confirm_label_container_number" : "confirm_label_air_waybill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(referenceValue ?? "—")
                    .font(.headline)
            }
            Spacer()
            TransportBadge(mode: shipment.transportMode)
        }
    }

    private var referenceValue: String? {
        shipment.isOcean ? shipment.containerNumber : shipment.airwayBillNumber
    }

    @ViewBuilder
    private var routeRow: some View {
        let origin: String?
        let dest: String?
        let symbol: String
        if shipment.isOcean {
            origin = shipment.pol?.nilIfBlank
            dest = shipment.pod?.nilIfBlank
            symbol = "sailboat"
        } else {
            origin = formatEndpoint(city: shipment.airOriginCity, iata: shipment.airOriginIata)
            dest = formatEndpoint(city: shipment.airDestCity, iata: shipment.airDestIata)
            symbol = "airplane"
        }

        if origin != nil || dest != nil {
            HStack {
                Text(origin ?? "—")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                Text(dest ?? "—")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    @ViewBuilder
    private var deviceCountSection: some View {
        let deviceCount = shipment.devices.count
        let unitCount = shipment.units.count
        let isMultiUnit = unitCount > 1

        if isMultiUnit {
            Text("confirm_mps_badge")
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
        }

        if deviceCount == 0 {
            Text("confirm_no_devices_expected")
                .font(.headline)
        } else if isMultiUnit {
            Text(mpsSummaryString(units: unitCount, devices: deviceCount))
                .font(.headline)
        } else {
            // Plural variants live in `confirm_devices_to_collect` in
            // Localizable.xcstrings; localizedStringWithFormat fires the
            // CLDR plural rule based on `deviceCount`.
            Text(devicesToCollectString(count: deviceCount))
                .font(.headline)
        }

        if isMultiUnit {
            Text(unitBreakdown)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private func devicesToCollectString(count: Int) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("confirm_devices_to_collect", comment: ""),
            count
        )
    }

    private func mpsSummaryString(units: Int, devices: Int) -> String {
        String(
            format: String(localized: "confirm_mps_summary"),
            units, devices
        )
    }

    private var unitBreakdown: String {
        let fallback = String(localized: "collection_unattributed_unit")
        return shipment.units
            .map { $0.label?.nilIfBlank ?? fallback }
            .joined(separator: "  ·  ")
    }

    private func formatEndpoint(city: String?, iata: String?) -> String? {
        let c = city?.nilIfBlank
        let i = iata?.nilIfBlank
        switch (c, i) {
        case (let c?, let i?): return "\(c) (\(i))"
        case (nil, let i?): return i
        case (let c?, nil): return c
        default: return nil
        }
    }
}

private struct TransportBadge: View {
    let mode: String?

    var body: some View {
        if let label {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Pre-resolved label so the parent `Text` uses the `StringProtocol`
    /// init (literal) — unknown modes are NOT localisation keys and must
    /// not be re-looked-up by `LocalizedStringKey`.
    private var label: String? {
        guard let mode else { return nil }
        let lower = mode.lowercased()
        if lower == "air" || lower == "air_freight" {
            return String(localized: "confirm_badge_air_freight")
        }
        if lower == "ocean_reefer" {
            return String(localized: "confirm_badge_ocean_reefer")
        }
        // Unknown mode — title-case the raw value as a defensive fallback.
        let normalised = mode.replacingOccurrences(of: "_", with: " ")
        return normalised.prefix(1).uppercased() + normalised.dropFirst()
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
