// UnaMentis - RemoteLLMModel default resolution tests
// Locks the single-source-of-truth contract: one default, override wins,
// empty override falls back, and the default is offered first in the picker.

import XCTest
@testable import UnaMentis

final class RemoteLLMModelTests: XCTestCase {

    private let key = RemoteLLMModel.defaultsKey
    private var saved: String?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.string(forKey: key)
    }

    override func tearDown() {
        if let saved {
            UserDefaults.standard.set(saved, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    func testDefaultWhenNoOverride() {
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(RemoteLLMModel.current, RemoteLLMModel.defaultModel)
        XCTAssertEqual(RemoteLLMModel.defaultModel, "qwen2.5:14b-instruct",
                       "the app-wide default remote model should match what the server serves")
    }

    func testUserOverrideWins() {
        UserDefaults.standard.set("some-other-model", forKey: key)
        XCTAssertEqual(RemoteLLMModel.current, "some-other-model")
    }

    func testEmptyOverrideFallsBackToDefault() {
        UserDefaults.standard.set("", forKey: key)
        XCTAssertEqual(RemoteLLMModel.current, RemoteLLMModel.defaultModel)
    }

    func testDefaultIsOfferedFirstInPickerFallback() {
        XCTAssertEqual(RemoteLLMModel.selfHostedFallbackModels.first, RemoteLLMModel.defaultModel)
    }
}
