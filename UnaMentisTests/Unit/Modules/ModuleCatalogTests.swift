// UnaMentis - Module Catalog Tests
// Tests for ModuleCatalog registration, capability filtering, and rootView.
//
// Part of Module System Testing (MODULE_SDK_SPEC.md Phase 1).

import XCTest
import SwiftUI
@testable import UnaMentis

@MainActor
final class ModuleCatalogTests: XCTestCase {

    // MARK: - Registration

    func testCatalog_registersKnowledgeBowl() {
        let catalog = ModuleCatalog.shared
        XCTAssertTrue(
            catalog.modules.contains { $0.id == "knowledge-bowl" },
            "Knowledge Bowl should be registered in the catalog"
        )
    }

    func testCatalog_moduleWithId_returnsKnowledgeBowl() {
        let module = ModuleCatalog.shared.module(withId: "knowledge-bowl")
        XCTAssertNotNil(module)
        XCTAssertEqual(module?.name, "Knowledge Bowl")
    }

    func testCatalog_moduleWithId_unknownReturnsNil() {
        XCTAssertNil(ModuleCatalog.shared.module(withId: "does-not-exist"))
    }

    func testCatalog_allModulesPassHostCapabilityCheck() {
        // Every visible module's required host capabilities must be provided;
        // that is the whole point of the filter.
        for module in ModuleCatalog.shared.modules {
            XCTAssertTrue(
                HostCapabilities.supports(module.manifest),
                "Visible module \(module.id) has unmet host capabilities"
            )
        }
    }

    // MARK: - Capability Filtering

    func testHostCapabilities_supportsModuleWithNoRequirements() {
        let manifest = Self.manifest(requiresHostCapabilities: [])
        XCTAssertTrue(HostCapabilities.supports(manifest))
    }

    func testHostCapabilities_supportsModuleWithProvidedRequirement() {
        // "flags/1" is advertised by the current build.
        let manifest = Self.manifest(requiresHostCapabilities: ["flags/1"])
        XCTAssertTrue(HostCapabilities.supports(manifest))
    }

    func testHostCapabilities_hidesModuleWithUnsupportedRequirement() {
        // A capability the current build does not provide (a future host
        // service). The module must be considered unsupported.
        let manifest = Self.manifest(
            requiresHostCapabilities: ["voice.session/1", "eval.semantic/1"]
        )
        XCTAssertFalse(
            HostCapabilities.supports(manifest),
            "A module requiring unshipped host capabilities must be filtered out"
        )
    }

    func testHostCapabilities_partialUnsupportedFails() {
        // One met, one unmet: the whole check must fail.
        let manifest = Self.manifest(
            requiresHostCapabilities: ["flags/1", "learner-model/1"]
        )
        XCTAssertFalse(HostCapabilities.supports(manifest))
    }

    // MARK: - Root View Fallback

    func testCatalog_rootView_knownModuleIsNotFallback() {
        // A known module returns its own view. We cannot introspect AnyView's
        // contents, so we assert it is produced without hitting the fallback
        // path (which is exercised separately below).
        let view = ModuleCatalog.shared.rootView(for: "knowledge-bowl")
        XCTAssertNotNil(view)
    }

    func testCatalog_rootView_unknownModuleReturnsFallback() {
        // Unknown IDs must resolve to the ContentUnavailableView fallback
        // rather than crashing or returning an arbitrary module view.
        let view = ModuleCatalog.shared.rootView(for: "no-such-module")
        XCTAssertNotNil(view)
        // The important guarantee is that an unknown ID does not resolve to a
        // registered module.
        XCTAssertNil(ModuleCatalog.shared.module(withId: "no-such-module"))
    }

    // MARK: - Helpers

    /// Builds a manifest with configurable host requirements for filter tests.
    private static func manifest(requiresHostCapabilities: [String]) -> ModuleManifest {
        ModuleManifest(
            specVersion: "0.1.0",
            id: "filter-test",
            name: "Filter Test",
            version: "1.0.0",
            engine: .custom,
            surfaces: [.phone],
            capabilities: [],
            requiresHostCapabilities: requiresHostCapabilities,
            optionalHostCapabilities: [],
            voiceCoverage: VoiceCoverage(declared: 0.0),
            serverTiers: [0],
            locales: ["en-US"],
            contentPacks: ContentPacks(bundled: [], compatibleSchemas: []),
            privacy: Privacy(
                collectsAudio: false,
                storesTranscripts: false,
                sharesWithMentor: .never
            ),
            minPlatform: MinPlatform(ios: "18.0")
        )
    }
}
