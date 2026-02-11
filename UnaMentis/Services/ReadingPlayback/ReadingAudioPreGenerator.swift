// UnaMentis - Reading Audio Pre-Generator
// Background TTS synthesis for first chunk at import time
//
// Pre-generates audio for chunk 0 so playback starts instantly when
// the user hits play. If the user starts playback while generation is
// still in progress, the playback service waits for the in-progress
// task rather than starting a duplicate synthesis.
//
// Part of Services/ReadingPlayback

import Foundation
import CoreData
import Logging

// MARK: - Reading Audio Pre-Generator

/// Actor that pre-generates TTS audio for the first chunk of reading list items.
///
/// Triggered after document import, runs in the background. The playback path
/// checks for cached audio and coordinates with in-progress generation to avoid
/// duplicate work.
///
/// Audio is stored as raw PCM Float32 data on the ReadingChunk entity.
/// TODO: Migrate to Opus encoding when project-wide Opus codec is implemented.
public actor ReadingAudioPreGenerator {

    /// Shared singleton instance
    public static let shared = ReadingAudioPreGenerator()

    private let logger = Logger(label: "com.unamentis.reading.audio.pregen")

    /// In-progress generation tasks keyed by item ID.
    /// Callers can await the task value to wait for completion.
    private var inProgressTasks: [UUID: Task<Data?, Never>] = [:]

    private init() {}

    // MARK: - Pre-generation

    /// Pre-generate TTS audio for the first chunk of a reading item.
    /// Runs in the background and stores the result on the Core Data entity.
    ///
    /// - Parameters:
    ///   - itemId: The reading item's UUID
    ///   - chunkText: The text of chunk 0 to synthesize
    ///   - persistenceController: Core Data persistence for saving the result
    public func preGenerateFirstChunk(
        itemId: UUID,
        chunkText: String,
        persistenceController: PersistenceController
    ) {
        // Don't duplicate if already generating
        guard inProgressTasks[itemId] == nil else {
            logger.debug("Pre-generation already in progress for \(itemId)")
            return
        }

        logger.info("Starting pre-generation for item \(itemId)")

        let task = Task<Data?, Never> { [weak self] in
            guard let self else { return nil }

            do {
                let audioData = await self.synthesizeChunk(text: chunkText)

                if let audioData {
                    // Store on the Core Data entity
                    await self.storeCachedAudio(
                        audioData,
                        itemId: itemId,
                        persistenceController: persistenceController
                    )
                    await self.logger.info(
                        "Pre-generation complete for \(itemId), \(audioData.count) bytes"
                    )
                } else {
                    await self.markPreGenFailed(
                        itemId: itemId,
                        persistenceController: persistenceController
                    )
                    await self.logger.warning("Pre-generation failed for \(itemId)")
                }

                // Clean up tracking
                await self.removeTask(itemId: itemId)
                return audioData

            } catch {
                await self.markPreGenFailed(
                    itemId: itemId,
                    persistenceController: persistenceController
                )
                await self.removeTask(itemId: itemId)
                return nil
            }
        }

        inProgressTasks[itemId] = task
    }

    /// Wait for an in-progress pre-generation to complete.
    /// Returns the audio data if generation succeeds, nil otherwise.
    /// Returns nil immediately if no generation is in progress.
    public func waitForPreGeneration(itemId: UUID) async -> Data? {
        guard let task = inProgressTasks[itemId] else {
            return nil
        }
        return await task.value
    }

    /// Check if pre-generation is currently in progress for an item
    public func isGenerating(itemId: UUID) -> Bool {
        inProgressTasks[itemId] != nil
    }

    // MARK: - Private

    private func removeTask(itemId: UUID) {
        inProgressTasks.removeValue(forKey: itemId)
    }

    /// Synthesize audio for a chunk of text using the on-device TTS
    private func synthesizeChunk(text: String) async -> Data? {
        // Use Pocket TTS with user's settings for consistency with playback
        let ttsService = KyutaiPocketTTSService(config: .fromUserDefaults())

        do {
            // Ensure the model is loaded
            try await ttsService.ensureLoaded()

            // Synthesize and collect all audio segments
            let audioStream = try await ttsService.synthesize(text: text)
            var allAudioData = Data()
            var sampleRate: Double = 24000 // Default Pocket TTS rate

            for await audioChunk in audioStream {
                allAudioData.append(audioChunk.audioData)

                // Capture sample rate from the format
                if case .pcmFloat32(let rate, _) = audioChunk.format {
                    sampleRate = rate
                }
            }

            guard !allAudioData.isEmpty else {
                logger.warning("TTS produced empty audio")
                return nil
            }

            logger.debug("Synthesized \(allAudioData.count) bytes at \(sampleRate)Hz")
            return allAudioData
        } catch {
            logger.error("TTS synthesis failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Store pre-generated audio data on the ReadingChunk entity
    private func storeCachedAudio(
        _ audioData: Data,
        itemId: UUID,
        persistenceController: PersistenceController
    ) async {
        await MainActor.run {
            let context = persistenceController.viewContext

            // Find the reading item and its first chunk
            let request = ReadingListItem.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", itemId as CVarArg)
            request.fetchLimit = 1

            guard let item = try? context.fetch(request).first else {
                return
            }

            // Get chunk 0
            guard let firstChunk = item.chunksArray.first, firstChunk.index == 0 else {
                return
            }

            // Store the audio data
            firstChunk.cachedAudioData = audioData
            firstChunk.cachedAudioSampleRate = 24000 // Pocket TTS output rate

            // Update item status
            item.audioPreGenStatus = .ready

            try? persistenceController.save()
        }
    }

    /// Mark pre-generation as failed on the item
    private func markPreGenFailed(
        itemId: UUID,
        persistenceController: PersistenceController
    ) async {
        await MainActor.run {
            let context = persistenceController.viewContext
            let request = ReadingListItem.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", itemId as CVarArg)
            request.fetchLimit = 1

            guard let item = try? context.fetch(request).first else { return }
            item.audioPreGenStatus = .failed
            try? persistenceController.save()
        }
    }
}
