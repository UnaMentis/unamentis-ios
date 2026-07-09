// UnaMentis - Module Protocol
// Defines the interface for specialized training modules
//
// Modules are self-contained training systems that can be registered
// and discovered by the app. Each module provides its own views,
// session management, and progress tracking.
//
// This protocol is evolving toward the spec's `UnaMentisModule` contract
// (MODULE_SDK_SPEC.md section 4) without breaking existing modules. A module
// now declares a `ModuleManifest` (the single source of metadata truth) and
// gains async lifecycle hooks. The legacy display properties are derived from
// the manifest via a protocol extension, so metadata lives in one place.

import SwiftUI

/// Protocol defining a specialized training module
///
/// Modules are focused training systems for specific goals like
/// competition preparation or skill development. Each module:
/// - Declares a manifest (MODULE_SDK_SPEC.md section 3)
/// - Has its own root view and dashboard
/// - Participates in an async lifecycle (initialize/start/pause/resume/stop)
/// - Tracks progress independently
public protocol ModuleProtocol: Identifiable, Hashable, Sendable {
    /// The module's manifest: the single source of truth for its metadata,
    /// capabilities, surfaces, and host requirements.
    var manifest: ModuleManifest { get }

    /// Unique identifier for the module
    var id: String { get }

    /// Display name for the module
    var name: String { get }

    /// Brief description (1-2 sentences)
    var shortDescription: String { get }

    /// Detailed description for the module info page
    var longDescription: String { get }

    /// SF Symbol name for the module icon
    var iconName: String { get }

    /// Theme color for the module UI
    var themeColor: Color { get }

    /// Whether the module supports team/multiplayer mode
    var supportsTeamMode: Bool { get }

    /// Whether the module has speed training features
    var supportsSpeedTraining: Bool { get }

    /// Whether the module simulates competition scenarios
    var supportsCompetitionSim: Bool { get }

    /// Version of the module
    var version: String { get }

    // MARK: - Lifecycle (MODULE_SDK_SPEC.md section 4.1)
    //
    // Default no-op implementations are provided so existing modules adopt the
    // contract without change. The host parameter carries platform services;
    // it is a placeholder in Phase 1 (see ModuleHost).

    /// Called once per app launch before any UI. Receives all host services.
    func initialize(host: ModuleHost) async throws

    /// The module surface becomes active.
    func start() async

    /// The app was backgrounded or the session was interrupted.
    func pause() async

    /// Resume after a pause.
    func resume() async

    /// The module surface was dismissed; release resources.
    func stop() async

    /// Creates the root view for the module
    @MainActor
    func makeRootView() -> AnyView

    /// Creates the dashboard/summary view shown in the modules list
    @MainActor
    func makeDashboardView() -> AnyView
}

// MARK: - Default Implementations

extension ModuleProtocol {
    // Legacy display metadata derived from the manifest so it lives in ONE
    // place. A module that authors a manifest gets all of these for free.
    public var id: String { manifest.id }
    public var name: String { manifest.name }
    public var version: String { manifest.version }

    /// Team support is derived from the open capability set (`team.local` or
    /// `team.sync`) replacing the legacy standalone boolean.
    public var supportsTeamMode: Bool {
        manifest.capabilities.contains("team.local")
            || manifest.capabilities.contains("team.sync")
    }

    /// Speed training is derived from the `training.speed` capability.
    public var supportsSpeedTraining: Bool {
        manifest.capabilities.contains("training.speed")
    }

    /// Competition simulation is derived from the `sim.opponent` capability.
    public var supportsCompetitionSim: Bool {
        manifest.capabilities.contains("sim.opponent")
    }

    // Lifecycle default no-ops. Modules override only what they need.
    public func initialize(host: ModuleHost) async throws {}
    public func start() async {}
    public func pause() async {}
    public func resume() async {}
    public func stop() async {}

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Type-Erased Module

/// Type-erased wrapper for modules to enable storage in collections
public struct SpecializedModule: Identifiable, Hashable, Sendable {
    public let manifest: ModuleManifest
    public let id: String
    public let name: String
    public let shortDescription: String
    public let longDescription: String
    public let iconName: String
    public let themeColor: Color
    public let supportsTeamMode: Bool
    public let supportsSpeedTraining: Bool
    public let supportsCompetitionSim: Bool
    public let version: String

    private let _makeRootView: @MainActor @Sendable () -> AnyView
    private let _makeDashboardView: @MainActor @Sendable () -> AnyView

    public init<M: ModuleProtocol>(_ module: M) {
        self.manifest = module.manifest
        self.id = module.id
        self.name = module.name
        self.shortDescription = module.shortDescription
        self.longDescription = module.longDescription
        self.iconName = module.iconName
        self.themeColor = module.themeColor
        self.supportsTeamMode = module.supportsTeamMode
        self.supportsSpeedTraining = module.supportsSpeedTraining
        self.supportsCompetitionSim = module.supportsCompetitionSim
        self.version = module.version
        self._makeRootView = { @MainActor @Sendable in module.makeRootView() }
        self._makeDashboardView = { @MainActor @Sendable in module.makeDashboardView() }
    }

    @MainActor
    public func makeRootView() -> AnyView {
        _makeRootView()
    }

    @MainActor
    public func makeDashboardView() -> AnyView {
        _makeDashboardView()
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: SpecializedModule, rhs: SpecializedModule) -> Bool {
        lhs.id == rhs.id
    }
}
