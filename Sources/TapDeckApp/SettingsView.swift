import SwiftUI
import TapKit

/// Settings window (Section 3.6.3): five tabs — General, Recording, Formats
/// & Export, Automation, Advanced.
struct SettingsView: View {
    @ObservedObject var appState: AppState
    @AppStorage("recordingsFolder") private var recordingsFolder: String = "~/Music/TapDeck/"
    @AppStorage("namingTemplate") private var namingTemplate: String = "{date} {time} — {source}"
    @AppStorage("showDockIcon") private var showDockIcon: Bool = false
    @AppStorage("timelinePolicy") private var timelinePolicy: String = TimelinePolicy.preserveWallClock.rawValue
    @AppStorage("silentCapture") private var silentCapture: Bool = false
    @AppStorage("ditherEnabled") private var ditherEnabled: Bool = true
    @AppStorage("bakeCompensationIntoMaster") private var bakeCompensationIntoMaster: Bool = false
    @AppStorage("bufferFrameSize") private var bufferFrameSize: Double = 512
    @AppStorage("forcedRateEnabled") private var forcedRateEnabled: Bool = false

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
            recordingTab.tabItem { Label("Recording", systemImage: "record.circle") }
            formatsTab.tabItem { Label("Formats & Export", systemImage: "square.and.arrow.up") }
            automationTab.tabItem { Label("Automation", systemImage: "bolt") }
            advancedTab.tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 520, height: 420)
        .padding()
    }

    private var generalTab: some View {
        Form {
            TextField("Recordings folder", text: $recordingsFolder)
            TextField("Naming template", text: $namingTemplate)
            Text("Tokens: {date} {time} {source} {app} {device} {rate}").font(.caption).foregroundStyle(.secondary)
            Toggle("Show Dock icon", isOn: $showDockIcon)
        }.padding()
    }

    private var recordingTab: some View {
        Form {
            Picker("Timeline policy", selection: $timelinePolicy) {
                Text("Preserve wall clock").tag(TimelinePolicy.preserveWallClock.rawValue)
                Text("Compress timeline").tag(TimelinePolicy.compressTimeline.rawValue)
            }
            Toggle("Silent capture (mute system output while recording)", isOn: $silentCapture)
        }.padding()
    }

    private var formatsTab: some View {
        Form {
            Toggle("Dither 16-bit exports (TPDF)", isOn: $ditherEnabled)
            Toggle("Bake compensation into master", isOn: $bakeCompensationIntoMaster)
            if bakeCompensationIntoMaster {
                Text("Warning: this modifies the master's samples. The master is normally never touched.")
                    .font(.caption).foregroundStyle(.red)
            }
        }.padding()
    }

    private var automationTab: some View {
        Form {
            Text("Shell hooks: onSessionStart, onSegmentClose, onSessionFinalize")
            Text("Triggers: schedule rules and app-activity auto-record configured here.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding()
    }

    private var advancedTab: some View {
        Form {
            Slider(value: $bufferFrameSize, in: 128...4096, step: 128) {
                Text("Buffer frame size: \(Int(bufferFrameSize))")
            }
            Toggle("Force capture rate", isOn: $forcedRateEnabled)
            if forcedRateEnabled {
                Text("Forcing a rate different from the output device's current rate makes macOS resample the audio before TapDeck can capture it. Only use this if you need a fixed rate more than you need maximum fidelity.")
                    .font(.caption).foregroundStyle(.red)
            }
            Button("Run Calibration…") {
                // Wired to CalibrationService.runCalibration in the full app;
                // left as an action point here.
            }
        }.padding()
    }
}
