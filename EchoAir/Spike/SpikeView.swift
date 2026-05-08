#if DEBUG
import SwiftUI

/// Debug-only spike UI. Reachable from `ContentView` via a `#if DEBUG`
/// NavigationLink. Removed entirely from release builds via the file-level
/// `#if DEBUG` guard, so the harness ships zero code to the App Store.
struct SpikeView: View {
    @StateObject private var runner = SpikeRunner()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("BLE Spike").font(.title2).fontWeight(.semibold)
                Spacer()
                Button(runner.isRunning ? "Running…" : "Run spike") {
                    Task { await runner.run() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(runner.isRunning)
            }

            Text("Connects to the configured S23H, reads sensor info, pages records via NormalOrder from cursor 0. Pass criteria are logged inline.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if runner.log.isEmpty {
                        Text("Tap “Run spike” to start.")
                            .foregroundStyle(.secondary)
                            .padding()
                    } else {
                        ForEach(Array(runner.log.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding()
        .navigationTitle("Spike")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { SpikeView() }
}
#endif
