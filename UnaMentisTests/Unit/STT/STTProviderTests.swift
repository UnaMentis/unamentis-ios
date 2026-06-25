// UnaMentis - STTProvider Enum Tests
// Unit tests for the STTProvider classification logic
//
// The STTProvider enum is the cross-cutting source of truth for how the app
// classifies speech-to-text providers: their per-hour cost, whether they need
// the network, whether they run on-device, whether they are self-hosted, and
// their stable string identifiers. These properties drive provider selection,
// cost tracking, and telemetry, so the exact values are a real contract.
//
// The on-device GLM-ASR cases (glmASRNano, glmASROnDevice) are already covered
// by GLMASROnDeviceProviderTests. This file covers the remaining cases
// (assemblyAI, deepgramNova3, openAIWhisper, groqWhisper, appleSpeech,
// parakeetEOU) plus the enum-wide invariants.

import XCTest
@testable import UnaMentis

final class STTProviderTests: XCTestCase {

    // MARK: - Cost Classification

    func testCostPerHour_paidCloudProviders_matchPublishedRates() {
        // These decimals feed cost tracking and the UI. A regression here would
        // silently misreport spend, so the exact published rates are asserted.
        XCTAssertEqual(STTProvider.assemblyAI.costPerHour, Decimal(string: "0.37"))
        XCTAssertEqual(STTProvider.deepgramNova3.costPerHour, Decimal(string: "0.258"))
        XCTAssertEqual(STTProvider.openAIWhisper.costPerHour, Decimal(string: "0.36"))
    }

    func testCostPerHour_freeAndOnDeviceProviders_areZero() {
        XCTAssertEqual(STTProvider.groqWhisper.costPerHour, Decimal(0))
        XCTAssertEqual(STTProvider.appleSpeech.costPerHour, Decimal(0))
        XCTAssertEqual(STTProvider.parakeetEOU.costPerHour, Decimal(0))
    }

    // MARK: - Network Requirement

    func testRequiresNetwork_cloudProviders_needNetwork() {
        XCTAssertTrue(STTProvider.assemblyAI.requiresNetwork)
        XCTAssertTrue(STTProvider.deepgramNova3.requiresNetwork)
        XCTAssertTrue(STTProvider.openAIWhisper.requiresNetwork)
        XCTAssertTrue(STTProvider.groqWhisper.requiresNetwork)
    }

    func testRequiresNetwork_onDeviceProviders_doNotNeedNetwork() {
        XCTAssertFalse(STTProvider.appleSpeech.requiresNetwork)
        XCTAssertFalse(STTProvider.parakeetEOU.requiresNetwork)
    }

    // MARK: - On-Device Classification

    func testIsOnDevice_appleAndParakeet_runOnDevice() {
        XCTAssertTrue(STTProvider.appleSpeech.isOnDevice)
        XCTAssertTrue(STTProvider.parakeetEOU.isOnDevice)
    }

    func testIsOnDevice_cloudProviders_doNotRunOnDevice() {
        XCTAssertFalse(STTProvider.assemblyAI.isOnDevice)
        XCTAssertFalse(STTProvider.deepgramNova3.isOnDevice)
        XCTAssertFalse(STTProvider.openAIWhisper.isOnDevice)
        XCTAssertFalse(STTProvider.groqWhisper.isOnDevice)
    }

    // MARK: - Self-Hosted Classification

    func testIsSelfHosted_isExclusiveToGLMASRNano() {
        // Only the self-hosted GLM-ASR server qualifies. On-device GLM-ASR is
        // NOT self-hosted (it runs locally, no server), and no cloud provider is.
        // This exclusivity drives the self-hosted server configuration UI.
        for provider in STTProvider.allCases where provider != .glmASRNano {
            XCTAssertFalse(
                provider.isSelfHosted,
                "\(provider) must not be classified as self-hosted; only glmASRNano is"
            )
        }
        XCTAssertTrue(STTProvider.glmASRNano.isSelfHosted)
    }

    // MARK: - Identifiers

    func testIdentifier_returnsStableShortStrings() {
        // Identifiers are persisted/logged and used as routing keys, so they
        // must remain stable. Assert the exact mapping for the uncovered cases.
        XCTAssertEqual(STTProvider.assemblyAI.identifier, "assemblyai")
        XCTAssertEqual(STTProvider.deepgramNova3.identifier, "deepgram")
        XCTAssertEqual(STTProvider.openAIWhisper.identifier, "whisper")
        XCTAssertEqual(STTProvider.groqWhisper.identifier, "groq")
        XCTAssertEqual(STTProvider.appleSpeech.identifier, "apple")
        XCTAssertEqual(STTProvider.parakeetEOU.identifier, "parakeet-eou")
    }

    func testIdentifier_areUniqueAcrossAllProviders() {
        // Identifiers are routing keys; a collision would route to the wrong
        // provider. Verify uniqueness across the whole enum.
        let identifiers = STTProvider.allCases.map(\.identifier)
        XCTAssertEqual(
            Set(identifiers).count,
            identifiers.count,
            "Every STTProvider must have a unique identifier"
        )
    }

    func testDisplayName_matchesRawValue() {
        // displayName is what the picker UI shows. It is derived from rawValue,
        // so assert the contract holds and that names are non-empty.
        for provider in STTProvider.allCases {
            XCTAssertEqual(provider.displayName, provider.rawValue)
            XCTAssertFalse(provider.displayName.isEmpty, "\(provider) needs a display name")
        }
    }

    // MARK: - Cross-Property Invariants

    func testOnDeviceProviders_neverRequireNetwork() {
        // isOnDevice and requiresNetwork are independently implemented switches
        // over the same cases. They must stay logically consistent: anything
        // on-device must not require the network. This guards against a future
        // case being added to one switch but not the other.
        for provider in STTProvider.allCases where provider.isOnDevice {
            XCTAssertFalse(
                provider.requiresNetwork,
                "\(provider) is on-device and must not require the network"
            )
        }
    }

    func testOnDeviceProviders_areAlwaysFree() {
        // On-device inference has no per-hour API cost. This invariant protects
        // cost reporting if a new on-device provider is added later.
        for provider in STTProvider.allCases where provider.isOnDevice {
            XCTAssertEqual(
                provider.costPerHour,
                Decimal(0),
                "\(provider) is on-device and must have zero per-hour cost"
            )
        }
    }
}
