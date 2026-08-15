// UnaMentis - Progress Store and Unified Proficiency Host Service
// MODULE_SDK_SPEC.md section 5.4, capabilities "progress/1" and "proficiency/1"
//
// The host-owned, module-namespaced persistence layer. Modules never write raw
// files: they store structured attempts, keep module-private key/value state,
// and read/write the shared unified proficiency model through this service. All
// persistence is namespaced by module ID (section 5.4 and 11), which gives
// every module GDPR export (`exportAll`) and erasure (`deleteAll`) for free.
//
// This is the minimal spec-shaped implementation Knowledge Bowl exercises:
// - AttemptRecord round-trips to a per-module JSON store.
// - keyValue(namespace:) is a module-private KV store, isolated per module.
// - proficiency/reportMastery back a simple 0-100 mastery model keyed by
//   StandardDomain, shared across modules.
//
// It is file-backed rather than Core Data on purpose: KB stats are already
// file-backed JSON (KBSessionStore), the data volume is small, and a temp-dir
// store makes the "real over mock" unit tests trivial. The root directory is
// injectable so tests run in isolation.

import Foundation

// MARK: - Path Safety

/// Turns a caller-supplied identifier (module id, pack id) into something that
/// is always exactly ONE directory name under a store root.
///
/// Host services take these ids from module code, and a store must never let an
/// id escape its root: `".."` used to resolve to the parent, so
/// `deleteAll(for: "..")` pointed at the whole Documents directory.
enum ModuleStorePath {
    /// A safe single path component for `raw`. Separators and traversal are
    /// neutralized rather than rejected, so a store call is always well
    /// defined; reverse-DNS ids (the real ones) pass through unchanged.
    static func safeComponent(_ raw: String) -> String {
        var component = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for separator in ["/", "\\", ":"] {
            component = component.replacingOccurrences(of: separator, with: "_")
        }
        component = component.replacingOccurrences(of: "\0", with: "_")
        // Anything starting with a dot covers "." and ".." (and keeps stores
        // out of hidden files); prefixing makes traversal impossible.
        if component.hasPrefix(".") {
            component = "_" + component
        }
        return component.isEmpty ? "_unnamed" : component
    }
}

// MARK: - Standard Domain

/// A cross-module knowledge domain, the key of the unified proficiency model
/// (MODULE_SDK_SPEC.md section 5.4). Deliberately an open string wrapper rather
/// than a closed enum: new modules name new domains without a host change, the
/// same additive principle the manifest capability set uses. Modules map their
/// own taxonomy onto these (Knowledge Bowl maps KBDomain -> StandardDomain).
public struct StandardDomain: RawRepresentable, Hashable, Sendable, Codable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

// MARK: - Attempt Record

/// One structured learning attempt (MODULE_SDK_SPEC.md section 5.4): a question,
/// the learner's response, the evaluation outcome, and latency. Stored
/// namespaced by module ID. Kept module-agnostic on purpose so every module
/// records attempts the same way.
public struct AttemptRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    /// The module that produced this attempt (the namespace dimension).
    public let module: String
    /// The domain this attempt exercised, for proficiency roll-up.
    public let domain: StandardDomain
    /// Stable identifier of the item attempted (e.g. a question ID).
    public let itemId: String
    /// The learner's response, if captured.
    public let response: String?
    /// Whether the response was judged correct.
    public let correct: Bool
    /// Time from item presentation to response, in milliseconds.
    public let latencyMs: Int
    /// When the attempt occurred.
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        module: String,
        domain: StandardDomain,
        itemId: String,
        response: String?,
        correct: Bool,
        latencyMs: Int,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.module = module
        self.domain = domain
        self.itemId = itemId
        self.response = response
        self.correct = correct
        self.latencyMs = latencyMs
        self.timestamp = timestamp
    }
}

// MARK: - Proficiency

/// A learner's mastery of one domain, 0 to 100 (MODULE_SDK_SPEC.md section 5.4).
/// The shared substrate: mastery observed in one module informs difficulty and
/// scheduling in others.
public struct Proficiency: Codable, Sendable, Equatable {
    public let domain: StandardDomain
    /// Mastery, clamped to 0...100.
    public let mastery: Double
    /// Number of observations that produced this value.
    public let observationCount: Int
    /// Sum of the WEIGHTS behind `mastery`. Tracked separately from the count
    /// because they are different quantities: a single weight-10 observation is
    /// one observation carrying ten times the influence, and folding the next
    /// observation in needs the weight, not the count.
    public let totalWeight: Double
    /// When it was last updated.
    public let updatedAt: Date

    public init(
        domain: StandardDomain,
        mastery: Double = 0,
        observationCount: Int = 0,
        totalWeight: Double? = nil,
        updatedAt: Date = Date()
    ) {
        self.domain = domain
        self.mastery = min(max(mastery, 0), 100)
        self.observationCount = observationCount
        self.totalWeight = max(0, totalWeight ?? Double(observationCount))
        self.updatedAt = updatedAt
    }

    /// Records written before `totalWeight` existed carry only a count; treat
    /// each of those observations as weight 1, which is what they were.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        domain = try container.decode(StandardDomain.self, forKey: .domain)
        mastery = min(max(try container.decode(Double.self, forKey: .mastery), 0), 100)
        let count = try container.decode(Int.self, forKey: .observationCount)
        observationCount = count
        totalWeight = max(0, try container.decodeIfPresent(Double.self, forKey: .totalWeight) ?? Double(count))
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

/// A single mastery observation written into the unified model
/// (MODULE_SDK_SPEC.md section 5.4). `signal` is the observed performance for
/// this domain in 0...100 (e.g. a correct answer might report 100, an incorrect
/// one 0); the store folds it into a running estimate.
public struct MasteryObservation: Sendable {
    public let module: String
    public let domain: StandardDomain
    public let signal: Double
    public let weight: Double

    public init(module: String, domain: StandardDomain, signal: Double, weight: Double = 1.0) {
        self.module = module
        self.domain = domain
        self.signal = min(max(signal, 0), 100)
        self.weight = max(weight, 0)
    }
}

// MARK: - Module KV Store

/// A module-private key/value store (MODULE_SDK_SPEC.md section 5.4,
/// `keyValue(namespace:)`). Isolated per module: one module cannot read or
/// clobber another's state.
public protocol ModuleKVStore: Sendable {
    func string(forKey key: String) async -> String?
    func setString(_ value: String?, forKey key: String) async
    func data(forKey key: String) async -> Data?
    func setData(_ value: Data?, forKey key: String) async
    func removeAll() async
}

// MARK: - Data Export

/// A GDPR export bundle for one module (MODULE_SDK_SPEC.md sections 5.4, 11).
public struct DataExport: Codable, Sendable {
    public let module: String
    public let attempts: [AttemptRecord]
    public let keyValues: [String: String]
    public let exportedAt: Date

    public init(module: String, attempts: [AttemptRecord], keyValues: [String: String], exportedAt: Date = Date()) {
        self.module = module
        self.attempts = attempts
        self.keyValues = keyValues
        self.exportedAt = exportedAt
    }
}

// MARK: - Service Protocol

/// The host progress + proficiency store (MODULE_SDK_SPEC.md section 5.4).
public protocol ProgressStoreService: Sendable {
    /// Persist one structured attempt, namespaced by its module ID.
    func store(_ record: AttemptRecord) async

    /// A module-private key/value store for the given module ID.
    func keyValue(namespace: String) -> ModuleKVStore

    /// Read cross-module mastery for a domain from the unified model.
    func proficiency(for domain: StandardDomain) async -> Proficiency

    /// Fold a mastery observation into the unified model.
    func reportMastery(_ observation: MasteryObservation) async

    /// Export all of a module's data (GDPR export).
    func exportAll(for module: String) async -> DataExport

    /// Delete all of a module's data (GDPR erasure). Only the target module's
    /// data is removed; other modules and the shared proficiency model for
    /// domains they still contribute to are untouched.
    func deleteAll(for module: String) async
}

// MARK: - File-Backed Implementation

/// File-backed, module-namespaced progress store.
///
/// Layout under the root directory:
/// ```
/// <root>/<moduleID>/attempts.json   attempts for that module
/// <root>/<moduleID>/kv.json         that module's private KV
/// <root>/_proficiency.json          the shared unified proficiency model
/// ```
/// The root is injectable so tests use a temp directory. An `actor` guards all
/// file I/O and the in-memory proficiency map.
public actor FileProgressStoreService: ProgressStoreService {
    private let root: URL
    private let fileManager = FileManager.default

    /// The shared proficiency model, loaded lazily and kept in memory.
    private var proficiencyByDomain: [String: Proficiency]?

    /// Create a store rooted at the given directory. Defaults to
    /// `Documents/ModuleProgress`, the production location.
    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let documents = (try? FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.root = documents.appendingPathComponent("ModuleProgress", isDirectory: true)
        }
    }

    // MARK: Paths

    private func moduleDirectory(_ module: String) -> URL {
        root.appendingPathComponent(sanitized(module), isDirectory: true)
    }

    private func attemptsURL(_ module: String) -> URL {
        moduleDirectory(module).appendingPathComponent("attempts.json")
    }

    private func kvURL(_ module: String) -> URL {
        moduleDirectory(module).appendingPathComponent("kv.json")
    }

    private var proficiencyURL: URL {
        root.appendingPathComponent("_proficiency.json")
    }

    /// Keep module IDs safe as a path component.
    private func sanitized(_ component: String) -> String {
        ModuleStorePath.safeComponent(component)
    }

    private func ensureDirectory(_ url: URL) {
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // MARK: Attempts

    public func store(_ record: AttemptRecord) async {
        ensureDirectory(moduleDirectory(record.module))
        var attempts = loadAttempts(record.module)
        attempts.append(record)
        writeAttempts(attempts, module: record.module)
    }

    private func loadAttempts(_ module: String) -> [AttemptRecord] {
        let url = attemptsURL(module)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([AttemptRecord].self, from: data)) ?? []
    }

    private func writeAttempts(_ attempts: [AttemptRecord], module: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(attempts) else { return }
        try? data.write(to: attemptsURL(module), options: [.atomic])
    }

    // MARK: KV

    public nonisolated func keyValue(namespace: String) -> ModuleKVStore {
        FileModuleKVStore(store: self, module: namespace)
    }

    fileprivate func kvGet(_ module: String, _ key: String) -> String? {
        loadKV(module)[key]
    }

    fileprivate func kvGetData(_ module: String, _ key: String) -> Data? {
        loadKV(module)[key].flatMap { Data(base64Encoded: $0) }
    }

    fileprivate func kvSet(_ module: String, _ key: String, _ value: String?) {
        ensureDirectory(moduleDirectory(module))
        var kv = loadKV(module)
        if let value { kv[key] = value } else { kv.removeValue(forKey: key) }
        writeKV(kv, module: module)
    }

    fileprivate func kvSetData(_ module: String, _ key: String, _ value: Data?) {
        kvSet(module, key, value?.base64EncodedString())
    }

    fileprivate func kvRemoveAll(_ module: String) {
        try? fileManager.removeItem(at: kvURL(module))
    }

    private func loadKV(_ module: String) -> [String: String] {
        guard let data = try? Data(contentsOf: kvURL(module)) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func writeKV(_ kv: [String: String], module: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(kv) else { return }
        try? data.write(to: kvURL(module), options: [.atomic])
    }

    // MARK: Proficiency

    public func proficiency(for domain: StandardDomain) async -> Proficiency {
        loadProficiency()[domain.rawValue] ?? Proficiency(domain: domain)
    }

    public func reportMastery(_ observation: MasteryObservation) async {
        var map = loadProficiency()
        let existing = map[observation.domain.rawValue] ?? Proficiency(domain: observation.domain)

        // Weighted running estimate toward the observed signal. The prior term
        // is the accumulated WEIGHT, not the observation count: mixing the two
        // recorded a weight-10 observation as a single unit of prior influence
        // (so the next observation diluted it as if it had been weight 1), and
        // a weight-0 observation on a fresh domain jumped mastery to the full
        // signal even though it was explicitly weightless.
        let priorWeight = existing.totalWeight
        let weight = observation.weight
        let totalWeight = priorWeight + weight
        let newMastery: Double
        if weight <= 0 {
            // A weightless observation carries no signal, whatever the history.
            newMastery = existing.mastery
        } else if totalWeight > 0 {
            newMastery = (existing.mastery * priorWeight + observation.signal * weight) / totalWeight
        } else {
            newMastery = observation.signal
        }
        map[observation.domain.rawValue] = Proficiency(
            domain: observation.domain,
            mastery: newMastery,
            observationCount: existing.observationCount + 1,
            totalWeight: totalWeight,
            updatedAt: Date()
        )
        proficiencyByDomain = map
        writeProficiency(map)
    }

    private func loadProficiency() -> [String: Proficiency] {
        if let cached = proficiencyByDomain { return cached }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let map: [String: Proficiency]
        if let data = try? Data(contentsOf: proficiencyURL),
           let decoded = try? decoder.decode([String: Proficiency].self, from: data) {
            map = decoded
        } else {
            map = [:]
        }
        proficiencyByDomain = map
        return map
    }

    private func writeProficiency(_ map: [String: Proficiency]) {
        ensureDirectory(root)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(map) else { return }
        try? data.write(to: proficiencyURL, options: [.atomic])
    }

    // MARK: Export / Erasure

    public func exportAll(for module: String) async -> DataExport {
        DataExport(
            module: module,
            attempts: loadAttempts(module),
            keyValues: loadKV(module)
        )
    }

    public func deleteAll(for module: String) async {
        // Remove only the target module's directory. The shared proficiency
        // model is intentionally left intact: other modules' contributions to a
        // domain must survive one module's erasure.
        try? fileManager.removeItem(at: moduleDirectory(module))
    }
}

// MARK: - File KV Store

/// A `ModuleKVStore` bound to one module, delegating to the actor-isolated
/// `FileProgressStoreService`.
private struct FileModuleKVStore: ModuleKVStore {
    let store: FileProgressStoreService
    let module: String

    func string(forKey key: String) async -> String? {
        await store.kvGet(module, key)
    }
    func setString(_ value: String?, forKey key: String) async {
        await store.kvSet(module, key, value)
    }
    func data(forKey key: String) async -> Data? {
        await store.kvGetData(module, key)
    }
    func setData(_ value: Data?, forKey key: String) async {
        await store.kvSetData(module, key, value)
    }
    func removeAll() async {
        await store.kvRemoveAll(module)
    }
}
