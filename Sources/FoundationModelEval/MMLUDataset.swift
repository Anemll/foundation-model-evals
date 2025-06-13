import Foundation

struct MMLUEntry: Codable {
    let questionId: Int
    let question: String
    let options: [String]
    let answer: String
    let answerIndex: Int
    let cotContent: String
    let category: String
    let src: String
    
    enum CodingKeys: String, CodingKey {
        case questionId = "question_id"
        case question
        case options
        case answer
        case answerIndex = "answer_index"
        case cotContent = "cot_content"
        case category
        case src
    }
}

typealias MMLUDataset = [MMLUEntry]

// 65
let asciiA: UInt8 = ("A" as Character).asciiValue!

extension MMLUEntry {
    func answerLetter(for answerIndex: Int) -> String {
        String(Character(UnicodeScalar(Int(asciiA) + answerIndex)!))
    }

    var answerLetter: String? {
        guard isValidIndex else { return nil }
        return answerLetter(for: answerIndex)
    }

    // "J"
    var maxAnswerLetter: String? {
        guard options.count > 0 else { return nil }
        return String(Character(UnicodeScalar(Int(asciiA) + options.count - 1)!))
    }

    var isValidIndex: Bool {
        return answerIndex >= 0 && answerIndex < options.count
    }

    /// Validates that the answer letter matches the answer_index (A=0, B=1, etc.)
    var isAnswerConsistent: Bool {
        guard answer.count == 1,
              let firstChar = answer.first else {
            return false
        }

        let letterIndex = Int(firstChar.asciiValue! - asciiA)
        guard letterIndex >= 0 && letterIndex < options.count else {
            return false
        }

        return letterIndex == answerIndex
    }

    var isValid: Bool { isValidIndex && isAnswerConsistent }

    var selectedOption: String? {
        guard isValidIndex else { return nil }
        return options[answerIndex]
    }

    var formattedOptions: String {
        options.enumerated().reduce("") { prev, item in
            let (answerIndex, answer) = item
            var result = prev.isEmpty ? prev : "\(prev), "
            result += "\(answerLetter(for: answerIndex)). \(answer)"
            return result
        }
    }
}

// MARK: - Loading
extension MMLUDataset {
    static func loadFromFile(at url: URL) throws -> MMLUDataset {
        let content = try String(contentsOf: url, encoding: .utf8)
        return try loadFromJSONL(content)
    }

    static func loadFromJSONL(_ jsonlString: String) throws -> MMLUDataset {
        let lines = jsonlString.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let decoder = JSONDecoder()
        var questions: MMLUDataset = []

        for (index, line) in lines.enumerated() {
            guard let data = line.data(using: .utf8) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: [],
                        debugDescription: "Failed to convert line \(index + 1) to UTF-8 data"
                    )
                )
            }

            do {
                let question = try decoder.decode(MMLUEntry.self, from: data)
                questions.append(question)
            } catch {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: [],
                        debugDescription: "Failed to parse line \(index + 1): \(error.localizedDescription)"
                    )
                )
            }
        }

        return questions
    }
}

// MARK: - Filtering and Querying
extension Array where Element == MMLUEntry {
    var validQuestions: [MMLUEntry] {
        return self.filter(\.isValid)
    }

    func filter(byCategory category: String) -> [MMLUEntry] {
        return validQuestions.filter { $0.category == category }
    }
    
    func filter(bySource source: String) -> [MMLUEntry] {
        return validQuestions.filter { $0.src == source }
    }
    
    var uniqueCategories: Set<String> {
        return Set(self.map { $0.category })
    }
    
    var uniqueSources: Set<String> {
        return Set(self.map { $0.src })
    }
    
    func groupedByCategory() -> [String: [MMLUEntry]] {
        return Dictionary(grouping: self, by: { $0.category })
    }
    
    var invalidQuestions: [MMLUEntry] {
        return self.filter { !$0.isValid }
    }
    
    var inconsistentQuestions: [MMLUEntry] {
        return self.filter { $0.isValidIndex && !$0.isValid }
    }
}
