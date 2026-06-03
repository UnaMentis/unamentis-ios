// UnaMentis - Barge-In Responder
// ==============================
//
// The single shared conversational barge-in layer. Every narrating surface
// (session conversation, direct-streaming lecture, reading list, ...) detects a
// barge-in the same way (BargeInDetector), transcribes the interrupting
// utterance, then hands the transcript here. This component classifies it once
// (BargeInClassifier) and runs the one engagement-response loop: lead with a
// filler, stream the LLM answer, speak it via TTS, then hand control back to the
// surface to resume narration.
//
// Surface-specific actions (execute a command, pause/resume narration, play an
// audio chunk through this surface's engine/player) are delegated, so there is
// exactly one conversational loop and N thin surface adapters, instead of a
// bespoke loop per surface. The responder is STT-free on purpose: transcription
// is surface- and environment-specific (and the on-device recognizer differs by
// surface), so the surface transcribes and passes the text in.

import Foundation

/// Surface-specific hooks the shared responder calls. A narrating view model
/// (on @MainActor) conforms and performs the actual side effects.
public protocol BargeInResponderDelegate: AnyObject, Sendable {
    /// The barge-in is an explicit command; execute it on this surface.
    func bargeInExecuteCommand(_ command: VoiceCommand) async
    /// An engagement response is about to start; pause narration.
    func bargeInWillRespond() async
    /// Play one response audio chunk through this surface's audio output.
    func bargeInPlay(_ chunk: TTSAudioChunk) async
    /// The engagement response finished; resume narration.
    func bargeInDidRespond(responseText: String) async
    /// Optional instant filler to play before the model's first tokens arrive.
    func bargeInFiller(forUtterance utterance: String) async -> TTSAudioChunk?
}

public actor BargeInResponder {
    /// Builds the system prompt for an engagement, given the user's utterance.
    public typealias SystemPromptBuilder = @Sendable (_ utterance: String) -> String

    private let classifier: BargeInClassifier
    private let validCommands: Set<VoiceCommand>?
    private let config: LLMConfig
    private let systemPrompt: SystemPromptBuilder
    private weak var delegate: BargeInResponderDelegate?

    /// - Parameters:
    ///   - validCommands: commands valid on this surface (nil = all). An
    ///     out-of-context command falls through to engagement.
    ///   - systemPrompt: builds the engagement system prompt from the utterance.
    public init(
        classifier: BargeInClassifier = BargeInClassifier(),
        validCommands: Set<VoiceCommand>? = nil,
        config: LLMConfig = .default,
        systemPrompt: @escaping SystemPromptBuilder
    ) {
        self.classifier = classifier
        self.validCommands = validCommands
        self.config = config
        self.systemPrompt = systemPrompt
    }

    public func setDelegate(_ delegate: BargeInResponderDelegate?) {
        self.delegate = delegate
    }

    /// Handle a confirmed barge-in given its transcript. Returns the
    /// classification so the surface can log/telemeter it.
    @discardableResult
    public func handle(
        transcript: String,
        llm: any LLMService,
        tts: any TTSService
    ) async -> BargeInClassification {
        let classification = await classifier.classify(transcript: transcript, validCommands: validCommands)
        switch classification {
        case let .command(command, _, _):
            await delegate?.bargeInExecuteCommand(command)
        case .engagement:
            await respondToEngagement(transcript: transcript, llm: llm, tts: tts)
        }
        return classification
    }

    private func respondToEngagement(transcript: String, llm: any LLMService, tts: any TTSService) async {
        await delegate?.bargeInWillRespond()

        // Lead with an instant filler so the user never perceives a gap while the
        // model produces its first tokens.
        if let filler = await delegate?.bargeInFiller(forUtterance: transcript) {
            await delegate?.bargeInPlay(filler)
        }

        let messages = [
            LLMMessage(role: .system, content: systemPrompt(transcript)),
            LLMMessage(role: .user, content: transcript)
        ]

        var responseText = ""
        do {
            let stream = try await llm.streamCompletion(messages: messages, config: config)
            for await token in stream {
                responseText += token.content
                if token.isDone { break }
            }
        } catch {
            // Best effort: fall through and resume even if the LLM failed.
        }

        if !responseText.isEmpty {
            do {
                let audio = try await tts.synthesize(text: responseText)
                for await chunk in audio where !chunk.audioData.isEmpty {
                    await delegate?.bargeInPlay(chunk)
                }
            } catch {
                // Best effort: resume even if TTS failed.
            }
        }

        await delegate?.bargeInDidRespond(responseText: responseText)
    }
}
