// UnaMentis - On-Device Speech (STT) Status
// =========================================
//
// A Settings section that makes the on-device speech model fully observable:
// whether a download was initiated, its live progress, and the result - plus a
// control to (re)start it. Drop into any Form: `OnDeviceSpeechStatusView()`.

import SwiftUI

struct OnDeviceSpeechStatusView: View {
    @ObservedObject private var manager = STTModelManager.shared

    var body: some View {
        Section {
            HStack {
                Label("Speech Recognition Model", systemImage: "waveform")
                    .accessibilityLabel("Speech recognition model")
                Spacer()
                statusBadge
            }

            if case .downloading(let fraction) = manager.state {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: fraction)
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Download \(Int((fraction * 100).rounded())) percent complete")
                }
            }

            if case .failed(let message) = manager.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            actionButton

            if let updated = manager.lastUpdated {
                Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("On-Device Speech (Parakeet)")
        } footer: {
            Text("Streaming speech-to-text runs entirely on-device (Apple Neural Engine). The model is downloaded once, about a few hundred MB, on first use - best on Wi-Fi.")
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch manager.state {
        case .unavailable:
            Text("Not in this build").foregroundStyle(.secondary)
        case .notDownloaded:
            Text("Not downloaded").foregroundStyle(.secondary)
        case .downloading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Downloading…")
            }
            .foregroundStyle(.blue)
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder private var actionButton: some View {
        switch manager.state {
        case .notDownloaded:
            Button("Download Now") { manager.ensureDownloaded() }
        case .failed:
            Button("Retry Download") { manager.redownload() }
        case .ready:
            Button("Re-download") { manager.redownload() }
        case .downloading, .unavailable:
            EmptyView()
        }
    }
}
