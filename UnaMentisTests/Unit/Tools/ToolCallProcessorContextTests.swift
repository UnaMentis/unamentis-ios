// UnaMentis - ToolCallProcessor Context and Error-Fidelity Tests
// Complements ToolCallProcessorTests by exercising behaviors that only
// surface when a tool call is driven through the processor itself:
//
//  1. Context delegation: configureContext / clearContext must reach the
//     shared TodoToolHandler and change what mark_for_review actually produces
//     when dispatched via the processor (not the handler directly).
//  2. Error-message fidelity: a handler that throws a LocalizedError must have
//     its specific localized description surfaced in the processor's error
//     result, not a generic placeholder.
//  3. Pass-through of handler-produced error results: a handler that returns
//     an .error result (without throwing) must reach the caller unchanged.
//
// No paid APIs are involved. The TodoManager is a real, in-memory Core Data
// backed manager, and the handler doubles are real internal ToolHandler
// implementations, so they follow the StubXxx naming convention. Tests that
// touch TodoManager.shared run on the main actor because TodoManager's create
// methods and the resulting managed objects are @MainActor and non-Sendable.

import XCTest
import CoreData
@testable import UnaMentis

@MainActor
final class ToolCallProcessorContextTests: XCTestCase {

    private var persistenceController: PersistenceController!

    private func installFreshManager() {
        persistenceController = PersistenceController(inMemory: true)

        // Clean slate: remove any TodoItems left over from a prior run so the
        // assertions below see only what this test created.
        let context = persistenceController.viewContext
        let request = TodoItem.fetchRequest()
        if let items = try? context.fetch(request) {
            for item in items { context.delete(item) }
            try? context.save()
        }

        TodoManager.shared = TodoManager(persistenceController: persistenceController)
    }

    private func activeItems() throws -> [TodoItem] {
        try XCTUnwrap(TodoManager.shared).fetchActiveItems()
    }

    override func tearDown() async throws {
        await MainActor.run {
            TodoManager.shared = nil
            persistenceController = nil
            // The processor configures the shared TodoToolHandler; reset it so
            // context does not leak into other tests sharing the singleton.
        }
        await ToolCallProcessor.shared.clearContext()
        try await super.tearDown()
    }

    // MARK: - Context delegation through the processor

    func testConfigureContext_throughProcessor_drivesMarkForReviewTitle() async throws {
        installFreshManager()
        let processor = ToolCallProcessor()

        // Configure context via the processor. It must delegate to the shared
        // TodoToolHandler, which the default-registered handler also uses.
        await processor.configureContext(
            sessionId: UUID(),
            topicId: UUID(),
            topicTitle: "Cellular Respiration"
        )

        let call = LLMToolCall(
            id: "ctx1",
            name: "mark_for_review",
            arguments: #"{"reason":"User confused glycolysis with Krebs cycle"}"#
        )

        let result = await processor.process(call)

        XCTAssertTrue(result.isSuccess, "Result content: \(result.content)")
        XCTAssertTrue(result.content.contains("Cellular Respiration"),
                      "Context set on the processor must reach the dispatched handler, got: \(result.content)")

        // The persisted item proves the title actually used the configured topic,
        // not just that the confirmation string was assembled.
        let review = try activeItems().first { $0.title == "Review: Cellular Respiration" }
        XCTAssertNotNil(review,
                        "Processor-configured topic must shape the persisted review item title")
        XCTAssertEqual(review?.itemType, .reinforcement)
    }

    func testClearContext_throughProcessor_revertsToGenericReviewTitle() async throws {
        installFreshManager()
        let processor = ToolCallProcessor()

        await processor.configureContext(
            sessionId: UUID(),
            topicId: UUID(),
            topicTitle: "Trigonometry"
        )
        await processor.clearContext()

        let call = LLMToolCall(id: "ctx2", name: "mark_for_review", arguments: "{}")
        let result = await processor.process(call)
        XCTAssertTrue(result.isSuccess)

        let items = try activeItems()
        XCTAssertNil(items.first { $0.title == "Review: Trigonometry" },
                     "Clearing context on the processor must drop the prior topic title")
        XCTAssertNotNil(items.first { $0.title == "Review: Current topic" },
                        "After clearing, mark_for_review must fall back to the generic title")
    }

    // MARK: - Error-message fidelity through dispatch

    /// A real handler that throws a LocalizedError (ToolCallError). Used to prove
    /// the processor surfaces the error's localized description, not a generic
    /// message, in the error result the LLM ultimately sees.
    private actor StubLocalizedErrorHandler: ToolHandler {
        nonisolated var toolDefinitions: [LLMToolDefinition] {
            [
                LLMToolDefinition(
                    name: "localized_fail",
                    description: "Throws a ToolCallError with a known description.",
                    inputSchema: ToolInputSchema(properties: [:], required: [])
                )
            ]
        }

        func handle(_ toolCall: LLMToolCall) async throws -> LLMToolResult {
            throw ToolCallError.executionFailed("disk is full")
        }
    }

    func testThrownLocalizedError_surfacesSpecificMessageInResult() async {
        let processor = ToolCallProcessor()
        await processor.register(StubLocalizedErrorHandler())

        let call = LLMToolCall(id: "e1", name: "localized_fail", arguments: "{}")
        let result = await processor.process(call)

        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.toolCallId, "e1")
        // ToolCallError is LocalizedError, so localizedDescription is the
        // errorDescription. The processor must carry that specific text through,
        // prefixed by the error factory.
        XCTAssertEqual(result.content, "Error: Tool execution failed: disk is full",
                       "The handler's specific localized error must reach the result, got: \(result.content)")
    }

    // MARK: - Pass-through of handler-produced error results

    /// A real handler that returns an .error result without throwing. The
    /// processor must not overwrite or re-wrap a deliberately produced error
    /// result; it should reach the caller verbatim.
    private actor StubErrorResultHandler: ToolHandler {
        nonisolated var toolDefinitions: [LLMToolDefinition] {
            [
                LLMToolDefinition(
                    name: "returns_error",
                    description: "Returns an error result instead of throwing.",
                    inputSchema: ToolInputSchema(properties: [:], required: [])
                )
            ]
        }

        func handle(_ toolCall: LLMToolCall) async throws -> LLMToolResult {
            .error(toolCallId: toolCall.id, error: "quota exceeded")
        }
    }

    func testHandlerReturnedErrorResult_isPassedThroughUnchanged() async {
        let processor = ToolCallProcessor()
        await processor.register(StubErrorResultHandler())

        let call = LLMToolCall(id: "e2", name: "returns_error", arguments: "{}")
        let result = await processor.process(call)

        XCTAssertFalse(result.isSuccess,
                       "A handler-produced error result must remain an error after dispatch")
        XCTAssertEqual(result.toolCallId, "e2")
        XCTAssertEqual(result.content, "Error: quota exceeded",
                       "The processor must not rewrap a non-throwing handler's error result")
    }

    // MARK: - processAll keeps per-call context-driven content distinct

    func testProcessAll_mixesContextDrivenSuccessAndUnknownToolErrors() async throws {
        installFreshManager()
        let processor = ToolCallProcessor()
        await processor.configureContext(
            sessionId: UUID(),
            topicId: UUID(),
            topicTitle: "Photosynthesis"
        )

        let known = LLMToolCall(id: "pa-known", name: "mark_for_review", arguments: "{}")
        let unknown = LLMToolCall(id: "pa-unknown", name: "no_such_tool", arguments: "{}")

        let results = await processor.processAll([known, unknown])

        XCTAssertEqual(results.count, 2)
        let byId = Dictionary(uniqueKeysWithValues: results.map { ($0.toolCallId, $0) })

        XCTAssertEqual(byId["pa-known"]?.isSuccess, true)
        XCTAssertEqual(byId["pa-known"]?.content.contains("Photosynthesis"), true,
                       "The known call must honor configured context even in a batch")
        XCTAssertEqual(byId["pa-unknown"]?.isSuccess, false)
        XCTAssertEqual(byId["pa-unknown"]?.content.contains("Unknown tool: no_such_tool"), true)
    }
}
