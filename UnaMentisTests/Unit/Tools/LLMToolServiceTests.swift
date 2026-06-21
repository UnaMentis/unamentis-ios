// UnaMentis - LLMToolService Tests
// Exercises the pure tool-calling value types: argument parsing, result
// factories, error descriptions, Codable schema round-trips, and the
// built-in todo tool definitions. No paid APIs are involved, so everything
// here uses the real types directly.

import XCTest
@testable import UnaMentis

final class LLMToolServiceTests: XCTestCase {

    // MARK: - LLMToolCall.parseArguments

    func testParseArguments_decodesValidJSONIntoStruct() throws {
        let call = LLMToolCall(
            id: "call_1",
            name: "add_todo",
            arguments: #"{"title":"Review limits","type":"learning_target","notes":"chapter 3"}"#
        )

        let args: AddTodoArguments = try call.parseArguments()

        XCTAssertEqual(args.title, "Review limits")
        XCTAssertEqual(args.type, "learning_target")
        XCTAssertEqual(args.notes, "chapter 3")
    }

    func testParseArguments_allowsOptionalFieldsToBeAbsent() throws {
        let call = LLMToolCall(
            id: "call_2",
            name: "add_todo",
            arguments: #"{"title":"Practice verbs","type":"reinforcement"}"#
        )

        let args: AddTodoArguments = try call.parseArguments()

        XCTAssertEqual(args.title, "Practice verbs")
        XCTAssertNil(args.notes, "Absent optional field must decode to nil, not fail")
    }

    func testParseArguments_throwsOnMalformedJSON() {
        let call = LLMToolCall(id: "call_3", name: "add_todo", arguments: "{not json")

        XCTAssertThrowsError(try { () -> AddTodoArguments in
            try call.parseArguments()
        }()) { error in
            // A malformed body surfaces as a decoding error, not a silent default.
            XCTAssertTrue(error is DecodingError, "Expected DecodingError, got \(error)")
        }
    }

    func testParseArguments_throwsOnMissingRequiredField() {
        // "type" is required by AddTodoArguments but absent here.
        let call = LLMToolCall(id: "call_4", name: "add_todo", arguments: #"{"title":"Only a title"}"#)

        XCTAssertThrowsError(try { () -> AddTodoArguments in
            try call.parseArguments()
        }())
    }

    // MARK: - LLMToolResult factories

    func testSuccessFactory_setsContentAndSuccessFlag() {
        let result = LLMToolResult.success(toolCallId: "abc", content: "Done")

        XCTAssertEqual(result.toolCallId, "abc")
        XCTAssertEqual(result.content, "Done")
        XCTAssertTrue(result.isSuccess)
    }

    func testErrorFactory_prefixesContentAndClearsSuccessFlag() {
        let result = LLMToolResult.error(toolCallId: "abc", error: "boom")

        XCTAssertEqual(result.toolCallId, "abc")
        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.content, "Error: boom",
                       "Error results must carry a human-readable, prefixed message")
    }

    func testDefaultInit_isSuccessByDefault() {
        let result = LLMToolResult(toolCallId: "id", content: "x")
        XCTAssertTrue(result.isSuccess, "Plain init defaults to success")
    }

    // MARK: - ToolCallError descriptions

    func testToolCallError_descriptionsAreSpecificPerCase() {
        XCTAssertEqual(ToolCallError.unknownTool("frobnicate").errorDescription,
                       "Unknown tool: frobnicate")
        XCTAssertEqual(ToolCallError.invalidArguments("bad").errorDescription,
                       "Invalid tool arguments: bad")
        XCTAssertEqual(ToolCallError.executionFailed("nope").errorDescription,
                       "Tool execution failed: nope")
        XCTAssertEqual(ToolCallError.toolDisabled("web_search").errorDescription,
                       "Tool is disabled: web_search")
    }

    // MARK: - ToolStopReason raw values

    func testToolStopReason_rawValuesMatchWireFormat() {
        XCTAssertEqual(ToolStopReason.endTurn.rawValue, "end_turn")
        XCTAssertEqual(ToolStopReason.maxTokens.rawValue, "max_tokens")
        XCTAssertEqual(ToolStopReason.stopSequence.rawValue, "stop_sequence")
        XCTAssertEqual(ToolStopReason.toolUse.rawValue, "tool_use")
        // And decoding from the wire string must round-trip.
        XCTAssertEqual(ToolStopReason(rawValue: "tool_use"), .toolUse)
    }

    // MARK: - LLMToolToken defaults

    func testToolToken_defaultsAreEmpty() {
        let token = LLMToolToken()
        XCTAssertNil(token.textContent)
        XCTAssertNil(token.toolCalls)
        XCTAssertFalse(token.isDone)
        XCTAssertNil(token.stopReason)
    }

    func testToolToken_carriesToolCallsAndStopReason() {
        let call = LLMToolCall(id: "t1", name: "web_search", arguments: "{}")
        let token = LLMToolToken(toolCalls: [call], isDone: true, stopReason: .toolUse)

        XCTAssertEqual(token.toolCalls?.count, 1)
        XCTAssertEqual(token.toolCalls?.first?.name, "web_search")
        XCTAssertTrue(token.isDone)
        XCTAssertEqual(token.stopReason, .toolUse)
    }

    // MARK: - Codable schema round-trips

    func testToolProperty_codingKeyMapsEnumValuesToJSONEnum() throws {
        let property = ToolProperty(type: "string", description: "kind", enumValues: ["a", "b"])

        let data = try JSONEncoder().encode(property)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // The Swift property is enumValues but the wire key must be "enum".
        XCTAssertEqual(json["enum"] as? [String], ["a", "b"])
        XCTAssertNil(json["enumValues"], "The Swift field name must not leak into JSON")
        XCTAssertEqual(json["type"] as? String, "string")
        XCTAssertEqual(json["description"] as? String, "kind")
    }

    func testToolProperty_omitsEnumWhenNil() throws {
        let property = ToolProperty(type: "string", description: "free text")

        let data = try JSONEncoder().encode(property)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(json["enum"], "A property without enum values must not emit an enum key")
    }

    func testToolDefinition_roundTripsThroughCodable() throws {
        let original = LLMToolDefinition(
            name: "add_todo",
            description: "Add an item",
            inputSchema: ToolInputSchema(
                properties: [
                    "title": ToolProperty(type: "string", description: "the title"),
                    "kind": ToolProperty(type: "string", description: "kind", enumValues: ["x", "y"])
                ],
                required: ["title"]
            )
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LLMToolDefinition.self, from: data)

        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.description, original.description)
        XCTAssertEqual(decoded.inputSchema.type, "object")
        XCTAssertEqual(decoded.inputSchema.required, ["title"])
        XCTAssertEqual(decoded.inputSchema.properties["title"]?.type, "string")
        XCTAssertEqual(decoded.inputSchema.properties["kind"]?.enumValues, ["x", "y"])
        XCTAssertNil(decoded.inputSchema.properties["title"]?.enumValues)
    }

    func testToolInputSchema_defaultsTypeToObject() {
        let schema = ToolInputSchema(properties: [:], required: [])
        XCTAssertEqual(schema.type, "object", "Schema type defaults to object")
    }

    // MARK: - Built-in todo tool definitions

    func testTodoTools_all_containsBothToolsWithExpectedNames() {
        let names = TodoTools.all.map(\.name)
        XCTAssertEqual(names.count, 2)
        XCTAssertTrue(names.contains("add_todo"))
        XCTAssertTrue(names.contains("mark_for_review"))
    }

    func testAddTodoTool_requiresTitleAndTypeAndConstrainsTypeEnum() {
        let tool = TodoTools.addTodo

        XCTAssertEqual(tool.name, "add_todo")
        XCTAssertEqual(Set(tool.inputSchema.required), ["title", "type"])

        let typeProperty = tool.inputSchema.properties["type"]
        XCTAssertEqual(typeProperty?.enumValues, ["learning_target", "reinforcement"],
                       "The type field must constrain the LLM to the two known todo types")
        // notes is documented but not required.
        XCTAssertNotNil(tool.inputSchema.properties["notes"])
        XCTAssertFalse(tool.inputSchema.required.contains("notes"))
    }

    func testMarkForReviewTool_hasNoRequiredFields() {
        let tool = TodoTools.markForReview

        XCTAssertEqual(tool.name, "mark_for_review")
        XCTAssertTrue(tool.inputSchema.required.isEmpty,
                      "mark_for_review should be callable with no arguments")
        XCTAssertNotNil(tool.inputSchema.properties["reason"])
    }
}
