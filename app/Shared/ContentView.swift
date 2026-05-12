import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hammer.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .foregroundStyle(.tint)
                // Decorative — the title text below carries the meaning. Mark
                // hidden so VoiceOver doesn't announce "hammer-and-wrench, image".
                .accessibilityHidden(true)
            Text("HelloApp")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(AccessibilityIdentifiers.title)
            Text("iOS + macOS template")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Rename me. Run `bin/rename.sh --help`.")
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
