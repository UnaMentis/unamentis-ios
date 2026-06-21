// UnaMentis - On-Device STT Model Manager
// ========================================
//
// Observable owner of the on-device STT model lifecycle. Observability is a
// first-class requirement: you can always see that a download was initiated,
// watch its progress, and see the result, with no ambiguity. This drives the
// "On-Device Speech" status UI in Settings and is triggered on app launch.
//
// Backed by FluidAudio's Parakeet realtime EOU model. Gated on
// `#if canImport(FluidAudio)`; reports `.unavailable` when the package is absent.

import Foundation
import OSLog

#if canImport(FluidAudio)
import FluidAudio
#endif

@MainActor
public final class STTModelManager: ObservableObject {
    public static let shared = STTModelManager()

    public enum State: Equatable {
        case unavailable            // FluidAudio not in this build
        case notDownloaded
        case downloading(Double)    // fractionCompleted 0...1
        case ready
        case failed(String)
    }

    /// Current model state. The UI observes this; transitions are the record of
    /// initiation -> progress -> result.
    @Published public private(set) var state: State
    /// When the state last changed.
    @Published public private(set) var lastUpdated: Date?

    private let logger = Logger(subsystem: "com.unamentis", category: "STTModel")
    private static let doneKey = "fluidAudioModelPrefetched"
    private var task: Task<Void, Never>?

    private init() {
        #if canImport(FluidAudio)
        state = UserDefaults.standard.bool(forKey: Self.doneKey) ? .ready : .notDownloaded
        #else
        state = .unavailable
        #endif
    }

    public var isAvailable: Bool {
        #if canImport(FluidAudio)
        return true
        #else
        return false
        #endif
    }

    /// Start a download if one isn't already done or running. Safe to call
    /// repeatedly (app launch + the UI both call it).
    public func ensureDownloaded() {
        guard isAvailable, task == nil, state != .ready else { return }
        start(force: false)
    }

    /// Force a fresh download (clears the cache first).
    public func redownload() {
        guard isAvailable else { return }
        start(force: true)
    }

    private func start(force: Bool) {
        #if canImport(FluidAudio)
        task?.cancel()
        setState(.downloading(0))
        logger.info("STT model download initiated (force: \(force))")
        // The Task inherits @MainActor from this method. Capture self strongly:
        // the manager is a singleton and finish() clears `task`, so there is no
        // lasting cycle, and a strong (constant) capture avoids referencing a
        // `var` (weak self) inside the @Sendable progress closure.
        task = Task {
            if force { DownloadUtils.clearAllModelCaches() }
            do {
                let asr = StreamingEouAsrManager(chunkSize: .ms160)
                try await asr.loadModels(progressHandler: { progress in
                    Task { @MainActor in self.updateProgress(progress.fractionCompleted) }
                })
                self.finish(.ready, persist: true)
            } catch {
                self.finish(.failed(error.localizedDescription), persist: false)
            }
        }
        #endif
    }

    private func updateProgress(_ fraction: Double) {
        guard case .downloading = state else { return }
        setState(.downloading(fraction))
    }

    private func finish(_ newState: State, persist: Bool) {
        if persist { UserDefaults.standard.set(true, forKey: Self.doneKey) }
        task = nil
        setState(newState)
        switch newState {
        case .ready: logger.info("STT model ready")
        case .failed(let message): logger.error("STT model download failed: \(message)")
        default: break
        }
    }

    private func setState(_ newState: State) {
        state = newState
        lastUpdated = Date()
    }
}
