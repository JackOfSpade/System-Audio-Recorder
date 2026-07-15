import SwiftUI
import TapKit

/// The menu-bar dropdown content (Section 3.6.1): record button, source
/// picker, device readout, live meters, elapsed time, health chip, and the
/// Library/Settings/Quit items.
struct MenuBarView: View {
    @ObservedObject var appState: AppState
    var openLibrary: () -> Void
    var openSettings: () -> Void
    var quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: { appState.toggleRecord() }) {
                Label(appState.isRecording ? "Stop Recording" : "Record", systemImage: appState.isRecording ? "stop.circle.fill" : "record.circle")
                    .font(.title3)
            }
            .buttonStyle(.borderedProminent)
            .disabled(appState.permissionOutcome == .notGranted)

            HStack {
                Text("Source")
                Spacer()
                Text("System Audio").foregroundStyle(.secondary)
            }

            Divider()

            ForEach(Array(appState.meters.enumerated()), id: \.offset) { _, meter in
                MeterBarsView(meter: meter)
            }

            HStack {
                Text(formattedElapsed)
                    .monospacedDigit()
                Spacer()
                Text(appState.healthDescription)
                    .foregroundStyle(healthColor)
            }
            .font(.caption)

            if appState.permissionOutcome == .notGranted {
                Text("System audio capture permission not granted.")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            Divider()

            Button("Open Library…", action: openLibrary)
            Button("Settings…", action: openSettings)
            Divider()
            Button("Quit TapDeck") { quit() }
                .disabled(appState.isRecording)
                .help(appState.isRecording ? "Stop the current recording first." : "")
        }
        .padding(12)
        .frame(width: 280)
    }

    private var formattedElapsed: String {
        let total = Int(appState.elapsedSeconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private var healthColor: Color {
        switch appState.status {
        case .idle: return .secondary
        case .recording: return .green
        case .error: return .red
        }
    }
}

struct MeterBarsView: View {
    let meter: MeterSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(meter.peakByChannel.enumerated()), id: \.offset) { index, peak in
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.secondary.opacity(0.2))
                        Rectangle()
                            .fill(peak >= 1.0 ? Color.red : Color.green)
                            .frame(width: geo.size.width * CGFloat(min(peak, 1.0)))
                    }
                }
                .frame(height: 6)
                .cornerRadius(3)
            }
        }
    }
}
