// UnaMentis - Context Expansion Tool Tests
// Unit tests for the LLM context expansion tool definition and request parsing.
//
// This is pure, deterministic logic with no external dependencies, so every
// type under test uses its real implementation.

import XCTest
@testable import UnaMentis

final class ContextExpansionToolTests: XCTestCase {

    // MARK: - Tool Definition

    func testToolDefinition_hasExpectedNameAndRequiredQuery() {
        let definition = ContextExpansionTool.toolDefinition

        XCTAssertEqual(definition.name, "expand_context")
        XCTAssertEqual(definition.name, ContextExpansionTool.name)
        XCTAssertEqual(definition.inputSchema.required, ["query"])
        XCTAssertFalse(definition.description.isEmpty)
    }

    func testToolDefinition_exposesQueryScopeAndReasonProperties() {
        let properties = ContextExpansionTool.toolDefinition.inputSchema.properties

        XCTAssertNotNil(properties["query"])
        XCTAssertNotNil(properties["scope"])
        XCTAssertNotNil(properties["reason"])
        XCTAssertEqual(properties["query"]?.type, "string")
    }

    func testToolDefinition_scopeEnumeratesAllExpansionScopes() {
        let scopeProperty = ContextExpansionTool.toolDefinition.inputSchema.properties["scope"]
        let enumValues = scopeProperty?.enumValues ?? []

        XCTAssertEqual(
            Set(enumValues),
            ["current_topic", "current_unit", "full_curriculum", "related_topics"]
        )
    }

    func testToolDefinition_inputSchemaTypeIsObject() {
        XCTAssertEqual(ContextExpansionTool.toolDefinition.inputSchema.type, "object")
    }

    // MARK: - ExpansionRequest direct init

    func testExpansionRequest_defaultScopeIsCurrentTopic() {
        let request = ExpansionRequest(query: "Tell me more")
        XCTAssertEqual(request.scope, .currentTopic)
        XCTAssertNil(request.reason)
    }

    func testExpansionRequest_preservesExplicitValues() {
        let request = ExpansionRequest(
            query: "Photosynthesis details",
            scope: .fullCurriculum,
            reason: "Need depth"
        )
        XCTAssertEqual(request.query, "Photosynthesis details")
        XCTAssertEqual(request.scope, .fullCurriculum)
        XCTAssertEqual(request.reason, "Need depth")
    }

    // MARK: - ExpansionRequest init from JSON

    func testExpansionRequest_fromJSON_parsesAllFields() {
        let json: [String: Any] = [
            "query": "What is osmosis?",
            "scope": "current_unit",
            "reason": "Student asked a follow-up"
        ]

        let request = ExpansionRequest(from: json)

        XCTAssertNotNil(request)
        XCTAssertEqual(request?.query, "What is osmosis?")
        XCTAssertEqual(request?.scope, .currentUnit)
        XCTAssertEqual(request?.reason, "Student asked a follow-up")
    }

    func testExpansionRequest_fromJSON_missingQueryReturnsNil() {
        let json: [String: Any] = ["scope": "current_topic"]
        XCTAssertNil(ExpansionRequest(from: json))
    }

    func testExpansionRequest_fromJSON_missingScopeDefaultsToCurrentTopic() {
        let json: [String: Any] = ["query": "Explain gravity"]
        let request = ExpansionRequest(from: json)

        XCTAssertEqual(request?.scope, .currentTopic)
        XCTAssertNil(request?.reason)
    }

    func testExpansionRequest_fromJSON_invalidScopeFallsBackToCurrentTopic() {
        let json: [String: Any] = [
            "query": "Explain inertia",
            "scope": "nonexistent_scope"
        ]
        let request = ExpansionRequest(from: json)

        XCTAssertEqual(request?.scope, .currentTopic,
                       "Unknown scope strings must default to currentTopic")
    }

    func testExpansionRequest_fromJSON_acceptsAllValidScopeStrings() {
        let cases: [(String, ExpansionScope)] = [
            ("current_topic", .currentTopic),
            ("current_unit", .currentUnit),
            ("full_curriculum", .fullCurriculum),
            ("related_topics", .relatedTopics)
        ]

        for (raw, expected) in cases {
            let request = ExpansionRequest(from: ["query": "q", "scope": raw])
            XCTAssertEqual(request?.scope, expected, "Scope string \(raw) should map to \(expected)")
        }
    }

    // MARK: - ExpansionScope raw values

    func testExpansionScope_rawValuesAreCamelCase() {
        XCTAssertEqual(ExpansionScope.currentTopic.rawValue, "currentTopic")
        XCTAssertEqual(ExpansionScope.currentUnit.rawValue, "currentUnit")
        XCTAssertEqual(ExpansionScope.fullCurriculum.rawValue, "fullCurriculum")
        XCTAssertEqual(ExpansionScope.relatedTopics.rawValue, "relatedTopics")
    }

    // MARK: - ExpansionScope Codable

    func testExpansionScope_decodesSnakeCase() throws {
        let decoder = JSONDecoder()
        let snakeCases: [(String, ExpansionScope)] = [
            ("current_topic", .currentTopic),
            ("current_unit", .currentUnit),
            ("full_curriculum", .fullCurriculum),
            ("related_topics", .relatedTopics)
        ]

        for (raw, expected) in snakeCases {
            let data = Data("\"\(raw)\"".utf8)
            let decoded = try decoder.decode(ExpansionScope.self, from: data)
            XCTAssertEqual(decoded, expected)
        }
    }

    func testExpansionScope_decodesCamelCase() throws {
        let decoder = JSONDecoder()
        let data = Data("\"fullCurriculum\"".utf8)
        let decoded = try decoder.decode(ExpansionScope.self, from: data)
        XCTAssertEqual(decoded, .fullCurriculum)
    }

    func testExpansionScope_decodesUnknownToCurrentTopic() throws {
        let decoder = JSONDecoder()
        let data = Data("\"garbage\"".utf8)
        let decoded = try decoder.decode(ExpansionScope.self, from: data)
        XCTAssertEqual(decoded, .currentTopic)
    }

    func testExpansionScope_encodesCamelCaseRawValue() throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(ExpansionScope.relatedTopics)
        let json = try XCTUnwrap(String(bytes: data, encoding: .utf8))
        XCTAssertEqual(json, "\"relatedTopics\"")
    }

    func testExpansionRequest_codableRoundTrip() throws {
        let original = ExpansionRequest(
            query: "Define velocity",
            scope: .currentUnit,
            reason: "Clarity"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ExpansionRequest.self, from: data)

        XCTAssertEqual(decoded.query, original.query)
        XCTAssertEqual(decoded.scope, original.scope)
        XCTAssertEqual(decoded.reason, original.reason)
    }

    // MARK: - ExpansionToolResult

    func testExpansionToolResult_hasContentTrueWhenItemsRetrieved() {
        let result = ExpansionToolResult(
            success: true,
            content: "Some content",
            retrievedItems: 2,
            totalTokens: 100,
            searchDuration: 0.05,
            scope: .currentTopic
        )
        XCTAssertTrue(result.hasContent)
    }

    func testExpansionToolResult_hasContentFalseWhenNoItems() {
        let result = ExpansionToolResult(
            success: false,
            content: "No additional context found for your query.",
            retrievedItems: 0,
            totalTokens: 0,
            searchDuration: 0.01,
            scope: .fullCurriculum
        )
        XCTAssertFalse(result.hasContent)
    }

    // MARK: - RetrievedContent / ExpansionResult token accounting

    func testRetrievedContent_estimatesTokensFromContentLength() {
        // 40 characters at ~4 chars/token = 10 tokens.
        let content = String(repeating: "a", count: 40)
        let retrieved = RetrievedContent(
            sourceTitle: "Topic",
            content: content,
            relevanceScore: 0.9
        )
        XCTAssertEqual(retrieved.estimatedTokens, 10)
    }

    func testExpansionResult_sumsTokensAcrossRetrievedContent() {
        let items = [
            RetrievedContent(sourceTitle: "A", content: String(repeating: "x", count: 40), relevanceScore: 1.0),
            RetrievedContent(sourceTitle: "B", content: String(repeating: "y", count: 80), relevanceScore: 0.5)
        ]

        let result = ExpansionResult(query: "q", scope: .currentUnit, retrievedContent: items)

        // 10 + 20 = 30 tokens total.
        XCTAssertEqual(result.totalTokens, 30)
        XCTAssertEqual(result.retrievedContent.count, 2)
        XCTAssertEqual(result.scope, .currentUnit)
    }
}
