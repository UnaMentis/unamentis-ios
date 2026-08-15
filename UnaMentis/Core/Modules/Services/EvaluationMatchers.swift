// UnaMentis - Evaluation Matchers
// MODULE_SDK_SPEC.md section 5.2 (eval.text-fuzzy/1).
//
// The algorithmic fuzzy-matching stack, MOVED from Knowledge Bowl's
// Services/KnowledgeBowl/Algorithms into the host evaluation service and
// generalized to carry no KB types. These are the exact algorithms the KB
// validator used (Double Metaphone phonetics, character/word n-gram similarity,
// token Jaccard/Dice similarity, and Apple NaturalLanguage lemmatization), so
// the lift is behavior-preserving. They are stateless value types, safe to hold
// inside the actor-backed evaluation service.

import Foundation
import NaturalLanguage

// MARK: - Phonetic Matcher (Double Metaphone)

/// Double Metaphone phonetic matching. Moved from KBPhoneticMatcher.
struct EvalPhoneticMatcher: Sendable {

    func metaphone(_ text: String) -> (primary: String, secondary: String?) {
        let cleaned = text.uppercased().filter { $0.isLetter }
        guard !cleaned.isEmpty else { return ("", nil) }

        var context = MetaphoneContext(text: cleaned)
        processInitialExceptions(&context)
        processMainLoop(&context)
        return context.result()
    }

    /// Double Metaphone codes WITHOUT the 4-character truncation `metaphone`
    /// applies. Matching compares these: two answers whose codes agree only
    /// because both were cut to four characters are not phonetically the same
    /// word. That truncation let "Austria" match "Australia" (both truncate to
    /// ASTR, full codes ASTR and ASTRL), a false accept on a real geography
    /// answer. Every genuine variant pair (Stephen/Steven, Philadelphia/
    /// Filadelfia, Christopher/Kristopher, receive/recieve) agrees at full
    /// length, so tolerance for real misspellings is unchanged.
    func fullCodes(_ text: String) -> (primary: String, secondary: String?) {
        let cleaned = text.uppercased().filter { $0.isLetter }
        guard !cleaned.isEmpty else { return ("", nil) }

        var context = MetaphoneContext(text: cleaned)
        processInitialExceptions(&context)
        processMainLoop(&context)
        return context.fullResult()
    }

    func arePhoneticMatch(_ str1: String, _ str2: String) -> Bool {
        let codes1 = fullCodes(str1)
        let codes2 = fullCodes(str2)

        guard !codes1.primary.isEmpty && !codes2.primary.isEmpty else { return false }

        if codes1.primary == codes2.primary { return true }
        if let sec1 = codes1.secondary, sec1 == codes2.primary { return true }
        if let sec2 = codes2.secondary, codes1.primary == sec2 { return true }
        if let sec1 = codes1.secondary, let sec2 = codes2.secondary, sec1 == sec2 { return true }
        return false
    }

    // MARK: Processing

    private func processInitialExceptions(_ context: inout MetaphoneContext) {
        if context.stringAt(0, 2, "GN", "KN", "PN", "WR", "PS") {
            context.advanceIndex()
        }
        if context.charAt(0) == "X" {
            context.appendBoth("S")
            context.advanceIndex()
        }
    }

    private func processMainLoop(_ context: inout MetaphoneContext) {
        while context.hasMore() {
            let ch = context.currentChar()
            let pos = context.currentPosition()
            processCharacter(ch, at: pos, context: &context)
            context.advanceIndex()
        }
    }

    private func processCharacter(_ ch: Character, at pos: Int, context: inout MetaphoneContext) {
        switch ch {
        case "A", "E", "I", "O", "U", "Y":
            processVowel(at: pos, context: &context)
        case "B": processB(context: &context)
        case "C": processC(at: pos, context: &context)
        case "D": processD(at: pos, context: &context)
        case "F": processF(context: &context)
        case "G": processG(at: pos, context: &context)
        case "H": processH(at: pos, context: &context)
        case "J": processJ(at: pos, context: &context)
        case "K", "L", "M", "N": processSimple(ch, context: &context)
        case "P": processP(context: &context)
        case "Q": processQ(context: &context)
        case "R": processR(context: &context)
        case "S": processS(at: pos, context: &context)
        case "T": processT(at: pos, context: &context)
        case "V": processV(context: &context)
        case "W": processW(at: pos, context: &context)
        case "X": processX(at: pos, context: &context)
        case "Z": processZ(context: &context)
        default: break
        }
    }

    private func processVowel(at pos: Int, context: inout MetaphoneContext) {
        if pos == 0 { context.appendBoth("A") }
    }

    private func processB(context: inout MetaphoneContext) {
        context.appendBoth("P")
        if context.charAt(1) == "B" { context.advanceIndex() }
    }

    private func processC(at pos: Int, context: inout MetaphoneContext) {
        if context.stringAt(pos, 2, "CH") {
            if pos == 0 && context.stringAt(pos, 3, "CHR") {
                context.appendBoth("K")
                context.advanceIndex()
            } else if context.stringAt(pos, 3, "CHL", "CHM", "CHN") {
                context.appendBoth("K")
                context.advanceIndex()
            } else if pos == 0 {
                context.appendPrimary("K")
                context.appendSecondary("X")
                context.advanceIndex()
            } else {
                context.appendPrimary("X")
                context.appendSecondary("K")
                context.advanceIndex()
            }
        } else if pos == 0 && context.stringAt(pos, 2, "CE", "CI") {
            context.appendBoth("S")
        } else if context.stringAt(pos, 2, "CE", "CI", "CY") {
            context.appendBoth("S")
        } else {
            context.appendBoth("K")
        }
        if context.charAt(1) == "C" && !context.stringAt(pos, 2, "CH") {
            context.advanceIndex()
        }
    }

    private func processD(at pos: Int, context: inout MetaphoneContext) {
        if context.stringAt(pos, 2, "DG") && (context.charAt(2) == "E" || context.charAt(2) == "I" || context.charAt(2) == "Y") {
            context.appendBoth("J")
            context.advanceIndex(by: 2)
        } else {
            context.appendBoth("T")
        }
        if context.charAt(1) == "D" { context.advanceIndex() }
    }

    private func processF(context: inout MetaphoneContext) {
        context.appendBoth("F")
        if context.charAt(1) == "F" { context.advanceIndex() }
    }

    private func processG(at pos: Int, context: inout MetaphoneContext) {
        if context.charAt(1) == "H" {
            if pos > 0 && !context.isVowel(context.charAt(-1)) {
                context.appendBoth("K")
            } else if pos == 0 {
                if context.charAt(2) == "I" {
                    context.appendBoth("J")
                } else {
                    context.appendBoth("K")
                }
            }
        } else if context.stringAt(pos, 2, "GN", "GNED") {
            context.advanceIndex()
        } else if context.charAt(1) == "E" || context.charAt(1) == "I" || context.charAt(1) == "Y" {
            context.appendPrimary("J")
            context.appendSecondary("K")
        } else {
            context.appendBoth("K")
        }
        if context.charAt(1) == "G" { context.advanceIndex() }
    }

    private func processH(at pos: Int, context: inout MetaphoneContext) {
        if (context.charAt(1) != nil && context.isVowel(context.charAt(1))) && (pos == 0 || !context.isVowel(context.charAt(-1))) {
            context.appendBoth("H")
        }
    }

    private func processJ(at pos: Int, context: inout MetaphoneContext) {
        context.appendPrimary("J")
        if pos == 0 || (context.charAt(-1) != nil && context.isVowel(context.charAt(-1))) {
            context.appendSecondary("J")
        } else {
            context.appendSecondary("A")
        }
        if context.charAt(1) == "J" { context.advanceIndex() }
    }

    private func processSimple(_ ch: Character, context: inout MetaphoneContext) {
        context.appendBoth(String(ch))
        if context.charAt(1) == ch { context.advanceIndex() }
    }

    private func processP(context: inout MetaphoneContext) {
        if context.charAt(1) == "H" {
            context.appendBoth("F")
            context.advanceIndex()
        } else {
            context.appendBoth("P")
        }
        if context.charAt(1) == "P" { context.advanceIndex() }
    }

    private func processQ(context: inout MetaphoneContext) {
        context.appendBoth("K")
        if context.charAt(1) == "Q" { context.advanceIndex() }
    }

    private func processR(context: inout MetaphoneContext) {
        context.appendBoth("R")
        if context.charAt(1) == "R" { context.advanceIndex() }
    }

    private func processS(at pos: Int, context: inout MetaphoneContext) {
        if context.stringAt(pos, 2, "SH") {
            context.appendBoth("X")
            context.advanceIndex()
        } else if context.stringAt(pos, 3, "SIO", "SIA") {
            context.appendPrimary("S")
            context.appendSecondary("X")
        } else {
            context.appendBoth("S")
        }
        if context.charAt(1) == "S" { context.advanceIndex() }
    }

    private func processT(at pos: Int, context: inout MetaphoneContext) {
        if context.stringAt(pos, 3, "TIA", "TIO") {
            context.appendBoth("X")
        } else if context.stringAt(pos, 2, "TH") {
            context.appendPrimary("0")
            context.appendSecondary("T")
            context.advanceIndex()
        } else if context.stringAt(pos, 2, "TCH") {
            context.appendBoth("X")
        } else {
            context.appendBoth("T")
        }
        if context.charAt(1) == "T" { context.advanceIndex() }
    }

    private func processV(context: inout MetaphoneContext) {
        context.appendBoth("F")
        if context.charAt(1) == "V" { context.advanceIndex() }
    }

    private func processW(at pos: Int, context: inout MetaphoneContext) {
        if pos == 0 && (context.charAt(1) != nil && context.isVowel(context.charAt(1))) {
            context.appendPrimary("A")
            context.appendSecondary("F")
        } else if context.stringAt(pos, 2, "WR") {
            context.appendBoth("R")
            context.advanceIndex()
        }
    }

    private func processX(at pos: Int, context: inout MetaphoneContext) {
        if pos == 0 {
            context.appendBoth("S")
        } else {
            context.appendBoth("KS")
        }
    }

    private func processZ(context: inout MetaphoneContext) {
        context.appendBoth("S")
        if context.charAt(1) == "Z" { context.advanceIndex() }
    }
}

/// Context for Double Metaphone encoding. Moved verbatim from KBPhoneticMatcher.
private struct MetaphoneContext {
    let text: String
    var index: String.Index
    var primary: String = ""
    var secondary: String = ""

    init(text: String) {
        self.text = text
        self.index = text.startIndex
    }

    mutating func advanceIndex(by offset: Int = 1) {
        index = text.index(index, offsetBy: offset, limitedBy: text.endIndex) ?? text.endIndex
    }

    func hasMore() -> Bool { index < text.endIndex }
    func currentChar() -> Character { text[index] }
    func currentPosition() -> Int { text.distance(from: text.startIndex, to: index) }

    func charAt(_ offset: Int) -> Character? {
        let targetIndex = text.index(index, offsetBy: offset, limitedBy: offset < 0 ? text.startIndex : text.endIndex)
        guard let targetIndex, text.indices.contains(targetIndex) else { return nil }
        return text[targetIndex]
    }

    func stringAt(_ start: Int, _ length: Int, _ matches: String...) -> Bool {
        guard start >= 0 else { return false }
        guard let startIdx = text.index(text.startIndex, offsetBy: start, limitedBy: text.endIndex) else { return false }
        guard text.distance(from: startIdx, to: text.endIndex) >= length else { return false }
        let endIdx = text.index(startIdx, offsetBy: length)
        return matches.contains(String(text[startIdx..<endIdx]))
    }

    func isVowel(_ ch: Character?) -> Bool {
        guard let ch else { return false }
        return "AEIOUY".contains(ch)
    }

    mutating func appendPrimary(_ code: String) { primary.append(code) }
    mutating func appendSecondary(_ code: String) { secondary.append(code) }
    mutating func appendBoth(_ code: String) {
        primary.append(code)
        secondary.append(code)
    }

    /// The classic 4-character Double Metaphone codes.
    func result() -> (primary: String, secondary: String?) {
        let primaryCode = String(primary.prefix(4))
        let secondaryCode = secondary.isEmpty || secondary == primary ? nil : String(secondary.prefix(4))
        return (primaryCode, secondaryCode)
    }

    /// The untruncated codes, used for match decisions.
    func fullResult() -> (primary: String, secondary: String?) {
        (primary, secondary.isEmpty || secondary == primary ? nil : secondary)
    }
}

// MARK: - N-Gram Matcher

/// Character/word n-gram similarity. Moved from KBNGramMatcher.
struct EvalNGramMatcher: Sendable {

    func characterNGramSimilarity(_ str1: String, _ str2: String, n: Int) -> Float {
        let padded1 = String(repeating: "#", count: n - 1) + str1.lowercased() + String(repeating: "#", count: n - 1)
        let padded2 = String(repeating: "#", count: n - 1) + str2.lowercased() + String(repeating: "#", count: n - 1)
        let ngrams1 = characterNGrams(padded1, n: n)
        let ngrams2 = characterNGrams(padded2, n: n)
        guard !ngrams1.isEmpty && !ngrams2.isEmpty else { return str1 == str2 ? 1.0 : 0.0 }
        return diceMultisetSimilarity(ngrams1, ngrams2)
    }

    func wordNGramSimilarity(_ str1: String, _ str2: String, n: Int) -> Float {
        let ngrams1 = wordNGrams(str1.lowercased(), n: n)
        let ngrams2 = wordNGrams(str2.lowercased(), n: n)
        guard !ngrams1.isEmpty && !ngrams2.isEmpty else { return str1 == str2 ? 1.0 : 0.0 }
        return diceMultisetSimilarity(ngrams1, ngrams2)
    }

    func nGramScore(_ str1: String, _ str2: String) -> Float {
        let normalized1 = str1.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized2 = str2.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized1 != normalized2 else { return 1.0 }

        let unigramScore = characterUnigramSimilarity(normalized1, normalized2)
        let bigramScore = characterNGramSimilarity(normalized1, normalized2, n: 2)
        let trigramScore = characterNGramSimilarity(normalized1, normalized2, n: 3)

        let isMultiWord = normalized1.contains(" ") || normalized2.contains(" ")
        if isMultiWord {
            let wordScore = wordBySimilarity(normalized1, normalized2)
            return (unigramScore * 0.2) + (bigramScore * 0.25) + (trigramScore * 0.25) + (wordScore * 0.3)
        } else {
            return (unigramScore * 0.3) + (bigramScore * 0.35) + (trigramScore * 0.35)
        }
    }

    private func characterUnigramSimilarity(_ str1: String, _ str2: String) -> Float {
        let chars1 = Array(str1.filter { !$0.isWhitespace })
        let chars2 = Array(str2.filter { !$0.isWhitespace })
        guard !chars1.isEmpty && !chars2.isEmpty else {
            return chars1.isEmpty && chars2.isEmpty ? 1.0 : 0.0
        }
        var freq1: [Character: Int] = [:]
        var freq2: [Character: Int] = [:]
        for ch in chars1 { freq1[ch, default: 0] += 1 }
        for ch in chars2 { freq2[ch, default: 0] += 1 }
        var intersection = 0
        for (ch, count1) in freq1 {
            if let count2 = freq2[ch] { intersection += min(count1, count2) }
        }
        return Float(2 * intersection) / Float(chars1.count + chars2.count)
    }

    private func wordBySimilarity(_ str1: String, _ str2: String) -> Float {
        let words1 = str1.split(separator: " ").map(String.init)
        let words2 = str2.split(separator: " ").map(String.init)
        guard !words1.isEmpty && !words2.isEmpty else { return 0.0 }
        var totalScore: Float = 0.0
        for word1 in words1 {
            var bestMatch: Float = 0.0
            for word2 in words2 {
                bestMatch = max(bestMatch, characterNGramSimilarity(word1, word2, n: 2))
            }
            totalScore += bestMatch
        }
        return totalScore / Float(words1.count)
    }

    private func characterNGrams(_ text: String, n: Int) -> [String] {
        guard text.count >= n else { return [text] }
        var ngrams: [String] = []
        let chars = Array(text)
        for i in 0...(chars.count - n) {
            ngrams.append(String(chars[i..<(i + n)]))
        }
        return ngrams
    }

    private func wordNGrams(_ text: String, n: Int) -> [String] {
        let words = text.split(separator: " ").map(String.init)
        guard words.count >= n else { return [text] }
        var ngrams: [String] = []
        for i in 0...(words.count - n) {
            ngrams.append(words[i..<(i + n)].joined(separator: " "))
        }
        return ngrams
    }

    private func diceMultisetSimilarity(_ arr1: [String], _ arr2: [String]) -> Float {
        guard !arr1.isEmpty || !arr2.isEmpty else { return 1.0 }
        guard !arr1.isEmpty && !arr2.isEmpty else { return 0.0 }
        var counts1: [String: Int] = [:]
        var counts2: [String: Int] = [:]
        for item in arr1 { counts1[item, default: 0] += 1 }
        for item in arr2 { counts2[item, default: 0] += 1 }
        var intersectionCount = 0
        for (key, count1) in counts1 {
            if let count2 = counts2[key] { intersectionCount += min(count1, count2) }
        }
        return Float(2 * intersectionCount) / Float(arr1.count + arr2.count)
    }
}

// MARK: - Token Matcher

/// Token Jaccard/Dice similarity. Moved from KBTokenMatcher.
struct EvalTokenMatcher: Sendable {

    func jaccardSimilarity(_ str1: String, _ str2: String) -> Float {
        let tokens1 = tokenize(str1)
        let tokens2 = tokenize(str2)
        if tokens1.isEmpty && tokens2.isEmpty { return 1.0 }
        guard !tokens1.isEmpty && !tokens2.isEmpty else { return 0.0 }
        let intersection = tokens1.intersection(tokens2).count
        let union = tokens1.union(tokens2).count
        guard union > 0 else { return 0.0 }
        return Float(intersection) / Float(union)
    }

    func diceSimilarity(_ str1: String, _ str2: String) -> Float {
        let tokens1 = tokenize(str1)
        let tokens2 = tokenize(str2)
        if tokens1.isEmpty && tokens2.isEmpty { return 1.0 }
        guard !tokens1.isEmpty && !tokens2.isEmpty else { return 0.0 }
        let intersection = tokens1.intersection(tokens2).count
        let sumOfSizes = tokens1.count + tokens2.count
        guard sumOfSizes > 0 else { return 0.0 }
        return Float(2 * intersection) / Float(sumOfSizes)
    }

    func tokenScore(_ str1: String, _ str2: String) -> Float {
        (jaccardSimilarity(str1, str2) + diceSimilarity(str1, str2)) / 2.0
    }

    private func tokenize(_ text: String) -> Set<String> {
        let normalized = text.lowercased()
        let tokens = normalized.components(separatedBy: .whitespacesAndNewlines)
            .flatMap { $0.components(separatedBy: .punctuationCharacters) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let stopWords: Set<String> = [
            "the", "a", "an", "of", "in", "at", "on", "to", "for", "with", "by", "from",
            "dr", "mr", "mrs", "ms", "jr", "sr"
        ]
        return Set(tokens.filter { !stopWords.contains($0) })
    }
}

// MARK: - Linguistic Matcher

/// Lemmatization and key-term extraction via Apple NaturalLanguage. Moved from
/// KBLinguisticMatcher.
struct EvalLinguisticMatcher: Sendable {

    /// Common function words dropped by the deterministic key-term fallback.
    private static let functionWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "nor", "is", "are", "was", "were",
        "am", "be", "been", "being", "of", "to", "in", "on", "at", "for", "with",
        "as", "by", "that", "this", "these", "those", "it", "its",
    ]

    func lemmatize(_ text: String) -> String {
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = text
        var lemmatized: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lemma) { tag, tokenRange in
            let word = tag?.rawValue ?? String(text[tokenRange])
            lemmatized.append(word)
            return true
        }
        return lemmatized.joined(separator: " ")
    }

    /// Extract key nouns and verbs for semantic core matching.
    func extractKeyTerms(_ text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var keyTerms: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass) { tag, tokenRange in
            guard let tag else { return true }
            if tag == .noun || tag == .verb {
                keyTerms.append(String(text[tokenRange]).lowercased())
            }
            return true
        }
        // NLTagger's lexical-class model is not guaranteed to be available in
        // every environment (for example a cold CI simulator); fall back to a
        // deterministic tokenizer that drops function words.
        if keyTerms.isEmpty {
            keyTerms = Self.fallbackKeyTerms(text)
        }
        return keyTerms
    }

    private static func fallbackKeyTerms(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !functionWords.contains($0) }
    }

    /// Whether two texts share a significant fraction of key terms (>= 50%).
    func shareKeyTerms(_ str1: String, _ str2: String) -> Bool {
        let terms1 = Set(extractKeyTerms(str1))
        let terms2 = Set(extractKeyTerms(str2))
        guard !terms1.isEmpty && !terms2.isEmpty else { return false }
        let overlap = Float(terms1.intersection(terms2).count) / Float(terms1.union(terms2).count)
        return overlap >= 0.5
    }

    func areLemmasEquivalent(_ str1: String, _ str2: String) -> Bool {
        let lemma1 = lemmatize(str1.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
        let lemma2 = lemmatize(str2.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
        return lemma1 == lemma2
    }
}
