import AppKit
import SwiftUI
import TapKit

/// Settings window: sidebar navigation on the left, content panel on the right.
/// Replaces the TabView layout whose tabs collapsed into a dropdown overflow menu
/// on narrow windows (making sections invisible until the user stumbled upon the
/// chevron button).
struct SettingsView: View {
    @ObservedObject var appState: AppState
    var keepSettingsVisible: () -> Void = {}
    var pinSettingsVisible: (Bool) -> Void = { _ in }
    @AppStorage("recordingsFolder") private var recordingsFolder: String = "~/Music/System Audio Recorder/"
    @AppStorage("namingTemplate") private var namingTemplate: String = "{date} {time} — {source}"
    @AppStorage("recordingFormat") private var recordingFormat: String = ExportFormat.caf32.rawValue
    @AppStorage("timelinePolicy") private var timelinePolicy: String = TimelinePolicy.preserveWallClock.rawValue
    @AppStorage("silentCapture") private var silentCapture: Bool = false
    @AppStorage("bufferFrameSize") private var bufferFrameSize: Double = 512
    @AppStorage("forcedRateEnabled") private var forcedRateEnabled: Bool = false

    enum Section: String, CaseIterable, Identifiable {
        case general   = "General"
        case recording = "Recording"
        case formats   = "Formats"
        case advanced  = "Advanced"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general:   return "gearshape"
            case .recording: return "record.circle"
            case .formats:   return "waveform"
            case .advanced:  return "wrench.and.screwdriver"
            }
        }
    }

    @State private var selectedSection: Section = .general
    @State private var isCalibratingEngine = false
    @State private var calibrationStatus: String?

    var body: some View {
        HStack(spacing: 0) {
            // MARK: Sidebar
            VStack(spacing: 0) {
                ForEach(Section.allCases) { section in
                    SidebarRow(
                        section: section,
                        isSelected: selectedSection == section
                    )
                    .onTapGesture { selectedSection = section }
                }
                Spacer()
            }
            .frame(width: 160)
            .background(.ultraThinMaterial)

            Divider()

            // MARK: Content panel
            ScrollView {
                Group {
                    switch selectedSection {
                    case .general:    generalPanel
                    case .recording:  recordingPanel
                    case .formats:    formatsPanel
                    case .advanced:   advancedPanel
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 620, height: 380)
    }

    // MARK: General

    private var generalPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            panelHeader("General", icon: "gearshape")

            settingsGroup("Storage") {
                LabeledField("Recordings folder") {
                    HStack {
                        TextField("", text: $recordingsFolder)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse…") { chooseRecordingsFolder() }
                    }
                }
                LabeledField("Naming template") {
                    TextField("", text: $namingTemplate)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Tokens: {date}  {time}  {source}  {app}  {device}  {rate}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func chooseRecordingsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a folder for recordings"
        panel.directoryURL = URL(fileURLWithPath: (recordingsFolder as NSString).expandingTildeInPath, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        recordingsFolder = url.path
    }

    // MARK: Recording

    private var recordingPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            panelHeader("Recording", icon: "record.circle")

            settingsGroup("Behaviour") {
                LabeledField("Timeline policy") {
                    Picker("", selection: $timelinePolicy) {
                        Text("Preserve wall clock").tag(TimelinePolicy.preserveWallClock.rawValue)
                        Text("Compress timeline").tag(TimelinePolicy.compressTimeline.rawValue)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240)
                }
                Toggle("Silent capture — mute system output while recording", isOn: $silentCapture)
            }
        }
    }

    // MARK: Formats

    private var formatsPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            panelHeader("Formats", icon: "waveform")

            settingsGroup("Output Format") {
                LabeledField("Format") {
                    Picker("", selection: $recordingFormat) {
                        Text("WAV 32-bit Float").tag(ExportFormat.wav32.rawValue)
                        Text("CAF 32-bit Float").tag(ExportFormat.caf32.rawValue)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                }

                formatHint
            }
        }
    }

    @ViewBuilder
    private var formatHint: some View {
        let hint: String = {
            switch ExportFormat(rawValue: recordingFormat) ?? .caf32 {
            case .wav32: return "WAV container · 32-bit Float PCM · broad compatibility"
            case .caf32: return "CAF container · 32-bit Float PCM · no conversion"
            }
        }()
        Text(hint)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: Advanced

    private var advancedPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            panelHeader("Advanced", icon: "wrench.and.screwdriver")

            settingsGroup("Audio Engine") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Force capture rate", isOn: $forcedRateEnabled)
                    if forcedRateEnabled {
                        Text("Forcing a rate different from the output device's current rate makes macOS resample audio before capture. Only enable if a fixed rate is more important than maximum fidelity.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            settingsGroup("Calibration") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last calibration result: \(Int(bufferFrameSize)) frames")
                    Text("Recordings always resolve the right size for whichever output device is active at the time, so this may differ from what's shown here if you've since switched devices. Lower is better — less latency, tighter meters — down to what a device's hardware can physically sustain. Calibration finds that floor for you; there's nothing to gain by setting it lower by hand.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button(isCalibratingEngine ? "Calibrating..." : "Run Calibration...") {
                        runEngineCalibration()
                    }
                    .disabled(isCalibratingEngine || appState.isRecording)

                    if isCalibratingEngine {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let calibrationStatus {
                    Text(calibrationStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func runEngineCalibration() {
        guard !isCalibratingEngine else { return }
        isCalibratingEngine = true
        calibrationStatus = "Testing I/O buffer sizes..."
        pinSettingsVisible(true)
        keepSettingsVisible()

        appState.engine.recommendBufferFrameSize { result in
            DispatchQueue.main.async {
                isCalibratingEngine = false
                switch result {
                case .success(let recommendation):
                    bufferFrameSize = Double(recommendation.selectedFrameSize)
                    let supported = recommendation.supportedFrameSizes.map(String.init).joined(separator: ", ")
                    calibrationStatus = "Selected \(recommendation.selectedFrameSize) frames for \(recommendation.deviceName). Supported: \(supported)."
                case .failure(let error):
                    calibrationStatus = "Calibration failed: \(error)"
                }
                pinSettingsVisible(false)
                keepSettingsVisible()
            }
        }
    }

    // MARK: Shared helpers

    private func panelHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
        }
    }

    private func settingsGroup<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label.uppercased())
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .tracking(0.5)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.separator, lineWidth: 0.5)
            )
        }
    }
}

// MARK: LabeledField

private struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .frame(width: 130, alignment: .trailing)
                .foregroundStyle(.secondary)
            content()
        }
    }
}

// MARK: SidebarRow

private struct SidebarRow: View {
    let section: SettingsView.Section
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: section.icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 20)
                .foregroundStyle(isSelected ? .white : .secondary)
            Text(section.rawValue)
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? .white : .primary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : Color.clear)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}
