// UnaMentis - ServerConfigManager actor logic tests
// Exercises the real ServerConfigManager actor: add / update / remove, type and
// health filtering, discovered-model/voice aggregation, and best-endpoint URL
// resolution. No network is required for any of these paths.
//
// TESTING PHILOSOPHY (Real Over Mock):
// ServerConfigManager is an internal actor, so we use the real singleton. It
// persists to UserDefaults under "voicelearn.server.configs"; we snapshot and
// restore that key, and remove every server we add, so the suite is
// non-destructive to a developer's saved configuration.

import XCTest
@testable import UnaMentis

/// Tests for the in-memory server registry logic of ServerConfigManager.
final class ServerConfigManagerTests: XCTestCase {

    private let manager = ServerConfigManager.shared
    private let storageKey = "voicelearn.server.configs"

    private var savedStorage: Data?
    /// IDs we created during a test so tearDown can remove exactly those.
    private var createdIDs: [UUID] = []

    override func setUp() async throws {
        try await super.setUp()
        savedStorage = UserDefaults.standard.data(forKey: storageKey)
        createdIDs = []
        // Stop the periodic health monitor so it cannot flip the health status of
        // our (deliberately unreachable) test servers out from under assertions.
        // addServer still spawns a one-shot health check, but that check blocks on
        // a multi-second network timeout against unreachable hosts, so the explicit
        // status we set with updateServer immediately before each read wins.
        await manager.stopHealthMonitoring()
    }

    override func tearDown() async throws {
        for id in createdIDs {
            await manager.removeServer(id)
        }
        // Restore the original persisted blob so any pre-existing servers survive
        // the next load. (The actor's in-memory state already excludes the ones we
        // removed above.)
        if let savedStorage {
            UserDefaults.standard.set(savedStorage, forKey: storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
        try await super.tearDown()
    }

    /// Build and register a server, tracking its ID for cleanup.
    @discardableResult
    private func register(
        name: String,
        host: String = "127.0.0.1",
        port: Int = 11400,
        isEnabled: Bool = true,
        healthStatus: ServerHealthStatus = .healthy,
        serverType: ServerType = .unamentisGateway,
        discoveredModels: [String] = [],
        discoveredVoices: [String] = []
    ) async -> ServerConfig {
        let config = ServerConfig(
            name: name,
            host: host,
            port: port,
            isEnabled: isEnabled,
            healthStatus: healthStatus,
            serverType: serverType,
            discoveredModels: discoveredModels,
            discoveredVoices: discoveredVoices
        )
        createdIDs.append(config.id)
        _ = await manager.addServer(config)
        // addServer spawns a one-shot health check that briefly sets .checking.
        // Re-assert the intended status as the last write so reads are deterministic.
        await manager.updateServer(config)
        return config
    }

    // MARK: - CRUD

    func testAddServerIsRetrievableByID() async {
        let added = await register(name: "Add Test")

        let fetched = await manager.getServer(added.id)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.name, "Add Test")
    }

    func testUpdateServerReplacesStoredConfig() async {
        var added = await register(name: "Original", healthStatus: .healthy)
        added.name = "Renamed"
        added.healthStatus = .degraded

        await manager.updateServer(added)

        let fetched = await manager.getServer(added.id)
        XCTAssertEqual(fetched?.name, "Renamed")
        XCTAssertEqual(fetched?.healthStatus, .degraded)
    }

    func testRemoveServerDeletesIt() async {
        let added = await register(name: "Removable")
        await manager.removeServer(added.id)
        // Already removed; drop from cleanup list to avoid a redundant call.
        createdIDs.removeAll { $0 == added.id }

        let fetched = await manager.getServer(added.id)
        XCTAssertNil(fetched)
    }

    func testGetAllServersSortedByName() async {
        let suffix = UUID().uuidString.prefix(8)
        await register(name: "zzz-\(suffix)")
        await register(name: "aaa-\(suffix)")
        await register(name: "mmm-\(suffix)")

        let all = await manager.getAllServers()
        let ours = all.filter { $0.name.hasSuffix(String(suffix)) }
        XCTAssertEqual(ours.map(\.name), ["aaa-\(suffix)", "mmm-\(suffix)", "zzz-\(suffix)"])
    }

    // MARK: - Type filtering

    func testGetServersOfTypeReturnsOnlyMatchingType() async {
        let ollama = await register(name: "Ollama Node", port: 11434, serverType: .ollama)
        await register(name: "Whisper Node", port: 11401, serverType: .whisperServer)

        let ollamaServers = await manager.getServers(ofType: .ollama)
        XCTAssertTrue(ollamaServers.contains { $0.id == ollama.id })
        XCTAssertFalse(ollamaServers.contains { $0.serverType == .whisperServer })
    }

    // MARK: - Health filtering

    func testHealthyLLMServersExcludeDisabledAndUnhealthy() async {
        let good = await register(name: "Good LLM", port: 11434, serverType: .ollama)
        await register(name: "Disabled LLM", port: 11435, isEnabled: false, serverType: .ollama)
        await register(name: "Unhealthy LLM", port: 11436, healthStatus: .unhealthy, serverType: .ollama)

        let llmServers = await manager.getHealthyLLMServers()
        XCTAssertTrue(llmServers.contains { $0.id == good.id })
        XCTAssertFalse(llmServers.contains { $0.name == "Disabled LLM" })
        XCTAssertFalse(llmServers.contains { $0.name == "Unhealthy LLM" })
    }

    func testHealthyLLMServersExcludeTTSOnlyTypes() async {
        await register(name: "Piper Only", port: 11402, serverType: .piperServer)

        let llmServers = await manager.getHealthyLLMServers()
        XCTAssertFalse(llmServers.contains { $0.name == "Piper Only" },
                       "a Piper TTS server must not be classified as an LLM server")
    }

    func testHealthySTTServersIncludeWhisperAndGateway() async {
        let whisper = await register(name: "Whisper", port: 11401, serverType: .whisperServer)
        let gateway = await register(name: "Gateway STT", port: 11400, serverType: .unamentisGateway)

        let sttServers = await manager.getHealthySTTServers()
        XCTAssertTrue(sttServers.contains { $0.id == whisper.id })
        XCTAssertTrue(sttServers.contains { $0.id == gateway.id })
    }

    func testHealthyTTSServersIncludeAllTTSEngineTypes() async {
        let piper = await register(name: "Piper", port: 11402, serverType: .piperServer)
        let vibe = await register(name: "VibeVoice", port: 8880, serverType: .vibeVoiceServer)
        let chatter = await register(name: "Chatterbox", port: 8004, serverType: .chatterboxServer)

        let ttsServers = await manager.getHealthyTTSServers()
        XCTAssertTrue(ttsServers.contains { $0.id == piper.id })
        XCTAssertTrue(ttsServers.contains { $0.id == vibe.id })
        XCTAssertTrue(ttsServers.contains { $0.id == chatter.id })
    }

    func testHealthyChatterboxServersFilterToChatterboxOnly() async {
        let chatter = await register(name: "Chatterbox", port: 8004, serverType: .chatterboxServer)
        await register(name: "Piper", port: 11402, serverType: .piperServer)

        let chatterServers = await manager.getHealthyChatterboxServers()
        XCTAssertTrue(chatterServers.contains { $0.id == chatter.id })
        XCTAssertTrue(chatterServers.allSatisfy { $0.serverType == .chatterboxServer })
    }

    // MARK: - Discovered model / voice aggregation

    func testDiscoveredModelsAggregateUniqueSortedAcrossHealthyServers() async {
        let suffix = UUID().uuidString.prefix(6)
        await register(
            name: "M1",
            port: 11434,
            serverType: .ollama,
            discoveredModels: ["z-\(suffix)", "a-\(suffix)"]
        )
        await register(
            name: "M2",
            port: 11435,
            serverType: .ollama,
            discoveredModels: ["a-\(suffix)", "m-\(suffix)"]
        )
        // An unhealthy server's models must be ignored.
        await register(
            name: "M3-unhealthy",
            port: 11436,
            healthStatus: .unhealthy,
            serverType: .ollama,
            discoveredModels: ["ignored-\(suffix)"]
        )

        let models = await manager.getAllDiscoveredModels()
        let ours = models.filter { $0.hasSuffix(String(suffix)) }
        XCTAssertEqual(ours, ["a-\(suffix)", "m-\(suffix)", "z-\(suffix)"],
                       "models must be unique, sorted, and exclude unhealthy servers")
    }

    func testDiscoveredVoicesAggregateUniqueSortedAcrossHealthyServers() async {
        let suffix = UUID().uuidString.prefix(6)
        await register(
            name: "V1",
            port: 11402,
            serverType: .piperServer,
            discoveredVoices: ["nova-\(suffix)", "alpha-\(suffix)"]
        )
        await register(
            name: "V2",
            port: 11403,
            serverType: .piperServer,
            discoveredVoices: ["alpha-\(suffix)"]
        )

        let voices = await manager.getAllDiscoveredVoices()
        let ours = voices.filter { $0.hasSuffix(String(suffix)) }
        XCTAssertEqual(ours, ["alpha-\(suffix)", "nova-\(suffix)"])
    }

    // MARK: - Best-endpoint resolution

    func testBestLLMEndpointUsesChatCompletionsForGateway() async {
        await register(name: "Gateway LLM", host: "10.0.0.5", port: 11400, serverType: .unamentisGateway)

        let endpoint = await manager.getBestLLMEndpoint()
        XCTAssertEqual(endpoint?.absoluteString, "http://10.0.0.5:11400/v1/chat/completions")
    }

    func testBestSTTEndpointAppendsTranscriptionsPath() async {
        await register(name: "STT", host: "10.0.0.6", port: 11401, serverType: .whisperServer)

        let endpoint = await manager.getBestSTTEndpoint()
        XCTAssertEqual(endpoint?.absoluteString, "http://10.0.0.6:11401/v1/audio/transcriptions")
    }

    func testBestTTSEndpointAppendsSpeechPath() async {
        await register(name: "TTS", host: "10.0.0.7", port: 11402, serverType: .piperServer)

        let endpoint = await manager.getBestTTSEndpoint()
        XCTAssertEqual(endpoint?.absoluteString, "http://10.0.0.7:11402/v1/audio/speech")
    }

    func testHasAvailableServerReflectsHealthyLLMPresence() async {
        let added = await register(name: "Healthy LLM", port: 11434, serverType: .ollama)
        let available = await manager.hasAvailableServer
        XCTAssertTrue(available, "a healthy LLM server should make hasAvailableServer true")

        // Removing it should not crash; we cannot assert false because other tests
        // or pre-existing config may also contribute, so we only assert the positive.
        await manager.removeServer(added.id)
        createdIDs.removeAll { $0 == added.id }
    }
}
