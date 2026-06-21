// UnaMentis - TodoToolHandler Tests
// Exercises the todo tool handler end to end against a real, in-memory
// TodoManager backed by a real Core Data stack (PersistenceController in-memory).
// No paid APIs are involved. The handler reaches TodoManager.shared, which is
// @MainActor global state, so each test installs and tears down a fresh manager
// to stay isolated. Test methods run on the main actor so the @MainActor
// TodoManager fetch methods and Core Data objects can be inspected directly
// without crossing an actor boundary with non-Sendable managed objects.

import XCTest
import CoreData
@testable import UnaMentis

@MainActor
final class TodoToolHandlerTests: XCTestCase {

    private var persistenceController: PersistenceController!

    private func installFreshManager() {
        persistenceController = PersistenceController(inMemory: true)

        // Clean slate: remove any TodoItems left over from a prior run.
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
        }
        try await super.tearDown()
    }

    // MARK: - Tool definitions

    func testToolDefinitions_exposeTodoTools() {
        let handler = TodoToolHandler()
        let names = handler.toolDefinitions.map(\.name)
        XCTAssertTrue(names.contains("add_todo"))
        XCTAssertTrue(names.contains("mark_for_review"))
    }

    // MARK: - Unknown tool

    func testHandle_unknownTool_throwsUnknownTool() async {
        let handler = TodoToolHandler()
        let call = LLMToolCall(id: "t0", name: "not_a_todo_tool", arguments: "{}")

        do {
            _ = try await handler.handle(call)
            XCTFail("Expected unknownTool to be thrown")
        } catch let error as ToolCallError {
            guard case .unknownTool(let name) = error else {
                return XCTFail("Expected .unknownTool, got \(error)")
            }
            XCTAssertEqual(name, "not_a_todo_tool")
        } catch {
            XCTFail("Expected ToolCallError.unknownTool, got \(error)")
        }
    }

    // MARK: - add_todo argument parsing

    func testHandleAddTodo_malformedArguments_throws() async {
        installFreshManager()
        let handler = TodoToolHandler()
        // "type" is required by AddTodoArguments; this body omits it.
        let call = LLMToolCall(id: "t1", name: "add_todo", arguments: #"{"title":"orphan"}"#)

        do {
            _ = try await handler.handle(call)
            XCTFail("Expected parsing of incomplete add_todo arguments to throw")
        } catch {
            XCTAssertTrue(error is DecodingError, "Expected a DecodingError, got \(error)")
        }
    }

    // MARK: - add_todo success path (real persistence)

    func testHandleAddTodo_learningTarget_persistsItem() async throws {
        installFreshManager()
        let handler = TodoToolHandler()

        let call = LLMToolCall(
            id: "t2",
            name: "add_todo",
            arguments: #"{"title":"Review limits","type":"learning_target","notes":"chapter 3"}"#
        )

        let result = try await handler.handle(call)

        XCTAssertTrue(result.isSuccess, "Result content: \(result.content)")
        XCTAssertEqual(result.toolCallId, "t2")
        XCTAssertTrue(result.content.contains("Review limits"))

        // The item must really exist in the store, not just be reported.
        let items = try activeItems()
        let created = items.first { $0.title == "Review limits" }
        XCTAssertNotNil(created, "add_todo must persist a real TodoItem, found titles: \(items.map(\.title))")
        XCTAssertEqual(created?.itemType, .learningTarget)
        XCTAssertEqual(created?.source, .voice, "Voice-triggered learning targets are sourced as .voice")
        XCTAssertEqual(created?.notes, "chapter 3")
    }

    func testHandleAddTodo_reinforcementType_persistsAsReinforcement() async throws {
        installFreshManager()
        let handler = TodoToolHandler()

        let call = LLMToolCall(
            id: "t3",
            name: "add_todo",
            arguments: #"{"title":"Drill conjugations","type":"reinforcement"}"#
        )

        let result = try await handler.handle(call)
        XCTAssertTrue(result.isSuccess)

        let created = try activeItems().first { $0.title == "Drill conjugations" }
        XCTAssertNotNil(created, "A reinforcement add_todo must create a real item")
        XCTAssertEqual(created?.itemType, .reinforcement)
        // Reinforcement items use the reinforcement creation path and source.
        XCTAssertEqual(created?.source, .reinforcement)
    }

    func testHandleAddTodo_unknownType_defaultsToLearningTarget() async throws {
        installFreshManager()
        let handler = TodoToolHandler()

        // An LLM-supplied type we do not recognize should not fail; it falls
        // back to learning target rather than dropping the request.
        let call = LLMToolCall(
            id: "t4",
            name: "add_todo",
            arguments: #"{"title":"Mystery item","type":"banana"}"#
        )

        let result = try await handler.handle(call)
        XCTAssertTrue(result.isSuccess)

        let created = try activeItems().first { $0.title == "Mystery item" }
        XCTAssertEqual(created?.itemType, .learningTarget,
                       "An unrecognized type must default to learningTarget")
    }

    func testHandleAddTodo_caseInsensitiveType() async throws {
        installFreshManager()
        let handler = TodoToolHandler()

        let call = LLMToolCall(
            id: "t5",
            name: "add_todo",
            arguments: #"{"title":"Mixed case","type":"Learning_Target"}"#
        )

        let result = try await handler.handle(call)
        XCTAssertTrue(result.isSuccess)

        let created = try activeItems().first { $0.title == "Mixed case" }
        XCTAssertEqual(created?.itemType, .learningTarget,
                       "Type matching must be case-insensitive")
    }

    // MARK: - add_todo when manager is missing

    func testHandleAddTodo_withoutManager_returnsErrorResult() async throws {
        // Ensure the manager is not initialized.
        TodoManager.shared = nil
        persistenceController = nil
        let handler = TodoToolHandler()

        let call = LLMToolCall(
            id: "t6",
            name: "add_todo",
            arguments: #"{"title":"Will not persist","type":"learning_target"}"#
        )

        let result = try await handler.handle(call)

        XCTAssertFalse(result.isSuccess,
                       "Without a TodoManager the handler must report a graceful error")
        XCTAssertEqual(result.toolCallId, "t6")
        XCTAssertTrue(result.content.contains("Failed to add item"),
                      "Error content should describe the add failure, got: \(result.content)")
    }

    // MARK: - mark_for_review

    func testHandleMarkForReview_usesTopicTitleAndPersistsReinforcement() async throws {
        installFreshManager()
        let handler = TodoToolHandler()

        let topicId = UUID()
        await handler.configureContext(
            sessionId: UUID(),
            topicId: topicId,
            topicTitle: "Photosynthesis"
        )

        let call = LLMToolCall(
            id: "t7",
            name: "mark_for_review",
            arguments: #"{"reason":"User struggled with the light reactions"}"#
        )

        let result = try await handler.handle(call)

        XCTAssertTrue(result.isSuccess, "Result content: \(result.content)")
        XCTAssertTrue(result.content.contains("Photosynthesis"),
                      "The confirmation should name the topic, got: \(result.content)")

        let review = try activeItems().first { $0.title == "Review: Photosynthesis" }
        XCTAssertNotNil(review, "mark_for_review must persist a 'Review: <topic>' item")
        XCTAssertEqual(review?.itemType, .reinforcement)
        // Reason and the topic id reference must both be captured in notes.
        XCTAssertEqual(review?.notes?.contains("User struggled with the light reactions"), true)
        XCTAssertEqual(review?.notes?.contains(topicId.uuidString), true,
                       "The topic id should be referenced in the review item's notes")
    }

    func testHandleMarkForReview_withoutContext_usesGenericTitle() async throws {
        installFreshManager()
        let handler = TodoToolHandler()
        // No configureContext call: there is no current topic.

        let call = LLMToolCall(id: "t8", name: "mark_for_review", arguments: "{}")
        let result = try await handler.handle(call)

        XCTAssertTrue(result.isSuccess)

        let review = try activeItems().first { $0.title == "Review: Current topic" }
        XCTAssertNotNil(review,
                        "Without topic context the review item falls back to a generic title")
        XCTAssertEqual(review?.itemType, .reinforcement)
    }

    func testClearContext_revertsToGenericReviewTitle() async throws {
        installFreshManager()
        let handler = TodoToolHandler()

        await handler.configureContext(sessionId: UUID(), topicId: UUID(), topicTitle: "Algebra")
        await handler.clearContext()

        let call = LLMToolCall(id: "t9", name: "mark_for_review", arguments: "{}")
        let result = try await handler.handle(call)
        XCTAssertTrue(result.isSuccess)

        let items = try activeItems()
        // After clearing, the topic title must no longer be used.
        XCTAssertNil(items.first { $0.title == "Review: Algebra" },
                     "Cleared context must not leak the previous topic title")
        XCTAssertNotNil(items.first { $0.title == "Review: Current topic" })
    }
}
