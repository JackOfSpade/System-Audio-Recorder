import SwiftUI
import TapKit

/// Library window (Section 3.6.2): sessions list, session detail (segments,
/// events timeline), and the export panel.
struct LibraryView: View {
    @ObservedObject var appState: AppState
    @State private var sessions: [SessionSummary] = []
    @State private var selected: SessionSummary?
    @State private var exportFormat: ExportFormat = .flac16
    @State private var compensateGain = true
    @State private var exportStatus: String = ""

    var body: some View {
        NavigationSplitView {
            List(sessions.indices, id: \.self, selection: Binding(
                get: { selected.flatMap { s in sessions.firstIndex { $0.folderURL == s.folderURL } } },
                set: { idx in selected = idx.map { sessions[$0] } }
            )) { idx in
                let session = sessions[idx]
                VStack(alignment: .leading) {
                    Text(session.manifest.session.title).font(.headline)
                    HStack(spacing: 6) {
                        Text(session.manifest.session.sourceType).font(.caption)
                        if session.manifest.session.recovered == true {
                            Badge(text: "Recovered", color: .orange)
                        }
                        if session.manifest.lanes.flatMap({ $0.events }).contains(where: { $0.type == .zeroDropoutRebuild }) {
                            Badge(text: "Had dropouts", color: .red)
                        }
                        if session.manifest.lanes.flatMap({ $0.events }).contains(where: { $0.type == .overrunGap }) {
                            Badge(text: "Had gaps", color: .yellow)
                        }
                    }
                }
                .tag(session)
            }
            .navigationTitle("Library")
            .toolbar {
                Button("Refresh", systemImage: "arrow.clockwise") { reload() }
            }
        } detail: {
            if let selected {
                sessionDetail(selected)
            } else {
                Text("Select a session").foregroundStyle(.secondary)
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        appState.engine.sessionStore.runCrashRecoveryScan()
        sessions = appState.engine.sessionStore.listSessions()
        // `selected` otherwise keeps holding the OLD snapshot from before
        // this reload — the sidebar (built fresh from `sessions`) and the
        // detail pane (still showing the stale `selected`) would then
        // disagree, e.g. after a crash-recovery pass just changed this same
        // session's `recovered`/segment data. Re-resolve it by folder URL,
        // or clear it if the session no longer exists.
        if let selectedFolder = selected?.folderURL {
            selected = sessions.first { $0.folderURL == selectedFolder }
        }
    }

    @ViewBuilder
    private func sessionDetail(_ session: SessionSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(session.manifest.session.title).font(.title2)
                Text("Device: \(session.manifest.session.device.name)").font(.caption)

                ForEach(session.manifest.lanes, id: \.index) { lane in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Lane: \(lane.slug)").font(.headline)
                        ForEach(lane.segments, id: \.index) { segment in
                            Text("  \(segment.file) — \(Int(segment.sampleRate))Hz, \(segment.channels)ch, \(segment.frames ?? 0) frames")
                                .font(.caption).monospaced()
                        }
                        if !lane.events.isEmpty {
                            Text("Events:").font(.subheadline)
                            ForEach(Array(lane.events.enumerated()), id: \.offset) { _, event in
                                Text("  \(event.atWallTime) — \(event.type.rawValue)")
                                    .font(.caption2).monospaced()
                            }
                        }
                    }
                }

                Divider()
                exportPanel(session)
            }
            .padding()
        }
    }

    @ViewBuilder
    private func exportPanel(_ session: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Export").font(.headline)
            Picker("Format", selection: $exportFormat) {
                ForEach(ExportFormat.allCases, id: \.self) { format in
                    Text(format.rawValue).tag(format)
                }
            }
            Toggle("Apply level compensation", isOn: $compensateGain)
            Text("The CAF float master is the only true archive; 16/24-bit exports are bit-depth reductions.")
                .font(.caption2).foregroundStyle(.secondary)
            Button("Export") { runExport(session) }
            if !exportStatus.isEmpty {
                Text(exportStatus).font(.caption)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([session.folderURL])
            }
        }
    }

    private func runExport(_ session: SessionSummary) {
        // Previously exported only lanes.first/segments.first — a session
        // with more than one segment (device switches, rate changes) or
        // more than one lane (multi-track app-set recordings) silently lost
        // everything after the first, while still reporting success.
        let outDir = session.folderURL.appendingPathComponent("exports")
        let ext = exportFormat == .wav24 ? "wav" : (exportFormat == .aac || exportFormat.rawValue.hasPrefix("alac") ? "m4a" : "flac")

        var exportedCount = 0
        var failureCount = 0
        var totalClipped = 0

        for lane in session.manifest.lanes {
            let gain = compensateGain ? lane.calibration?.gainCompensationDB : nil
            let laneDir = outDir.appendingPathComponent(lane.slug)
            for segment in lane.segments {
                let masterURL = session.folderURL.appendingPathComponent(segment.file)
                let dest = laneDir.appendingPathComponent("\(lane.slug)-\(segment.index).\(ext)")
                try? Foundation.FileManager.default.createDirectory(at: laneDir, withIntermediateDirectories: true)
                do {
                    let result = try ExportService.export(masterURL: masterURL, to: dest, format: exportFormat, gainCompensationDB: gain)
                    exportedCount += 1
                    totalClipped += result.clippedSampleCount
                } catch {
                    failureCount += 1
                }
            }
        }

        if exportedCount == 0 && failureCount == 0 {
            exportStatus = "Nothing to export"
        } else if failureCount == 0 {
            exportStatus = "Exported \(exportedCount) file(s) to \(outDir.lastPathComponent)" + (totalClipped > 0 ? " (clipped: \(totalClipped))" : "")
        } else {
            exportStatus = "Exported \(exportedCount) file(s), \(failureCount) failed"
        }
    }
}

extension SessionSummary: Hashable {
    public static func == (lhs: SessionSummary, rhs: SessionSummary) -> Bool { lhs.folderURL == rhs.folderURL }
    public func hash(into hasher: inout Hasher) { hasher.combine(folderURL) }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
