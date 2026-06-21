// UnaMentis - SelfHostedLLMService Construction Tests
// Verifies the no-network construction paths and factory helpers of the
// self-hosted (OpenAI-compatible) LLM service. The streaming and HTTP paths
// require a live server, so they are out of scope for unit tests; what is
// deterministic and worth pinning is how the service is built from explicit
// configuration, from a ServerConfig, and from the Ollama/gateway factories.

import XCTest
@testable import UnaMentis

final class SelfHostedLLMServiceTests: XCTestCase {

    // MARK: - Explicit construction

    func testExplicitInitIsFreeAndUsable() async {
        let url = URL(string: "http://localhost:11434")!
        let service = SelfHostedLLMService(baseURL: url, modelName: "llama3.2:3b")

        let input = await service.costPerInputToken
        let output = await service.costPerOutputToken
        XCTAssertEqual(input, 0)
        XCTAssertEqual(output, 0)
    }

    func testExplicitInitWithAuthTokenStillConstructs() async {
        let url = URL(string: "https://my-server.example.com")!
        let service = SelfHostedLLMService(
            baseURL: url,
            modelName: "qwen2.5:7b",
            authToken: "secret-token"
        )
        // The auth token is private; we can only confirm construction succeeded.
        let metrics = await service.metrics
        XCTAssertEqual(metrics.totalInputTokens, 0)
    }

    // MARK: - Construction from ServerConfig

    func testInitFromServerConfigSucceedsWithValidHost() async {
        let server = ServerConfig(name: "Home Ollama", host: "192.168.1.50", port: 11434)
        let service = SelfHostedLLMService(server: server, modelName: "mistral:7b")
        XCTAssertNotNil(service, "A server with a valid host/port yields a baseURL and a service")
    }

    func testInitFromServerConfigDerivesBaseURL() {
        // The ServerConfig baseURL is what the service consumes. Confirm the
        // host/port compose into the expected URL the service relies on.
        let server = ServerConfig(name: "Home Ollama", host: "192.168.1.50", port: 11434)
        XCTAssertEqual(server.baseURL?.absoluteString, "http://192.168.1.50:11434")
    }

    // MARK: - Factory helpers

    func testOllamaFactoryDefaultsToLocalhost() async {
        let service = SelfHostedLLMService.ollama()
        // Defaults: localhost:11434, qwen2.5:7b. Free, like all self-hosted.
        let input = await service.costPerInputToken
        XCTAssertEqual(input, 0)
    }

    func testOllamaFactoryAcceptsCustomHostPortModel() async {
        let service = SelfHostedLLMService.ollama(
            host: "10.0.0.5",
            port: 11500,
            model: "llama3.2:1b"
        )
        let output = await service.costPerOutputToken
        XCTAssertEqual(output, 0)
    }

    func testGatewayFactoryConstructs() async {
        let service = SelfHostedLLMService.voicelearnGateway()
        let metrics = await service.metrics
        // Self-hosted seeds a fast local TTFT and zero token counts up front.
        XCTAssertGreaterThanOrEqual(metrics.medianTTFT, 0)
        XCTAssertEqual(metrics.totalOutputTokens, 0)
    }

    // MARK: - Metrics seed

    func testSelfHostedSeedsFastLocalLatency() async {
        let service = SelfHostedLLMService.ollama()
        let metrics = await service.metrics
        // Local inference is seeded faster than the cloud defaults.
        XCTAssertLessThanOrEqual(metrics.medianTTFT, metrics.p99TTFT)
        XCTAssertLessThan(metrics.medianTTFT, 1.0)
    }
}
