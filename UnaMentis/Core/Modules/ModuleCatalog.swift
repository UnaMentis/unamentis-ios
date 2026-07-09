// UnaMentis - Module Catalog
// The single registration point for compiled-in first-party modules.
//
// This replaces the hardcoded `BundledModule.all` static array and the
// `moduleViewForId` switch that used to live in ModulesView. Per
// MODULE_SDK_SPEC.md sections 3.3 and 4.3, the catalog is the only host file a
// first-party module touches outside its own directory.

import SwiftUI

/// The single registration point for compiled-in first-party modules.
///
/// Adding a first-party module = one entry in `registeredModules`.
/// See MODULE_SDK_SPEC.md (sections 4.3 and 13, Phase 1).
///
/// Modules are filtered by host capability negotiation
/// (`HostCapabilities.supports`, section 3) so a module whose required host
/// capabilities this build lacks is hidden rather than launched into a gap.
@MainActor
public final class ModuleCatalog {
    /// Shared singleton.
    public static let shared = ModuleCatalog()

    /// The host service bundle injected into modules (MODULE_SDK_SPEC.md
    /// section 5). Constructed once by the catalog; module surfaces reach
    /// platform services (e.g. the voice pipeline) through this, never by
    /// instantiating audio primitives themselves.
    public let host: any ModuleHost = DefaultModuleHost()

    /// Every compiled-in first-party module. This is the one place to register.
    ///
    /// Adding a module here is the entire host-side change; the module's
    /// manifest and views live in the module's own directory.
    ///
    /// The template ExampleEchoModule is registered GATED: it compiles in only in
    /// DEBUG builds (feature-flag gating per MODULE_SDK_SPEC.md section 3, the
    /// same hook first-party rollouts use), so it never appears in a release.
    private let registeredModules: [any ModuleProtocol] = {
        var modules: [any ModuleProtocol] = [
            KnowledgeBowlModule(),
            QuizBowlModule(),
            OralExamModule(),
            AuralSkillsModule(),
            SATPrepModule()
        ]
        #if DEBUG
        modules.append(ExampleEchoModule())
        #endif
        return modules
    }()

    /// The modules visible in this build, after capability filtering.
    ///
    /// A module survives here only if `HostCapabilities.supports(manifest)` is
    /// true. Feature-flag gating hooks in here too as flags land (section 3).
    public private(set) var modules: [SpecializedModule]

    private init() {
        self.modules = registeredModules
            .filter { HostCapabilities.supports($0.manifest) }
            .map { SpecializedModule($0) }
    }

    /// The module with the given ID, or nil if unknown or filtered out.
    public func module(withId id: String) -> SpecializedModule? {
        modules.first { $0.id == id }
    }

    /// The root view for a module ID, or a fallback if the ID is unknown.
    ///
    /// Replaces the old `moduleViewForId` switch: the view now comes from the
    /// module's own `makeRootView()` rather than a hardcoded case.
    @MainActor
    public func rootView(for moduleId: String) -> AnyView {
        guard let module = module(withId: moduleId) else {
            return AnyView(
                ContentUnavailableView(
                    "Module Not Found",
                    systemImage: "questionmark.circle",
                    description: Text("This module is not available.")
                )
            )
        }
        return module.makeRootView()
    }
}
