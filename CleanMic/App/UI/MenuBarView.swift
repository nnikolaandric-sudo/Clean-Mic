import SwiftUI

// TODO: Faza 3 — Menu-bar dropdown
// Spec: PRD-05-UX-UI.md §3.1
struct MenuBarView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CleanMic — TODO: implementirati po PRD-05")
                .font(.headline)
            Text("ON/OFF, Input dropdown, Mode radio, Level meters")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 320)
    }
}
