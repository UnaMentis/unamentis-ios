// UnaMentis - Evaluation Normalization
// MODULE_SDK_SPEC.md section 5.2.
//
// Category-aware answer normalization, MOVED from KBAnswerValidator and
// generalized from KBAnswerType to AnswerCategory. The behavior is identical to
// KB's normalize/normalizeText/normalizePerson/... family so the lift preserves
// verdicts. Punctuation stripping, article removal, "Last, First" reordering,
// title/subtitle handling, written-number parsing, place abbreviations, and
// scientific-formula whitespace removal all match the legacy validator.

import Foundation

extension DefaultResponseEvaluationService {

    /// Normalize text based on answer category. Mirrors KBAnswerValidator.normalize.
    func normalize(_ text: String, for category: AnswerCategory) -> String {
        let base = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch category {
        case .text:
            return normalizeText(base)
        case .person:
            return normalizePerson(base)
        case .place:
            return normalizePlace(base)
        case .numeric:
            return normalizeNumber(base)
        case .date:
            return normalizeDate(base)
        case .title:
            return normalizeTitle(base)
        case .scientific:
            return normalizeScientific(base)
        case .choice:
            return base.filter { $0.isLetter }.prefix(1).lowercased()
        }
    }

    private func normalizeText(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "[.,!?;:'\"()-]", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        result = removeArticles(result)
        return result.trimmingCharacters(in: .whitespaces)
    }

    private func normalizePerson(_ text: String) -> String {
        // Reorder "Last, First" before normalizeText strips the comma.
        var result = text
        if result.contains(",") {
            let parts = result.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                result = "\(parts[1]) \(parts[0])"
            }
        }
        result = normalizeText(result)
        let titles = ["dr", "mr", "mrs", "ms", "miss", "prof", "professor", "sir", "dame", "lord", "lady"]
        for title in titles {
            result = result.replacingOccurrences(of: "^\(title)\\.?\\s+", with: "", options: .regularExpression)
        }
        return result
    }

    private func normalizePlace(_ text: String) -> String {
        var result = normalizeText(text)
        let abbreviations: [String: String] = [
            "usa": "united states of america",
            "us": "united states",
            "uk": "united kingdom",
            "uae": "united arab emirates",
            "mt": "mount",
            "st": "saint",
            "ft": "fort"
        ]
        for (abbr, full) in abbreviations where result == abbr {
            result = full
        }
        return result
    }

    private func normalizeNumber(_ text: String) -> String {
        var result = normalizeText(text)
        let wordNumbers: [String: String] = [
            "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
            "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
            "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13",
            "fourteen": "14", "fifteen": "15", "sixteen": "16", "seventeen": "17",
            "eighteen": "18", "nineteen": "19", "twenty": "20", "thirty": "30",
            "forty": "40", "fifty": "50", "sixty": "60", "seventy": "70",
            "eighty": "80", "ninety": "90", "hundred": "100", "thousand": "1000",
            "million": "1000000", "billion": "1000000000"
        ]
        for (word, num) in wordNumbers where result == word {
            return num
        }
        result = result.replacingOccurrences(of: ",", with: "")
        return result
    }

    private func normalizeDate(_ text: String) -> String {
        var result = normalizeText(text)
        let months: [String: String] = [
            "january": "1", "jan": "1", "february": "2", "feb": "2",
            "march": "3", "mar": "3", "april": "4", "apr": "4",
            "may": "5", "june": "6", "jun": "6", "july": "7", "jul": "7",
            "august": "8", "aug": "8", "september": "9", "sep": "9", "sept": "9",
            "october": "10", "oct": "10", "november": "11", "nov": "11",
            "december": "12", "dec": "12"
        ]
        for (name, num) in months {
            result = result.replacingOccurrences(of: name, with: num)
        }
        return result
    }

    private func normalizeTitle(_ text: String) -> String {
        // Drop the subtitle after a colon before normalizeText strips the colon.
        var result = text
        if let colonIndex = result.firstIndex(of: ":") {
            result = String(result[..<colonIndex])
        }
        result = normalizeText(result)
        result = result.replacingOccurrences(of: "^the\\s+", with: "", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespaces)
    }

    private func normalizeScientific(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    }

    private func removeArticles(_ text: String) -> String {
        var result = text
        let articles = ["the ", "a ", "an "]
        for article in articles where result.hasPrefix(article) {
            result = String(result.dropFirst(article.count))
        }
        return result
    }
}
