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

// MARK: - Prompt Building
extension MMLUEntry {
    /// Introduction text for MMLU prompts - includes category
    static func promptIntro(for category: String, reasoning: Bool) -> String {
        if reasoning {
            // Reasoning / CoT mode
            return "The following are multiple choice questions (with answers) about \(category). Think step by step and then finish your answer with \"The answer is (X)\" where X is the correct letter choice."
            //return """
            //You are answering multiple-choice questions about \(category).
            //Think step by step and then finish your answer with "The answer is (X)" where X is the correct letter choice.
            //"""
        } else {
            // Direct-answer MCQ mode (no explanations)
            return """
            You are answering multiple-choice exam questions.

            IMPORTANT:
            - Do NOT repeat or restate the question.
            - Do NOT start your answer with "Question:" or "Options:".
            - Do NOT list the answer choices again.
            - Do NOT include any explanation or reasoning.
            - Answer ONLY in the format: "The answer is (X)" where X is the correct letter choice.
            """
        }
    }

    /// Lead-in text before model generates answer
    static func promptLeadIn(reasoning: Bool) -> String {
        if reasoning {
            // CoT mode: explicitly invite step-by-step thinking
            return "Let's think step by step."
            //return "Answer: Let's think step by step."
        } else {
            // Direct mode: let the model generate "The answer is (X)" itself
            // Do NOT pre-seed "Answer: The answer is (" – that conflicts with the system prompt
            return ""
        }
    }

    /// Format this entry as a few-shot example (uses chain-of-thought if reasoning enabled)
    func formatAsExample(reasoning: Bool) -> String {
        if reasoning {
            let cot = cotContent.isEmpty ? "The answer is (\(answer))." : cotContent
            return """
                Question: \(question)
                Options: \(formattedOptions)
                Answer: \(cot)


                """
        } else {
            return """
                Question: \(question)
                Options: \(formattedOptions)
                Answer: The answer is (\(answer)).


                """
        }
    }

    /// Format this entry as the final question (without answer)
    func formatAsQuestion() -> String {
        return "Question: \(question)\nOptions: \(formattedOptions)"
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
