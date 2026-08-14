// UnaMentis - On-Device LLM Model Manager
// Manages Ministral 3 3B model download, storage, and lifecycle
//
// Part of Services/LLM

import CryptoKit
import Foundation
import OSLog

// MARK: - Model Configuration

/// Model configuration for on-device LLM
public struct OnDeviceLLMModelConfig: Sendable {
    /// Model identifier
    let id: String
    /// Display name
    let displayName: String
    /// Hugging Face repository
    let huggingFaceRepo: String
    /// Filename in the repository
    let filename: String
    /// Expected file size in bytes
    let expectedSizeBytes: Int64
    /// Expected SHA256 of the downloaded file, lowercase hex.
    ///
    /// Sourced from the Hugging Face LFS metadata for the pinned `revision`
    /// (`GET /api/models/<repo>/tree/<revision>?recursive=true`, the `lfs.oid`
    /// field, which is the SHA256 of the file contents). The download is rejected
    /// unless the file hashes to this value, so a corrupted transfer or a
    /// substituted file is never committed to the model path llama.cpp loads.
    let expectedSHA256: String
    /// Pinned Hugging Face revision (repo commit SHA) the hash and size describe.
    ///
    /// The download URL resolves this revision, not `main`, so an upstream
    /// force-push can never make every download fail its hash check after the
    /// full multi-gigabyte transfer. Bump revision, size, and hash together.
    let revision: String
    /// Quantization type
    let quantization: String
    /// Context window size
    let contextSize: UInt32
    /// Minimum RAM required in GB
    let minimumRAMGB: Int
    /// Description for users
    let description: String

    /// Direct download URL from Hugging Face CDN, pinned to `revision`
    var downloadURL: URL {
        URL(string: "https://huggingface.co/\(huggingFaceRepo)/resolve/\(revision)/\(filename)")!
    }

    /// Expected size in MB for display
    var expectedSizeMB: Int {
        Int(expectedSizeBytes / 1_000_000)
    }
}

// MARK: - Available Models

/// Available on-device LLM models, ordered as a device-capability tier ladder.
///
/// The beta ships a tiered on-device strategy so every supported device gets the
/// most capable model it can run without risking an out-of-memory session kill:
/// - `gemma4_e2b`: showcase model for 12 GB devices (iPhone 17 Pro class). Newest
///   architecture (April 2026), Apache 2.0, the quality-for-size leader.
/// - `qwen3_1_7B`: fallback for 8 GB devices (iPhone 15 Pro / 16 / 16 Pro). Apache 2.0.
/// - `qwen3_0_6B`: low-RAM fallback for 6 GB devices (iPhone 14 / 14 Pro / 15). Apache 2.0,
///   ~163 ms TTFT, the fastest first-responder.
/// - `ministral3_3B`: legacy/general model retained for compatibility.
///
/// All four run on the same llama.cpp runtime. Gemma 4 requires a llama.cpp build
/// from April 2026 or later (the `gemma4` architecture); the Qwen3 and Ministral
/// models run on the build already integrated. See
/// `docs/ios/ON_DEVICE_LLM_MODEL_RECONSIDERATION_2026-06-20.md`.
public enum OnDeviceLLMModel: String, CaseIterable, Sendable {
    case gemma4_e2b = "gemma-4-e2b"
    case qwen3_1_7B = "qwen3-1.7b"
    case qwen3_0_6B = "qwen3-0.6b"
    case ministral3_3B = "ministral-3-3b"

    /// Model configuration
    public var config: OnDeviceLLMModelConfig {
        switch self {
        case .gemma4_e2b:
            return OnDeviceLLMModelConfig(
                id: "gemma-4-e2b-it",
                displayName: "Gemma 4 E2B",
                huggingFaceRepo: "unsloth/gemma-4-E2B-it-GGUF",
                filename: "gemma-4-E2B-it-Q4_K_M.gguf",
                expectedSizeBytes: 3_106_738_272, // 3.11 GB (HF LFS size; Per-Layer Embeddings load ~5.1B weights)
                expectedSHA256: "740185b21d22ceb83a11c3aa62ad5842ef32c70f6096d756bbee85a1e4ec34b8",
                revision: "0314792d7f1f7e229411f620751375812bb9faf2",
                quantization: "Q4_K_M",
                contextSize: 8192,
                minimumRAMGB: 12,
                description: "April 2026 release from Google. Apache 2.0. Quality-for-size leader; showcase model for high-end devices. Requires a llama.cpp build with gemma4 support."
            )
        case .qwen3_1_7B:
            return OnDeviceLLMModelConfig(
                id: "qwen3-1.7b",
                displayName: "Qwen3 1.7B",
                huggingFaceRepo: "unsloth/Qwen3-1.7B-GGUF",
                filename: "Qwen3-1.7B-Q4_K_M.gguf",
                expectedSizeBytes: 1_107_409_472, // ~1.11 GB (HF LFS size)
                expectedSHA256: "b139949c5bd74937ad8ed8c8cf3d9ffb1e99c866c823204dc42c0d91fa181897",
                revision: "d7f544eead698dbd1f15126ef60b45a1e1933222",
                quantization: "Q4_K_M",
                contextSize: 8192,
                minimumRAMGB: 8,
                description: "May 2025 release from Alibaba. Apache 2.0. Fast, capable fallback for 8 GB devices. Thinking mode is disabled for low-latency conversation."
            )
        case .qwen3_0_6B:
            return OnDeviceLLMModelConfig(
                id: "qwen3-0.6b",
                displayName: "Qwen3 0.6B",
                huggingFaceRepo: "unsloth/Qwen3-0.6B-GGUF",
                filename: "Qwen3-0.6B-Q4_K_M.gguf",
                expectedSizeBytes: 396_705_472, // ~397 MB (HF LFS size)
                expectedSHA256: "ac2d97712095a558e31573f62f466a3f9d93990898b0ec79d7c974c1780d524a",
                revision: "50968a4468ef4233ed78cd7c3de230dd1d61a56b",
                quantization: "Q4_K_M",
                contextSize: 8192,
                minimumRAMGB: 6,
                description: "May 2025 release from Alibaba. Apache 2.0. Low-RAM, low-latency first-responder for 6 GB devices. Thinking mode disabled."
            )
        case .ministral3_3B:
            return OnDeviceLLMModelConfig(
                id: "ministral-3-3b-instruct-2512",
                displayName: "Ministral 3 3B",
                huggingFaceRepo: "mistralai/Ministral-3-3B-Instruct-2512-GGUF",
                filename: "Ministral-3-3B-Instruct-2512-Q4_K_M.gguf",
                expectedSizeBytes: 2_147_023_008, // ~2.15 GB (HF LFS size)
                expectedSHA256: "9ed150d4367e68df0ac8e1540f6ddc65b42d0ee26378329d1ecbca60f93fc5f8",
                revision: "eb599d408350ea2bb60452cb86be7c7b2fc28227",
                quantization: "Q4_K_M",
                contextSize: 4096,
                minimumRAMGB: 8,
                description: "December 2025 release from Mistral AI. Apache 2.0. Retained for compatibility."
            )
        }
    }

    /// Whether this model's architecture loads on the llama.cpp build that ships
    /// in the app today (`UnaMentis/Frameworks/llama.xcframework`, b7263).
    ///
    /// Gemma 4 (arch `gemma4`) needs an April-2026-or-later llama.cpp; b7263 has
    /// build functions only through gemma3n, so a Gemma 4 GGUF fails to load with
    /// "unknown architecture". This stays `false` until a gemma4-capable
    /// llama.xcframework is integrated and Gemma 4 generation is verified on device.
    /// Flipping it to `true` is the ONLY change needed to auto-activate the Gemma 4
    /// showcase on 12 GB devices.
    /// Decision + tiering: docs/ios/ON_DEVICE_LLM_MODEL_RECONSIDERATION_2026-06-20.md.
    public var runsOnBundledRuntime: Bool {
        switch self {
        // Enabled 2026-06-26: the bundled llama.xcframework was upgraded from b7263
        // to b9821, which includes the gemma4 architecture. Gemma 4 E2B loads and
        // generates on it (verified in the simulator).
        case .gemma4_e2b: return true
        case .qwen3_1_7B, .qwen3_0_6B, .ministral3_3B: return true
        }
    }

    /// The decided capability ceiling per device (the TARGET, not necessarily what
    /// loads today). Per ON_DEVICE_LLM_MODEL_RECONSIDERATION_2026-06-20.md: Gemma 4
    /// E2B is the 12 GB showcase, Qwen3-1.7B the 8 GB tier, Qwen3-0.6B the 6 GB tier.
    /// Ministral 3 3B is deprecated and is not a ceiling for any tier.
    /// Use `bestRunnableForDevice(...)` for the model the app downloads and loads now.
    public static func recommendedForDevice(
        physicalMemoryGB: Int = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
    ) -> OnDeviceLLMModel? {
        switch physicalMemoryGB {
        case 12...: return .gemma4_e2b
        case 8...: return .qwen3_1_7B
        case 6...: return .qwen3_0_6B
        default: return nil // below 6 GB: server LLM + Apple TTS fallback
        }
    }

    /// The most capable model the device can run RIGHT NOW: RAM-appropriate AND
    /// supported by the bundled llama.cpp runtime. This is what the app actually
    /// downloads and loads. On a 12 GB device today this is Qwen3-1.7B (the decided
    /// fallback tier), because the Gemma 4 showcase awaits a gemma4-capable
    /// llama.cpp. When `gemma4_e2b.runsOnBundledRuntime` flips to true, 12 GB
    /// devices auto-upgrade to Gemma 4 E2B with no other change. Ministral 3 3B is
    /// deprecated and intentionally excluded from this ladder.
    public static func bestRunnableForDevice(
        physicalMemoryGB: Int = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
    ) -> OnDeviceLLMModel? {
        let ladder: [OnDeviceLLMModel] = [.gemma4_e2b, .qwen3_1_7B, .qwen3_0_6B]
        return ladder.first { $0.config.minimumRAMGB <= physicalMemoryGB && $0.runsOnBundledRuntime }
    }
}

// MARK: - Model Manager

/// Manages on-device LLM model files
///
/// Model files are stored in Documents/models/LLM/ and downloaded from Hugging Face CDN.
///
/// Features:
/// - Download from Hugging Face with progress tracking
/// - Resume interrupted downloads
/// - Delete models to free storage
/// - Verify model integrity
///
/// This is a shared singleton to ensure consistent state across the app.
/// The settings UI and service both reference the same instance.
public actor OnDeviceLLMModelManager {
    /// Shared singleton instance
    public static let shared = OnDeviceLLMModelManager()

    private let logger = Logger(subsystem: "com.unamentis", category: "OnDeviceLLMModelManager")

    // MARK: - Model State

    /// Current state of the model
    public enum ModelState: Sendable, Equatable {
        case notDownloaded       // Model not present
        case downloading(Float)  // Download in progress with progress (0.0-1.0)
        case verifying           // Verifying downloaded file
        case available           // Model present, not loaded
        case loading(Float)      // Loading into memory
        case loaded              // Ready for inference
        case error(String)       // Error occurred

        public static func == (lhs: ModelState, rhs: ModelState) -> Bool {
            switch (lhs, rhs) {
            case (.notDownloaded, .notDownloaded),
                 (.verifying, .verifying),
                 (.available, .available),
                 (.loaded, .loaded):
                return true
            case let (.downloading(p1), .downloading(p2)),
                 let (.loading(p1), .loading(p2)):
                return abs(p1 - p2) < 0.01
            case let (.error(e1), .error(e2)):
                return e1 == e2
            default:
                return false
            }
        }

        public var isReady: Bool {
            self == .loaded
        }

        public var isAvailable: Bool {
            self == .available || self == .loaded
        }

        public var displayText: String {
            switch self {
            case .notDownloaded: return "Not Downloaded"
            case .downloading(let progress): return "Downloading \(Int(progress * 100))%"
            case .verifying: return "Verifying..."
            case .available: return "Ready to Load"
            case .loading(let progress): return "Loading \(Int(progress * 100))%"
            case .loaded: return "Loaded"
            case .error(let message): return "Error: \(message)"
            }
        }
    }

    public private(set) var state: ModelState = .notDownloaded

    /// The model the app downloads/loads, chosen for THIS device: the most capable
    /// model whose RAM tier fits AND that the bundled llama.cpp can run today. On a
    /// 12 GB iPhone this resolves to Qwen3-1.7B now and auto-upgrades to the Gemma 4
    /// E2B showcase once a gemma4-capable llama.cpp lands. Set in init() from the
    /// real device RAM. See ON_DEVICE_LLM_MODEL_RECONSIDERATION_2026-06-20.md.
    public private(set) var selectedModel: OnDeviceLLMModel

    // MARK: - Download State

    /// Hands out its continuation exactly once, no matter how the URLSession
    /// completion handler and cancelDownload() race. Resuming a checked
    /// continuation twice is a fatal error, and the two resume sites run on
    /// different executors, so take-once semantics need a lock, not actor state.
    private final class DownloadContinuationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<URL, Error>?

        init(_ continuation: CheckedContinuation<URL, Error>) {
            self.continuation = continuation
        }

        func take() -> CheckedContinuation<URL, Error>? {
            lock.lock()
            defer { lock.unlock() }
            let taken = continuation
            continuation = nil
            return taken
        }
    }

    private var downloadTask: URLSessionDownloadTask?
    private var downloadContinuationBox: DownloadContinuationBox?
    private var progressObservation: NSKeyValueObservation?

    // MARK: - Model Paths

    /// Base directory for LLM models
    private var modelDirectory: URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsPath.appendingPathComponent("models/LLM", isDirectory: true)
    }

    /// Path to the current model file. A file exists here only after it passed
    /// hash verification: downloads land at `stagingModelPath` and are renamed
    /// in as the final commit step, so presence implies verified.
    public var modelPath: URL {
        modelDirectory.appendingPathComponent(selectedModel.config.filename)
    }

    /// Staging path holding a downloaded file until its hash is verified. If the
    /// app dies mid-verification, the file is here, not at `modelPath`, so it can
    /// never be mistaken for an available model on the next launch.
    var stagingModelPath: URL {
        modelDirectory.appendingPathComponent(selectedModel.config.filename + ".unverified")
    }

    /// Sidecar recording the verified SHA256 of the file at `modelPath`. Lets a
    /// later launch (or a pin bump to a new model revision) know whether the
    /// on-disk file still matches the expected hash without re-reading gigabytes.
    var verifiedSidecarPath: URL {
        modelDirectory.appendingPathComponent(selectedModel.config.filename + ".sha256")
    }

    /// Path as string for llama.cpp
    public var modelPathString: String {
        modelPath.path
    }

    // MARK: - Initialization

    public init() {
        // Pick the device-appropriate, runnable model up front so the download UI
        // and the session load the same thing. Falls back to the smallest runnable
        // model on unexpectedly small devices.
        self.selectedModel = OnDeviceLLMModel.bestRunnableForDevice() ?? .qwen3_0_6B
        Task {
            await checkModelAvailability()
        }
    }

    // MARK: - Public API

    /// Get current model state (refreshes from filesystem first)
    nonisolated public func currentState() async -> ModelState {
        await refreshStateFromFilesystem()
        return await state
    }

    /// Refresh state from filesystem to ensure it's accurate
    private func refreshStateFromFilesystem() {
        // Only refresh if we're in a potentially stale state
        switch state {
        case .downloading, .verifying, .loading:
            // These are transient states managed by operations, don't override
            return
        case .notDownloaded, .available, .loaded, .error:
            // Check actual file presence
            if isModelAvailable() {
                // File exists - if we thought it wasn't downloaded, update to available
                if case .notDownloaded = state {
                    state = .available
                }
                // Keep .loaded state if we were loaded
            } else if case .loaded = state {
                // The model is loaded in memory; a failing file probe must not
                // report it as not-downloaded. Keep the in-memory loaded state.
            } else {
                // File doesn't exist - reset to notDownloaded.
                state = .notDownloaded
            }
        }
    }

    /// Check if model is available locally
    public func isModelAvailable() -> Bool {
        FileManager.default.fileExists(atPath: modelPath.path)
    }

    /// Get model file size in bytes (0 if not downloaded)
    public func modelSizeBytes() -> Int64 {
        guard isModelAvailable() else { return 0 }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: modelPath.path)
            return attrs[.size] as? Int64 ?? 0
        } catch {
            return 0
        }
    }

    /// Get model file size in MB for display
    public func modelSizeMB() -> Int {
        Int(modelSizeBytes() / 1_000_000)
    }

    /// Ensure model is available (download if needed)
    ///
    /// A file already on disk is not trusted on presence alone: installs that
    /// predate hash pinning, or a pin bump to a new model revision, leave files
    /// the download-time gate never saw. The verified sidecar makes the repeat
    /// check cheap; a full hash runs only when the sidecar is missing or stale,
    /// and a file that fails its pin is deleted and re-downloaded.
    public func ensureModelAvailable() async throws {
        if isModelAvailable() {
            if try await verifyExistingModelIfNeeded() {
                state = .available
                return
            }
            // The existing file failed its pin and was deleted; fall through.
        }

        try await downloadModel()
    }

    /// Download the model from Hugging Face
    public func downloadModel() async throws {
        guard !isModelAvailable() else {
            state = .available
            return
        }

        let config = selectedModel.config
        logger.info("Starting download of \(config.displayName) from Hugging Face")

        state = .downloading(0.0)

        // Create model directory if needed
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        // Create URLSession configuration for background download
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 300
        sessionConfig.timeoutIntervalForResource = 3600 // 1 hour for large file
        let session = URLSession(configuration: sessionConfig)

        // Download to the staging path. The URLSession temp file must be moved
        // before the completion handler returns (the system may delete it after),
        // so the handler stages it synchronously and the actor only ever works
        // with the staged file.
        let stagingURL = stagingModelPath
        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let box = DownloadContinuationBox(continuation)
                self.downloadContinuationBox = box

                let task = session.downloadTask(with: config.downloadURL) { tempURL, response, error in
                    // take() returns nil when cancelDownload already resumed;
                    // resuming twice would crash.
                    guard let continuation = box.take() else { return }

                    if let error = error {
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let httpResponse = response as? HTTPURLResponse,
                          (200...299).contains(httpResponse.statusCode) else {
                        continuation.resume(throwing: OnDeviceLLMModelError.downloadFailed("Invalid response"))
                        return
                    }

                    guard let tempURL = tempURL else {
                        continuation.resume(throwing: OnDeviceLLMModelError.downloadFailed("No file returned"))
                        return
                    }

                    do {
                        if FileManager.default.fileExists(atPath: stagingURL.path) {
                            try FileManager.default.removeItem(at: stagingURL)
                        }
                        try FileManager.default.moveItem(at: tempURL, to: stagingURL)
                        continuation.resume(returning: stagingURL)
                    } catch {
                        continuation.resume(throwing: OnDeviceLLMModelError.downloadFailed(
                            "Could not stage downloaded file: \(error.localizedDescription)"
                        ))
                    }
                }

                self.downloadTask = task

                // Observe progress
                self.progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                    Task { [weak self] in
                        await self?.updateDownloadProgress(Float(progress.fractionCompleted))
                    }
                }

                task.resume()
            }
        } catch {
            cleanUpDownloadBookkeeping()
            if error is CancellationError {
                // cancelDownload already set the state; do not overwrite it.
                throw error
            }
            state = .error("Download failed: \(error.localizedDescription)")
            throw error
        }

        cleanUpDownloadBookkeeping()
        try await verifyAndCommit(stagingURL: stagingURL, config: config)
    }

    /// Invalidate progress observation and drop download bookkeeping on every
    /// exit path, success or failure, so no continuation dangles and no stale
    /// observation fires into the next download.
    private func cleanUpDownloadBookkeeping() {
        progressObservation?.invalidate()
        progressObservation = nil
        downloadTask = nil
        downloadContinuationBox = nil
    }

    /// Verify the staged file and commit it to `modelPath`.
    ///
    /// The staged file only reaches `modelPath` after passing an exact size check
    /// and the SHA256 gate, so presence at `modelPath` implies verified even if
    /// the app dies mid-verification. On any failure the staged file is deleted
    /// and the error state is set.
    private func verifyAndCommit(stagingURL: URL, config: OnDeviceLLMModelConfig) async throws {
        state = .verifying
        logger.info("Download complete, verifying file...")

        // Exact size fast-fail: expectedSizeBytes is the exact LFS size for the
        // pinned revision, so any difference already means the hash cannot match.
        // Rejecting here avoids hashing gigabytes of a truncated transfer.
        let stagedSize = (try? FileManager.default.attributesOfItem(atPath: stagingURL.path)[.size] as? Int64) ?? 0
        guard stagedSize == config.expectedSizeBytes else {
            try? FileManager.default.removeItem(at: stagingURL)
            let message = "Downloaded size \(stagedSize) does not match expected \(config.expectedSizeBytes)"
            logger.error("\(message)")
            state = .error("Model download was incomplete or corrupted. Please try again.")
            throw OnDeviceLLMModelError.verificationFailed(message)
        }

        do {
            try await Self.verifyFile(at: stagingURL, expectedSHA256: config.expectedSHA256)

            // Commit: the file appears at modelPath only after verification.
            if FileManager.default.fileExists(atPath: modelPath.path) {
                try FileManager.default.removeItem(at: modelPath)
            }
            try FileManager.default.moveItem(at: stagingURL, to: modelPath)
            try? config.expectedSHA256.lowercased().write(
                to: verifiedSidecarPath, atomically: true, encoding: .utf8
            )
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            logger.error("Integrity check failed for \(config.displayName): \(error.localizedDescription)")
            state = .error((error as? OnDeviceLLMModelError)?.errorDescription
                ?? "Model integrity check failed. Please try again.")
            throw error
        }

        state = .available
        logger.info("Model \(config.displayName) verified and downloaded successfully (\(stagedSize / 1_000_000) MB)")
    }

    /// Check an already-downloaded file against the current pin, cheaply when the
    /// verified sidecar matches, with a full hash otherwise.
    /// - Returns: true when the file at `modelPath` is verified. false when it
    ///   failed the pin and was deleted so the caller can re-download.
    private func verifyExistingModelIfNeeded() async throws -> Bool {
        let expected = selectedModel.config.expectedSHA256.lowercased()

        if let recorded = try? String(contentsOf: verifiedSidecarPath, encoding: .utf8),
           recorded.trimmingCharacters(in: .whitespacesAndNewlines) == expected {
            return true
        }

        logger.info("Existing model has no matching verification record; hashing it against the pin")
        state = .verifying
        let actual = try await Self.sha256Hex(ofFileAt: modelPath)
        if actual == expected {
            try? actual.write(to: verifiedSidecarPath, atomically: true, encoding: .utf8)
            return true
        }

        logger.warning("Existing model failed its hash pin (expected \(expected.prefix(12)), got \(actual.prefix(12))); deleting for re-download")
        try? FileManager.default.removeItem(at: modelPath)
        try? FileManager.default.removeItem(at: verifiedSidecarPath)
        state = .notDownloaded
        return false
    }

    /// Cancel ongoing download
    public func cancelDownload() {
        downloadTask?.cancel()

        // take() wins or loses the race with the completion handler atomically;
        // whichever side gets the continuation is the only one that resumes it.
        if let continuation = downloadContinuationBox?.take() {
            continuation.resume(throwing: CancellationError())
        }
        cleanUpDownloadBookkeeping()

        state = .notDownloaded
        logger.info("Download cancelled")
    }

    /// Delete the model to free storage
    public func deleteModel() async throws {
        guard isModelAvailable() else {
            return
        }

        logger.info("Deleting model at \(self.modelPath.path)")

        do {
            try FileManager.default.removeItem(at: modelPath)
            try? FileManager.default.removeItem(at: verifiedSidecarPath)
            try? FileManager.default.removeItem(at: stagingModelPath)
            state = .notDownloaded
            logger.info("Model deleted successfully")
        } catch {
            logger.error("Failed to delete model: \(error.localizedDescription)")
            throw OnDeviceLLMModelError.deleteFailed(error.localizedDescription)
        }
    }

    /// Mark model as loaded (called by OnDeviceLLMService after successful load)
    public func markLoaded() {
        state = .loaded
    }

    /// Mark model as available (called when unloading)
    public func markUnloaded() {
        if isModelAvailable() {
            state = .available
        } else {
            state = .notDownloaded
        }
    }

    // MARK: - Integrity Verification

    /// Bytes hashed per read. Model files reach 3.11 GB, so the file is streamed
    /// through the digest in fixed-size chunks and never held in memory at once.
    static let hashChunkSize = 1 << 20 // 1 MiB

    /// How many chunks to hash between suspension points. 64 chunks is 64 MiB,
    /// roughly tens of milliseconds of work per slice on device.
    static let hashYieldStride = 64

    /// Compute the SHA256 of a file by streaming it in `hashChunkSize` chunks.
    ///
    /// Memory use stays flat at one chunk regardless of file size, which matters
    /// because the largest model is 3.11 GB and loading it whole would blow the
    /// app's memory budget on the very devices that need the on-device path.
    ///
    /// Async with a yield every `hashYieldStride` chunks: hashing 3.11 GB takes
    /// seconds, and an unbroken synchronous loop would hold whatever executor it
    /// runs on (and, when called from the actor, the actor itself) the whole
    /// time. The yields honor the cooperative pool's forward-progress contract
    /// and let other work interleave.
    ///
    /// - Returns: The digest as lowercase hex.
    public static func sha256Hex(ofFileAt url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        var chunksSinceYield = 0
        while true {
            let chunk = try handle.read(upToCount: hashChunkSize)
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            chunksSinceYield += 1
            if chunksSinceYield >= Self.hashYieldStride {
                chunksSinceYield = 0
                await Task.yield()
            }
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Verify a downloaded model file against its expected SHA256.
    ///
    /// On mismatch the file is deleted before throwing, so a corrupted or
    /// substituted GGUF is never left on disk where a later launch could treat its
    /// mere presence as "model available" and hand it to llama.cpp.
    ///
    /// - Throws: `OnDeviceLLMModelError.hashMismatch` if the digest differs,
    ///   `OnDeviceLLMModelError.verificationFailed` if the file cannot be read.
    public static func verifyFile(at url: URL, expectedSHA256: String) async throws {
        let actual: String
        do {
            actual = try await sha256Hex(ofFileAt: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw OnDeviceLLMModelError.verificationFailed(error.localizedDescription)
        }

        let expected = expectedSHA256.lowercased()
        guard actual == expected else {
            try? FileManager.default.removeItem(at: url)
            throw OnDeviceLLMModelError.hashMismatch(expected: expected, actual: actual)
        }
    }

    // MARK: - Private Helpers

    private func checkModelAvailability() {
        // A staged file left behind by an app death mid-verification is not a
        // model; delete the straggler so it cannot linger and confuse storage
        // accounting. Never verified means never trusted.
        if FileManager.default.fileExists(atPath: stagingModelPath.path), downloadTask == nil {
            logger.warning("Removing stale unverified staging file from an interrupted download")
            try? FileManager.default.removeItem(at: stagingModelPath)
        }

        // Route through refreshStateFromFilesystem so this init-time probe never
        // clobbers a transient/runtime state (.loaded, .loading, .downloading).
        // Setting state directly here raced with markLoaded() and reset a
        // loaded-in-memory model back to .available/.notDownloaded.
        refreshStateFromFilesystem()
        logger.info("Model availability checked; state=\(String(describing: self.state))")
    }

    private func updateDownloadProgress(_ progress: Float) {
        // KVO progress ticks are delivered through detached Tasks that can land
        // after the download finished; a late tick must not overwrite a terminal
        // state (.verifying, .available, .error) with .downloading.
        guard case .downloading = state else { return }
        state = .downloading(progress)
    }
}

// MARK: - Model Error

/// Errors for on-device LLM model operations
public enum OnDeviceLLMModelError: Error, LocalizedError {
    case modelNotDownloaded
    case downloadFailed(String)
    case deleteFailed(String)
    case insufficientStorage
    case insufficientRAM
    case networkUnavailable
    /// The downloaded file did not hash to the expected SHA256. The file has been deleted.
    case hashMismatch(expected: String, actual: String)
    /// The downloaded file could not be read to compute its hash. The file has been deleted.
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotDownloaded:
            return "The on-device LLM model is not downloaded. Download it in Settings to enable this feature."
        case .downloadFailed(let reason):
            return "Failed to download model: \(reason)"
        case .deleteFailed(let reason):
            return "Failed to delete model: \(reason)"
        case .insufficientStorage:
            return "Not enough storage space. The model requires approximately 2.2 GB of free space."
        case .insufficientRAM:
            return "This device does not have enough RAM to run the on-device LLM. A minimum of 4 GB is required."
        case .networkUnavailable:
            return "Network connection is required to download the model."
        case .hashMismatch(let expected, let actual):
            return "Model integrity check failed. The download was corrupted or tampered with and has been deleted. Please try again. (expected \(expected.prefix(12)), got \(actual.prefix(12)))"
        case .verificationFailed(let reason):
            return "Could not verify the downloaded model, so it was deleted. Please try again. (\(reason))"
        }
    }
}

// MARK: - Model Info

/// Static information about the on-device LLM model.
///
/// Display fields derive from the canonical model's config so the settings UI can
/// never drift from the model the app actually downloads and runs. Keep `canonical`
/// in sync with `OnDeviceLLMModelManager.selectedModel`.
public enum OnDeviceLLMModelInfo {
    /// The model the app downloads and runs on THIS device (the device-appropriate,
    /// runnable tier). Derives everything below so the settings UI can never drift
    /// from the model that is actually used, including after the Gemma 4 upgrade.
    public static var canonical: OnDeviceLLMModel {
        OnDeviceLLMModel.bestRunnableForDevice() ?? .qwen3_1_7B
    }

    public static var displayName: String { canonical.config.displayName }
    public static var quantization: String { canonical.config.quantization }
    public static var totalSizeMB: Float { Float(canonical.config.expectedSizeBytes) / 1_000_000 }
    public static var contextSize: UInt32 { UInt32(canonical.config.contextSize) }
    public static var minimumRAMGB: Int { canonical.config.minimumRAMGB }
    public static let minimumIOSVersion = "16.0"
    public static let license = "Apache 2.0"

    public static var version: String {
        switch canonical {
        case .gemma4_e2b: return "April 2026"
        case .qwen3_1_7B, .qwen3_0_6B: return "May 2025"
        case .ministral3_3B: return "December 2025"
        }
    }

    public static var publisher: String {
        switch canonical {
        case .gemma4_e2b: return "Google"
        case .qwen3_1_7B, .qwen3_0_6B: return "Alibaba (Qwen)"
        case .ministral3_3B: return "Mistral AI"
        }
    }

    /// Approximate download size, derived so UI copy never drifts from the model.
    public static var downloadSizeText: String {
        String(format: "~%.1f GB", Double(canonical.config.expectedSizeBytes) / 1_000_000_000)
    }

    /// Why users should keep the model
    public static let keepModelReasons = [
        "Enables fully offline AI features for learning modules",
        "No internet connection required for tutoring sessions",
        "Your data stays private and never leaves your device",
        "No API costs for on-device processing",
        "Faster response times compared to cloud services"
    ]

    /// What happens if deleted
    public static let deletionConsequences = [
        "Learning modules will fall back to simpler validation methods",
        "Complex answers requiring judgment may not be validated correctly",
        "Some curriculum features may require an internet connection",
        "You can re-download the model anytime"
    ]
}

// MARK: - State Observer

/// Observable wrapper for model state (for SwiftUI)
@MainActor
public final class OnDeviceLLMModelStateObserver: ObservableObject {
    @Published public var state: OnDeviceLLMModelManager.ModelState = .notDownloaded
    @Published public var downloadProgress: Float = 0.0

    private let manager: OnDeviceLLMModelManager

    public init(manager: OnDeviceLLMModelManager) {
        self.manager = manager
        Task {
            await refreshState()
        }
    }

    public func refreshState() async {
        state = await manager.currentState()
        if case .downloading(let progress) = state {
            downloadProgress = progress
        }
    }

    public func downloadModel() async throws {
        try await manager.downloadModel()
        await refreshState()
    }

    public func cancelDownload() async {
        await manager.cancelDownload()
        await refreshState()
    }

    public func deleteModel() async throws {
        try await manager.deleteModel()
        await refreshState()
    }

    public var isModelAvailable: Bool {
        get async { await manager.isModelAvailable() }
    }

    public var modelSizeMB: Int {
        get async { await manager.modelSizeMB() }
    }

    public var modelPath: String {
        get async { await manager.modelPathString }
    }
}

// MARK: - Preview Support

#if DEBUG
extension OnDeviceLLMModelManager {
    public static func preview() -> OnDeviceLLMModelManager {
        OnDeviceLLMModelManager()
    }
}
#endif
