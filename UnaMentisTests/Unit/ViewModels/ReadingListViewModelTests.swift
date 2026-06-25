// UnaMentis - ReadingListViewModelTests
// Unit tests for ReadingListViewModel and its filter enum
//
// The view model resolves its manager through the shared ReadingListManager
// singleton, whose lifecycle is owned by the app. These tests cover the
// deterministic, isolated surface: the initial published state the SwiftUI
// list binds to and the ReadingListFilter enum used by the segmented control.
// CRUD against the manager is covered against a real in-memory store in
// ReadingListManagerTests.

import XCTest
@testable import UnaMentis

@MainActor
final class ReadingListViewModelTests: XCTestCase {

    // MARK: - Initial State

    func testInitialState_isEmptyAndNotLoading() {
        let vm = ReadingListViewModel()

        XCTAssertTrue(vm.activeItems.isEmpty)
        XCTAssertTrue(vm.completedItems.isEmpty)
        XCTAssertTrue(vm.archivedItems.isEmpty)
        XCTAssertEqual(vm.selectedFilter, .active)
        XCTAssertFalse(vm.isLoading)
        XCTAssertFalse(vm.showImportSheet)
        XCTAssertNil(vm.errorMessage)
        XCTAssertNil(vm.statistics)
    }

    // MARK: - ReadingListFilter Enum

    func testReadingListFilter_allCasesAndDisplayNames() {
        XCTAssertEqual(ReadingListFilter.allCases, [.active, .completed, .archived])
        XCTAssertEqual(ReadingListFilter.active.displayName, "Active")
        XCTAssertEqual(ReadingListFilter.completed.displayName, "Completed")
        XCTAssertEqual(ReadingListFilter.archived.displayName, "Archived")
    }

    func testReadingListFilter_displayNameMatchesRawValue() {
        for filter in ReadingListFilter.allCases {
            XCTAssertEqual(filter.displayName, filter.rawValue)
        }
    }
}
