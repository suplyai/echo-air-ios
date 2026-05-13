import SwiftUI

/// Guided landing page. Two-paragraph intro + three action cards
/// (AWB / container / QR) + language pill in the trailing toolbar.
///
/// Translated from
/// `app/src/main/kotlin/app/suply/echoair/ui/home/HomeScreen.kt`.
///
/// iOS deviations from the Android original:
/// • Hero illustration → SF Symbol placeholder (`airplane` / `shippingbox.fill`
///   cross-fade) per Phase 3 decision. Real assets can drop in later
///   without touching the surrounding layout.
/// • `Activity.recreate()` after language change → not available on iOS.
///   `LocaleManager.apply` saves + syncs `AppleLanguages`; full UI
///   re-render only happens on next launch. Documented in LocaleManager.
struct HomeView: View {
    @Binding var path: [AppDestination]
    @Binding var showLanguagePicker: Bool
    let currentLocale: AppLocale

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HomeHero()
                    .padding(.top, 4)

                // Two-paragraph intro — same typography on both per the
                // v0.7.1 copy update. The first paragraph is instructional,
                // not a headline; the second is operational guidance.
                VStack(alignment: .leading, spacing: 8) {
                    Text("home_intro_primary")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Text("home_intro_positioning")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ActionCard(
                    symbol: "airplane",
                    title: "home_action_awb_title",
                    subtitle: "home_action_awb_subtitle",
                    primary: true,
                    onTap: { path.append(.awbEntry) }
                )
                ActionCard(
                    symbol: Symbols.oceanRoute,
                    title: "home_enter_container_number",
                    subtitle: "home_enter_container_number_help",
                    primary: false,
                    onTap: { path.append(.containerEntry) }
                )
                // QR is the third option — no subtitle: the single-line
                // CTA is self-explanatory and keeps the three-card stack
                // visually balanced.
                ActionCard(
                    symbol: "qrcode.viewfinder",
                    title: "home_scan_qr_button",
                    subtitle: nil,
                    primary: false,
                    onTap: { path.append(.qrScan) }
                )

                Text("home_footer_no_account")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)

                #if DEBUG
                NavigationLink {
                    SpikeView()
                } label: {
                    Label("Open BLE spike", systemImage: "wrench.adjustable")
                }
                .buttonStyle(.bordered)
                .padding(.top, 24)
                #endif
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showLanguagePicker = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "globe")
                            .font(.system(size: 14))
                        Text(currentLocale.displayCode)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                }
                .accessibilityLabel(Text("home_language_selector_label"))
            }
        }
    }
}

/// Cross-fading hero placeholder. Android uses two artist-drawn
/// illustrations alternating every 3s; iOS uses two SF Symbols on the
/// same rhythm. Reduced-motion shows only the cargo-box variant
/// (mode-neutral, conveys "any scale" without movement).
private struct HomeHero: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showVariant = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))

            Image(systemName: "airplane")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Color.accentColor)
                .opacity(showVariant ? 0 : 1)
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Color.accentColor)
                .opacity(showVariant ? 1 : 0)
        }
        .aspectRatio(8.0 / 5.0, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("home_hero_image_description"))
        .task {
            guard !reduceMotion else { return }
            // 3s hold per side, 600ms cross-fade. Matches the Android
            // brief's perceived cycle of ~7.2s.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { break }
                withAnimation(.easeInOut(duration: 0.6)) {
                    showVariant.toggle()
                }
            }
        }
    }
}

private struct ActionCard: View {
    let symbol: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    let primary: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(primary ? Color.white : Color.primary)
                    .frame(width: 32, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundStyle(primary ? Color.white : Color.primary)
                        .multilineTextAlignment(.leading)
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle((primary ? Color.white : Color.secondary).opacity(0.85))
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(primary ? Color.accentColor : Color(.secondarySystemBackground))
            )
            .shadow(color: primary ? .black.opacity(0.08) : .clear,
                    radius: primary ? 2 : 0, x: 0, y: 1)
        }
        .buttonStyle(.plain)
    }
}
