// UnaMentis - WebSearchToolHandler Tests
// Exercises the web_search tool handler against a real in-process search
// provider. The provider double is an internal WebSearchProvider actor (not a
// paid-API mock), so it uses the StubXxx naming convention and returns
// deterministic results captured from the call arguments.

import XCTest
@testable import UnaMentis

final class WebSearchToolHandlerTests: XCTestCase {

    // MARK: - Real in-process search provider

    /// A real WebSearchProvider that records the last query/maxResults and
    /// returns canned results, or throws a configured error. This is internal
    /// plumbing, not a paid external API, so it is a Stub rather than a Mock.
    private actor StubWebSearchProvider: WebSearchProvider {
        private(set) var lastQuery: String?
        private(set) var lastMaxResults: Int?
        private(set) var callCount = 0

        private let results: [WebSearchResult]
        private let errorToThrow: Error?

        init(results: [WebSearchResult] = [], errorToThrow: Error? = nil) {
            self.results = results
            self.errorToThrow = errorToThrow
        }

        func search(query: String, maxResults: Int) async throws -> WebSearchResponse {
            callCount += 1
            lastQuery = query
            lastMaxResults = maxResults
            if let errorToThrow {
                throw errorToThrow
            }
            return WebSearchResponse(query: query, results: results, totalResults: results.count)
        }
    }

    private func sampleResults() -> [WebSearchResult] {
        [
            WebSearchResult(
                title: "Mars facts",
                url: "https://example.com/mars",
                description: "The red planet."
            ),
            WebSearchResult(
                title: "Mars missions",
                url: "https://example.com/missions",
                description: "Rovers and orbiters."
            )
        ]
    }

    // MARK: - Tool definition

    func testToolDefinition_advertisesWebSearchWithRequiredQuery() async {
        let handler = WebSearchToolHandler()
        let defs = handler.toolDefinitions

        XCTAssertEqual(defs.count, 1)
        let tool = try? XCTUnwrap(defs.first)
        XCTAssertEqual(tool?.name, "web_search")
        XCTAssertEqual(tool?.inputSchema.required, ["query"],
                       "query must be the only required argument")
        XCTAssertNotNil(tool?.inputSchema.properties["num_results"],
                        "num_results must be an advertised optional property")
    }

    // MARK: - Success path

    func testHandle_withConfiguredProvider_returnsFormattedResults() async throws {
        let handler = WebSearchToolHandler()
        let provider = StubWebSearchProvider(results: sampleResults())
        await handler.configure(provider: provider)

        let call = LLMToolCall(id: "ws1", name: "web_search", arguments: #"{"query":"mars"}"#)
        let result = try await handler.handle(call)

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.toolCallId, "ws1")
        // Content is the provider response formatted for the LLM.
        XCTAssertTrue(result.content.contains("Search results for: mars"))
        XCTAssertTrue(result.content.contains("Mars facts"))
        XCTAssertTrue(result.content.contains("https://example.com/missions"))

        // The query was passed through to the provider verbatim.
        let lastQuery = await provider.lastQuery
        XCTAssertEqual(lastQuery, "mars")
    }

    func testHandle_defaultsToFiveResultsWhenCountOmitted() async throws {
        let handler = WebSearchToolHandler()
        let provider = StubWebSearchProvider(results: sampleResults())
        await handler.configure(provider: provider)

        let call = LLMToolCall(id: "ws2", name: "web_search", arguments: #"{"query":"history"}"#)
        _ = try await handler.handle(call)

        let maxResults = await provider.lastMaxResults
        XCTAssertEqual(maxResults, 5, "An absent num_results must fall back to the default of 5")
    }

    func testHandle_passesThroughExplicitResultCount() async throws {
        let handler = WebSearchToolHandler()
        let provider = StubWebSearchProvider(results: sampleResults())
        await handler.configure(provider: provider)

        let call = LLMToolCall(
            id: "ws3",
            name: "web_search",
            arguments: #"{"query":"physics","num_results":3}"#
        )
        _ = try await handler.handle(call)

        let maxResults = await provider.lastMaxResults
        XCTAssertEqual(maxResults, 3, "An explicit num_results must reach the provider unchanged")
    }

    func testHandle_emptyResults_returnsSuccessWithNoResultsMessage() async throws {
        let handler = WebSearchToolHandler()
        let provider = StubWebSearchProvider(results: [])
        await handler.configure(provider: provider)

        let call = LLMToolCall(id: "ws4", name: "web_search", arguments: #"{"query":"zxqwv"}"#)
        let result = try await handler.handle(call)

        XCTAssertTrue(result.isSuccess, "An empty result set is still a successful search")
        XCTAssertTrue(result.content.contains("No results found for: zxqwv"))
    }

    // MARK: - Failure paths

    func testHandle_withoutProvider_returnsConfigurationError() async throws {
        let handler = WebSearchToolHandler()
        // Intentionally not configured.

        let call = LLMToolCall(id: "ws5", name: "web_search", arguments: #"{"query":"anything"}"#)
        let result = try await handler.handle(call)

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.content.contains("not configured"),
                      "An unconfigured handler must explain that web search is unavailable")
    }

    func testHandle_invalidArguments_returnsErrorAndNeverCallsProvider() async throws {
        let handler = WebSearchToolHandler()
        let provider = StubWebSearchProvider(results: sampleResults())
        await handler.configure(provider: provider)

        // "query" is required; this body omits it.
        let call = LLMToolCall(id: "ws6", name: "web_search", arguments: #"{"num_results":2}"#)
        let result = try await handler.handle(call)

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.content.contains("Invalid search arguments"))

        let callCount = await provider.callCount
        XCTAssertEqual(callCount, 0, "Argument parsing must fail before the provider is touched")
    }

    func testHandle_providerThrows_returnsSearchFailedError() async throws {
        let handler = WebSearchToolHandler()
        let provider = StubWebSearchProvider(errorToThrow: WebSearchError.rateLimited)
        await handler.configure(provider: provider)

        let call = LLMToolCall(id: "ws7", name: "web_search", arguments: #"{"query":"news"}"#)
        let result = try await handler.handle(call)

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.content.contains("Search failed"),
                      "A provider failure must degrade to an error result, got: \(result.content)")
    }

    func testHandle_unknownToolName_throwsUnknownTool() async {
        let handler = WebSearchToolHandler()

        let call = LLMToolCall(id: "ws8", name: "not_web_search", arguments: "{}")
        do {
            _ = try await handler.handle(call)
            XCTFail("Expected handle to throw for an unrecognized tool name")
        } catch let error as ToolCallError {
            guard case .unknownTool(let name) = error else {
                return XCTFail("Expected .unknownTool, got \(error)")
            }
            XCTAssertEqual(name, "not_web_search")
        } catch {
            XCTFail("Expected ToolCallError.unknownTool, got \(error)")
        }
    }
}
