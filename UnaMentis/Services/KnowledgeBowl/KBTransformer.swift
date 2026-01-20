//
//  KBTransformer.swift
//  UnaMentis
//
//  Transforms questions from various formats into Knowledge Bowl format
//  Prepares for future canonical question format integration
//

import Foundation

// MARK: - KB Question Transformer

/// Transforms questions from import formats into Knowledge Bowl format
struct KBTransformer {
    // MARK: - Import Data Structures

    /// Raw question data from import sources (JSON, APIs, etc.)
    struct ImportedQuestion: Codable {
        let text: String
        let answer: String
        let acceptableAnswers: [String]?
        let domain: String
        let subdomain: String?
        let difficulty: String?
        let gradeLevel: String?
        let source: String
        let mcqOptions: [String]?
        let requiresCalculation: Bool?
        let hasFormula: Bool?
        let yearWritten: Int?
    }

    // MARK: - Transformation

    /// Transform an imported question into KB format
    func transform(_ imported: ImportedQuestion) -> KBQuestion? {
        // Map domain string to KBDomain
        guard let domain = mapDomain(imported.domain) else {
            print("[KBTransformer] Unknown domain: \(imported.domain)")
            return nil
        }

        // Map difficulty
        let difficulty = mapDifficulty(imported.difficulty)

        // Determine suitability
        let suitability = KBQuestionSuitability(
            forWritten: true,  // Most questions work for written
            forOral: !(imported.requiresCalculation ?? false),
            mcqPossible: imported.mcqOptions != nil && (imported.mcqOptions?.count ?? 0) >= 2,
            requiresVisual: imported.hasFormula ?? false
        )

        // Estimate read time (~150 words per minute for competition reading)
        let wordCount = imported.text.split(separator: " ").count
        let readTime = Double(wordCount) / 150.0 * 60.0  // seconds

        // Create answer model
        let answer = KBAnswer(
            primary: imported.answer,
            acceptable: imported.acceptableAnswers,
            answerType: inferAnswerType(imported.answer)
        )

        return KBQuestion(
            id: UUID(),
            text: imported.text,
            answer: answer,
            domain: domain,
            subdomain: imported.subdomain,
            difficulty: difficulty,
            suitability: suitability,
            estimatedReadTime: readTime,
            mcqOptions: imported.mcqOptions,
            source: imported.source,
            yearWritten: imported.yearWritten
        )
    }

    /// Transform a batch of imported questions
    func transformBatch(_ imported: [ImportedQuestion]) -> [KBQuestion] {
        imported.compactMap { transform($0) }
    }

    // MARK: - Domain Mapping

    private func mapDomain(_ domainString: String) -> KBDomain? {
        let normalized = domainString.lowercased().trimmingCharacters(in: .whitespaces)

        switch normalized {
        case "science", "sciences", "natural science":
            return .science
        case "mathematics", "math", "maths":
            return .mathematics
        case "literature", "english", "language arts":
            return .literature
        case "history", "world history", "us history":
            return .history
        case "social studies", "social science", "civics", "geography":
            return .socialStudies
        case "arts", "fine arts", "visual arts", "music":
            return .arts
        case "current events", "current affairs", "news":
            return .currentEvents
        case "language", "foreign language", "linguistics":
            return .language
        case "technology", "computer science", "programming":
            return .technology
        case "pop culture", "popular culture", "entertainment":
            return .popCulture
        case "religion", "philosophy", "ethics":
            return .religionPhilosophy
        case "miscellaneous", "misc", "general knowledge", "other":
            return .miscellaneous
        default:
            return nil
        }
    }

    // MARK: - Difficulty Mapping

    private func mapDifficulty(_ difficultyString: String?) -> KBDifficulty {
        guard let difficultyString = difficultyString else {
            return .competent  // Default
        }

        let normalized = difficultyString.lowercased().trimmingCharacters(in: .whitespaces)

        switch normalized {
        case "novice", "beginner", "easy", "elementary", "grade 6-7":
            return .novice
        case "competent", "intermediate", "medium", "middle school", "grade 8-9":
            return .competent
        case "varsity", "advanced", "hard", "high school", "grade 10-12":
            return .varsity
        default:
            // Try to infer from grade level
            if normalized.contains("6") || normalized.contains("7") {
                return .novice
            } else if normalized.contains("8") || normalized.contains("9") {
                return .competent
            } else if normalized.contains("10") || normalized.contains("11") || normalized.contains("12") {
                return .varsity
            }
            return .competent  // Default
        }
    }

    // MARK: - Answer Type Inference

    private func inferAnswerType(_ answer: String) -> KBAnswerType {
        let normalized = answer.lowercased().trimmingCharacters(in: .whitespaces)

        // Check for numbers
        if Double(normalized) != nil || normalized.contains(where: { "0123456789".contains($0) }) {
            return .number
        }

        // Check for common person indicators
        let personIndicators = ["dr.", "mr.", "mrs.", "ms.", "president", "king", "queen", "emperor"]
        if personIndicators.contains(where: { normalized.contains($0) }) {
            return .person
        }

        // Check for dates
        let dateIndicators = ["january", "february", "march", "april", "may", "june",
                             "july", "august", "september", "october", "november", "december",
                             "19", "20"]  // Century indicators
        if dateIndicators.contains(where: { normalized.contains($0) }) {
            return .date
        }

        // Check for places (countries, cities, etc.)
        // This is simplified - a more robust implementation would use a gazetteer
        if normalized.contains("city") || normalized.contains("state") ||
           normalized.contains("country") || normalized.contains("ocean") ||
           normalized.contains("river") || normalized.contains("mountain") {
            return .place
        }

        // Check for titles (books, movies, etc.)
        if normalized.hasPrefix("the ") || normalized.contains("\"") {
            return .title
        }

        // Check for scientific terms
        if normalized.contains("acid") || normalized.contains("oxide") ||
           normalized.contains("element") || normalized.contains("compound") {
            return .scientific
        }

        // Default to term
        return .term
    }

    // MARK: - Quality Assessment

    /// Calculate quality score for an imported question (0.0 to 1.0)
    func qualityScore(_ imported: ImportedQuestion) -> Double {
        var score = 0.5

        // Has MCQ options (easier to grade)
        if let options = imported.mcqOptions, options.count >= 4 {
            score += 0.2
        }

        // Has acceptable answer alternatives
        if let acceptable = imported.acceptableAnswers, !acceptable.isEmpty {
            score += 0.1
        }

        // Appropriate length (not too short, not too long)
        let wordCount = imported.text.split(separator: " ").count
        if wordCount >= 10 && wordCount <= 50 {
            score += 0.1
        }

        // Not formula-heavy (voice-friendly)
        if !(imported.hasFormula ?? false) {
            score += 0.1
        }

        return min(1.0, score)
    }

    /// Filter questions by quality threshold
    func filterByQuality(_ imported: [ImportedQuestion], threshold: Double = 0.5) -> [ImportedQuestion] {
        imported.filter { qualityScore($0) >= threshold }
    }
}

// MARK: - Question Suitability

/// Determines which KB formats a question is suitable for
struct KBQuestionSuitability: Codable {
    let forWritten: Bool
    let forOral: Bool
    let mcqPossible: Bool
    let requiresVisual: Bool

    /// Question is suitable for both written and oral
    var isVersatile: Bool {
        forWritten && forOral
    }
}

// MARK: - Import Helpers

extension KBTransformer {
    /// Load questions from JSON file
    static func loadFromJSON(fileURL: URL) throws -> [ImportedQuestion] {
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        struct ImportWrapper: Codable {
            let questions: [ImportedQuestion]
        }

        let wrapper = try decoder.decode(ImportWrapper.self, from: data)
        return wrapper.questions
    }

    /// Transform and save questions to KB format
    static func importAndSave(from fileURL: URL, to outputURL: URL) throws -> Int {
        let transformer = KBTransformer()

        // Load imported questions
        let imported = try loadFromJSON(fileURL: fileURL)
        print("[KBTransformer] Loaded \(imported.count) questions from \(fileURL.lastPathComponent)")

        // Filter by quality
        let filtered = transformer.filterByQuality(imported, threshold: 0.5)
        print("[KBTransformer] Filtered to \(filtered.count) quality questions")

        // Transform to KB format
        let kbQuestions = transformer.transformBatch(filtered)
        print("[KBTransformer] Transformed \(kbQuestions.count) questions to KB format")

        // Save to output file
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        struct OutputWrapper: Codable {
            let questions: [KBQuestion]
            let metadata: ImportMetadata
        }

        struct ImportMetadata: Codable {
            let importDate: Date
            let sourceFile: String
            let totalImported: Int
            let qualityFiltered: Int
            let successfullyTransformed: Int
        }

        let output = OutputWrapper(
            questions: kbQuestions,
            metadata: ImportMetadata(
                importDate: Date(),
                sourceFile: fileURL.lastPathComponent,
                totalImported: imported.count,
                qualityFiltered: filtered.count,
                successfullyTransformed: kbQuestions.count
            )
        )

        let outputData = try encoder.encode(output)
        try outputData.write(to: outputURL, options: [.atomic])

        return kbQuestions.count
    }
}
