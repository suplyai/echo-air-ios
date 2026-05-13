import SwiftUI

/// Ocean-reefer counterpart to `AwbEntryView`: a single-field entry for
/// an ISO 6346 container number with two-stage validation (format gate
/// + mod-11 check digit). Each stage surfaces its own inline error so a
/// typo in the trailing digit reads differently from "this isn't even
/// a container number".
///
/// Translated from
/// `app/src/main/kotlin/app/suply/echoair/ui/container/ManualContainerScreen.kt`.
struct ContainerEntryView: View {
    @ObservedObject var captureVM: CaptureViewModel
    let onConfirmShipment: () -> Void

    @State private var raw = ""
    @FocusState private var focused: Bool
    @State private var showConfirmSheet = false
    @State private var failureAlertPresented = false

    private var canonical: String { Iso6346.canonicalise(raw) }
    private var wellFormed: Bool { canonical.count == 11 && Iso6346.isWellFormed(canonical) }
    private var valid: Bool { wellFormed && Iso6346.isValid(canonical) }
    private var showFormatError: Bool { canonical.count == 11 && !wellFormed }
    private var showCheckDigitError: Bool { wellFormed && !valid }
    private var expectedCheckDigit: Int? {
        showCheckDigitError ? Iso6346.computedCheckDigit(canonical) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("container_entry_heading")
                .font(.headline)
            Text("container_entry_subheading")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("", text: $raw, prompt: Text("container_entry_placeholder")
                    .foregroundColor(.secondary.opacity(0.3)))
                    .keyboardType(.default)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled(true)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 22, weight: .medium, design: .monospaced))
                    .tracking(2)
                    .textFieldStyle(.plain)
                    .focused($focused)
                if valid {
                    Image(systemName: "checkmark")
                        .font(.body)
                        .foregroundStyle(Color(hex: 0x34C759))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(valid ? Color(hex: 0x34C759) : Color(.separator), lineWidth: 1)
            )
            .onChange(of: raw) { newValue in
                // Live canonicalisation — strip non-alphanumerics +
                // uppercase + cap at 11. Cleaner than letting the user
                // type characters the validator quietly drops.
                let cleaned = String(Iso6346.canonicalise(newValue).prefix(11))
                if cleaned != newValue { raw = cleaned }
            }
            .onSubmit(submit)
            .animation(.easeInOut(duration: 0.2), value: valid)

            if showFormatError {
                Text("container_entry_validation_format")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .transition(.opacity)
            }
            if showCheckDigitError {
                Text(checkDigitMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .transition(.opacity)
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
            .disabled(!valid || captureVM.state.loading)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
        .animation(.easeInOut(duration: 0.15), value: showFormatError)
        .animation(.easeInOut(duration: 0.15), value: showCheckDigitError)
        .navigationTitle("container_entry_title")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = true }
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
            captureVM.state.failure?.copy.title ?? "",
            isPresented: $failureAlertPresented,
            actions: {
                Button(String(localized: "common_ok")) { captureVM.clear() }
            },
            message: { Text(captureVM.state.failure?.copy.body ?? "") }
        )
    }

    private func submit() {
        guard valid, !captureVM.state.loading else { return }
        EchoHaptics.tick()
        captureVM.identifyByContainer(canonical)
    }

    private var checkDigitMessage: String {
        if let expected = expectedCheckDigit {
            return String(format: String(localized: "container_entry_validation_checkdigit_expected"), expected)
        }
        return String(localized: "container_entry_validation_checkdigit")
    }
}
