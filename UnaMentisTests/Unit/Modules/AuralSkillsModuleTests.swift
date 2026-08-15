// UnaMentis - Aural Skills Module Tests
// Covers the starter-pack generator expansion (counts, coverage, prompt
// buildability), the music evaluation profile (synonym hits AND confusable
// rejection, which is the pedagogically load-bearing property), and the
// drill session loop driven by the scripted voice session.

import XCTest
@testable import UnaMentis

@MainActor
final class AuralSkillsModuleTests: XCTestCase {

    private var harness: ScriptedModuleHost!

    override func setUp() {
        super.setUp()
        harness = ScriptedModuleHost.make()
    }

    override func tearDown() {
        harness?.tearDown()
        harness = nil
        super.tearDown()
    }

    private func loadItems() async throws -> [AuralItem] {
        try await AuralContentLoader.shared.items(host: harness.host)
    }

    // MARK: - Generator expansion

    func testStarterPackExpandsToExpectedCounts() async throws {
        let items = try await loadItems()

        var countsByKind: [String: Int] = [:]
        for item in items {
            countsByKind[item.kind, default: 0] += 1
        }

        XCTAssertEqual(countsByKind["interval"], 96, "12 intervals x styles x roots x difficulties")
        XCTAssertEqual(countsByKind["triad"], 20)
        XCTAssertEqual(countsByKind["tonality"], 10, "6 generated triads + 4 hand-authored melodies")
        XCTAssertEqual(countsByKind["cadence"], 8, "4 cadence types x 2 keys")
        XCTAssertEqual(countsByKind["solfege"], 14, "7 degrees x 2 keys")
        XCTAssertEqual(items.count, 148)
        XCTAssertGreaterThanOrEqual(items.count, 60, "Starter pack floor per the module plan")
    }

    func testIntervalCoverageAcrossStylesAndDifficulties() async throws {
        let items = try await loadItems()
        let intervals = items.filter { $0.kind == "interval" }

        let expectedPrimaries = AuralTheory.intervals.map(\.primary)
        for primary in expectedPrimaries {
            for style in ["melodic-asc", "melodic-desc", "harmonic"] {
                let matching = intervals.filter {
                    $0.answer.primary == primary && $0.prompt.synthesis.style == style
                }
                XCTAssertFalse(
                    matching.isEmpty,
                    "Interval '\(primary)' missing in style \(style)"
                )
            }
            let difficulties = Set(intervals.filter { $0.answer.primary == primary }.map(\.difficulty))
            XCTAssertGreaterThanOrEqual(
                difficulties.count, 2,
                "Interval '\(primary)' must exist at 2+ difficulties"
            )
        }
    }

    func testContentCoverageOfQualitiesCadencesAndDegrees() async throws {
        let items = try await loadItems()

        let triadPrimaries = Set(items.filter { $0.kind == "triad" }.map(\.answer.primary))
        XCTAssertEqual(triadPrimaries, ["major", "minor", "diminished", "augmented"])

        let cadencePrimaries = Set(items.filter { $0.kind == "cadence" }.map(\.answer.primary))
        XCTAssertEqual(cadencePrimaries, [
            "perfect cadence", "plagal cadence", "imperfect cadence", "interrupted cadence"
        ])

        let solfegePrimaries = Set(items.filter { $0.kind == "solfege" }.map(\.answer.primary))
        XCTAssertEqual(solfegePrimaries, ["do", "re", "mi", "fa", "sol", "la", "ti"])

        let tonalityPrimaries = Set(items.filter { $0.kind == "tonality" }.map(\.answer.primary))
        XCTAssertEqual(tonalityPrimaries, ["major", "minor"])
    }

    func testEveryItemHasUniqueIdAndBuildablePrompt() async throws {
        let items = try await loadItems()
        XCTAssertEqual(Set(items.map(\.id)).count, items.count, "Item ids must be unique")

        for item in items {
            let prompt = AuralPromptBuilder.prompt(for: item)
            XCTAssertNotNil(prompt, "Item \(item.id) has an unbuildable synthesis prompt")
            if let prompt {
                XCTAssertNoThrow(
                    try DefaultToneGenerationService.shared.render(prompt),
                    "Item \(item.id) fails to render"
                )
            }
            XCTAssertFalse(item.answer.primary.isEmpty)
            XCTAssertFalse(item.skills.isEmpty)
        }
    }

    func testPromptBuilderStylesShapeEvents() async throws {
        let items = try await loadItems()

        let ascending = try XCTUnwrap(items.first { $0.id == "interval-m3-asc-c4-d1" })
        let events = try XCTUnwrap(AuralPromptBuilder.prompt(for: ascending)).events
        XCTAssertEqual(events.count, 2)
        XCTAssertLessThan(events[0].pitches[0].midiNote, events[1].pitches[0].midiNote)

        let harmonic = try XCTUnwrap(items.first { $0.id == "interval-p5-harm-c4-d2" })
        let harmonicEvents = try XCTUnwrap(AuralPromptBuilder.prompt(for: harmonic)).events
        XCTAssertEqual(harmonicEvents.count, 1)
        XCTAssertEqual(harmonicEvents[0].pitches.count, 2)

        let cadence = try XCTUnwrap(items.first { $0.id == "cadence-perfect-c" })
        let cadenceEvents = try XCTUnwrap(AuralPromptBuilder.prompt(for: cadence)).events
        XCTAssertGreaterThanOrEqual(cadenceEvents.count, 2)
        XCTAssertTrue(cadenceEvents.allSatisfy { $0.pitches.count >= 3 })

        let solfege = try XCTUnwrap(items.first { $0.id == "solfege-5-c4-d2" })
        let solfegeEvents = try XCTUnwrap(AuralPromptBuilder.prompt(for: solfege)).events
        XCTAssertEqual(solfegeEvents.count, 2, "Tonic context chord, then the degree")
        XCTAssertEqual(solfegeEvents[0].pitches.count, 3, "Context is the tonic triad")
        XCTAssertEqual(solfegeEvents[1].pitches[0].midiNote, 67, "Sol above C4 is G4")
    }

    func testPackLoadsThroughContentStoreWithIntegrityCheck() async throws {
        // A fresh (uncached) loader stages the bundled pack and imports it
        // through THIS harness's ContentStore, so a wrong manifest hash or a
        // missing license would throw here.
        let loader = AuralContentLoader()
        let items = try await loader.items(host: harness.host)
        XCTAssertFalse(items.isEmpty)

        let handles = await harness.contentStore.packs(matching: PackQuery(schema: "aural-items/1"))
        XCTAssertTrue(
            handles.contains { $0.packId == AuralContentLoader.packId },
            "The starter pack must register through the ContentStore import path"
        )
    }

    // MARK: - Evaluation profile

    private func evaluate(_ response: String, item: AuralItem) async -> Bool {
        let result = await harness.evaluationService.evaluate(
            LearnerResponse(text: response),
            against: MusicEvaluation.spec(for: item)
        )
        return result.verdict == .correct
    }

    private func item(withId id: String) async throws -> AuralItem {
        let items = try await loadItems()
        return try XCTUnwrap(items.first { $0.id == id }, "Missing item \(id)")
    }

    func testSynonymProfileAcceptsEquivalentLabels() async throws {
        let minorThird = try await item(withId: "interval-m3-asc-c4-d1")
        for accepted in ["minor third", "m3", "minor 3rd", "flat third", "the minor third"] {
            let verdict = await evaluate(accepted, item: minorThird)
            XCTAssertTrue(verdict, "'\(accepted)' must be accepted for minor third")
        }

        let perfectCadence = try await item(withId: "cadence-perfect-c")
        for accepted in ["perfect cadence", "authentic cadence", "five one", "V I"] {
            let verdict = await evaluate(accepted, item: perfectCadence)
            XCTAssertTrue(verdict, "'\(accepted)' must be accepted for perfect cadence")
        }

        let interrupted = try await item(withId: "cadence-interrupted-c")
        let deceptive = await evaluate("deceptive cadence", item: interrupted)
        XCTAssertTrue(deceptive, "'deceptive cadence' must be accepted for interrupted cadence")

        let ti = try await item(withId: "solfege-7-c4-d2")
        for accepted in ["ti", "tee", "leading tone"] {
            let verdict = await evaluate(accepted, item: ti)
            XCTAssertTrue(verdict, "'\(accepted)' must be accepted for ti")
        }

        let sol = try await item(withId: "solfege-5-c4-d2")
        let soVerdict = await evaluate("so", item: sol)
        XCTAssertTrue(soVerdict, "'so' must be accepted for sol")

        let diminished = try await item(withId: "triad-diminished-harm-e4-d2")
        let dimVerdict = await evaluate("dim", item: diminished)
        XCTAssertTrue(dimVerdict, "'dim' must be accepted for diminished")
    }

    func testConfusableLabelsAreRejected() async throws {
        // False accepts teach the wrong ear; these are the load-bearing cases.
        let minorThird = try await item(withId: "interval-m3-asc-c4-d1")
        for wrong in ["major third", "minor second", "minor sixth", "perfect fourth"] {
            let verdict = await evaluate(wrong, item: minorThird)
            XCTAssertFalse(verdict, "'\(wrong)' must be REJECTED for minor third")
        }

        let perfectCadence = try await item(withId: "cadence-perfect-c")
        for wrong in ["imperfect cadence", "plagal cadence", "interrupted cadence", "half cadence"] {
            let verdict = await evaluate(wrong, item: perfectCadence)
            XCTAssertFalse(verdict, "'\(wrong)' must be REJECTED for perfect cadence")
        }

        let major = try await item(withId: "tonality-major-harm-c4-d1")
        let wrongQuality = await evaluate("minor", item: major)
        XCTAssertFalse(wrongQuality, "'minor' must be REJECTED for a major triad")

        let sol = try await item(withId: "solfege-5-c4-d2")
        let wrongDegree = await evaluate("la", item: sol)
        XCTAssertFalse(wrongDegree, "'la' must be REJECTED for sol")
    }

    // MARK: - Solfège policy (movable do)
    //
    // The chromatic syllables are DIFFERENT degrees, and telling them apart is
    // most of what this module teaches. Accepting one for its diatonic
    // neighbour trains exactly the confusion the drill exists to remove.

    func testLoweredThirdIsNeverAcceptedForTheMajorThirdDegree() async throws {
        let mi = try await item(withId: "solfege-3-c4-d2")

        let me = await evaluate("me", item: mi)
        XCTAssertFalse(
            me,
            "'me' is the LOWERED third (the module's own minor triad is do, me, sol), "
                + "so it must be REJECTED for mi"
        )

        // Phonetic spellings of mi itself stay accepted: they are STT
        // renderings of the same syllable, not a different degree.
        for accepted in ["mi", "mee", "mediant"] {
            let verdict = await evaluate(accepted, item: mi)
            XCTAssertTrue(verdict, "'\(accepted)' must still be accepted for mi")
        }
    }

    func testMiAndMeAreNotSynonymsInEitherDirection() {
        let forMi = MusicEvaluation.expandedAcceptable(primary: "mi", acceptable: [])
        XCTAssertFalse(
            forMi.contains { $0.lowercased() == "me" },
            "The lowered third must not be an acceptable answer for mi"
        )

        // The reverse matters too: a future item whose answer IS "me" must not
        // pick up "mi" through the synonym group.
        let forMe = MusicEvaluation.expandedAcceptable(primary: "me", acceptable: [])
        XCTAssertFalse(
            forMe.contains { $0.lowercased() == "mi" },
            "The major third must not be an acceptable answer for me"
        )

        // The minor triad still coaches the lowered third by name.
        let minor = AuralTheory.triadQuality(named: "minor")
        XCTAssertEqual(minor?.degrees, ["do", "me", "sol"])
    }

    func testRaisedFifthIsNeverAcceptedForTheLeadingTone() async throws {
        let ti = try await item(withId: "solfege-7-c4-d2")

        let si = await evaluate("si", item: ti)
        XCTAssertFalse(
            si,
            "This module is MOVABLE do, where si is the raised fifth, not the seventh degree"
        )

        // The module's own augmented triad is what makes si the raised fifth,
        // so accepting si for ti would contradict this table.
        let augmented = AuralTheory.triadQuality(named: "augmented")
        XCTAssertEqual(augmented?.degrees, ["do", "mi", "si"])

        let forTi = MusicEvaluation.expandedAcceptable(primary: "ti", acceptable: [])
        XCTAssertFalse(forTi.contains { $0.lowercased() == "si" })
    }

    // MARK: - Enharmonic spelling
    //
    // The sounding pitch was always right; the NOTE NAMES were not. Spelling
    // comes from the root's letter plus the interval's diatonic size, so a
    // major third above E is a G (G#), never an A (Ab).

    /// Every note name an item declares, prompt notes plus context chord plus
    /// progression stacks.
    private func allNoteNames(of item: AuralItem) -> [String] {
        let synthesis = item.prompt.synthesis
        return (synthesis.notes ?? [])
            + (synthesis.contextChord ?? [])
            + (synthesis.chords ?? []).flatMap { $0 }
    }

    /// Diatonic letter steps between two spelled notes.
    private func letterSteps(
        from lower: AuralTheory.SpelledNote,
        to upper: AuralTheory.SpelledNote
    ) -> Int {
        (upper.letterIndex + 7 * upper.octave) - (lower.letterIndex + 7 * lower.octave)
    }

    func testGeneratedIntervalNamesMatchTheirLabel() async throws {
        let items = try await loadItems()
        let intervals = items.filter { $0.kind == "interval" }
        XCTAssertFalse(intervals.isEmpty)

        for item in intervals {
            let interval = try XCTUnwrap(
                AuralTheory.intervals.first { $0.primary == item.answer.primary },
                "\(item.id) has no theory entry for '\(item.answer.primary)'"
            )
            let notes = try XCTUnwrap(item.prompt.synthesis.notes)
            XCTAssertEqual(notes.count, 2, "\(item.id) must declare exactly two notes")

            let lower = try XCTUnwrap(AuralTheory.spelledNote(notes[0]))
            let upper = try XCTUnwrap(AuralTheory.spelledNote(notes[1]))

            XCTAssertEqual(
                upper.midi - lower.midi, interval.semitones,
                "\(item.id) sounds \(notes[0]) to \(notes[1]), the wrong size for a \(interval.primary)"
            )
            XCTAssertEqual(
                letterSteps(from: lower, to: upper), interval.diatonicSteps,
                "\(item.id) is SPELLED \(notes[0]) to \(notes[1]), which is not a \(interval.primary)"
            )
        }
    }

    func testGeneratedTriadNamesMatchTheirQuality() async throws {
        let items = try await loadItems()
        let triads = items.filter {
            ($0.kind == "triad" || $0.kind == "tonality") && ($0.prompt.synthesis.notes?.count == 3)
        }
        XCTAssertFalse(triads.isEmpty)

        for item in triads {
            let notes = try XCTUnwrap(item.prompt.synthesis.notes)
            let spelled = try notes.map { try XCTUnwrap(AuralTheory.spelledNote($0)) }

            // Every triad quality is tertian, so the three members always sit
            // on the root letter, its third, and its fifth.
            XCTAssertEqual(
                spelled.map { letterSteps(from: spelled[0], to: $0) }, [0, 2, 4],
                "\(item.id) is spelled \(notes.joined(separator: ", ")), which is not a stack of thirds"
            )

            let offsets = spelled.map { $0.midi - spelled[0].midi }
            XCTAssertTrue(
                AuralTheory.triadQualities.contains { $0.semitoneOffsets == offsets },
                "\(item.id) sounds offsets \(offsets), which is no known triad quality"
            )
        }
    }

    func testGeneratedSolfegeNamesMatchTheirDegree() async throws {
        let items = try await loadItems()
        let solfege = items.filter { $0.kind == "solfege" }
        XCTAssertFalse(solfege.isEmpty)

        for item in solfege {
            let degree = try XCTUnwrap(
                AuralTheory.scaleDegrees.first { $0.syllable == item.answer.primary }
            )
            let context = try XCTUnwrap(item.prompt.synthesis.contextChord)
            let chord = try context.map { try XCTUnwrap(AuralTheory.spelledNote($0)) }
            let tonic = chord[0]

            XCTAssertEqual(
                chord.map { letterSteps(from: tonic, to: $0) }, [0, 2, 4],
                "\(item.id) context chord \(context.joined(separator: ", ")) is not a tertian triad"
            )
            XCTAssertEqual(chord.map { $0.midi - tonic.midi }, [0, 4, 7], "\(item.id) context is the major tonic triad")

            let targetNames = try XCTUnwrap(item.prompt.synthesis.notes)
            let target = try XCTUnwrap(AuralTheory.spelledNote(targetNames[0]))
            XCTAssertEqual(
                target.midi - tonic.midi, degree.semitonesAboveTonic,
                "\(item.id) sounds the wrong degree"
            )
            XCTAssertEqual(
                letterSteps(from: tonic, to: target), degree.diatonicSteps,
                "\(item.id) spells degree \(degree.number) on the wrong letter"
            )
        }
    }

    func testTransposedSpellingsComeFromTheRootsLetter() async throws {
        let items = try await loadItems()
        func notes(_ id: String) throws -> [String] {
            let item = try XCTUnwrap(items.first { $0.id == id }, "Missing item \(id)")
            return try XCTUnwrap(item.prompt.synthesis.notes)
        }

        // A major third above E is a G, not an A; a tritone is an augmented
        // fourth (an A), not a diminished fifth (a B).
        XCTAssertEqual(try notes("interval-maj3-asc-e4-d2"), ["E4", "G#4"])
        XCTAssertEqual(try notes("interval-tt-asc-e4-d2"), ["E4", "A#4"])
        XCTAssertEqual(try notes("interval-maj7-asc-e4-d2"), ["E4", "D#5"])

        // Sharp roots keep sharp spellings up the letter ladder.
        XCTAssertEqual(try notes("interval-maj2-harm-fs3-d3"), ["F#3", "G#3"])
        XCTAssertEqual(try notes("interval-maj3-harm-fs3-d3"), ["F#3", "A#3"])
        XCTAssertEqual(try notes("interval-maj6-harm-fs3-d3"), ["F#3", "D#4"])
        XCTAssertEqual(try notes("interval-maj7-harm-fs3-d3"), ["F#3", "E#4"])

        // Triads stack thirds, so an augmented fifth is a raised fifth letter.
        XCTAssertEqual(try notes("triad-major-harm-e4-d2"), ["E4", "G#4", "B4"])
        XCTAssertEqual(try notes("triad-augmented-harm-e4-d2"), ["E4", "G#4", "B#4"])
        XCTAssertEqual(try notes("triad-augmented-harm-a3-d2"), ["A3", "C#4", "E#4"])
    }

    func testGeneratedNamesRoundTripThroughTheHostToneParser() async throws {
        let items = try await loadItems()

        for item in items {
            for note in allNoteNames(of: item) {
                let spelled = try XCTUnwrap(
                    AuralTheory.spelledNote(note), "\(item.id): '\(note)' is not a note name"
                )
                XCTAssertLessThanOrEqual(
                    abs(spelled.accidental), AuralTheory.maxEmittableAccidental,
                    "\(item.id): '\(note)' needs a double accidental, which TonePitch cannot parse"
                )
                let pitch = try XCTUnwrap(
                    TonePitch(noteName: note), "\(item.id): '\(note)' is unparseable by TonePitch"
                )
                XCTAssertEqual(
                    pitch.midiNote, spelled.midi,
                    "\(item.id): '\(note)' sounds a different pitch through TonePitch than it spells"
                )
            }
        }
    }

    // MARK: - Repeat detection

    func testRepeatRequestDetection() {
        XCTAssertTrue(AuralDrill.isRepeatRequest("repeat"))
        XCTAssertTrue(AuralDrill.isRepeatRequest("Again"))
        XCTAssertTrue(AuralDrill.isRepeatRequest("play it again."))
        XCTAssertTrue(AuralDrill.isRepeatRequest("One more time"))
        XCTAssertFalse(AuralDrill.isRepeatRequest("minor third"))
        XCTAssertFalse(AuralDrill.isRepeatRequest("the answer is repeat maybe"))
    }

    // MARK: - Session loop (scripted voice)

    func testDrillSessionLoopEvaluatesRecordsAndReplaysOnRequest() async throws {
        let items = try await loadItems()
        let minorThird = try XCTUnwrap(items.first { $0.id == "interval-m3-asc-c4-d1" })
        let perfectFifth = try XCTUnwrap(items.first { $0.id == "interval-p5-asc-c4-d1" })

        let session = harness.voiceSession
        // Round 1: correct answer. Round 2: a repeat request, then a wrong answer.
        await session.enqueueTranscripts(["minor third", "repeat", "octave"])

        let result = try await AuralDrill.run(
            moduleId: "aural-skills",
            host: harness.host,
            session: session,
            area: .intervals,
            rounds: 2,
            claimedCommands: [.quit, .skip, .repeatLast],
            shuffle: false,
            overrideItems: [minorThird, perfectFifth]
        )

        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.attemptsEvaluated, 2)

        // Attempts recorded with the right outcomes, namespaced to the module.
        let export = await harness.progressStore.exportAll(for: "aural-skills")
        XCTAssertEqual(export.attempts.count, 2)
        XCTAssertEqual(export.attempts.filter(\.correct).count, 1)
        XCTAssertEqual(Set(export.attempts.map(\.itemId)), [minorThird.id, perfectFifth.id])

        // Mastery observations landed in the unified model.
        let proficiency = await harness.progressStore.proficiency(
            for: AuralSkillArea.intervals.domain
        )
        XCTAssertEqual(proficiency.observationCount, 2)

        // module.attempt telemetry per attempt.
        let attemptEvents = await harness.telemetryRecorder.attemptCount(module: "aural-skills")
        XCTAssertGreaterThanOrEqual(attemptEvents, 2)

        // Cues for both outcomes.
        let cues = await session.playedCues
        XCTAssertTrue(cues.contains(.correct))
        XCTAssertTrue(cues.contains(.incorrect))

        // The tone prompt played once for round 1, and for round 2: once as
        // the prompt, once for the honored repeat request, and once in the
        // wrong-answer feedback replay.
        let spoken = await session.spokenTexts
        let tonePlays = spoken.filter { $0 == "Here is the sound." }.count
        XCTAssertEqual(tonePlays, 4, "Repeat and wrong-answer feedback must replay the prompt")

        // Wrong answers get the coaching line from item data.
        XCTAssertTrue(
            spoken.contains { $0.contains("do to sol") },
            "Solfège coaching must be spoken after a wrong answer"
        )
        // And the round summary was spoken.
        XCTAssertTrue(spoken.contains { $0.contains("1 out of 2 correct") })
    }

    func testDrillHonorsInjectedQuitCommand() async throws {
        let items = try await loadItems()
        let pool = Array(items.prefix(3))

        let session = harness.voiceSession
        await session.injectCommand(.quit)

        let result = try await AuralDrill.run(
            moduleId: "aural-skills",
            host: harness.host,
            session: session,
            area: .intervals,
            rounds: 3,
            claimedCommands: [.quit, .skip, .repeatLast],
            shuffle: false,
            overrideItems: pool
        )

        XCTAssertTrue(result.completed)
        XCTAssertTrue(result.commandsHonored.contains(.quit))
        // The quit may land before the first round or after one echo-mode
        // attempt depending on task scheduling; it must end the drill early.
        XCTAssertLessThanOrEqual(result.attemptsEvaluated, 1, "Quit must end the drill early")
    }

    func testMasteryLadderSelectsEasyItemsForNewLearners() async throws {
        // A fresh store has no observations, so the pool must be easy-only.
        let pool = try await AuralDrill.selectPool(
            host: harness.host, area: .intervals, shuffle: false
        )
        XCTAssertFalse(pool.isEmpty)
        XCTAssertTrue(
            pool.allSatisfy { $0.difficulty == 1 },
            "Below the mastery threshold the drill stays on easy items"
        )

        // Report strong mastery, then expect the mixed pool.
        for _ in 0..<10 {
            await harness.progressStore.reportMastery(MasteryObservation(
                module: "aural-skills",
                domain: AuralSkillArea.intervals.domain,
                signal: 100
            ))
        }
        let mixedPool = try await AuralDrill.selectPool(
            host: harness.host, area: .intervals, shuffle: false
        )
        XCTAssertTrue(
            Set(mixedPool.map(\.difficulty)).count > 1,
            "Above the mastery threshold the drill mixes difficulties"
        )
    }

    // MARK: - Pack verification is enforced, not advisory

    /// The harness host with a substituted ContentStore, so the loader's
    /// verification policy can be driven directly.
    private func host(content: any ContentStoreService) -> any ModuleHost {
        AuralTestHost(
            voice: harness.host.voice,
            telemetry: harness.host.telemetry,
            progress: harness.host.progress,
            content: content,
            evaluation: harness.host.evaluation,
            sessionRegistration: harness.sessionRegistrationService
        )
    }

    func testIntegrityFailureIsFatalAndNeverFallsBackToADirectDecode() async throws {
        let mismatch = ContentStoreError.integrityMismatch(expected: "expected", actual: "actual")
        let loader = AuralContentLoader()

        do {
            _ = try await loader.items(
                host: host(content: ScriptedFailingContentStore(failure: .store(mismatch)))
            )
            XCTFail("A pack that fails its integrity check must not load")
        } catch let error as ContentStoreError {
            XCTAssertEqual(error, mismatch)
        }

        let reason = await loader.fallbackReason
        XCTAssertNil(reason, "An integrity failure must never reach the direct-decode fallback")
    }

    func testLicenseFailureIsFatal() async throws {
        let loader = AuralContentLoader()
        do {
            _ = try await loader.items(
                host: host(content: ScriptedFailingContentStore(failure: .store(.licenseMissing)))
            )
            XCTFail("A pack with no license must not load")
        } catch let error as ContentStoreError {
            XCTAssertEqual(error, .licenseMissing)
        }
    }

    func testUnavailableImportSeamFallsBackAndRecordsWhy() async throws {
        // A genuinely different condition: the host's store cannot import at
        // all. The offline drill still runs, and the bypass is recorded.
        let loader = AuralContentLoader()
        let items = try await loader.items(
            host: host(content: ScriptedFailingContentStore(failure: .seamUnavailable))
        )
        XCTAssertFalse(items.isEmpty)

        let reason = await loader.fallbackReason
        XCTAssertNotNil(reason, "A fallback must be recorded, never silent")
    }

    func testVerifiedPathRecordsNoFallback() async throws {
        let loader = AuralContentLoader()
        _ = try await loader.items(host: harness.host)
        let reason = await loader.fallbackReason
        XCTAssertNil(reason, "The real ContentStore import path is the verified path")
    }

    // MARK: - Malformed packs are surfaced, not silently shortened

    func testPackEntryCarryingNeitherItemNorTemplateIsRejected() {
        XCTAssertThrowsError(
            try JSONDecoder().decode([AuralPackEntry].self, from: Data("[{}]".utf8))
        ) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("Expected a dataCorrupted decoding error, got \(error)")
            }
        }

        // A typo'd key is the realistic form of the same bug.
        let typo = Data(#"[{"tempate":{"kind":"interval","roots":["C4"],"difficulty":1}}]"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode([AuralPackEntry].self, from: typo))
    }

    func testWellFormedPackEntriesStillDecode() throws {
        let json = Data(#"[{"template":{"kind":"interval","roots":["C4"],"difficulty":1}}]"#.utf8)
        let entries = try JSONDecoder().decode([AuralPackEntry].self, from: json)
        XCTAssertEqual(entries.count, 1)
        XCTAssertNotNil(entries[0].template)
        XCTAssertNil(entries[0].item)
    }

    func testUnknownTemplateKindIsSurfaced() {
        let template = AuralItemTemplate(kind: "polyrhythm", roots: ["C4"], difficulty: 1)
        XCTAssertThrowsError(try AuralItemGenerator.expand(template)) { error in
            XCTAssertEqual(error as? AuralSkillsError, .unknownTemplateKind("polyrhythm"))
        }
    }

    func testUnknownTemplateValuesAndUnplayableRootsAreSurfaced() {
        XCTAssertThrowsError(
            try AuralItemGenerator.expand(AuralItemTemplate(
                kind: "interval", intervals: ["m9"], roots: ["C4"], difficulty: 1
            ))
        ) { error in
            XCTAssertEqual(
                error as? AuralSkillsError, .unknownTemplateValue(field: "interval", value: "m9")
            )
        }

        XCTAssertThrowsError(
            try AuralItemGenerator.expand(AuralItemTemplate(
                kind: "triad", qualities: ["mixolydian"], roots: ["C4"], difficulty: 1
            ))
        ) { error in
            XCTAssertEqual(
                error as? AuralSkillsError, .unknownTemplateValue(field: "quality", value: "mixolydian")
            )
        }

        XCTAssertThrowsError(
            try AuralItemGenerator.expand(AuralItemTemplate(
                kind: "interval", intervals: ["P5"], roots: ["H4"], difficulty: 1
            ))
        ) { error in
            XCTAssertEqual(error as? AuralSkillsError, .unplayableRoot("H4"))
        }
    }
}

// MARK: - Test Seams

/// A ContentStore that reports a chosen failure from every access, so the
/// loader's verification policy is driven directly rather than by corrupting
/// the app bundle. Not a mock of a paid external API: the content store is an
/// internal host service, and everything else in these tests is the real one.
private struct ScriptedFailingContentStore: ContentStoreService {
    /// Whether the store REACHED the pack and rejected it, or could not run
    /// the import path at all. The loader must treat these differently.
    enum Failure: Error, Sendable, Equatable {
        case store(ContentStoreError)
        case seamUnavailable
    }

    let failure: Failure

    /// The error every access throws.
    private var thrown: any Error {
        switch failure {
        case .store(let error): return error
        case .seamUnavailable: return failure
        }
    }

    func packs(matching query: PackQuery) async -> [ContentPackHandle] { [] }

    func download(_ packId: String) async throws -> ContentPackHandle { throw thrown }

    func importPack(from url: URL) async throws -> ContentPackHandle { throw thrown }

    func items<T: PackItem>(
        _ type: T.Type, from handle: ContentPackHandle, query: ItemQuery
    ) async throws -> [T] {
        throw thrown
    }
}

/// The harness services with one substituted, for tests that need to vary a
/// single host service.
private struct AuralTestHost: ModuleHost {
    let voice: any VoiceSessionService
    let telemetry: any ModuleTelemetryService
    let progress: any ProgressStoreService
    let content: any ContentStoreService
    let evaluation: any ResponseEvaluationService
    private let _sessionRegistration: any SessionRegistrationService

    init(
        voice: any VoiceSessionService,
        telemetry: any ModuleTelemetryService,
        progress: any ProgressStoreService,
        content: any ContentStoreService,
        evaluation: any ResponseEvaluationService,
        sessionRegistration: any SessionRegistrationService
    ) {
        self.voice = voice
        self.telemetry = telemetry
        self.progress = progress
        self.content = content
        self.evaluation = evaluation
        self._sessionRegistration = sessionRegistration
    }

    @MainActor var sessionRegistration: any SessionRegistrationService {
        _sessionRegistration
    }
}
