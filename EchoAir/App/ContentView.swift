import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("Echo Air")
                    .font(.largeTitle)
                    .fontWeight(.semibold)
                Text("iOS scaffold")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                #if DEBUG
                NavigationLink("Open BLE spike") {
                    SpikeView()
                }
                .buttonStyle(.bordered)
                .padding(.top, 24)
                #endif
            }
            .padding()
        }
    }
}

#Preview {
    ContentView()
}
