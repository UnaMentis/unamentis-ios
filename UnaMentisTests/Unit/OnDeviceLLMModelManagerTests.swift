//
//  OnDeviceLLMModelManagerTests.swift
//  UnaMentisTests
//
//  Unit tests for OnDeviceLLMModelManager
//

import XCTest
@testable import UnaMentis

/// Unit tests for OnDeviceLLMModelManager
///
/// Tests model configuration, state management, and file operations.
/// Note: Network download tests are skipped in CI to avoid hitting Hugging Face CDN.
final class OnDeviceLLMModelManagerTests: XCTestCase {

    // MARK: - Model Configuration Tests

    func testModelConfigHasCorrectValues() {
        let config = OnDeviceLLMModel.ministral3_3B.config

        XCTAssertEqual(config.id, "ministral-3-3b-instruct-2512")
        XCTAssertEqual(config.displayName, "Ministral 3 3B")
        XCTAssertEqual(config.huggingFaceRepo, "mistralai/Ministral-3-3B-Instruct-2512-GGUF")
        XCTAssertEqual(config.filename, "Ministral-3-3B-Instruct-2512-Q4_K_M.gguf")
        XCTAssertEqual(config.quantization, "Q4_K_M")
        XCTAssertEqual(config.contextSize, 4096)
        XCTAssertEqual(config.minimumRAMGB, 8)
        XCTAssertGreaterThan(config.expectedSizeBytes, 2_000_000_000) // > 2GB
    }

    func testModelConfigDownloadURL() {
        let config = OnDeviceLLMModel.ministral3_3B.config
        let expectedURL = "https://huggingface.co/mistralai/Ministral-3-3B-Instruct-2512-GGUF/resolve/main/Ministral-3-3B-Instruct-2512-Q4_K_M.gguf"

        XCTAssertEqual(config.downloadURL.absoluteString, expectedURL)
    }

    func testModelConfigExpectedSizeMB() {
        let config = OnDeviceLLMModel.ministral3_3B.config

        // ~2.15 GB = ~2150 MB
        XCTAssertEqual(config.expectedSizeMB, 2150)
    }

    // MARK: - Model State Tests

    func testModelStateEquality() {
        // Same states should be equal
        XCTAssertEqual(OnDeviceLLMModelManager.ModelState.notDownloaded, .notDownloaded)
        XCTAssertEqual(OnDeviceLLMModelManager.ModelState.available, .available)
        XCTAssertEqual(OnDeviceLLMModelManager.ModelState.loaded, .loaded)
        XCTAssertEqual(OnDeviceLLMModelManager.ModelState.verifying, .verifying)

        // Progress states with same progress
        XCTAssertEqual(
            OnDeviceLLMModelManager.ModelState.downloading(0.5),
            .downloading(0.5)
        )
        XCTAssertEqual(
            OnDeviceLLMModelManager.ModelState.loading(0.75),
            .loading(0.75)
        )

        // Progress states with similar progress (within tolerance)
        XCTAssertEqual(
            OnDeviceLLMModelManager.ModelState.downloading(0.501),
            .downloading(0.505)
        )

        // Error states with same message
        XCTAssertEqual(
            OnDeviceLLMModelManager.ModelState.error("test error"),
            .error("test error")
        )
    }

    func testModelStateInequality() {
        // Different states should not be equal
        XCTAssertNotEqual(
            OnDeviceLLMModelManager.ModelState.notDownloaded,
            .available
        )
        XCTAssertNotEqual(
            OnDeviceLLMModelManager.ModelState.downloading(0.5),
            .downloading(0.8)
        )
        XCTAssertNotEqual(
            OnDeviceLLMModelManager.ModelState.error("error1"),
            .error("error2")
        )
    }

    func testModelStateIsReady() {
        XCTAssertTrue(OnDeviceLLMModelManager.ModelState.loaded.isReady)
        XCTAssertFalse(OnDeviceLLMModelManager.ModelState.available.isReady)
        XCTAssertFalse(OnDeviceLLMModelManager.ModelState.notDownloaded.isReady)
        XCTAssertFalse(OnDeviceLLMModelManager.ModelState.downloading(0.5).isReady)
    }

    func testModelStateIsAvailable() {
        XCTAssertTrue(OnDeviceLLMModelManager.ModelState.available.isAvailable)
        XCTAssertTrue(OnDeviceLLMModelManager.ModelState.loaded.isAvailable)
        XCTAssertFalse(OnDeviceLLMModelManager.ModelState.notDownloaded.isAvailable)
        XCTAssertFalse(OnDeviceLLMModelManager.ModelState.downloading(0.5).isAvailable)
    }

    func testModelStateDisplayText() {
        XCTAssertEqual(
            OnDeviceLLMModelManager.ModelState.notDownloaded.displayText,
            "Not Downloaded"
        )
        XCTAssertEqual(
            OnDeviceLLMModelManager.ModelState.downloading(0.5).displayText,
            "Downloading 50%"
        )
        XCTAssertEqual(
            OnDeviceLLMModelManager.ModelState.verifying.displayText,
            "Verifying..."
        )
        XCTAssertEqual(
            OnDeviceLLMModelManager.ModelState.available.displayText,
            "Ready to Load"
        )
        XCTAssertEqual(
            OnDeviceLLMModelManager.ModelState.loading(0.25).displayText,
            "Loading 25%"
        )
        XCTAssertEqual(
            OnDeviceLLMModelManager.ModelState.loaded.displayText,
            "Loaded"
        )
        XCTAssertTrue(
            OnDeviceLLMModelManager.ModelState.error("Network error").displayText.contains("Network error")
        )
    }

    // MARK: - Model Info Tests

    func testModelInfoDerivesFromRunnableModel() {
        // The settings info derives from the device's runnable model so the UI can
        // never drift from what is downloaded/run. It must never surface the
        // deprecated Ministral. The exact model depends on the host's RAM tier, so
        // assert the derivation and the decided constraints, not a fixed model.
        let canonical = OnDeviceLLMModelInfo.canonical
        XCTAssertNotEqual(canonical, .ministral3_3B, "Ministral is deprecated, never the canonical model")
        XCTAssertTrue(canonical.runsOnBundledRuntime, "canonical must load on the bundled llama.cpp")
        XCTAssertEqual(canonical, OnDeviceLLMModel.bestRunnableForDevice())

        // Every displayed field derives from the canonical model's config.
        XCTAssertEqual(OnDeviceLLMModelInfo.displayName, canonical.config.displayName)
        XCTAssertEqual(OnDeviceLLMModelInfo.quantization, canonical.config.quantization)
        XCTAssertEqual(OnDeviceLLMModelInfo.totalSizeMB, Float(canonical.config.expectedSizeBytes) / 1_000_000)
        XCTAssertEqual(OnDeviceLLMModelInfo.contextSize, UInt32(canonical.config.contextSize))
        XCTAssertEqual(OnDeviceLLMModelInfo.minimumRAMGB, canonical.config.minimumRAMGB)
        XCTAssertEqual(OnDeviceLLMModelInfo.license, "Apache 2.0")
    }

    func testBestRunnableForDevicePerRAMTier() {
        // With the gemma4-capable llama.cpp (b9821), Gemma 4 E2B is runnable and is
        // the 12 GB pick; Qwen3-1.7B is the 8 GB pick; Qwen3-0.6B the 6 GB pick.
        // Ministral is deprecated and excluded from the runnable ladder.
        XCTAssertTrue(OnDeviceLLMModel.gemma4_e2b.runsOnBundledRuntime)
        XCTAssertEqual(OnDeviceLLMModel.bestRunnableForDevice(physicalMemoryGB: 12), .gemma4_e2b)
        XCTAssertEqual(OnDeviceLLMModel.bestRunnableForDevice(physicalMemoryGB: 8), .qwen3_1_7B)
        XCTAssertEqual(OnDeviceLLMModel.bestRunnableForDevice(physicalMemoryGB: 6), .qwen3_0_6B)
        XCTAssertNotEqual(OnDeviceLLMModel.bestRunnableForDevice(physicalMemoryGB: 12), .ministral3_3B)
    }

    func testModelInfoKeepReasons() {
        XCTAssertFalse(OnDeviceLLMModelInfo.keepModelReasons.isEmpty)
        XCTAssertGreaterThanOrEqual(OnDeviceLLMModelInfo.keepModelReasons.count, 3)

        // Should mention offline capability
        let hasOfflineReason = OnDeviceLLMModelInfo.keepModelReasons.contains {
            $0.lowercased().contains("offline")
        }
        XCTAssertTrue(hasOfflineReason, "Should mention offline capability")

        // Should mention privacy
        let hasPrivacyReason = OnDeviceLLMModelInfo.keepModelReasons.contains {
            $0.lowercased().contains("private") || $0.lowercased().contains("privacy")
        }
        XCTAssertTrue(hasPrivacyReason, "Should mention privacy")
    }

    func testModelInfoDeletionConsequences() {
        XCTAssertFalse(OnDeviceLLMModelInfo.deletionConsequences.isEmpty)
        XCTAssertGreaterThanOrEqual(OnDeviceLLMModelInfo.deletionConsequences.count, 3)

        // Should mention re-download option
        let hasRedownloadInfo = OnDeviceLLMModelInfo.deletionConsequences.contains {
            $0.lowercased().contains("re-download") || $0.lowercased().contains("download")
        }
        XCTAssertTrue(hasRedownloadInfo, "Should mention re-download option")
    }

    // MARK: - Model Error Tests

    func testModelErrorDescriptions() {
        XCTAssertNotNil(OnDeviceLLMModelError.modelNotDownloaded.errorDescription)
        XCTAssertTrue(
            OnDeviceLLMModelError.modelNotDownloaded.errorDescription!.contains("not downloaded")
        )

        XCTAssertNotNil(OnDeviceLLMModelError.downloadFailed("test").errorDescription)
        XCTAssertTrue(
            OnDeviceLLMModelError.downloadFailed("network").errorDescription!.contains("network")
        )

        XCTAssertNotNil(OnDeviceLLMModelError.deleteFailed("permission").errorDescription)
        XCTAssertTrue(
            OnDeviceLLMModelError.deleteFailed("permission").errorDescription!.contains("permission")
        )

        XCTAssertNotNil(OnDeviceLLMModelError.insufficientStorage.errorDescription)
        XCTAssertTrue(
            OnDeviceLLMModelError.insufficientStorage.errorDescription!.contains("storage")
        )

        XCTAssertNotNil(OnDeviceLLMModelError.insufficientRAM.errorDescription)
        XCTAssertTrue(
            OnDeviceLLMModelError.insufficientRAM.errorDescription!.contains("RAM")
        )

        XCTAssertNotNil(OnDeviceLLMModelError.networkUnavailable.errorDescription)
        XCTAssertTrue(
            OnDeviceLLMModelError.networkUnavailable.errorDescription!.contains("Network")
        )
    }

    // MARK: - Manager Tests

    func testManagerInitialState() async {
        let manager = OnDeviceLLMModelManager()

        // Give it time to check model availability
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        let state = await manager.currentState()

        // Should be notDownloaded since model isn't bundled in tests
        // or available if model was previously downloaded
        XCTAssertTrue(
            state == .notDownloaded || state == .available,
            "Initial state should be notDownloaded or available"
        )
    }

    func testManagerModelPath() async {
        let manager = OnDeviceLLMModelManager()
        let path = await manager.modelPath
        let expectedFile = (OnDeviceLLMModel.bestRunnableForDevice() ?? .qwen3_0_6B).config.filename

        XCTAssertTrue(path.path.contains("models/LLM"))
        XCTAssertTrue(path.path.contains(expectedFile), "modelPath should point to the device's runnable model file")
        XCTAssertFalse(path.path.contains("Ministral"), "Ministral is deprecated")
    }

    func testManagerModelPathString() async {
        let manager = OnDeviceLLMModelManager()
        let pathString = await manager.modelPathString
        let expectedFile = (OnDeviceLLMModel.bestRunnableForDevice() ?? .qwen3_0_6B).config.filename

        XCTAssertTrue(pathString.contains("models/LLM"))
        XCTAssertTrue(pathString.contains(expectedFile), "modelPathString should point to the device's runnable model file")
    }

    func testManagerSelectedModelIsTheDeviceRunnableModel() async {
        let manager = OnDeviceLLMModelManager()
        let selectedModel = await manager.selectedModel

        // The manager downloads/loads the device-appropriate, runnable model, never
        // the deprecated Ministral and never a model the bundled llama.cpp cannot run.
        XCTAssertEqual(selectedModel, OnDeviceLLMModel.bestRunnableForDevice() ?? .qwen3_0_6B)
        XCTAssertNotEqual(selectedModel, .ministral3_3B)
        XCTAssertTrue(selectedModel.runsOnBundledRuntime)
    }

    func testManagerMarkLoadedAndUnloaded() async {
        let manager = OnDeviceLLMModelManager()

        // Mark as loaded
        await manager.markLoaded()
        var state = await manager.currentState()
        XCTAssertEqual(state, .loaded)

        // Mark as unloaded
        await manager.markUnloaded()
        state = await manager.currentState()
        // Should be available or notDownloaded depending on file existence
        XCTAssertTrue(
            state == .available || state == .notDownloaded,
            "After unload, state should be available or notDownloaded"
        )
    }

    func testManagerCancelDownload() async {
        let manager = OnDeviceLLMModelManager()

        // Cancel when not downloading should be safe
        await manager.cancelDownload()

        let state = await manager.currentState()
        XCTAssertEqual(state, .notDownloaded)
    }

    // MARK: - State Observer Tests

    @MainActor
    func testStateObserverInitialization() async {
        let manager = OnDeviceLLMModelManager()
        let observer = OnDeviceLLMModelStateObserver(manager: manager)

        // Give it time to refresh
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms

        // State should be synced with manager
        let managerState = await manager.currentState()

        // Compare states
        XCTAssertEqual(observer.state, managerState)
    }

    @MainActor
    func testStateObserverRefresh() async {
        let manager = OnDeviceLLMModelManager()
        let observer = OnDeviceLLMModelStateObserver(manager: manager)

        await observer.refreshState()

        let managerState = await manager.currentState()
        XCTAssertEqual(observer.state, managerState)
    }

    // MARK: - All Models Enumeration

    func testAllModelsAvailable() {
        let allModels = OnDeviceLLMModel.allCases

        XCTAssertEqual(allModels.count, 4, "Tiered ladder: Gemma 4 E2B, Qwen3-1.7B, Qwen3-0.6B, Ministral")
        XCTAssertTrue(allModels.contains(.gemma4_e2b))
        XCTAssertTrue(allModels.contains(.qwen3_1_7B))
        XCTAssertTrue(allModels.contains(.qwen3_0_6B))
        XCTAssertTrue(allModels.contains(.ministral3_3B))
    }

    func testRecommendedForDeviceTiering() {
        // RAM-gated capability ceiling: showcase on 12GB, fallbacks below.
        XCTAssertEqual(OnDeviceLLMModel.recommendedForDevice(physicalMemoryGB: 16), .gemma4_e2b)
        XCTAssertEqual(OnDeviceLLMModel.recommendedForDevice(physicalMemoryGB: 12), .gemma4_e2b)
        XCTAssertEqual(OnDeviceLLMModel.recommendedForDevice(physicalMemoryGB: 8), .qwen3_1_7B)
        XCTAssertEqual(OnDeviceLLMModel.recommendedForDevice(physicalMemoryGB: 6), .qwen3_0_6B)
        XCTAssertNil(OnDeviceLLMModel.recommendedForDevice(physicalMemoryGB: 4))
    }

    func testModelRawValues() {
        XCTAssertEqual(OnDeviceLLMModel.ministral3_3B.rawValue, "ministral-3-3b")
    }
}
