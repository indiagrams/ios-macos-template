import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hammer.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .foregroundStyle(.tint)
            Text("HelloApp")
                .font(.largeTitle.bold())
            Text("iOS + macOS template")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Rename me. See README.md → \"Renaming the stub\".")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
        .frame(minWidth: 320, minHeight: 240)
    }
}

#Preview {
    ContentView()
}
