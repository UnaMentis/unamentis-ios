// UnaMentis - DebugConversationViewModelTests
// Unit tests for DebugConversationViewModel
//
// The view model and its scenario types are DEBUG only, so these tests are
// compiled only in DEBUG. They validate real outcomes of the deterministic,
// synchronous logic: provider-to-model resolution, scenario content, guard
// rails when no session is active, and log/state reset. Session start and
// message injection require live audio/LLM services and are not exercised
// here; the guard paths that protect those flows are.

#if DEBUG

import XCTest
@testable import UnaMentis

@MainActor
final class DebugConversationViewModelTests: XCTestCase {

    override func setUp() async throws {
        // Pin a known LLM provider/model so loadCurrentSettings is deterministic.
        UserDefaults.standard.removeObject(forKey: "llmProvider")
        UserDefaults.standard.removeObject(forKey: RemoteLLMModel.defaultsKey)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "llmProvider")
        UserDefaults.standard.removeObject(forKey: RemoteLLMModel.defaultsKey)
    }

    // MARK: - Available Model Resolution

    func testUpdateAvailableModels_openAIListsKnownModels() {
        let vm = DebugConversationViewModel()
        vm.selectedLLMProvider = .openAI

        vm.updateAvailableModels()

        XCTAssertEqual(vm.availableModels, ["gpt-4o", "gpt-4o-mini", "gpt-4-turbo"])
    }

    func testUpdateAvailableModels_anthropicListsKnownModels() {
        let vm = DebugConversationViewModel()
        vm.selectedLLMProvider = .anthropic

        vm.updateAvailableModels()

        XCTAssertTrue(vm.availableModels.contains("claude-sonnet-4-20250514"))
        XCTAssertTrue(vm.availableModels.contains("claude-3-haiku-20240307"))
    }

    func testUpdateAvailableModels_googleListsKnownModels() {
        let vm = DebugConversationViewModel()
        vm.selectedLLMProvider = .google

        vm.updateAvailableModels()

        XCTAssertTrue(vm.availableModels.contains("gemini-2.5-flash"))
        XCTAssertTrue(vm.availableModels.contains("gemini-2.0-flash"))
    }

    func testUpdateAvailableModels_resetsSelectionWhenModelInvalidForProvider() {
        let vm = DebugConversationViewModel()
        vm.selectedLLMProvider = .openAI
        // A model that does not belong to OpenAI's list.
        vm.selectedModel = "claude-3-haiku-20240307"

        vm.updateAvailableModels()

        // The selection must snap to the first valid model for the provider.
        XCTAssertEqual(vm.selectedModel, "gpt-4o")
    }

    func testUpdateAvailableModels_keepsSelectionWhenModelValid() {
        let vm = DebugConversationViewModel()
        vm.selectedLLMProvider = .openAI
        vm.selectedModel = "gpt-4o-mini"

        vm.updateAvailableModels()

        // A valid selection must be preserved, not reset to the first entry.
        XCTAssertEqual(vm.selectedModel, "gpt-4o-mini")
    }

    // MARK: - Settings Loading

    func testLoadCurrentSettings_usesDefaultsWhenNoOverride() {
        let vm = DebugConversationViewModel()

        vm.loadCurrentSettings()

        // With no stored llmProvider, the view model defaults to local MLX to
        // match the SettingsView default, and uses the app-wide model default.
        XCTAssertEqual(vm.selectedLLMProvider, .localMLX)
        XCTAssertEqual(vm.selectedModel, RemoteLLMModel.defaultModel)
    }

    func testLoadCurrentSettings_honorsStoredProvider() {
        UserDefaults.standard.set(LLMProvider.anthropic.rawValue, forKey: "llmProvider")
        defer { UserDefaults.standard.removeObject(forKey: "llmProvider") }

        let vm = DebugConversationViewModel()
        vm.loadCurrentSettings()

        XCTAssertEqual(vm.selectedLLMProvider, .anthropic)
    }

    // MARK: - Conversation Test Scenarios

    func testConversationScenario_eachHasThreeMessages() {
        for scenario in ConversationTestScenario.allCases {
            XCTAssertEqual(scenario.messages.count, 3,
                           "\(scenario.rawValue) should drive a three-turn exchange")
            XCTAssertFalse(scenario.description.isEmpty)
        }
    }

    func testConversationScenario_greetingFirstMessage() {
        XCTAssertEqual(ConversationTestScenario.greeting.messages.first, "Hello, how are you?")
        XCTAssertEqual(ConversationTestScenario.factualQA.messages.first, "What is photosynthesis?")
    }

    func testConversationScenario_idMatchesRawValue() {
        XCTAssertEqual(ConversationTestScenario.conceptExplain.id,
                       ConversationTestScenario.conceptExplain.rawValue)
    }

    // MARK: - Conversation Log Reset

    func testClearConversation_resetsLogAndCounters() {
        let vm = DebugConversationViewModel()
        vm.conversationLog = [
            ConversationEntry(role: .user, content: "hi", timestamp: Date()),
            ConversationEntry(role: .assistant, content: "hello", timestamp: Date())
        ]
        vm.turnCount = 7
        vm.lastLatency = 1.5

        vm.clearConversation()

        XCTAssertTrue(vm.conversationLog.isEmpty)
        XCTAssertEqual(vm.turnCount, 0)
        XCTAssertEqual(vm.lastLatency, 0, accuracy: 0.0001)
    }

    // MARK: - Guard Rails Without Active Session

    func testSendMessage_withoutSessionSetsError() async {
        let vm = DebugConversationViewModel()
        vm.inputText = "test question"

        await vm.sendMessage()

        XCTAssertEqual(vm.lastError, "No active session. Start a session first.")
        // Input must be preserved so the user does not lose their text.
        XCTAssertEqual(vm.inputText, "test question")
    }

    func testRunScenario_withoutSessionSetsError() async {
        let vm = DebugConversationViewModel()

        await vm.runConversationTestScenario(.greeting)

        XCTAssertEqual(vm.lastError, "No active session. Start a session first.")
    }

    // MARK: - Conversation Entry Role Display

    func testConversationEntryRole_displayNames() {
        XCTAssertEqual(ConversationEntry.ConversationRole.user.displayName, "You")
        XCTAssertEqual(ConversationEntry.ConversationRole.assistant.displayName, "AI")
        XCTAssertEqual(ConversationEntry.ConversationRole.system.displayName, "System")
        XCTAssertEqual(ConversationEntry.ConversationRole.error.displayName, "Error")
    }

    // MARK: - Debug Session Errors

    func testDebugSessionError_descriptions() {
        XCTAssertEqual(
            DebugSessionError.missingAPIKey("OpenAI").errorDescription,
            "OpenAI API key not configured. Please add it in Settings."
        )
        XCTAssertEqual(
            DebugSessionError.sessionStartFailed("no model").errorDescription,
            "Session failed to start: no model"
        )
    }
}

#endif
