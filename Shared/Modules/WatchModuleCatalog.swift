// UnaMentis - Watch Module Catalog (Shared)
// The single source of truth for modules reachable on the watch surface.
//
// Why this exists (a Phase 1 decision, see MODULE_SDK_SPEC.md sections 8 and
// 13): the full iOS ModuleCatalog lives under UnaMentis/Core/Modules, which is
// NOT a source of the watchOS target (project.yml gives the watch target only
// `UnaMentis Watch App/` and `Shared/`). The iOS ModuleManifest also pulls in
// iOS-only host machinery. So the watch cannot import ModuleCatalog directly.
//
// Rather than hardcode a KB reference at the watch presentation site, the watch
// resolves its modules through this catalog. It is deliberately lightweight:
// per-module identity plus a root-view factory, one entry per watch-capable
// module. This file lives in Shared so the module identity list has one home
// reachable from both targets. The root-view factory references watch-only
// views, so the whole entry list is compiled only on watchOS; the iOS build
// sees the same identities via `moduleIds` without the watch views.
//
// When the SDK's cross-platform manifest sharing lands (spec Phase 7), this
// merges with the unified catalog. Until then this is the smallest correct way
// to make the watch route catalog-driven instead of hardcoded.

import SwiftUI

/// The IDs of modules that declare a watch surface. Available to both targets
/// so the watch-surface module set has one home. Matches manifest IDs
/// (MODULE_SDK_SPEC.md section 3).
enum WatchModuleIdentity {
    static let watchModuleIds: [String] = [
        "knowledge-bowl"
    ]
}

#if os(watchOS)

/// Identity plus entry point for a module on the watch surface.
@MainActor
struct WatchModuleEntry: Identifiable {
    /// Stable module ID. Matches the iOS manifest ID.
    let id: String

    /// Display name for the watch launch list.
    let name: String

    /// SF Symbol for the launch row.
    let iconName: String

    /// Builds the module's watch root view.
    @MainActor let makeRootView: () -> AnyView
}

/// The single registration point for watch-surface modules.
///
/// Adding a watch-capable module = one entry here (and its ID in
/// `WatchModuleIdentity`). Mirrors the iOS `ModuleCatalog`; see
/// MODULE_SDK_SPEC.md section 8.
@MainActor
enum WatchModuleCatalog {
    /// Every module that renders on the watch. One entry per module.
    static let entries: [WatchModuleEntry] = [
        WatchModuleEntry(
            id: "knowledge-bowl",
            name: "Knowledge Bowl",
            iconName: "brain.head.profile",
            makeRootView: { AnyView(KBWatchMainView()) }
        )
    ]

    /// The watch entry for a module ID, or nil if the module has no watch surface.
    static func entry(withId id: String) -> WatchModuleEntry? {
        entries.first { $0.id == id }
    }
}

#endif
