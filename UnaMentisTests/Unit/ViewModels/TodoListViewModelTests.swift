// UnaMentis - TodoListViewModelTests
// Unit tests for TodoListViewModel and its filter enum
//
// The view model resolves persistence through PersistenceController.shared and
// TodoManager.shared. To avoid mutating the shared store, these tests focus on
// the deterministic, isolated behaviors: the pre-load guard rails (which set a
// specific errorMessage when the manager is not yet initialized) and the
// TodoFilter enum the segmented control binds to. The CRUD happy paths are
// covered against a real in-memory store in TodoManagerTests.

import XCTest
@testable import UnaMentis

@MainActor
final class TodoListViewModelTests: XCTestCase {

    // MARK: - Initial State

    func testInitialState_defaultsToActiveFilterAndEmptyLists() {
        let vm = TodoListViewModel()

        XCTAssertEqual(vm.selectedFilter, .active)
        XCTAssertTrue(vm.activeItems.isEmpty)
        XCTAssertTrue(vm.completedItems.isEmpty)
        XCTAssertTrue(vm.archivedItems.isEmpty)
        XCTAssertFalse(vm.showAddSheet)
        XCTAssertFalse(vm.showClearCompletedConfirmation)
        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - Guard Rails Before Load

    func testCreateItem_beforeLoadSetsManagerNotInitializedError() async {
        // A fresh view model has not run loadAsync(), so todoManager is nil.
        let vm = TodoListViewModel()

        await vm.createItem(title: "New task", type: .topic, notes: nil)

        // The create path must surface a specific, user-facing error instead of
        // silently failing or crashing.
        XCTAssertEqual(vm.errorMessage, "To-do manager not initialized")
    }

    // MARK: - TodoFilter Enum

    func testTodoFilter_allCasesAndRawValues() {
        XCTAssertEqual(TodoFilter.allCases, [.active, .completed, .archived])
        XCTAssertEqual(TodoFilter.active.rawValue, "Active")
        XCTAssertEqual(TodoFilter.completed.rawValue, "Completed")
        XCTAssertEqual(TodoFilter.archived.rawValue, "Archived")
    }

    func testTodoFilter_iconNames() {
        XCTAssertEqual(TodoFilter.active.iconName, "checklist")
        XCTAssertEqual(TodoFilter.completed.iconName, "checkmark.circle")
        XCTAssertEqual(TodoFilter.archived.iconName, "archivebox")
    }
}
