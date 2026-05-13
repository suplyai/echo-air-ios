import SwiftUI

/// Structured AWB-entry screen.
///
///   [airline 3-digit]  —  [serial 8-digit]
///
/// Auto-advance (3 digits → serial focus), paste-friendly (strip
/// non-digits, distribute across fields if 11 land), numeric keyboard,
/// monospaced large digits. Inline mod-7 check-digit validation:
/// Continue is disabled until the 11 digits resolve to a valid AWB,
/// and an error hint surfaces the expected check digit so the consignee
/// can fix the typo without a round-trip.
///
/// Translated from
/// `app/src/main/kotlin/app/suply/echoair/ui/awb/ManualAwbScreen.kt`.
struct AwbEntryView: View {
    @ObservedObject var captureVM: CaptureViewModel
    let onConfirmShipment: () -> Void

    @State private var prefix = ""
    @State private var serial = ""
    @FocusState private var focused: Field?
    @State private var showConfirmSheet = false
    @State private var failureAlertPresented = false

    private enum Field: Hashable { case prefix, serial }

    private var canonical: String? {
        prefix.count == 3 && serial.count == 8 ? "\(prefix)-\(serial)" : nil
    }
    private var validAwb: String? { canonical.flatMap { Awb.isValid($0) ? $0 : nil } }
    private var checkDigitMismatch: Bool { serial.count == 8 && canonical != nil && validAwb == nil }
    private var serialValid: Bool {
        serial.count == 8 && Awb.expectedCheckDigit(serial) == serial.last?.wholeNumberValue
    }
    private var carrierName: String? {
        prefix.count == 3 ? IataCarriers.carrierName(prefix: prefix) : nil
    }
    private var prefixMatched: Bool { prefix.count == 3 && carrierName != nil }
    private var prefixUnknown: Bool { prefix.count == 3 && carrierName == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("awb_heading")
                .font(.headline)
            Text("awb_subheading")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                DigitField(
                    value: $prefix,
                    length: 3,
                    accent: prefixMatched ? Color(hex: 0x34C759) : nil
                )
                .focused($focused, equals: .prefix)
                .frame(maxWidth: .infinity)
                .frame(width: nil)
                .onChange(of: prefix) { newValue in
                    handlePaste(raw: newValue, field: .prefix)
                }

                Text("—")
                    .font(.title)
                    .foregroundStyle(.secondary)

                DigitField(
                    value: $serial,
                    length: 8,
                    accent: serialValid ? Color(hex: 0x34C759) : nil,
                    trailingCheckmark: serialValid
                )
                .focused($focused, equals: .serial)
                .frame(maxWidth: .infinity)
                .onChange(of: serial) { newValue in
                    handlePaste(raw: newValue, field: .serial)
                }
            }
            .frame(maxWidth: .infinity)

            // Inline feedback: green ✓ + carrier name on match, amber
            // unknown-prefix hint on miss, red check-digit error when
            // the body's 8th digit doesn't match.
            if prefixMatched, let name = carrierName {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundStyle(Color(hex: 0x34C759))
                    Text(name)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
            if prefixUnknown {
                Text("awb_unknown_prefix")
                    .font(.footnote)
                    .foregroundStyle(Color(hex: 0xB7791F))
                    .transition(.opacity)
            }
            if checkDigitMismatch {
                Text(checkDigitMismatchMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Spacer()

            Button(action: submit) {
                if captureVM.state.loading {
                    HStack(spacing: 12) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                        Text("awb_continue_loading")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Text("awb_continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(validAwb == nil || captureVM.state.loading)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
        .animation(.easeInOut(duration: 0.15), value: prefixMatched)
        .animation(.easeInOut(duration: 0.15), value: prefixUnknown)
        .animation(.easeInOut(duration: 0.15), value: checkDigitMismatch)
        .navigationTitle("awb_title")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = .prefix }
        .onChange(of: prefix) { newValue in
            // Auto-advance to serial when prefix completes. Soft haptic
            // on every prefix → matched-carrier event.
            if newValue.count == 3 {
                if carrierName != nil { EchoHaptics.softTap() }
                focused = .serial
            }
        }
        .onChange(of: captureVM.state.shipment) { newValue in
            showConfirmSheet = (newValue != nil)
        }
        .onChange(of: captureVM.state.failure) { newValue in
            failureAlertPresented = (newValue != nil)
        }
        .sheet(isPresented: $showConfirmSheet) {
            if let shipment = captureVM.state.shipment {
                ConfirmSheet(
                    shipment: shipment,
                    confidence: captureVM.state.confidence,
                    onConfirm: {
                        EchoHaptics.tick()
                        showConfirmSheet = false
                        onConfirmShipment()
                    },
                    onCancel: {
                        showConfirmSheet = false
                        captureVM.clear()
                    }
                )
                .presentationDetents([.large])
            }
        }
        .alert(
            failureTitle,
            isPresented: $failureAlertPresented,
            actions: {
                Button(String(localized: "common_ok")) { captureVM.clear() }
            },
            message: { Text(failureBody) }
        )
    }

    private var failureTitle: String { captureVM.state.failure?.copy.title ?? "" }
    private var failureBody: String { captureVM.state.failure?.copy.body ?? "" }

    /// Pre-localised + format-substituted check-digit error so we pass
    /// `Text(_: String)` rather than `Text(_: LocalizedStringKey)`.
    private var checkDigitMismatchMessage: String {
        if let expected = Awb.expectedCheckDigit(serial) {
            return String(format: String(localized: "awb_check_digit_mismatch_expected"), expected)
        }
        return String(localized: "awb_check_digit_mismatch")
    }

    private func submit() {
        guard let awb = validAwb, !captureVM.state.loading else { return }
        EchoHaptics.tick()
        captureVM.identifyByAwb(awb)
    }

    /// Strip non-digits + paste-distribute. If 11 digits land in either
    /// field at once (paste of a full AWB), split them across prefix
    /// (first 3) and serial (last 8).
    private func handlePaste(raw: String, field: Field) {
        let digits = raw.filter(\.isNumber)
        if digits.count >= 11 {
            prefix = String(digits.prefix(3))
            serial = String(digits.dropFirst(3).prefix(8))
            focused = nil
            return
        }
        switch field {
        case .prefix: prefix = String(digits.prefix(3))
        case .serial: serial = String(digits.prefix(8))
        }
    }
}

/// Monospaced numeric entry field. Used for the AWB prefix (3 digits)
/// and serial (8 digits) fields side-by-side.
private struct DigitField: View {
    @Binding var value: String
    let length: Int
    let accent: Color?
    let trailingCheckmark: Bool

    init(value: Binding<String>, length: Int, accent: Color? = nil, trailingCheckmark: Bool = false) {
        self._value = value
        self.length = length
        self.accent = accent
        self.trailingCheckmark = trailingCheckmark
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $value, prompt: Text(String(repeating: "0", count: length))
                .foregroundColor(.secondary.opacity(0.3)))
            .keyboardType(.numberPad)
            .multilineTextAlignment(.center)
            .font(.system(size: 26, weight: .medium, design: .monospaced))
            .tracking(2)
            .textFieldStyle(.plain)

            if trailingCheckmark {
                Image(systemName: "checkmark")
                    .font(.body)
                    .foregroundStyle(Color(hex: 0x34C759))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(accent ?? Color(.separator), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.2), value: accent)
    }
}
