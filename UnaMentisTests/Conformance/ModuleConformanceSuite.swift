// UnaMentis - Module Conformance Suite
// The reusable, executable form of MODULE_SDK_SPEC.md section 9's certification
// checklist. Every first-party module runs this in CI (see KBConformanceTests,
// TemplateModuleConformanceTests).
//
// Usage:
//
//     let harness = ScriptedModuleHost.make()
//     await ModuleConformance.run(module: MyModule(), level: .umCore, using: harness)
//     await ModuleConformance.run(module: MyModule(), level: .umVoice, using: harness)
//
// The suite asserts with XCTest directly (the repo is 100% XCTest), so a failing
// check fails the calling test at the check's own message. `run(...)` forwards
// the caller's file/line so failures point at the module's conformance test.
//
// Deliberately executable subset (tracked for the RFC process, see the Phase 6
// RFC and the final report): section 9 lists checks a headless unit suite cannot
// perform without a running app or real usage data, specifically VoiceOver and
// Dynamic Type auditing (needs the view hierarchy / a UI test host), resume-from-
// process-death (needs app relaunch), and "declared voice coverage within 15
// points of measured" (needs real telemetry). Those are asserted structurally
// where possible (the manifest is present and honest) and otherwise flagged, not
// silently skipped.

import XCTest
@testable import UnaMentis

// MARK: - Levels

/// A certification level (MODULE_SDK_SPEC.md section 9). This suite implements
/// UM-Core and UM-Voice, the two levels first-party modules must pass before
/// shipping. UM-Watch and UM-Team are named for completeness; their checks land
/// with the watch and team-sync phases.
enum ModuleConformanceLevel: String, Sendable {
    case umCore = "UM-Core"
    case umVoice = "UM-Voice"
}

// MARK: - Suite

/// The reusable conformance test API.
enum ModuleConformance {

    /// Run one conformance level against a module using a fresh harness.
    ///
    /// - Parameters:
    ///   - module: the module under test.
    ///   - level: which certification level to run.
    ///   - harness: a fresh `ScriptedModuleHost` (one per level keeps state clean).
    @MainActor
    static func run<M: ModuleProtocol>(
        module: M,
        level: ModuleConformanceLevel,
        using harness: ScriptedModuleHost,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        switch level {
        case .umCore:
            await runCore(module: module, harness: harness, file: file, line: line)
        case .umVoice:
            await runVoice(module: module, harness: harness, file: file, line: line)
        }
    }

    // MARK: - UM-Core

    /// UM-Core: Tier 0 offline completeness, lifecycle correctness, catalog
    /// capability gating, namespaced persistence, and localization sanity.
    @MainActor
    static func runCore<M: ModuleProtocol>(
        module: M,
        harness: ScriptedModuleHost,
        file: StaticString,
        line: UInt
    ) async {
        let manifest = module.manifest

        // --- Check 1: manifest identity is a nonempty slug. ---
        XCTAssertFalse(
            manifest.id.isEmpty,
            "UM-Core: module id must be a nonempty stable slug (section 3).",
            file: file, line: line
        )
        XCTAssertTrue(
            isSlug(manifest.id),
            "UM-Core: module id '\(manifest.id)' must be a reverse-DNS/slug id (lowercase, no spaces).",
            file: file, line: line
        )

        // --- Check 2: version is semver. ---
        XCTAssertTrue(
            isSemver(manifest.version),
            "UM-Core: version '\(manifest.version)' must be semver MAJOR.MINOR.PATCH (section 3).",
            file: file, line: line
        )

        // --- Check 3: declared surfaces include phone (required, section 8). ---
        XCTAssertTrue(
            manifest.surfaces.contains(.phone),
            "UM-Core: every module must declare the required phone surface (section 8).",
            file: file, line: line
        )

        // --- Check 4: voiceCoverage.declared is a probability in 0...1 (section 3). ---
        XCTAssertTrue(
            (0.0...1.0).contains(manifest.voiceCoverage.declared),
            "UM-Core: voiceCoverage.declared \(manifest.voiceCoverage.declared) must be within 0...1.",
            file: file, line: line
        )

        // --- Check 5: serverTiers contains Tier 0 (mandatory, section 3). ---
        XCTAssertTrue(
            manifest.serverTiers.contains(0),
            "UM-Core: serverTiers must contain 0; Tier 0 offline core is mandatory (section 3).",
            file: file, line: line
        )

        // --- Check 6: localization sanity: manifest locales nonempty. ---
        XCTAssertFalse(
            manifest.locales.isEmpty,
            "UM-Core: manifest must declare at least one locale (section 9 localization).",
            file: file, line: line
        )
        for locale in manifest.locales {
            XCTAssertFalse(
                locale.isEmpty,
                "UM-Core: locale tags must be nonempty BCP-47 identifiers.",
                file: file, line: line
            )
        }

        // --- Check 7: lifecycle correctness. initialize/start/pause/resume/stop
        // completes; a double-stop is tolerated (idempotent release). ---
        do {
            try await module.initialize(host: harness.host)
            await module.start()
            await module.pause()
            await module.resume()
            await module.stop()
            await module.stop()  // double-stop must be tolerated
        } catch {
            XCTFail(
                "UM-Core: module lifecycle threw: \(error) (section 4.1).",
                file: file, line: line
            )
        }

        // --- Check 8: catalog capability gating. A module whose required host
        // capability is absent is hidden; a module whose requirements are all met
        // is shown. ---
        XCTAssertTrue(
            HostCapabilities.supports(manifest),
            "UM-Core: the build must provide every host capability the module requires "
                + "(requiresHostCapabilities=\(manifest.requiresHostCapabilities)); otherwise the "
                + "module would be hidden and unshippable (section 3).",
            file: file, line: line
        )
        let gatedManifest = manifestRequiring(
            absentCapability: "conformance.absent-capability/1", basedOn: manifest
        )
        XCTAssertFalse(
            HostCapabilities.supports(gatedManifest),
            "UM-Core: a module requiring an absent host capability must be gated out (section 3).",
            file: file, line: line
        )

        // --- Check 9: persistence namespacing. A write via the harness store
        // lands under the module id, and deleteAll(other) does not touch it. ---
        let progress = harness.progressStore
        let record = AttemptRecord(
            module: manifest.id,
            domain: StandardDomain("conformance"),
            itemId: "conformance-item",
            response: "x",
            correct: true,
            latencyMs: 1
        )
        await progress.store(record)

        let ownExport = await progress.exportAll(for: manifest.id)
        XCTAssertEqual(
            ownExport.attempts.count, 1,
            "UM-Core: a stored attempt must land under the module's namespace (section 5.4).",
            file: file, line: line
        )

        await progress.deleteAll(for: "some-other-module")
        let afterOtherErase = await progress.exportAll(for: manifest.id)
        XCTAssertEqual(
            afterOtherErase.attempts.count, 1,
            "UM-Core: deleteAll(for: other module) must not touch this module's data (section 5.4, 11).",
            file: file, line: line
        )

        // And this module's own erasure clears only its data.
        await progress.deleteAll(for: manifest.id)
        let afterSelfErase = await progress.exportAll(for: manifest.id)
        XCTAssertEqual(
            afterSelfErase.attempts.count, 0,
            "UM-Core: deleteAll(for: self) must clear the module's own data (GDPR erasure, section 11).",
            file: file, line: line
        )
    }

    // MARK: - UM-Voice

    /// UM-Voice: the module's primary voice-first activity, driven ONLY through
    /// the scripted voice session (zero touch/UI), observes its own terminal
    /// event and so reaches completion, evaluates at least one spoken response,
    /// emits the required `module.attempt` telemetry, records those attempts
    /// through the host progress store under its own namespace, drives at least
    /// one module-scoped voice state, honors every unified command it claims,
    /// and releases nothing it does not own.
    ///
    /// Modules must adopt `ConformanceDrivable` to run at this level.
    @MainActor
    static func runVoice<M: ModuleProtocol>(
        module: M,
        harness: ScriptedModuleHost,
        file: StaticString,
        line: UInt
    ) async {
        guard let drivable = module as? any ConformanceDrivable else {
            XCTFail(
                "UM-Voice: module '\(module.manifest.id)' declares voice-first coverage "
                    + "(voiceCoverage=\(module.manifest.voiceCoverage.declared)) but does not adopt "
                    + "ConformanceDrivable, so its voice activity cannot be driven headlessly (section 9).",
                file: file, line: line
            )
            return
        }
        await runVoiceDrivable(drivable, harness: harness, file: file, line: line)
    }

    @MainActor
    private static func runVoiceDrivable(
        _ module: any ConformanceDrivable,
        harness: ScriptedModuleHost,
        file: StaticString,
        line: UInt
    ) async {
        let moduleId = module.manifest.id

        // The module must declare voice-first intent for this level to apply.
        XCTAssertGreaterThan(
            module.manifest.voiceCoverage.declared, 0.0,
            "UM-Voice: only modules declaring voice-first coverage run this level (section 9).",
            file: file, line: line
        )

        do {
            try await module.initialize(host: harness.host)
        } catch {
            XCTFail("UM-Voice: initialize threw: \(error).", file: file, line: line)
            return
        }

        // Drive the primary voice activity ONLY through the scripted session.
        // Any real UI/touch call would deadlock or crash headlessly, which is the
        // point: this proves zero-touch completion (section 9).
        let session = harness.voiceSession
        let script = ConformanceVoiceScript(roundCount: 3)

        let result: ConformanceRunResult
        do {
            result = try await module.runPrimaryVoiceActivity(
                host: harness.host, session: session, script: script
            )
        } catch {
            XCTFail(
                "UM-Voice: the primary voice activity threw instead of completing hands-free: \(error).",
                file: file, line: line
            )
            return
        }

        // --- Check 1: the activity OBSERVED its own terminal event and so
        // reached completion. A driver that hardcodes this makes the whole level
        // vacuous, so `completed` must be tracked from the terminal signal
        // (.matchEnded / .roundEnded / .sessionEnded, or the activity's own
        // summary point); an event loop that simply ran out of events did not
        // complete. ---
        XCTAssertTrue(
            result.completed,
            "UM-Voice: the primary voice activity must run to completion driven only by voice, and must "
                + "report completion from the terminal event it observed, not assume it (section 9).",
            file: file, line: line
        )

        // --- Check 2: at least one prompt was spoken (question/prompt spoken). ---
        let spoken = await session.spokenTexts
        XCTAssertFalse(
            spoken.isEmpty,
            "UM-Voice: the activity must speak at least one prompt through the voice session (section 5.1).",
            file: file, line: line
        )

        // --- Check 3: at least one scripted utterance was captured and evaluated. ---
        XCTAssertGreaterThan(
            result.attemptsEvaluated, 0,
            "UM-Voice: the activity must capture and evaluate at least one spoken response (section 9).",
            file: file, line: line
        )

        // --- Check 4: the required module.attempt telemetry was emitted, once
        // per evaluated attempt. Engine attempt writes are fire-and-forget
        // (QuizMatchEngine dispatches them in a Task), so the count is polled to
        // a bounded deadline rather than read once: the check must fail on a
        // missing event, never on a scheduling race. ---
        let attemptTelemetry = await waitForCount(atLeast: max(1, result.attemptsEvaluated)) {
            await harness.telemetryRecorder.attemptCount(module: moduleId)
        }
        XCTAssertGreaterThan(
            attemptTelemetry, 0,
            "UM-Voice: the activity must emit module.attempt telemetry for the responses it evaluated "
                + "(section 5.6).",
            file: file, line: line
        )
        XCTAssertGreaterThanOrEqual(
            attemptTelemetry, result.attemptsEvaluated,
            "UM-Voice: every evaluated attempt must emit module.attempt telemetry "
                + "(\(attemptTelemetry) emitted for \(result.attemptsEvaluated) attempts) (section 5.6).",
            file: file, line: line
        )

        // --- Check 5: the evaluated attempts reached the host's progress store
        // under the module's own namespace. This is host-recorded evidence, so
        // it cannot be satisfied by a driver that only reports numbers back
        // (sections 5.4, 9). ---
        let storedAttempts = await waitForCount(atLeast: 1) {
            await harness.progressStore.exportAll(for: moduleId).attempts.count
        }
        XCTAssertGreaterThan(
            storedAttempts, 0,
            "UM-Voice: the attempts the activity evaluated must be recorded through the host progress "
                + "store under the module's namespace (section 5.4).",
            file: file, line: line
        )

        // --- Check 6: the run drove at least one module-scoped voice state.
        // States are reported as the run enters them, so an activity that never
        // moved through a state cannot claim one. ---
        XCTAssertFalse(
            result.voiceStatesEntered.isEmpty,
            "UM-Voice: the activity must drive at least one module-scoped voice state so the host can "
                + "scope its command vocabulary (section 5.1).",
            file: file, line: line
        )

        // --- Check 7: the unified command vocabulary is honored for EVERY
        // command the activity claims. Driven by injecting the command through
        // the scripted session during a run; a command a module claims but
        // ignores is a false advertisement to the host. ---
        for command in module.claimedVoiceCommands.sorted(by: { $0.displayName < $1.displayName }) {
            await verifyCommandHonored(
                command, module: module, file: file, line: line
            )
        }

        // --- Check 8: the session was released cleanly at the end (the module
        // ends by handing the floor back; the HOST owns acquisition/release, so
        // the module must NOT release a session it did not acquire). ---
        let released = await session.released
        XCTAssertFalse(
            released,
            "UM-Voice: the module must not release a host-owned session; the host arbitrates the "
                + "pipeline lifecycle (section 5.1).",
            file: file, line: line
        )
    }

    /// Poll a host-recorded count until it reaches `minimum`, to a bounded
    /// deadline. Some engines write attempts fire-and-forget, so a single read
    /// races the run's last attempt; this settles the trail without ever
    /// hanging, and returns whatever the count reached so the caller asserts on
    /// a real value.
    @MainActor
    private static func waitForCount(
        atLeast minimum: Int,
        timeout: TimeInterval = 2.0,
        read: () async -> Int
    ) async -> Int {
        var latest = await read()
        let deadline = Date().addingTimeInterval(timeout)
        while latest < minimum, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
            latest = await read()
        }
        return latest
    }

    /// Verify that a claimed unified command terminates the activity cleanly when
    /// injected mid-run. A fresh harness is used so command handling is isolated.
    @MainActor
    private static func verifyCommandHonored(
        _ command: VoiceCommand,
        module: any ConformanceDrivable,
        file: StaticString,
        line: UInt
    ) async {
        let harness = ScriptedModuleHost.make()
        defer { harness.tearDown() }
        do {
            try await module.initialize(host: harness.host)
        } catch {
            XCTFail("UM-Voice: initialize threw during command check: \(error).", file: file, line: line)
            return
        }

        let session = harness.voiceSession
        // Inject the command up front; a quit/skip must be observed and acted on.
        await session.injectCommand(command)

        let script = ConformanceVoiceScript(roundCount: 3)
        let result: ConformanceRunResult
        do {
            result = try await module.runPrimaryVoiceActivity(
                host: harness.host, session: session, script: script
            )
        } catch {
            XCTFail(
                "UM-Voice: activity threw while handling the '\(command.displayName)' command: \(error).",
                file: file, line: line
            )
            return
        }

        XCTAssertTrue(
            result.commandsHonored.contains(command),
            "UM-Voice: the activity claims the '\(command.displayName)' command but did not honor it "
                + "when injected (section 9, unified command vocabulary).",
            file: file, line: line
        )

        // Handling a command must not turn the module into the session's owner:
        // quit ends the ACTIVITY and hands the floor back, the host releases the
        // pipeline (section 5.1).
        let released = await session.released
        XCTAssertFalse(
            released,
            "UM-Voice: handling the '\(command.displayName)' command must not release the host-owned "
                + "voice session; the module ends its activity and hands the floor back (section 5.1).",
            file: file, line: line
        )
    }

    // MARK: - Manifest helpers

    /// A copy of `base` whose required host capabilities include an absent one,
    /// for the capability-gating check.
    private static func manifestRequiring(
        absentCapability capability: String,
        basedOn base: ModuleManifest
    ) -> ModuleManifest {
        ModuleManifest(
            specVersion: base.specVersion,
            id: base.id + ".gated-probe",
            name: base.name,
            version: base.version,
            engine: base.engine,
            surfaces: base.surfaces,
            capabilities: base.capabilities,
            requiresHostCapabilities: base.requiresHostCapabilities + [capability],
            optionalHostCapabilities: base.optionalHostCapabilities,
            voiceCoverage: base.voiceCoverage,
            serverTiers: base.serverTiers,
            locales: base.locales,
            contentPacks: base.contentPacks,
            privacy: base.privacy,
            minPlatform: base.minPlatform
        )
    }

    // MARK: - Validators

    /// A slug: lowercase letters, digits, dots, and hyphens; nonempty; no spaces.
    private static func isSlug(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Basic semver: three dot-separated numeric components (prerelease/build
    /// suffixes tolerated after the patch number).
    private static func isSemver(_ value: String) -> Bool {
        let core = value.split(separator: "+", maxSplits: 1).first.map(String.init) ?? value
        let mainPart = core.split(separator: "-", maxSplits: 1).first.map(String.init) ?? core
        let components = mainPart.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3 else { return false }
        return components.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}
