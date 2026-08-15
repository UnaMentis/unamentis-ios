// UnaMentis - Drill Format Descriptor Tests
// Round-trip and derived-config coverage for the drill/1 descriptor
// (MODULE_SDK_SPEC.md section 6.3).

import XCTest
@testable import UnaMentis

final class DrillFormatDescriptorTests: XCTestCase {

    func testDescriptor_roundTripsThroughJSON() throws {
        let descriptor = DrillFormatDescriptor(
            formatId: "sat-vocab-drill",
            itemTypes: ["drill-items/1"],
            sessionShapes: [.count(10), .timeBoxed(seconds: 120)],
            schedulingPolicy: .review,
            voice: .init(answerSilenceSec: 1.6, maxUtteranceSec: 12, answerTimeoutSec: 20)
        )
        let data = try descriptor.encoded()
        let decoded = try DrillFormatDescriptor.decode(from: data)
        XCTAssertEqual(decoded, descriptor)
    }

    func testDescriptor_decodesBundledSchemaShape() throws {
        // The literal JSON the bundled sat-math-mental.json ships.
        let json = """
        {
          "formatId": "sat-math-mental",
          "engine": "drill/1",
          "itemTypes": ["drill-items/1"],
          "sessionShapes": [{ "kind": "count", "value": 10 }],
          "schedulingPolicy": "review",
          "voice": { "answerSilenceSec": 1.1, "maxUtteranceSec": 8.0, "answerTimeoutSec": 25.0 }
        }
        """.data(using: .utf8)!
        let descriptor = try DrillFormatDescriptor.decode(from: json)
        XCTAssertEqual(descriptor.formatId, "sat-math-mental")
        XCTAssertEqual(descriptor.engine, "drill/1")
        XCTAssertEqual(descriptor.itemTypes, ["drill-items/1"])
        XCTAssertEqual(descriptor.sessionShapes, [.count(10)])
        XCTAssertEqual(descriptor.schedulingPolicy, .review)
        XCTAssertEqual(descriptor.voice?.answerSilenceSec, 1.1)
    }

    func testDescriptor_toleratesUnknownFields() throws {
        // Additive-only schema policy (section 10): unknown fields are ignored.
        let json = """
        {
          "formatId": "future",
          "engine": "drill/1",
          "itemTypes": ["drill-items/1"],
          "sessionShapes": [{ "kind": "count", "value": 5 }],
          "schedulingPolicy": "free",
          "watchSuitable": true,
          "futureField": { "nested": 1 }
        }
        """.data(using: .utf8)!
        let descriptor = try DrillFormatDescriptor.decode(from: json)
        XCTAssertEqual(descriptor.formatId, "future")
        XCTAssertNil(descriptor.voice)
    }

    func testVoicePipelineConfig_usesVoiceBlockEndpointing() {
        let descriptor = DrillFormatDescriptor(
            formatId: "d",
            itemTypes: ["drill-items/1"],
            sessionShapes: [.count(10)],
            schedulingPolicy: .free,
            voice: .init(answerSilenceSec: 1.1, maxUtteranceSec: 8, answerTimeoutSec: 25)
        )
        let config = descriptor.voicePipelineConfig()
        XCTAssertEqual(config.endpointing.silenceThreshold, 1.1)
        XCTAssertEqual(config.endpointing.maxUtteranceDuration, 8)
        XCTAssertEqual(config.answerTimeout, .seconds(25))
        XCTAssertNil(config.buzzMode)
        XCTAssertNil(config.conference)
    }

    func testVoicePipelineConfig_fallsBackToDefaultsWithoutVoiceBlock() {
        let descriptor = DrillFormatDescriptor(
            formatId: "d",
            itemTypes: ["drill-items/1"],
            sessionShapes: [.count(10)],
            schedulingPolicy: .free
        )
        let config = descriptor.voicePipelineConfig()
        XCTAssertEqual(config.endpointing.silenceThreshold, EndpointingPolicy.default.silenceThreshold)
        XCTAssertNil(config.answerTimeout)
    }

    func testBundledDescriptors_loadFromAppBundle() throws {
        // The two SAT drill descriptors ship as bundled resources.
        for name in ["sat-vocab-drill", "sat-math-mental"] {
            let descriptor = try DrillFormatDescriptor.load(named: name, in: .main)
            XCTAssertEqual(descriptor.formatId, name)
            XCTAssertEqual(descriptor.engine, "drill/1")
            XCTAssertEqual(descriptor.schedulingPolicy, .review)
            XCTAssertFalse(descriptor.sessionShapes.isEmpty)
        }
    }
}
