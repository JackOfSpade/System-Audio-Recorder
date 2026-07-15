import SwiftUI
import TapKit

/// First-launch onboarding sheet (Section 3.6.4): explains what will happen,
/// runs the permission probe, and on success proceeds to a guided test
/// recording (a nicety layered on top of the Section 9 permission flow, not
/// part of it).
struct OnboardingView: View {
    @ObservedObject var appState: AppState
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 48))
            Text("Welcome to TapDeck").font(.title)
            Text("TapDeck records the audio your Mac plays — system-wide or from apps you choose. macOS requires your permission for this.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            switch appState.permissionOutcome {
            case .unknown:
                Button("Enable System Audio Capture") {
                    appState.requestPermissionIfNeeded()
                }
                .buttonStyle(.borderedProminent)
            case .granted:
                Text("Permission granted.").foregroundStyle(.green)
                Text("The tapdeck CLI will request its own separate permission the first time it records.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Done", action: onDismiss)
                    .buttonStyle(.borderedProminent)
            case .notGranted:
                Text("Permission was not granted.").foregroundStyle(.red)
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .padding(32)
        .frame(width: 440)
    }
}
