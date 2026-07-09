# Authoring a UnaMentis Module (iOS)

This is the practical, iOS-specific guide to writing a learning module. The
normative contract is [`MODULE_SDK_SPEC.md`](/Users/ramerman/dev/unamentis/docs/modules/MODULE_SDK_SPEC.md)
in the main repo; when this guide and the spec disagree, the spec wins. Read this
alongside the tutorial module, `UnaMentis/Modules/Template/ExampleEchoModule.swift`,
which is the smallest complete module and is annotated section by section.

A module is a self-contained learning experience with its own manifest, entry
points, and progress. It never owns audio, evaluation, storage, or telemetry: it
consumes those from the host. This is the whole point of the SDK, so a module
stays small and the platform improvements reach every module at once.

Writing style note for anything you add to the codebase: never use em dashes or
en dashes as sentence interrupters (see `.claude/rules/writing-style.md`).

## 1. Directory layout

A first-party module lives in one directory under `UnaMentis/Modules/<Name>/` and
touches exactly one host file outside it (the catalog registration line).

```
UnaMentis/Modules/MyModule/
  MyModule.swift                 // the module: manifest, lifecycle, view factories
  MyModule+Conformance.swift     // ConformanceDrivable adoption (voice-first modules)
  MyModuleViews.swift            // SwiftUI surface (optional split)
```

Model/service code a module needs may live under `Core/` and `Services/` (Knowledge
Bowl does this), but the module's own identity and wiring stay in its directory.
New `.swift` files under `UnaMentis/` are picked up automatically by XcodeGen; run
`xcodegen generate` after adding files, then `/validate`.

## 2. The manifest

Every module declares a `ModuleManifest` (spec section 3). It is the single source
of truth for identity, capabilities, surfaces, and host requirements. The legacy
display properties (`id`, `name`, `version`, the capability booleans) are derived
from it by the `ModuleProtocol` extension, so metadata lives in exactly one place.

```swift
public let manifest = ModuleManifest(
    specVersion: "0.1.0",
    id: "com.unamentis.mymodule",     // reverse-DNS, unique, STABLE FOREVER (namespaces progress)
    name: "My Module",
    version: "1.0.0",                 // semver MAJOR.MINOR.PATCH
    engine: .custom,                  // .quizMatch / .oralExam / .drill / .custom
    surfaces: [.phone],               // phone required; add .watch / .audioOnly as supported
    capabilities: [],                 // open, namespaced module-feature set
    requiresHostCapabilities: [       // versioned host capabilities you cannot run without
        "voice.session/1", "eval.text-fuzzy/1", "progress/1", "telemetry/1"
    ],
    optionalHostCapabilities: [],     // used when present, degrade gracefully without
    voiceCoverage: VoiceCoverage(declared: 1.0),  // honest 0...1 estimate
    serverTiers: [0],                 // Tier 0 (offline) is mandatory
    locales: ["en-US"],               // at least one; all must resolve
    contentPacks: ContentPacks(bundled: [], compatibleSchemas: []),
    privacy: Privacy(collectsAudio: true, storesTranscripts: false, sharesWithMentor: .never),
    minPlatform: MinPlatform(ios: "18.0")
)
```

Key rules the conformance suite enforces (UM-Core): `id` is a nonempty slug,
`version` is semver, `surfaces` contains `.phone`, `voiceCoverage.declared` is in
`0...1`, `serverTiers` contains `0`, and `locales` is nonempty.

### Host capability negotiation

`requiresHostCapabilities` is how a module tells the app what it needs. The catalog
hides a module whose required capabilities the build does not provide (spec section
3, "requires app update"). The build's provided set is `HostCapabilities.provided`
in `UnaMentis/Core/Modules/ModuleManifest.swift`. This build advertises, among
others: `voice.session/1`, `eval.text-exact/1`, `eval.text-fuzzy/1`, `eval.numeric/1`,
`eval.choice/1`, `progress/1`, `proficiency/1`, `telemetry/1`, `content.canonical-question/1`,
`session.registration/1`, `flags/1`. Do not require a capability the build does not
advertise, or your module will be gated out and unshippable. If you need a new one,
follow the RFC process (section 8).

## 3. Catalog registration

The catalog is the one host file a module touches. Add one line to
`registeredModules` in `UnaMentis/Core/Modules/ModuleCatalog.swift`:

```swift
private let registeredModules: [any ModuleProtocol] = {
    var modules: [any ModuleProtocol] = [
        KnowledgeBowlModule(),
    ]
    #if DEBUG
    modules.append(ExampleEchoModule())   // DEBUG-gated example; release-gate real modules similarly
    #endif
    return modules
}()
```

Capability filtering (`HostCapabilities.supports`) and feature-flag gating happen
here, so a module can be compiled in but hidden until its capabilities exist or a
flag turns it on.

## 4. Lifecycle and surfaces

A module conforms to `ModuleProtocol` (the app's current form of the spec's
`UnaMentisModule`, section 4.1). Lifecycle hooks default to no-ops via a protocol
extension, so override only what you need:

```swift
public func initialize(host: ModuleHost) async throws { /* stash host services */ }
public func start() async  { }   // surface became active
public func pause() async  { }   // app backgrounded / interrupted
public func resume() async { }
public func stop() async   { }   // surface dismissed; release resources (idempotent)

@MainActor public func makeRootView() -> AnyView { AnyView(MyRootView()) }
@MainActor public func makeDashboardView() -> AnyView { AnyView(MyDashboard()) }
```

`initialize(host:)` is called once before any UI, handing you the host service
bundle. A double `stop()` must be tolerated (UM-Core checks this).

## 5. Host services (spec section 5)

You reach every platform service through the `ModuleHost` passed to `initialize`.
One-line examples of each service this build ships:

```swift
// Voice (5.1): the ONE pipeline. Acquire exclusively, speak/listen, never own audio.
let session = try await host.voice.acquire(config: VoicePipelineConfig())
try await session.speak(.text("Say this word back."))
let heard = try await session.listen(expecting: .answer)   // heard.transcript
await session.playCue(.correct)                            // earcon + haptic
// The HOST owns acquire/release; do not release a session you did not acquire.

// Evaluation (5.2): supply a spec, the host owns the matching algorithm.
let spec = EvaluationSpec(primaryAnswer: "apple",
                          strictness: StrictnessProfile(id: "std", level: .standard),
                          evaluatorTiers: [.textExact, .textFuzzy])
let result = await host.evaluation.evaluate(LearnerResponse(text: heard.transcript), against: spec)
let correct = result.verdict == .correct

// Progress + proficiency (5.4): namespaced by module id; free GDPR export/erase.
await host.progress.store(AttemptRecord(module: manifest.id, domain: StandardDomain("vocabulary"),
                                        itemId: "apple", response: heard.transcript,
                                        correct: correct, latencyMs: 0))
await host.progress.reportMastery(MasteryObservation(module: manifest.id,
                                  domain: StandardDomain("vocabulary"), signal: correct ? 100 : 0))
let kv = host.progress.keyValue(namespace: manifest.id)   // module-private KV

// Content (5.3): query packs, pull typed items; host verifies integrity + schema.
let packs = await host.content.packs(matching: PackQuery(schema: "canonical-question/1"))

// Telemetry (5.6): required taxonomy, module-dimensioned.
await host.telemetry.record(.attempt(outcome: correct ? .correct : .incorrect, latencyMs: 0),
                            module: manifest.id)

// Session registration (5.9): first-class app session (watch control plane, error log, metrics).
let registered = host.sessionRegistration.begin(
    ModuleSessionDescriptor(module: manifest.id, title: "My Drill",
                            activityKind: ModuleActivityKind("drill"),
                            controls: .voicePractice, totalUnits: 3),
    onPause: { }, onResume: { }, onMute: nil, onStop: { }
)
registered.update(progress: ModuleSessionProgress(completedUnits: 1))
registered.end(summary: ModuleSessionSummary(completedUnits: 3, duration: 42))
```

The single most important invariant: **modules never instantiate STT, TTS, VAD, or
audio engines.** All speech flows through `host.voice`. This keeps the one-pipeline
guarantee true.

## 6. Content packs (spec section 7)

A content pack is a directory or archive carrying `manifest.json` (a `PackManifest`)
and `items.json`. Licensing (SPDX + attribution) and integrity (sha256 of the item
payload) are mandatory; the store refuses a pack with a bad hash or missing license.

- **Bundled packs** ship in the app and are listed in `manifest.contentPacks.bundled`.
- **Imported packs** arrive from Files/AirDrop via `host.content.importPack(from:)`
  (coach distribution). The item payload is hash-checked before the pack registers.
- **Downloaded packs** come from the server (Tier 1) via `host.content.download(_:)`.

Your item type conforms to `PackItem` (a Codable marker) so the store decodes it
without knowing your types. `KBQuestion` is a worked example (`extension KBQuestion:
PackItem {}`). Item schemas defined today: `canonical-question/1`, `oral-syllabus/1`,
`drill-items/1`.

## 7. Conformance: proving it works

Every first-party module must pass **UM-Core** and **UM-Voice** before shipping
(spec section 9). The suite is `UnaMentisTests/Conformance/ModuleConformanceSuite.swift`,
driven by the shared harness `UnaMentisTests/Helpers/ModuleTestHarness/`.

Write a conformance test like `KBConformanceTests` or `TemplateModuleConformanceTests`:

```swift
@MainActor
final class MyModuleConformanceTests: XCTestCase {
    private var harness: ScriptedModuleHost!
    override func setUp() { super.setUp(); harness = ScriptedModuleHost.make() }
    override func tearDown() { harness?.tearDown(); harness = nil; super.tearDown() }

    func testMyModule_passesUMCore() async {
        await ModuleConformance.run(module: MyModule(), level: .umCore, using: harness)
    }
    func testMyModule_passesUMVoice() async {   // voice-first modules only
        await ModuleConformance.run(module: MyModule(), level: .umVoice, using: harness)
    }
}
```

The harness gives you real services on temp dirs (progress, evaluation, content),
a scripted `VoiceSession`, a recording telemetry sink, and a recording watch
control plane whose pause/stop can be driven from tests.

### Making a voice-first activity drivable

UM-Voice runs your primary voice activity **with zero touch events**. To let it,
adopt `ConformanceDrivable` (in `UnaMentis/Core/Modules/ConformanceDrivable.swift`)
and factor your activity into a plain async function over host services and a
`VoiceSession`, so the SAME code path runs from your SwiftUI view and from the
harness:

```swift
extension MyModule: ConformanceDrivable {
    public var primaryVoiceActivity: ModuleActivityKind { ModuleActivityKind("my-activity") }
    public var claimedVoiceCommands: Set<VoiceCommand> { [.quit, .skip] }

    public func runPrimaryVoiceActivity(
        host: ModuleHost, session: any VoiceSession, script: ConformanceVoiceScript
    ) async throws -> ConformanceRunResult {
        // speak a prompt, listen, evaluate, record an attempt + telemetry, repeat,
        // then summarize. Honor quit/skip from session.events. Return the result.
    }
}
```

UM-Voice asserts: the activity completes, it spoke at least one prompt, it evaluated
at least one response, it emitted `module.attempt` telemetry per attempt, it honored
each claimed unified command (quit/skip), and it did not release the host-owned
session.

`ExampleEchoModule` is the reference adoption. `KnowledgeBowlModule+Conformance.swift`
shows the engine-backed variant (it drives `QuizMatchEngine` headlessly).

## 8. RFC process for new host capabilities

The platform grows by capability negotiation, not by per-client divergence (spec
section 10). If your module needs a host feature that does not exist yet:

1. Add a short proposal in `/Users/ramerman/dev/unamentis/docs/modules/rfcs/`
   (see `0001`-`0005` for the format): problem, proposed capability name
   (`name/majorVersion`), API sketch, affected platforms (iOS/Android/server).
2. Do not silently add the capability to `HostCapabilities.provided` before the
   service exists; advertising a capability with no implementation lets a module
   launch into a gap. Land the service, then advertise it.
3. Ratified proposals update `MODULE_SDK_SPEC.md`, keeping iOS, Android, and the
   server registry aligned.

Additive-only schema changes (new optional manifest/descriptor/pack fields, new
capability names) are non-breaking and need no major version bump; removing or
re-typing a field is a major bump.

## 9. Definition of done

Run `/validate` (lint + quick tests) and confirm it passes before calling a module
complete. A shippable module: builds for iOS and watch, passes UM-Core and (if
voice-first) UM-Voice, adds exactly one catalog line, and touches no host files
beyond that line and any ratified RFC changes.
