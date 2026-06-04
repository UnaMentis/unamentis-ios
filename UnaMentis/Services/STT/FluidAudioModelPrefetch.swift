// UnaMentis - On-Device STT Model Prefetch
// =========================================
//
// Prefetches the Parakeet realtime EOU model (~hundreds of MB, CoreML) so the
// first voice session does not block on a cold download from HuggingFace.
// No-op unless the FluidAudio package is present. Idempotent (skips if cached).
//
// TODO (device): gate the prefetch on Wi-Fi / not-low-data-mode and surface a
// progress UI for first-run testers.

import Foundation
import OSLog

#if canImport(FluidAudio)
import FluidAudio
#endif

public enum FluidAudioModelPrefetch {
    private static let logger = Logger(subsystem: "com.unamentis", category: "STTPrefetch")
    private static let prefetchedKey = "fluidAudioModelPrefetched"

    /// Kick off a background prefetch once, if the package is present and we
    /// haven't already cached the model. Best effort; failures are logged.
    public static func prefetchIfNeeded() {
        #if canImport(FluidAudio)
        guard !UserDefaults.standard.bool(forKey: prefetchedKey) else { return }
        Task.detached(priority: .utility) {
            do {
                let manager = StreamingEouAsrManager(chunkSize: .ms160)
                try await manager.loadModels()   // downloads + caches if missing
                UserDefaults.standard.set(true, forKey: prefetchedKey)
                logger.info("Prefetched Parakeet EOU model")
            } catch {
                logger.error("STT model prefetch failed: \(error.localizedDescription)")
            }
        }
        #endif
    }
}
