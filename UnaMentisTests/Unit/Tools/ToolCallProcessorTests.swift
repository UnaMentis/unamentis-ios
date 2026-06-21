// UnaMentis - ToolCallProcessor Tests
// Exercises the tool registry and dispatch: registration, unregistration,
// unknown-tool handling, single and parallel processing, and the
// provider-specific tool definition serialization (Anthropic / OpenAI).
//
// The handler doubles here are real internal ToolHandler implementations,
// not mocks of paid APIs, so they follow the StubXxx naming convention.

import XCTest
@testable import UnaMentis

final class ToolCallProcessorTests: XCTestCase {

    // MARK: - Internal handler doubles (real ToolHandler implementations)

    /// A real handler that echoes the call's arguments back as the result
    /// content. Used to prove dispatch routes to the registered handler.
    private actor StubEchoToolHandler: ToolHandler {
        let toolName: String

        init(toolName: String) { self.toolName = toolName }

        nonisolated var toolDefinitions: [LLMToolDefinition] {
            [
                LLMToolDefinition(
                    name: toolName,
                    description: "Echoes its input back, for testing dispatch.",
                    inputSchema: ToolInputSchema(
                        properties: [
                            "value": ToolProperty(type: "string", description: "anything")
                        ],
                        required: ["value"]
                    )
                )
            ]
        }

        func handle(_ toolCall: LLMToolCall) async throws -> LLMToolResult {
            .success(toolCallId: toolCall.id, content: "echo:\(toolCall.arguments)")
        }
    }

    /// A real handler that always throws, to prove the processor converts a
    /// thrown error into a graceful error result rather than crashing.
    private actor StubFailingToolHandler: ToolHandler {
        struct Boom: Error {}
        nonisolated var toolDefinitions: [LLMToolDefinition] {
            [
                LLMToolDefinition(
                    name: "always_fails",
                    description: "Always throws.",
                    inputSchema: ToolInputSchema(properties: [:], required: [])
                )
            ]
        }

        func handle(_ toolCall: LLMToolCall) async throws -> LLMToolResult {
            throw Boom()
        }
    }

    // MARK: - Registration and dispatch

    func testRegisteredHandlerReceivesMatchingCall() async {
        let processor = ToolCallProcessor()
        await processor.register(StubEchoToolHandler(toolName: "echo_tool"))

        let call = LLMToolCall(id: "c1", name: "echo_tool", arguments: #"{"value":"hi"}"#)
        let result = await processor.process(call)

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.toolCallId, "c1")
        XCTAssertEqual(result.content, #"echo:{"value":"hi"}"#,
                       "The registered handler must actually run and shape the result")
    }

    func testUnknownToolReturnsErrorResultNotThrow() async {
        let processor = ToolCallProcessor()

        let call = LLMToolCall(id: "c2", name: "does_not_exist", arguments: "{}")
        let result = await processor.process(call)

        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.toolCallId, "c2")
        XCTAssertTrue(result.content.contains("Unknown tool: does_not_exist"),
                      "An unrecognized tool must degrade to an error result, got: \(result.content)")
    }

    func testHandlerErrorIsConvertedToErrorResult() async {
        let processor = ToolCallProcessor()
        await processor.register(StubFailingToolHandler())

        let call = LLMToolCall(id: "c3", name: "always_fails", arguments: "{}")
        let result = await processor.process(call)

        XCTAssertFalse(result.isSuccess, "A throwing handler must not propagate, it must produce an error result")
        XCTAssertEqual(result.toolCallId, "c3")
    }

    func testUnregisterRemovesHandlerSoSubsequentCallsAreUnknown() async {
        let processor = ToolCallProcessor()
        await processor.register(StubEchoToolHandler(toolName: "echo_tool"))

        // Confirm it is wired up first.
        let before = await processor.process(
            LLMToolCall(id: "c4", name: "echo_tool", arguments: #"{"value":"x"}"#)
        )
        XCTAssertTrue(before.isSuccess)

        await processor.unregister(toolNames: ["echo_tool"])

        let after = await processor.process(
            LLMToolCall(id: "c5", name: "echo_tool", arguments: #"{"value":"x"}"#)
        )
        XCTAssertFalse(after.isSuccess, "After unregister, the tool must be unknown again")
        XCTAssertTrue(after.content.contains("Unknown tool"))
    }

    func testRegisterOverwritesPriorHandlerForSameToolName() async {
        let processor = ToolCallProcessor()
        await processor.register(StubEchoToolHandler(toolName: "shared_name"))
        // A failing handler claiming the same tool name should win after re-register.
        let second = StubReplacementHandler(toolName: "shared_name")
        await processor.register(second)

        let result = await processor.process(
            LLMToolCall(id: "c6", name: "shared_name", arguments: "{}")
        )
        XCTAssertEqual(result.content, "replacement-ran",
                       "The most recently registered handler for a name must win")
    }

    /// Helper handler whose result content is a fixed marker.
    private actor StubReplacementHandler: ToolHandler {
        let toolName: String
        init(toolName: String) { self.toolName = toolName }
        nonisolated var toolDefinitions: [LLMToolDefinition] {
            [
                LLMToolDefinition(
                    name: toolName,
                    description: "Replacement handler.",
                    inputSchema: ToolInputSchema(properties: [:], required: [])
                )
            ]
        }
        func handle(_ toolCall: LLMToolCall) async throws -> LLMToolResult {
            .success(toolCallId: toolCall.id, content: "replacement-ran")
        }
    }

    // MARK: - Parallel processing

    func testProcessAllReturnsOneResultPerCallPreservingIds() async {
        let processor = ToolCallProcessor()
        await processor.register(StubEchoToolHandler(toolName: "echo_tool"))

        let calls = (0..<10).map { idx in
            LLMToolCall(id: "id-\(idx)", name: "echo_tool", arguments: #"{"value":"v\#(idx)"}"#)
        }

        let results = await processor.processAll(calls)

        XCTAssertEqual(results.count, calls.count, "Every call must yield exactly one result")
        // Order is not guaranteed by the task group, so compare as sets of ids.
        let returnedIds = Set(results.map(\.toolCallId))
        let expectedIds = Set(calls.map(\.id))
        XCTAssertEqual(returnedIds, expectedIds, "Each call id must be represented exactly once")
        XCTAssertTrue(results.allSatisfy(\.isSuccess))
    }

    func testProcessAllHandlesMixOfKnownAndUnknownTools() async {
        let processor = ToolCallProcessor()
        await processor.register(StubEchoToolHandler(toolName: "echo_tool"))

        let known = LLMToolCall(id: "k", name: "echo_tool", arguments: #"{"value":"ok"}"#)
        let unknown = LLMToolCall(id: "u", name: "ghost", arguments: "{}")

        let results = await processor.processAll([known, unknown])

        XCTAssertEqual(results.count, 2)
        let byId = Dictionary(uniqueKeysWithValues: results.map { ($0.toolCallId, $0) })
        XCTAssertEqual(byId["k"]?.isSuccess, true)
        XCTAssertEqual(byId["u"]?.isSuccess, false)
    }

    func testProcessAllEmptyReturnsEmpty() async {
        let processor = ToolCallProcessor()
        let results = await processor.processAll([])
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Available tools (default handlers register lazily)

    func testAvailableTools_includeDefaultTodoAndWebSearchTools() async {
        let processor = ToolCallProcessor()
        let names = await processor.availableTools.map(\.name)

        // The processor lazily registers the todo and web search handlers.
        XCTAssertTrue(names.contains("add_todo"))
        XCTAssertTrue(names.contains("mark_for_review"))
        XCTAssertTrue(names.contains("web_search"))
    }

    func testAvailableTools_includeAdditionallyRegisteredHandler() async {
        let processor = ToolCallProcessor()
        await processor.register(StubEchoToolHandler(toolName: "echo_tool"))

        let names = await processor.availableTools.map(\.name)
        XCTAssertTrue(names.contains("echo_tool"))
        // Defaults are still present alongside the custom handler.
        XCTAssertTrue(names.contains("web_search"))
    }

    // MARK: - Provider-specific serialization

    func testAnthropicToolDefinitions_shapeMatchesAPIContract() async {
        let processor = ToolCallProcessor()
        await processor.register(StubEchoToolHandler(toolName: "echo_tool"))

        let defs = await processor.anthropicToolDefinitionsSnapshot()
        let echo = defs.first { $0.name == "echo_tool" }

        XCTAssertNotNil(echo, "Registered tool must appear in the Anthropic serialization")
        XCTAssertEqual(echo?.description, "Echoes its input back, for testing dispatch.")
        XCTAssertEqual(echo?.schemaType, "object")
        XCTAssertEqual(echo?.required, ["value"])
        XCTAssertEqual(echo?.properties["value"]?.type, "string")
    }

    func testOpenAIToolDefinitions_wrapInFunctionEnvelope() async {
        let processor = ToolCallProcessor()
        await processor.register(StubEchoToolHandler(toolName: "echo_tool"))

        let defs = await processor.openAIToolDefinitionsSnapshot()
        let echo = defs.first { $0.functionName == "echo_tool" }

        XCTAssertNotNil(echo, "Registered tool must appear in the OpenAI serialization")
        XCTAssertEqual(echo?.wrapperType, "function")
        XCTAssertEqual(echo?.functionName, "echo_tool")

        // OpenAI nests the schema under "parameters", not "input_schema".
        XCTAssertEqual(echo?.parametersType, "object")
        XCTAssertEqual(echo?.required, ["value"])
    }

    func testSerialization_includesEnumValuesForConstrainedProperties() async {
        // The built-in add_todo tool has an enum-constrained "type" property.
        let processor = ToolCallProcessor()
        let defs = await processor.anthropicToolDefinitionsSnapshot()

        let addTodo = defs.first { $0.name == "add_todo" }
        let typeProp = addTodo?.properties["type"]

        XCTAssertEqual(typeProp?.enumValues, ["learning_target", "reinforcement"],
                       "Enum constraints must be carried through to the provider payload")
    }

    func testSerialization_omitsEnumForFreeTextProperties() async {
        let processor = ToolCallProcessor()
        let defs = await processor.anthropicToolDefinitionsSnapshot()

        let addTodo = defs.first { $0.name == "add_todo" }
        let titleProp = addTodo?.properties["title"]

        XCTAssertNotNil(titleProp, "title property must be present")
        XCTAssertNil(titleProp?.enumValues, "Free-text properties must not carry an enum key")
    }
}

// MARK: - Sendable Tool Definition Accessors (test-only)

/// The production `anthropicToolDefinitions()` / `openAIToolDefinitions()` return
/// non-Sendable `[[String: Any]]`, which the Swift 6 actor boundary forbids
/// returning into a nonisolated test context. These actor-isolated extensions run
/// inside the actor and project the real serialized dictionaries into Sendable
/// structs, so the tests assert against the exact production output without a data
/// race. The values are read straight from the production dictionaries.

struct SerializedToolProperty: Sendable {
    let type: String?
    let enumValues: [String]?
}

struct SerializedAnthropicTool: Sendable {
    let name: String?
    let description: String?
    let schemaType: String?
    let required: [String]?
    let properties: [String: SerializedToolProperty]
}

struct SerializedOpenAITool: Sendable {
    let wrapperType: String?
    let functionName: String?
    let parametersType: String?
    let required: [String]?
    let properties: [String: SerializedToolProperty]
}

private func projectProperties(_ raw: Any?) -> [String: SerializedToolProperty] {
    guard let props = raw as? [String: [String: Any]] else { return [:] }
    var result: [String: SerializedToolProperty] = [:]
    for (key, value) in props {
        result[key] = SerializedToolProperty(
            type: value["type"] as? String,
            enumValues: value["enum"] as? [String]
        )
    }
    return result
}

extension ToolCallProcessor {
    func anthropicToolDefinitionsSnapshot() async -> [SerializedAnthropicTool] {
        let defs = await anthropicToolDefinitions()
        return defs.map { def in
            let schema = def["input_schema"] as? [String: Any]
            return SerializedAnthropicTool(
                name: def["name"] as? String,
                description: def["description"] as? String,
                schemaType: schema?["type"] as? String,
                required: schema?["required"] as? [String],
                properties: projectProperties(schema?["properties"])
            )
        }
    }

    func openAIToolDefinitionsSnapshot() async -> [SerializedOpenAITool] {
        let defs = await openAIToolDefinitions()
        return defs.map { def in
            let function = def["function"] as? [String: Any]
            let parameters = function?["parameters"] as? [String: Any]
            return SerializedOpenAITool(
                wrapperType: def["type"] as? String,
                functionName: function?["name"] as? String,
                parametersType: parameters?["type"] as? String,
                required: parameters?["required"] as? [String],
                properties: projectProperties(parameters?["properties"])
            )
        }
    }
}
