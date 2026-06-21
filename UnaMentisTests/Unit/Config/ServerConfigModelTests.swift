// UnaMentis - ServerConfig value-type and capability tests
// Covers the pure, deterministic logic in ServerConfigManager.swift: ServerConfig
// URL building, Codable round-trip, ServerType / ServerHealthStatus metadata,
// DiscoveredService decoding, and ServerCapabilities / ChatterboxServerInfo /
// ManagementModelInfo derived properties.

import XCTest
@testable import UnaMentis

/// Tests for the configuration value types backing ServerConfigManager.
final class ServerConfigModelTests: XCTestCase {

    // MARK: - ServerConfig URLs

    func testBaseURLComposesHostAndPort() {
        let config = ServerConfig(name: "Test", host: "192.168.1.10", port: 11400)
        XCTAssertEqual(config.baseURL?.absoluteString, "http://192.168.1.10:11400")
    }

    func testHealthURLAppendsHealthPath() {
        let config = ServerConfig(name: "Test", host: "localhost", port: 8080)
        XCTAssertEqual(config.healthURL?.absoluteString, "http://localhost:8080/health")
    }

    func testDiscoveryURLEqualsBaseURL() {
        let config = ServerConfig(name: "Test", host: "localhost", port: 11400)
        XCTAssertEqual(config.discoveryURL, config.baseURL)
    }

    func testDefaultInitializerValues() {
        let config = ServerConfig(name: "Defaults", host: "h", port: 1)
        XCTAssertTrue(config.isEnabled)
        XCTAssertNil(config.lastHealthCheck)
        XCTAssertEqual(config.healthStatus, .unknown)
        XCTAssertEqual(config.serverType, .unamentisGateway)
        XCTAssertTrue(config.discoveredServices.isEmpty)
        XCTAssertTrue(config.discoveredModels.isEmpty)
        XCTAssertTrue(config.discoveredVoices.isEmpty)
    }

    func testCodableRoundTripPreservesFields() throws {
        let original = ServerConfig(
            id: UUID(),
            name: "Round Trip",
            host: "example.local",
            port: 9000,
            isEnabled: false,
            healthStatus: .degraded,
            serverType: .ollama,
            discoveredServices: [DiscoveredService(type: .llm, url: "http://x/v1", model: "qwen")],
            discoveredModels: ["qwen2.5:7b"],
            discoveredVoices: ["nova"]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ServerConfig.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.host, original.host)
        XCTAssertEqual(decoded.port, original.port)
        XCTAssertEqual(decoded.isEnabled, original.isEnabled)
        XCTAssertEqual(decoded.healthStatus, original.healthStatus)
        XCTAssertEqual(decoded.serverType, original.serverType)
        XCTAssertEqual(decoded.discoveredModels, original.discoveredModels)
        XCTAssertEqual(decoded.discoveredVoices, original.discoveredVoices)
        XCTAssertEqual(decoded.discoveredServices.first?.type, .llm)
        XCTAssertEqual(decoded.discoveredServices.first?.model, "qwen")
    }

    // MARK: - ServerType

    func testServerTypeRawValuesMatchWireFormat() {
        XCTAssertEqual(ServerType.unamentisGateway.rawValue, "unamentis")
        XCTAssertEqual(ServerType.ollama.rawValue, "ollama")
        XCTAssertEqual(ServerType.llamaCpp.rawValue, "llama.cpp")
        XCTAssertEqual(ServerType.vllm.rawValue, "vllm")
    }

    func testServerTypeDefaultPortsAreDistinctPerType() {
        XCTAssertEqual(ServerType.unamentisGateway.defaultPort, 11400)
        XCTAssertEqual(ServerType.ollama.defaultPort, 11434)
        XCTAssertEqual(ServerType.whisperServer.defaultPort, 11401)
        XCTAssertEqual(ServerType.piperServer.defaultPort, 11402)
        XCTAssertEqual(ServerType.vibeVoiceServer.defaultPort, 8880)
        XCTAssertEqual(ServerType.chatterboxServer.defaultPort, 8004)
        XCTAssertEqual(ServerType.llamaCpp.defaultPort, 8080)
        XCTAssertEqual(ServerType.vllm.defaultPort, 8000)
        XCTAssertEqual(ServerType.custom.defaultPort, 8080)
    }

    func testOnlyGatewaySupportsDiscovery() {
        for type in ServerType.allCases {
            XCTAssertEqual(type.supportsDiscovery, type == .unamentisGateway,
                           "\(type) discovery support should be gateway-only")
        }
    }

    func testEveryServerTypeHasNonEmptyDisplayName() {
        for type in ServerType.allCases {
            XCTAssertFalse(type.displayName.isEmpty, "\(type) needs a display name")
        }
    }

    // MARK: - ServerHealthStatus

    func testHealthStatusUsability() {
        XCTAssertTrue(ServerHealthStatus.healthy.isUsable)
        XCTAssertTrue(ServerHealthStatus.degraded.isUsable)
        XCTAssertFalse(ServerHealthStatus.unhealthy.isUsable)
        XCTAssertFalse(ServerHealthStatus.unknown.isUsable)
        XCTAssertFalse(ServerHealthStatus.checking.isUsable)
    }

    func testHealthStatusHasDisplayNameAndIcon() {
        for status in [ServerHealthStatus.unknown, .checking, .healthy, .degraded, .unhealthy] {
            XCTAssertFalse(status.displayName.isEmpty)
            XCTAssertFalse(status.icon.isEmpty)
        }
    }

    // MARK: - DiscoveredService

    func testDiscoveredServiceServiceTypeDecodes() throws {
        let json = """
        { "type": "tts", "url": "http://h/v1/audio/speech", "model": "aura-2" }
        """.data(using: .utf8)!

        let service = try JSONDecoder().decode(DiscoveredService.self, from: json)
        XCTAssertEqual(service.type, .tts)
        XCTAssertEqual(service.url, "http://h/v1/audio/speech")
        XCTAssertEqual(service.model, "aura-2")
    }

    // MARK: - ServerCapabilities

    func testServerCapabilitiesTtsVoicesCombinesPiperAndVibeVoice() {
        let caps = ServerCapabilities(
            llmModels: ["qwen2.5:7b"],
            piperVoices: ["alpha", "beta"],
            vibeVoiceVoices: ["gamma"],
            chatterboxInfo: nil,
            hasOllama: true,
            hasPiperTTS: true,
            hasVibeVoiceTTS: true,
            hasChatterboxTTS: false
        )

        XCTAssertEqual(caps.ttsVoices, ["alpha", "beta", "gamma"])
        XCTAssertFalse(caps.isEmpty)
    }

    func testServerCapabilitiesIsEmptyWhenNothingDiscovered() {
        let caps = ServerCapabilities(
            llmModels: [],
            piperVoices: [],
            vibeVoiceVoices: [],
            chatterboxInfo: nil,
            hasOllama: false,
            hasPiperTTS: false,
            hasVibeVoiceTTS: false,
            hasChatterboxTTS: false
        )

        XCTAssertTrue(caps.isEmpty)
        XCTAssertEqual(caps.summary, "No services found")
    }

    func testServerCapabilitiesNotEmptyWhenOnlyChatterboxPresent() {
        let chatterbox = ChatterboxServerInfo(
            isAvailable: true,
            modelType: "multilingual",
            device: "mps",
            isMultilingualAvailable: true
        )
        let caps = ServerCapabilities(
            llmModels: [],
            piperVoices: [],
            vibeVoiceVoices: [],
            chatterboxInfo: chatterbox,
            hasOllama: false,
            hasPiperTTS: false,
            hasVibeVoiceTTS: false,
            hasChatterboxTTS: true
        )

        XCTAssertFalse(caps.isEmpty,
                       "a Chatterbox-only server still has a usable service")
    }

    func testServerCapabilitiesSummaryListsAllPresentServices() {
        let chatterbox = ChatterboxServerInfo(
            isAvailable: true,
            modelType: "turbo",
            device: "cuda",
            isMultilingualAvailable: false
        )
        let caps = ServerCapabilities(
            llmModels: ["a", "b"],
            piperVoices: ["v1"],
            vibeVoiceVoices: ["v2"],
            chatterboxInfo: chatterbox,
            hasOllama: true,
            hasPiperTTS: true,
            hasVibeVoiceTTS: true,
            hasChatterboxTTS: true
        )

        let summary = caps.summary
        XCTAssertTrue(summary.contains("2 LLM model(s)"))
        XCTAssertTrue(summary.contains("Piper TTS"))
        XCTAssertTrue(summary.contains("VibeVoice TTS"))
        XCTAssertTrue(summary.contains("Chatterbox TTS (turbo)"))
    }

    // MARK: - ManagementModelInfo

    func testManagementModelInfoStoresOptionalMetadata() {
        let model = ManagementModelInfo(
            id: "ollama:qwen2.5:14b",
            name: "Qwen2.5 14B",
            type: "llm",
            serverID: "srv-1",
            serverName: "Local Mac",
            status: "loaded",
            sizeGB: 9.0,
            parameterSize: "14B",
            quantization: "Q4_K_M",
            family: "qwen2",
            contextWindow: 32768,
            contextWindowFormatted: "32K",
            vramGB: 11.0
        )

        XCTAssertEqual(model.id, "ollama:qwen2.5:14b")
        XCTAssertEqual(model.type, "llm")
        XCTAssertEqual(model.contextWindow, 32768)
        XCTAssertEqual(model.contextWindowFormatted, "32K")
        XCTAssertEqual(model.vramGB, 11.0)
    }

    func testManagementModelInfoDefaultsOptionalFieldsToNil() {
        let model = ManagementModelInfo(
            id: "id",
            name: "n",
            type: "stt",
            serverID: "s",
            serverName: "sn",
            status: "available"
        )

        XCTAssertNil(model.sizeGB)
        XCTAssertNil(model.parameterSize)
        XCTAssertNil(model.quantization)
        XCTAssertNil(model.family)
        XCTAssertNil(model.contextWindow)
        XCTAssertNil(model.contextWindowFormatted)
        XCTAssertNil(model.vramGB)
    }
}
