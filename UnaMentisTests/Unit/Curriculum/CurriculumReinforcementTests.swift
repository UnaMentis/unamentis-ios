// UnaMentis - Curriculum Reinforcement Material Tests
// Real Core Data tests covering the full path taken by curriculum-authored
// "back-pocket" material: UMCF parse, persistence as a reinforcement Document,
// CurriculumEngine mapping onto the FOV buffer types, and arrival in the
// FOV context working buffer that the LLM sees.

import XCTest
import CoreData
@testable import UnaMentis

final class CurriculumReinforcementTests: XCTestCase {

    // MARK: - Properties

    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!
    var parser: UMCFParser!
    var curriculumEngine: CurriculumEngine!

    // MARK: - Setup / Teardown

    @MainActor
    override func setUp() async throws {
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
        parser = UMCFParser(persistenceController: persistenceController)
        curriculumEngine = CurriculumEngine(persistenceController: persistenceController)
    }

    @MainActor
    override func tearDown() async throws {
        curriculumEngine = nil
        parser = nil
        context = nil
        persistenceController = nil
    }

    // MARK: - Fixture

    /// Compact UMCF document modeled on the schema at
    /// curriculum/spec/umcf-schema.json. It carries one topic with segment-level
    /// alternative explanations covering all four authored styles, one misconception
    /// with several trigger phrases, one misconception with no trigger phrases, and a
    /// second topic with no reinforcement material at all.
    private var fixtureJSON: String {
        """
        {
            "umcf": "1.0",
            "id": {"value": "reinforcement-fixture"},
            "title": "Reinforcement Fixture",
            "version": {"number": "1.0.0"},
            "content": [
                {
                    "id": {"value": "topic-neuron"},
                    "title": "The Artificial Neuron",
                    "type": "topic",
                    "description": "How a single artificial neuron computes an output.",
                    "transcript": {
                        "segments": [
                            {
                                "id": "seg-1",
                                "type": "explanation",
                                "content": "A neuron sums weighted inputs and applies an activation.",
                                "alternativeExplanations": [
                                    {
                                        "style": "simpler",
                                        "content": "Think of a neuron as a small voting machine."
                                    },
                                    {
                                        "style": "technical",
                                        "content": "y equals f of the sum of w sub i times x sub i plus b."
                                    }
                                ]
                            },
                            {
                                "id": "seg-2",
                                "type": "explanation",
                                "content": "Weights decide how much each input matters.",
                                "alternativeExplanations": [
                                    {
                                        "style": "analogy",
                                        "content": "Weights are how loudly each advisor speaks."
                                    },
                                    {
                                        "style": "example-based",
                                        "content": "Given inputs 2 and 3 with weights 0.5 and 1, the sum is 4."
                                    },
                                    {
                                        "content": "A neuron is a weighted vote with a threshold."
                                    }
                                ]
                            }
                        ]
                    },
                    "misconceptions": [
                        {
                            "id": "misc-brain",
                            "misconception": "Neural networks simulate how the brain actually works",
                            "triggerPhrases": ["just like the brain", "brain simulation"],
                            "correction": "They are mathematical abstractions inspired by neurons, not brain models.",
                            "spokenCorrection": "That is a common mix-up. They borrowed an idea from biology.",
                            "explanation": "The name invites the comparison.",
                            "severity": "moderate"
                        },
                        {
                            "id": "misc-linear",
                            "misconception": "A single neuron can separate any dataset",
                            "correction": "A single neuron only separates linearly separable data."
                        },
                        {
                            "id": "misc-incomplete",
                            "misconception": "This entry has no correction"
                        }
                    ]
                },
                {
                    "id": {"value": "topic-bare"},
                    "title": "A Topic Without Extras",
                    "type": "topic",
                    "description": "No reinforcement material authored here."
                }
            ]
        }
        """
    }

    // MARK: - Helpers

    @MainActor
    private func importFixture() async throws -> Curriculum {
        let document = try await parser.parse(data: Data(fixtureJSON.utf8))
        return try UMCFParser.importDocument(
            document,
            persistenceController: persistenceController
        )
    }

    @MainActor
    private func topic(_ curriculum: Curriculum, titled title: String) throws -> Topic {
        let topics = curriculum.topics?.array as? [Topic] ?? []
        let match = topics.first { $0.title == title }
        return try XCTUnwrap(match, "Expected a topic titled \(title)")
    }

    // MARK: - Parsing

    /// The parser reads triggerPhrases, the canonical UMCF field name, rather than
    /// silently dropping detection phrases.
    func testParse_readsCanonicalTriggerPhrasesField() async throws {
        let document = try await parser.parse(data: Data(fixtureJSON.utf8))
        let node = try XCTUnwrap(document.content.first)
        let misconception = try XCTUnwrap(node.misconceptions?.first)

        XCTAssertEqual(misconception.detectionPhrases, ["just like the brain", "brain simulation"])
        XCTAssertEqual(misconception.spokenCorrection, "That is a common mix-up. They borrowed an idea from biology.")
    }

    /// Alternative explanations are parsed off the transcript segments that carry them.
    func testParse_readsSegmentAlternativeExplanations() async throws {
        let document = try await parser.parse(data: Data(fixtureJSON.utf8))
        let node = try XCTUnwrap(document.content.first)
        let firstSegment = try XCTUnwrap(node.transcript?.segments?.first)

        XCTAssertEqual(firstSegment.alternativeExplanations?.count, 2)
        XCTAssertEqual(firstSegment.alternativeExplanations?.first?.style, "simpler")
    }

    // MARK: - Persistence

    /// Import writes a reinforcement Document holding the whole set, so the material
    /// lives in the store and survives across app launches.
    @MainActor
    func testImport_persistsReinforcementDocument() async throws {
        let curriculum = try await importFixture()
        let neuron = try topic(curriculum, titled: "The Artificial Neuron")

        let reinforcementDocs = neuron.documentSet.filter { $0.documentType == .reinforcement }
        XCTAssertEqual(reinforcementDocs.count, 1)

        let data = try XCTUnwrap(reinforcementDocs.first?.decodedReinforcement())
        XCTAssertEqual(data.alternativeExplanations.count, 5)
        // The entry missing a correction is dropped as unusable for remediation.
        XCTAssertEqual(data.misconceptions.count, 2)
        XCTAssertEqual(data.alternativeExplanations.first?.segmentId, "seg-1")
    }

    /// A topic whose UMCF node authored no reinforcement material gets no document,
    /// so empty blobs do not accumulate in the store.
    @MainActor
    func testImport_skipsDocumentWhenNoMaterialAuthored() async throws {
        let curriculum = try await importFixture()
        let bare = try topic(curriculum, titled: "A Topic Without Extras")

        XCTAssertTrue(bare.documentSet.allSatisfy { $0.documentType != .reinforcement })
        XCTAssertNil(bare.reinforcementData)
    }

    /// Re-fetching the topic from the store, rather than reusing the imported object
    /// graph, still yields the material. This is the property that makes it survive a
    /// relaunch.
    @MainActor
    func testImport_materialIsReadableFromAFreshFetch() async throws {
        _ = try await importFixture()

        let request: NSFetchRequest<Topic> = Topic.fetchRequest()
        request.predicate = NSPredicate(format: "sourceId == %@", "topic-neuron")
        let refetched = try XCTUnwrap(try context.fetch(request).first)

        let data = try XCTUnwrap(refetched.reinforcementData)
        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(data.misconceptions.first?.id, "misc-brain")
    }

    /// The reinforcement document carries no summary, so it never leaks into the
    /// reference excerpts that generateContext builds from summarized documents.
    @MainActor
    func testImport_reinforcementDocumentIsExcludedFromGeneratedContext() async throws {
        let curriculum = try await importFixture()
        let neuron = try topic(curriculum, titled: "The Artificial Neuron")
        let reinforcementDoc = try XCTUnwrap(
            neuron.documentSet.first { $0.documentType == .reinforcement }
        )

        XCTAssertNil(reinforcementDoc.summary)

        let generated = curriculumEngine.generateContext(for: neuron)
        XCTAssertFalse(generated.contains("Reinforcement:"))
    }

    // MARK: - Style Mapping

    /// UMCF's four authored styles map onto the buffer style enum, with example-based
    /// preserved rather than collapsed into another style.
    func testStyleMapping_coversAllAuthoredUMCFStyles() {
        XCTAssertEqual(AlternativeExplanation.Style.from(umcfStyle: "simpler"), .simpler)
        XCTAssertEqual(AlternativeExplanation.Style.from(umcfStyle: "technical"), .technical)
        XCTAssertEqual(AlternativeExplanation.Style.from(umcfStyle: "analogy"), .analogy)
        XCTAssertEqual(AlternativeExplanation.Style.from(umcfStyle: "example-based"), .exampleBased)
    }

    /// Hand-authored separator and casing variants normalize, and anything unknown or
    /// missing falls back to simpler so the authored content is still offered.
    func testStyleMapping_normalizesVariantsAndFallsBack() {
        XCTAssertEqual(AlternativeExplanation.Style.from(umcfStyle: "Example_Based"), .exampleBased)
        XCTAssertEqual(AlternativeExplanation.Style.from(umcfStyle: "example based"), .exampleBased)
        XCTAssertEqual(AlternativeExplanation.Style.from(umcfStyle: nil), .simpler)
        XCTAssertEqual(AlternativeExplanation.Style.from(umcfStyle: "storytelling"), .simpler)
    }

    // MARK: - Curriculum Engine

    @MainActor
    func testGetAlternativeExplanations_returnsAuthoredMaterialWithStyles() async throws {
        let curriculum = try await importFixture()
        let neuron = try topic(curriculum, titled: "The Artificial Neuron")

        let alternatives = curriculumEngine.getAlternativeExplanations(for: neuron)

        XCTAssertEqual(alternatives.count, 5)
        XCTAssertEqual(alternatives.map(\.style), [.simpler, .technical, .analogy, .exampleBased, .simpler])
        XCTAssertEqual(alternatives.first?.content, "Think of a neuron as a small voting machine.")
    }

    /// Each authored trigger phrase becomes its own trigger, all sharing the same
    /// misconception and remediation. In this voice-first app the voice-optimized
    /// spokenCorrection is preferred over the written correction when authored.
    @MainActor
    func testGetMisconceptionTriggers_expandsEachTriggerPhrase() async throws {
        let curriculum = try await importFixture()
        let neuron = try topic(curriculum, titled: "The Artificial Neuron")

        let triggers = curriculumEngine.getMisconceptionTriggers(for: neuron)

        let brainTriggers = triggers.filter {
            $0.misconception == "Neural networks simulate how the brain actually works"
        }
        XCTAssertEqual(brainTriggers.map(\.triggerPhrase), ["just like the brain", "brain simulation"])
        XCTAssertTrue(brainTriggers.allSatisfy {
            $0.remediation == "That is a common mix-up. They borrowed an idea from biology."
        })
    }

    /// A misconception with no authored trigger phrases still reaches the tutor, keyed
    /// on the misconception statement itself.
    @MainActor
    func testGetMisconceptionTriggers_fallsBackToStatementWhenNoPhrases() async throws {
        let curriculum = try await importFixture()
        let neuron = try topic(curriculum, titled: "The Artificial Neuron")

        let triggers = curriculumEngine.getMisconceptionTriggers(for: neuron)
        let linear = try XCTUnwrap(triggers.first { $0.misconception.contains("separate any dataset") })

        XCTAssertEqual(linear.triggerPhrase, linear.misconception)
        XCTAssertEqual(linear.remediation, "A single neuron only separates linearly separable data.")
    }

    /// An export that emits an empty canonical triggerPhrases array alongside a
    /// populated legacy trigger field keeps its authored phrases: the empty
    /// canonical array must not shadow the legacy one.
    func testDetectionPhrases_emptyCanonicalFallsThroughToLegacyTrigger() throws {
        let json = """
        {
            "id": "misc-legacy",
            "misconception": "Legacy formatted misconception",
            "triggerPhrases": [],
            "trigger": ["old style phrase"],
            "correction": "The corrected understanding."
        }
        """
        let misconception = try JSONDecoder().decode(
            UMCFMisconception.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(misconception.detectionPhrases, ["old style phrase"])
    }

    /// Under a tight token budget the misconception warnings render ahead of the
    /// alternative explanations, so remediation content is never displaced by
    /// fallback rephrasings.
    func testWorkingBufferRender_misconceptionsSurviveTightBudgetOverAlternatives() {
        let verboseAlternative = AlternativeExplanation(
            style: .simpler,
            content: String(repeating: "A long fallback rephrasing of the concept. ", count: 60)
        )
        let buffer = WorkingBuffer(
            topicTitle: "Budget Pressure",
            topicContent: "Content",
            learningObjectives: [],
            glossaryTerms: [],
            alternativeExplanations: [verboseAlternative],
            misconceptionTriggers: [
                MisconceptionTrigger(
                    triggerPhrase: "just like the brain",
                    misconception: "Neural networks simulate the brain",
                    remediation: "They borrow an idea from biology."
                )
            ]
        )

        let rendered = buffer.render(tokenBudget: 200)

        XCTAssertTrue(rendered.contains("Watch for these common misconceptions"))
        XCTAssertFalse(rendered.contains("Alternative explanations you can offer"))
    }

    @MainActor
    func testEngineAccessors_returnEmptyForTopicWithoutMaterial() async throws {
        let curriculum = try await importFixture()
        let bare = try topic(curriculum, titled: "A Topic Without Extras")

        XCTAssertTrue(curriculumEngine.getAlternativeExplanations(for: bare).isEmpty)
        XCTAssertTrue(curriculumEngine.getMisconceptionTriggers(for: bare).isEmpty)
    }

    // MARK: - Working Buffer Rendering

    /// The working buffer renders alternative explanations with their style label, so
    /// the material actually reaches the model rather than sitting unused in the buffer.
    func testWorkingBufferRender_includesAlternativeExplanations() {
        let buffer = WorkingBuffer(
            topicTitle: "Neurons",
            topicContent: "Weighted sums.",
            alternativeExplanations: [
                AlternativeExplanation(style: .analogy, content: "Advisors voting."),
                AlternativeExplanation(style: .exampleBased, content: "Inputs 2 and 3.")
            ]
        )

        let rendered = buffer.render(tokenBudget: 10_000)

        XCTAssertTrue(rendered.contains("Alternative explanations you can offer:"))
        XCTAssertTrue(rendered.contains("- [Analogy] Advisors voting."))
        XCTAssertTrue(rendered.contains("- [Example-based] Inputs 2 and 3."))
    }

    // MARK: - End to End

    /// The whole path: UMCF JSON, Core Data, CurriculumEngine, FOV coordinator, and
    /// finally the working context string handed to the LLM.
    @MainActor
    func testEndToEnd_authoredMaterialReachesFOVWorkingContext() async throws {
        let curriculum = try await importFixture()
        let neuron = try topic(curriculum, titled: "The Artificial Neuron")

        try curriculumEngine.loadCurriculum(try XCTUnwrap(curriculum.id))

        let coordinator = FOVSessionContextCoordinator(curriculumEngine: curriculumEngine)
        await coordinator.setCurrentTopic(neuron)

        let fovContext = await coordinator.contextManager.buildContext()

        XCTAssertTrue(fovContext.workingContext.contains("The Artificial Neuron"))
        XCTAssertTrue(fovContext.workingContext.contains("Think of a neuron as a small voting machine."))
        XCTAssertTrue(fovContext.workingContext.contains("Given inputs 2 and 3"))
        XCTAssertTrue(fovContext.workingContext.contains("just like the brain"))
        XCTAssertTrue(
            fovContext.workingContext.contains(
                "They are mathematical abstractions inspired by neurons, not brain models."
            )
        )
    }

    /// A topic with no authored material leaves the reinforcement sections out of the
    /// working context entirely.
    @MainActor
    func testEndToEnd_topicWithoutMaterialOmitsReinforcementSections() async throws {
        let curriculum = try await importFixture()
        let bare = try topic(curriculum, titled: "A Topic Without Extras")

        try curriculumEngine.loadCurriculum(try XCTUnwrap(curriculum.id))

        let coordinator = FOVSessionContextCoordinator(curriculumEngine: curriculumEngine)
        await coordinator.setCurrentTopic(bare)

        let fovContext = await coordinator.contextManager.buildContext()

        XCTAssertTrue(fovContext.workingContext.contains("A Topic Without Extras"))
        XCTAssertFalse(fovContext.workingContext.contains("Alternative explanations you can offer:"))
        XCTAssertFalse(fovContext.workingContext.contains("Watch for these common misconceptions:"))
    }
}
