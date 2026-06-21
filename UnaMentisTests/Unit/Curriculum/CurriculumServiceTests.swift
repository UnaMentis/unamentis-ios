// UnaMentis - Curriculum Service Tests
// Unit tests for CurriculumService, the network client that fetches UMCF
// curricula from the management server.
//
// The HTTP layer is exercised with a real URLSession driven by a custom
// URLProtocol (StubURLProtocol). This is a real, standard URLSession test seam,
// not a paid external API: it lets the actor's real request building, status
// handling, and JSON decoding run end to end against canned local responses.

import XCTest
import Foundation
@testable import UnaMentis

// MARK: - URL Protocol Stub

/// Canned response for a single request, matched by URL path.
private struct StubbedResponse: Sendable {
    let statusCode: Int
    let body: Data
}

// Not `final`: URLProtocol's canInit/canonicalRequest must be overridden as
// `class func`, which conflicts with SwiftLint's static_over_final_class rule on
// a final class. Dropping `final` is the correct resolution, not a suppression.
//
/// A URLProtocol that serves canned responses keyed by the request path.
///
/// This is not a Mock of any paid API. It is a real URLProtocol subclass used as
/// the standard injection point for URLSession in tests, so the CurriculumService
/// actor's real request construction and decoding logic runs unmodified.
class StubURLProtocol: URLProtocol, @unchecked Sendable {

    // Path -> response. Access is serialized through the shared queue below.
    private static let queue = DispatchQueue(label: "com.unamentis.stuburlprotocol")
    nonisolated(unsafe) private static var responsesByPath: [String: StubbedResponse] = [:]
    nonisolated(unsafe) private static var lastRequestedURL: URL?
    nonisolated(unsafe) private static var lastHTTPMethod: String?

    static func reset() {
        queue.sync {
            responsesByPath = [:]
            lastRequestedURL = nil
            lastHTTPMethod = nil
        }
    }

    static func stub(path: String, statusCode: Int, body: Data) {
        queue.sync {
            responsesByPath[path] = StubbedResponse(statusCode: statusCode, body: body)
        }
    }

    static func recordedURL() -> URL? {
        queue.sync { lastRequestedURL }
    }

    static func recordedMethod() -> String? {
        queue.sync { lastHTTPMethod }
    }

    private static func response(for path: String) -> StubbedResponse? {
        queue.sync { responsesByPath[path] }
    }

    private static func record(url: URL?, method: String?) {
        queue.sync {
            lastRequestedURL = url
            lastHTTPMethod = method
        }
    }

    // MARK: URLProtocol overrides

    override class func canInit(with request: URLRequest) -> Bool {
        // Intercept everything this session sends.
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        Self.record(url: url, method: request.httpMethod)

        let path = url.path
        guard let stub = Self.response(for: path) else {
            // No stub registered for this path: simulate an unreachable host.
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }

        let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!

        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        // No-op: responses are delivered synchronously in startLoading.
    }
}

// MARK: - Tests

final class CurriculumServiceTests: XCTestCase {

    // MARK: - Properties

    private var session: URLSession!
    private let baseURL = URL(string: "http://test.local")!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()
        StubURLProtocol.reset()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() async throws {
        session = nil
        StubURLProtocol.reset()
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeService() async -> CurriculumService {
        let service = CurriculumService(session: session)
        await service.configure(baseURL: baseURL)
        return service
    }

    private func jsonData(_ string: String) -> Data {
        Data(string.utf8)
    }

    private func curriculaListJSON() -> Data {
        jsonData("""
        {
            "curricula": [
                {
                    "id": "curr-1",
                    "title": "Algebra Basics",
                    "description": "Intro to algebra",
                    "version": "1.0.0",
                    "topic_count": 5,
                    "difficulty": "beginner",
                    "keywords": ["math", "algebra"]
                },
                {
                    "id": "curr-2",
                    "title": "Geometry",
                    "description": "Shapes and proofs",
                    "version": "2.1.0",
                    "topic_count": 8
                }
            ],
            "total": 2
        }
        """)
    }

    private func curriculumDetailJSON() -> Data {
        jsonData("""
        {
            "id": "curr-1",
            "title": "Algebra Basics",
            "description": "Intro to algebra",
            "version": "1.0.0",
            "difficulty": "beginner",
            "keywords": ["math"],
            "topics": [
                {
                    "id": "topic-1",
                    "title": "Variables",
                    "description": "What is a variable",
                    "order_index": 0,
                    "has_transcript": true,
                    "segment_count": 3,
                    "assessment_count": 1
                }
            ],
            "glossary_terms": [
                {"term": "variable", "definition": "a symbol for a value"}
            ],
            "learning_objectives": ["Define a variable"]
        }
        """)
    }

    private func minimalUMCFJSON() -> String {
        """
        {
            "umcf": "1.0",
            "id": {"value": "curr-full-1"},
            "title": "Full Curriculum",
            "description": "downloaded",
            "version": {"number": "1.0.0"},
            "content": []
        }
        """
    }

    private func topicTranscriptJSON() -> Data {
        jsonData("""
        {
            "topic_id": "topic-1",
            "topic_title": "Variables",
            "segments": [
                {"id": "seg-1", "type": "introduction", "content": "Welcome."},
                {"id": "seg-2", "type": "explanation", "content": "A variable is a placeholder."}
            ]
        }
        """)
    }

    // MARK: - Configuration

    func testFetchCurricula_withoutConfiguredServer_throwsNoServerConfigured() async {
        let service = CurriculumService(session: session)

        do {
            _ = try await service.fetchCurricula()
            XCTFail("Expected noServerConfigured when no base URL is set")
        } catch let error as CurriculumServiceError {
            guard case .noServerConfigured = error else {
                return XCTFail("Expected .noServerConfigured, got \(error)")
            }
        } catch {
            XCTFail("Expected CurriculumServiceError, got \(error)")
        }
    }

    func testConfigureWithHostAndPort_buildsHTTPURL() async throws {
        let service = CurriculumService(session: session)
        try await service.configure(host: "192.168.0.5", port: 8766)

        StubURLProtocol.stub(path: "/api/curricula", statusCode: 200, body: curriculaListJSON())
        _ = try await service.fetchCurricula()

        let recorded = StubURLProtocol.recordedURL()
        XCTAssertEqual(recorded?.host, "192.168.0.5")
        XCTAssertEqual(recorded?.port, 8766)
        XCTAssertEqual(recorded?.scheme, "http")
    }

    // MARK: - fetchCurricula

    func testFetchCurricula_success_decodesSummaries() async throws {
        let service = await makeService()
        StubURLProtocol.stub(path: "/api/curricula", statusCode: 200, body: curriculaListJSON())

        let curricula = try await service.fetchCurricula()

        XCTAssertEqual(curricula.count, 2)
        XCTAssertEqual(curricula[0].id, "curr-1")
        XCTAssertEqual(curricula[0].title, "Algebra Basics")
        XCTAssertEqual(curricula[0].topicCount, 5)
        XCTAssertEqual(curricula[0].difficulty, "beginner")
        XCTAssertEqual(curricula[0].keywords, ["math", "algebra"])
        // The second summary omits optional fields, which should decode as nil.
        XCTAssertEqual(curricula[1].topicCount, 8)
        XCTAssertNil(curricula[1].difficulty)
        XCTAssertNil(curricula[1].keywords)
    }

    func testFetchCurricula_appendsSearchAndDifficultyQuery() async throws {
        let service = await makeService()
        StubURLProtocol.stub(path: "/api/curricula", statusCode: 200, body: curriculaListJSON())

        _ = try await service.fetchCurricula(search: "alg", difficulty: "beginner")

        let components = URLComponents(url: StubURLProtocol.recordedURL()!, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        XCTAssertTrue(items.contains(URLQueryItem(name: "search", value: "alg")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "difficulty", value: "beginner")))
    }

    func testFetchCurricula_emptyFilters_omitsQueryItems() async throws {
        let service = await makeService()
        StubURLProtocol.stub(path: "/api/curricula", statusCode: 200, body: curriculaListJSON())

        // Empty strings should be treated as no filter.
        _ = try await service.fetchCurricula(search: "", difficulty: "")

        let components = URLComponents(url: StubURLProtocol.recordedURL()!, resolvingAgainstBaseURL: false)
        XCTAssertNil(components?.queryItems, "Empty filter strings should not add query items")
    }

    func testFetchCurricula_serverError_throwsServerError() async {
        let service = await makeService()
        StubURLProtocol.stub(path: "/api/curricula", statusCode: 500, body: jsonData("internal boom"))

        do {
            _ = try await service.fetchCurricula()
            XCTFail("Expected serverError for a 500 response")
        } catch let error as CurriculumServiceError {
            guard case .serverError(let code, let message) = error else {
                return XCTFail("Expected .serverError, got \(error)")
            }
            XCTAssertEqual(code, 500)
            XCTAssertEqual(message, "internal boom")
        } catch {
            XCTFail("Expected CurriculumServiceError, got \(error)")
        }
    }

    func testFetchCurricula_malformedJSON_throwsDecodingError() async {
        let service = await makeService()
        StubURLProtocol.stub(path: "/api/curricula", statusCode: 200, body: jsonData("{ not valid json"))

        do {
            _ = try await service.fetchCurricula()
            XCTFail("Expected decodingError for malformed JSON")
        } catch let error as CurriculumServiceError {
            guard case .decodingError = error else {
                return XCTFail("Expected .decodingError, got \(error)")
            }
        } catch {
            XCTFail("Expected CurriculumServiceError, got \(error)")
        }
    }

    // MARK: - fetchCurriculumDetail

    func testFetchCurriculumDetail_success_decodesTopicsAndGlossary() async throws {
        let service = await makeService()
        StubURLProtocol.stub(path: "/api/curricula/curr-1", statusCode: 200, body: curriculumDetailJSON())

        let detail = try await service.fetchCurriculumDetail(id: "curr-1")

        XCTAssertEqual(detail.id, "curr-1")
        XCTAssertEqual(detail.topics.count, 1)
        XCTAssertEqual(detail.topics[0].title, "Variables")
        XCTAssertTrue(detail.topics[0].hasTranscript)
        XCTAssertEqual(detail.topics[0].segmentCount, 3)
        XCTAssertEqual(detail.glossaryTerms.count, 1)
        XCTAssertEqual(detail.glossaryTerms[0].term, "variable")
        // learning_objectives are plain strings here, exercising the flexible decoder.
        XCTAssertEqual(detail.learningObjectives.count, 1)
        XCTAssertEqual(detail.learningObjectives[0].statement, "Define a variable")
    }

    func testFetchCurriculumDetail_notFound_throwsNotFound() async {
        let service = await makeService()
        StubURLProtocol.stub(path: "/api/curricula/missing", statusCode: 404, body: jsonData("not found"))

        do {
            _ = try await service.fetchCurriculumDetail(id: "missing")
            XCTFail("Expected notFound for a 404 response")
        } catch let error as CurriculumServiceError {
            guard case .notFound(let id) = error else {
                return XCTFail("Expected .notFound, got \(error)")
            }
            XCTAssertEqual(id, "missing")
        } catch {
            XCTFail("Expected CurriculumServiceError, got \(error)")
        }
    }

    func testFetchCurriculumDetail_otherServerError_throwsServerError() async {
        let service = await makeService()
        StubURLProtocol.stub(path: "/api/curricula/curr-1", statusCode: 503, body: jsonData("unavailable"))

        do {
            _ = try await service.fetchCurriculumDetail(id: "curr-1")
            XCTFail("Expected serverError for a 503 response")
        } catch let error as CurriculumServiceError {
            guard case .serverError(let code, _) = error else {
                return XCTFail("Expected .serverError, got \(error)")
            }
            XCTAssertEqual(code, 503)
        } catch {
            XCTFail("Expected CurriculumServiceError, got \(error)")
        }
    }

    // MARK: - fetchFullCurriculum

    func testFetchFullCurriculum_directDocument_decodes() async throws {
        let service = await makeService()
        StubURLProtocol.stub(path: "/api/curricula/curr-full-1/full", statusCode: 200, body: jsonData(minimalUMCFJSON()))

        let document = try await service.fetchFullCurriculum(id: "curr-full-1")

        XCTAssertEqual(document.umcf, "1.0")
        XCTAssertEqual(document.id.value, "curr-full-1")
        XCTAssertEqual(document.title, "Full Curriculum")
    }

    func testFetchFullCurriculum_wrappedDocument_decodes() async throws {
        // The server may wrap the document in {"curriculum": ...}; the service
        // tries the wrapper shape first.
        let service = await makeService()
        let wrapped = jsonData("""
        { "curriculum": \(minimalUMCFJSON()) }
        """)
        StubURLProtocol.stub(path: "/api/curricula/curr-full-1/full", statusCode: 200, body: wrapped)

        let document = try await service.fetchFullCurriculum(id: "curr-full-1")

        XCTAssertEqual(document.id.value, "curr-full-1")
        XCTAssertEqual(document.title, "Full Curriculum")
    }

    func testFetchFullCurriculum_notFound_throwsNotFound() async {
        let service = await makeService()
        StubURLProtocol.stub(path: "/api/curricula/ghost/full", statusCode: 404, body: jsonData("nope"))

        do {
            _ = try await service.fetchFullCurriculum(id: "ghost")
            XCTFail("Expected notFound for a 404 response")
        } catch let error as CurriculumServiceError {
            guard case .notFound(let id) = error else {
                return XCTFail("Expected .notFound, got \(error)")
            }
            XCTAssertEqual(id, "ghost")
        } catch {
            XCTFail("Expected CurriculumServiceError, got \(error)")
        }
    }

    func testFetchFullCurriculum_invalidDocument_throwsDecodingError() async {
        let service = await makeService()
        // Valid JSON object, but not a UMCF document and not the wrapper shape.
        StubURLProtocol.stub(path: "/api/curricula/bad/full", statusCode: 200, body: jsonData("{\"unexpected\": true}"))

        do {
            _ = try await service.fetchFullCurriculum(id: "bad")
            XCTFail("Expected decodingError for a non-UMCF body")
        } catch let error as CurriculumServiceError {
            guard case .decodingError = error else {
                return XCTFail("Expected .decodingError, got \(error)")
            }
        } catch {
            XCTFail("Expected CurriculumServiceError, got \(error)")
        }
    }

    // MARK: - fetchFullCurriculumWithAssets

    func testFetchFullCurriculumWithAssets_decodesDocumentAndBase64Assets() async throws {
        let service = await makeService()

        let assetBytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let base64 = assetBytes.base64EncodedString()
        // The UMCF document fields plus an additional top-level assetData map.
        let body = jsonData("""
        {
            "umcf": "1.0",
            "id": {"value": "curr-assets"},
            "title": "Assets Curriculum",
            "version": {"number": "1.0.0"},
            "content": [],
            "assetData": {
                "img-1": {"data": "\(base64)", "mimeType": "image/png", "size": 4}
            }
        }
        """)
        StubURLProtocol.stub(path: "/api/curricula/curr-assets/full-with-assets", statusCode: 200, body: body)

        let (document, assets) = try await service.fetchFullCurriculumWithAssets(id: "curr-assets")

        XCTAssertEqual(document.id.value, "curr-assets")
        XCTAssertEqual(assets.count, 1)
        XCTAssertEqual(assets["img-1"], assetBytes, "Base64 asset payload should decode to the original bytes")
    }

    func testFetchFullCurriculumWithAssets_noAssetData_returnsEmptyMap() async throws {
        let service = await makeService()
        StubURLProtocol.stub(
            path: "/api/curricula/curr-assets/full-with-assets",
            statusCode: 200,
            body: jsonData(minimalUMCFJSON())
        )

        let (document, assets) = try await service.fetchFullCurriculumWithAssets(id: "curr-assets")

        XCTAssertEqual(document.id.value, "curr-full-1")
        XCTAssertTrue(assets.isEmpty, "Missing assetData should yield an empty asset map")
    }

    func testFetchFullCurriculumWithAssets_notFound_throwsNotFound() async {
        let service = await makeService()
        StubURLProtocol.stub(path: "/api/curricula/ghost/full-with-assets", statusCode: 404, body: jsonData("nope"))

        do {
            _ = try await service.fetchFullCurriculumWithAssets(id: "ghost")
            XCTFail("Expected notFound for a 404 response")
        } catch let error as CurriculumServiceError {
            guard case .notFound = error else {
                return XCTFail("Expected .notFound, got \(error)")
            }
        } catch {
            XCTFail("Expected CurriculumServiceError, got \(error)")
        }
    }

    // MARK: - fetchTopicTranscript

    func testFetchTopicTranscript_success_decodesSegments() async throws {
        let service = await makeService()
        StubURLProtocol.stub(
            path: "/api/curricula/curr-1/topics/topic-1/transcript",
            statusCode: 200,
            body: topicTranscriptJSON()
        )

        let transcript = try await service.fetchTopicTranscript(curriculumId: "curr-1", topicId: "topic-1")

        XCTAssertEqual(transcript.topicId, "topic-1")
        XCTAssertEqual(transcript.topicTitle, "Variables")
        XCTAssertEqual(transcript.segments.count, 2)
        XCTAssertEqual(transcript.segments[0].type, "introduction")
        XCTAssertEqual(transcript.segments[1].content, "A variable is a placeholder.")
    }

    func testFetchTopicTranscript_notFound_combinesIdsInError() async {
        let service = await makeService()
        StubURLProtocol.stub(
            path: "/api/curricula/curr-1/topics/topic-x/transcript",
            statusCode: 404,
            body: jsonData("nope")
        )

        do {
            _ = try await service.fetchTopicTranscript(curriculumId: "curr-1", topicId: "topic-x")
            XCTFail("Expected notFound for a 404 response")
        } catch let error as CurriculumServiceError {
            guard case .notFound(let id) = error else {
                return XCTFail("Expected .notFound, got \(error)")
            }
            XCTAssertEqual(id, "curr-1/topic-x", "notFound should report the combined curriculum/topic id")
        } catch {
            XCTFail("Expected CurriculumServiceError, got \(error)")
        }
    }

    // MARK: - reloadCurricula

    func testReloadCurricula_success_usesPOST() async throws {
        let service = await makeService()
        StubURLProtocol.stub(path: "/api/curricula/reload", statusCode: 200, body: Data())

        try await service.reloadCurricula()

        XCTAssertEqual(StubURLProtocol.recordedMethod(), "POST", "reloadCurricula should issue a POST request")
        XCTAssertEqual(StubURLProtocol.recordedURL()?.path, "/api/curricula/reload")
    }

    func testReloadCurricula_serverError_throwsServerError() async {
        let service = await makeService()
        StubURLProtocol.stub(path: "/api/curricula/reload", statusCode: 500, body: jsonData("fail"))

        do {
            try await service.reloadCurricula()
            XCTFail("Expected serverError for a 500 response")
        } catch let error as CurriculumServiceError {
            guard case .serverError(let code, _) = error else {
                return XCTFail("Expected .serverError, got \(error)")
            }
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("Expected CurriculumServiceError, got \(error)")
        }
    }

    func testReloadCurricula_withoutServer_throwsNoServerConfigured() async {
        let service = CurriculumService(session: session)

        do {
            try await service.reloadCurricula()
            XCTFail("Expected noServerConfigured")
        } catch let error as CurriculumServiceError {
            guard case .noServerConfigured = error else {
                return XCTFail("Expected .noServerConfigured, got \(error)")
            }
        } catch {
            XCTFail("Expected CurriculumServiceError, got \(error)")
        }
    }

    // MARK: - Error Descriptions

    func testErrorDescriptions_areHumanReadable() {
        XCTAssertEqual(CurriculumServiceError.invalidURL.errorDescription, "Invalid server URL configuration")
        XCTAssertEqual(CurriculumServiceError.noServerConfigured.errorDescription, "No management server configured")
        XCTAssertEqual(CurriculumServiceError.notFound("abc").errorDescription, "Curriculum not found: abc")
        XCTAssertEqual(CurriculumServiceError.networkError("down").errorDescription, "Network error: down")

        let serverWithMessage = CurriculumServiceError.serverError(503, "busy").errorDescription
        XCTAssertEqual(serverWithMessage, "Server error (503): busy")

        let serverWithoutMessage = CurriculumServiceError.serverError(500, nil).errorDescription
        XCTAssertEqual(serverWithoutMessage, "Server error (500): Unknown error")
    }
}
