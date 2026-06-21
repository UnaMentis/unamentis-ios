// UnaMentis - Remote LLM Model Default (single source of truth)
// =============================================================
//
// One place to set the app's default REMOTE LLM model. Every remote LLM call
// site resolves its model through `RemoteLLMModel.current`, and the Settings
// pickers default to `RemoteLLMModel.defaultModel`, so changing the app-wide
// default is a one-line edit here.
//
// This is the seam the planned multi-tier model router will grow from: a
// use-case-driven selection across 2 to 4 models (the server model, an on-device
// model, and 1 to 2 frontier lab models) chosen for token efficiency without
// giving up needed capability when it matters. Individual features may override
// the model, but the default lives here.

import Foundation

public enum RemoteLLMModel {
    /// UserDefaults / `@AppStorage` key holding a user or Settings override.
    public static let defaultsKey = "llmModel"

    /// The app-wide default remote model. Change this one line to change the
    /// default everywhere. Must match what the server currently serves (see
    /// docs/reviews/USM_CORE_RELIABILITY_AUDIT_2026-06-04.md in the server repo).
    public static let defaultModel = "qwen2.5:14b-instruct"

    /// Fallback option list for the self-hosted model picker, used only when live
    /// discovery from the server returns nothing. The default is listed first.
    public static let selfHostedFallbackModels = [
        defaultModel, "qwen2.5:32b", "qwen2.5:7b", "llama3.2:3b", "mistral:7b"
    ]

    /// The effective remote model: a non-empty user/Settings override if set,
    /// otherwise `defaultModel`. This is what remote LLM call sites should use.
    public static var current: String {
        let override = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        return override.isEmpty ? defaultModel : override
    }
}
