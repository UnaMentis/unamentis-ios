// UnaMentis - Self-Hosted LLM Resolution From Reader Settings
//
// The single place the reading features resolve their self-hosted LLM from
// user settings. The barge-in Q&A path and the summary pre-generator must
// agree on this resolution: when they diverged, a user whose reader Q&A
// worked could silently never get summaries because each path read the
// settings its own way.
//
// Part of Services/LLM

import Foundation

extension SelfHostedLLMService {

    /// The self-hosted LLM configured in settings, or nil when self-hosted
    /// mode is disabled or no server address is set.
    ///
    /// Callers apply their own policy on nil: the summary pre-generator
    /// defers generation (retrying when a server appears), while the reader's
    /// Q&A path substitutes a default-host service so a tap always produces a
    /// response attempt.
    static func configuredReaderService() -> SelfHostedLLMService? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "selfHostedEnabled"),
              let host = defaults.string(forKey: "primaryServerIP"),
              !host.isEmpty else {
            return nil
        }
        return SelfHostedLLMService.ollama(host: host, model: RemoteLLMModel.current)
    }
}
