// UnaMentis - Module Protocol Tests
// Tests for ModuleProtocol and SpecializedModule type-erased wrapper
//
// Part of Module System Testing

import XCTest
import SwiftUI
@testable import UnaMentis

final class ModuleProtocolTests: XCTestCase {

    // MARK: - Test Module Implementation

    /// Builds a minimal manifest for a test module. Capabilities default to
    /// empty so the derived feature booleans are all false unless overridden.
    static func makeManifest(
        id: String = "test-module",
        name: String = "Test Module",
        version: String = "1.0.0",
        capabilities: Set<String> = [],
        requiresHostCapabilities: [String] = []
    ) -> ModuleManifest {
        ModuleManifest(
            specVersion: "0.1.0",
            id: id,
            name: name,
            version: version,
            engine: .custom,
            surfaces: [.phone],
            capabilities: capabilities,
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

    /// A test module that implements ModuleProtocol for testing. Its id, name,
    /// and version derive from the manifest per the manifest-based protocol.
    struct TestModule: ModuleProtocol {
        let manifest: ModuleManifest
        let shortDescription: String
        let longDescription: String
        let iconName: String
        let themeColor: Color

        init(
            id: String = "test-module",
            name: String = "Test Module",
            shortDescription: String = "Short description",
            longDescription: String = "Long description for testing",
            iconName: String = "star",
            themeColor: Color = .blue
        ) {
            self.manifest = ModuleProtocolTests.makeManifest(id: id, name: name)
            self.shortDescription = shortDescription
            self.longDescription = longDescription
            self.iconName = iconName
            self.themeColor = themeColor
        }

        @MainActor
        func makeRootView() -> AnyView {
            AnyView(Text("Root View"))
        }

        @MainActor
        func makeDashboardView() -> AnyView {
            AnyView(Text("Dashboard View"))
        }
    }

    /// A test module with all capability-derived feature flags on.
    struct FullFeaturedModule: ModuleProtocol {
        let manifest = ModuleProtocolTests.makeManifest(
            id: "full-featured",
            name: "Full Featured",
            version: "2.0.0",
            capabilities: ["team.local", "training.speed", "sim.opponent"]
        )
        let shortDescription = "Has all features"
        let longDescription = "A module with all features enabled"
        let iconName = "star.fill"
        let themeColor = Color.orange

        @MainActor
        func makeRootView() -> AnyView {
            AnyView(Text("Full Featured Root"))
        }

        @MainActor
        func makeDashboardView() -> AnyView {
            AnyView(Text("Full Featured Dashboard"))
        }
    }

    // MARK: - ModuleProtocol Default Implementation Tests

    func testDefaultSupportsTeamMode_isFalse() {
        let module = TestModule()
        XCTAssertFalse(module.supportsTeamMode)
    }

    func testDefaultSupportsSpeedTraining_isFalse() {
        let module = TestModule()
        XCTAssertFalse(module.supportsSpeedTraining)
    }

    func testDefaultSupportsCompetitionSim_isFalse() {
        let module = TestModule()
        XCTAssertFalse(module.supportsCompetitionSim)
    }

    func testDefaultVersion_is1_0_0() {
        let module = TestModule()
        XCTAssertEqual(module.version, "1.0.0")
    }

    func testCustomFeatureFlags_areRespected() {
        let module = FullFeaturedModule()
        XCTAssertTrue(module.supportsTeamMode)
        XCTAssertTrue(module.supportsSpeedTraining)
        XCTAssertTrue(module.supportsCompetitionSim)
        XCTAssertEqual(module.version, "2.0.0")
    }

    // MARK: - ModuleProtocol Hashable Tests

    func testHashable_sameIdProducesSameHash() {
        let module1 = TestModule(id: "same-id")
        let module2 = TestModule(id: "same-id", name: "Different Name")

        XCTAssertEqual(module1.hashValue, module2.hashValue)
    }

    func testHashable_differentIdProducesDifferentHash() {
        let module1 = TestModule(id: "id-1")
        let module2 = TestModule(id: "id-2")

        XCTAssertNotEqual(module1.hashValue, module2.hashValue)
    }

    // MARK: - ModuleProtocol Equatable Tests

    func testEquatable_sameIdAreEqual() {
        let module1 = TestModule(id: "same-id")
        let module2 = TestModule(id: "same-id", name: "Different Name")

        XCTAssertEqual(module1, module2)
    }

    func testEquatable_differentIdAreNotEqual() {
        let module1 = TestModule(id: "id-1")
        let module2 = TestModule(id: "id-2")

        XCTAssertNotEqual(module1, module2)
    }

    // MARK: - SpecializedModule Wrapper Tests

    func testSpecializedModule_preservesId() {
        let original = TestModule(id: "original-id")
        let wrapped = SpecializedModule(original)

        XCTAssertEqual(wrapped.id, "original-id")
    }

    func testSpecializedModule_preservesName() {
        let original = TestModule(name: "Original Name")
        let wrapped = SpecializedModule(original)

        XCTAssertEqual(wrapped.name, "Original Name")
    }

    func testSpecializedModule_preservesShortDescription() {
        let original = TestModule(shortDescription: "Short desc")
        let wrapped = SpecializedModule(original)

        XCTAssertEqual(wrapped.shortDescription, "Short desc")
    }

    func testSpecializedModule_preservesLongDescription() {
        let original = TestModule(longDescription: "Long description text")
        let wrapped = SpecializedModule(original)

        XCTAssertEqual(wrapped.longDescription, "Long description text")
    }

    func testSpecializedModule_preservesIconName() {
        let original = TestModule(iconName: "custom.icon")
        let wrapped = SpecializedModule(original)

        XCTAssertEqual(wrapped.iconName, "custom.icon")
    }

    func testSpecializedModule_preservesThemeColor() {
        let original = TestModule(themeColor: .red)
        let wrapped = SpecializedModule(original)

        XCTAssertEqual(wrapped.themeColor, .red)
    }

    func testSpecializedModule_preservesFeatureFlags() {
        let original = FullFeaturedModule()
        let wrapped = SpecializedModule(original)

        XCTAssertTrue(wrapped.supportsTeamMode)
        XCTAssertTrue(wrapped.supportsSpeedTraining)
        XCTAssertTrue(wrapped.supportsCompetitionSim)
    }

    func testSpecializedModule_preservesVersion() {
        let original = FullFeaturedModule()
        let wrapped = SpecializedModule(original)

        XCTAssertEqual(wrapped.version, "2.0.0")
    }

    @MainActor
    func testSpecializedModule_makeRootView_works() {
        let original = TestModule()
        let wrapped = SpecializedModule(original)

        let view = wrapped.makeRootView()
        XCTAssertNotNil(view)
    }

    @MainActor
    func testSpecializedModule_makeDashboardView_works() {
        let original = TestModule()
        let wrapped = SpecializedModule(original)

        let view = wrapped.makeDashboardView()
        XCTAssertNotNil(view)
    }

    // MARK: - SpecializedModule Hashable Tests

    func testSpecializedModule_hashable_sameIdSameHash() {
        let module1 = SpecializedModule(TestModule(id: "same-id"))
        let module2 = SpecializedModule(TestModule(id: "same-id"))

        XCTAssertEqual(module1.hashValue, module2.hashValue)
    }

    func testSpecializedModule_hashable_differentIdDifferentHash() {
        let module1 = SpecializedModule(TestModule(id: "id-1"))
        let module2 = SpecializedModule(TestModule(id: "id-2"))

        XCTAssertNotEqual(module1.hashValue, module2.hashValue)
    }

    // MARK: - SpecializedModule Equatable Tests

    func testSpecializedModule_equatable_sameIdEqual() {
        let module1 = SpecializedModule(TestModule(id: "same-id"))
        let module2 = SpecializedModule(TestModule(id: "same-id"))

        XCTAssertEqual(module1, module2)
    }

    func testSpecializedModule_equatable_differentIdNotEqual() {
        let module1 = SpecializedModule(TestModule(id: "id-1"))
        let module2 = SpecializedModule(TestModule(id: "id-2"))

        XCTAssertNotEqual(module1, module2)
    }

    // MARK: - SpecializedModule Identifiable Tests

    func testSpecializedModule_identifiable_idIsCorrect() {
        let wrapped = SpecializedModule(TestModule(id: "my-id"))

        XCTAssertEqual(wrapped.id, "my-id")
    }

    // MARK: - Collection Usage Tests

    func testSpecializedModule_canBeStoredInSet() {
        let module1 = SpecializedModule(TestModule(id: "id-1"))
        let module2 = SpecializedModule(TestModule(id: "id-2"))
        let module3 = SpecializedModule(TestModule(id: "id-1"))  // Duplicate

        var set: Set<SpecializedModule> = []
        set.insert(module1)
        set.insert(module2)
        set.insert(module3)

        XCTAssertEqual(set.count, 2)  // Duplicate should not be added
    }

    func testSpecializedModule_canBeStoredInArray() {
        let modules = [
            SpecializedModule(TestModule(id: "id-1")),
            SpecializedModule(TestModule(id: "id-2")),
            SpecializedModule(FullFeaturedModule())
        ]

        XCTAssertEqual(modules.count, 3)
    }

    func testSpecializedModule_canBeUsedAsDictionaryKey() {
        let module1 = SpecializedModule(TestModule(id: "id-1"))
        let module2 = SpecializedModule(TestModule(id: "id-2"))

        var dict: [SpecializedModule: String] = [:]
        dict[module1] = "First"
        dict[module2] = "Second"

        XCTAssertEqual(dict[module1], "First")
        XCTAssertEqual(dict[module2], "Second")
    }

    // MARK: - Manifest-Derived Metadata Tests

    func testModule_idDerivesFromManifest() {
        let module = TestModule(id: "derived-id")
        XCTAssertEqual(module.id, "derived-id")
        XCTAssertEqual(module.id, module.manifest.id)
    }

    func testModule_nameDerivesFromManifest() {
        let module = TestModule(name: "Derived Name")
        XCTAssertEqual(module.name, "Derived Name")
        XCTAssertEqual(module.name, module.manifest.name)
    }

    func testModule_versionDerivesFromManifest() {
        let module = FullFeaturedModule()
        XCTAssertEqual(module.version, "2.0.0")
        XCTAssertEqual(module.version, module.manifest.version)
    }

    func testModule_teamModeDerivesFromCapability() {
        let team = TestModuleWithCapabilities(capabilities: ["team.sync"])
        XCTAssertTrue(team.supportsTeamMode)

        let noTeam = TestModuleWithCapabilities(capabilities: [])
        XCTAssertFalse(noTeam.supportsTeamMode)
    }

    func testSpecializedModule_preservesManifest() {
        let original = FullFeaturedModule()
        let wrapped = SpecializedModule(original)
        XCTAssertEqual(wrapped.manifest, original.manifest)
    }

    // MARK: - Lifecycle Default Tests

    @MainActor
    func testModule_lifecycleDefaults_areNoOps() async throws {
        let module = TestModule()
        // Default no-op lifecycle should complete without throwing. The host is
        // the shared ScriptedModuleHost harness (its former inline TestHost).
        let harness = ScriptedModuleHost.make()
        defer { harness.tearDown() }
        try await module.initialize(host: harness.host)
        await module.start()
        await module.pause()
        await module.resume()
        await module.stop()
    }

    // MARK: - Extra Test Types

    /// A module whose capabilities can be set directly, for capability-derived
    /// property tests.
    struct TestModuleWithCapabilities: ModuleProtocol {
        let manifest: ModuleManifest
        let shortDescription = "Caps"
        let longDescription = "Capability test module"
        let iconName = "star"
        let themeColor = Color.blue

        init(capabilities: Set<String>) {
            self.manifest = ModuleProtocolTests.makeManifest(
                id: "caps-\(capabilities.sorted().joined(separator: "-"))",
                capabilities: capabilities
            )
        }

        @MainActor func makeRootView() -> AnyView { AnyView(Text("Root")) }
        @MainActor func makeDashboardView() -> AnyView { AnyView(Text("Dash")) }
    }
}
