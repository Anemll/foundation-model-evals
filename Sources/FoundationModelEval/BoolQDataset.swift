import Foundation

struct BoolQEntry: Codable {
    let question: String
    let answerBool: Bool
    let passage: String

    // Custom coding keys to map JSON "answer" field to our "answerBool" property
    enum CodingKeys: String, CodingKey {
        case question
        case answerBool = "answer"
        case passage
    }

    // Convert to unified format for processing
    var questionId: Int {
        abs(question.hashValue) % 1000000
    }

    var options: [String] {
        ["No", "Yes"]  // Index 0 = No (false), Index 1 = Yes (true)
    }

    var answerString: String {
        answerBool ? "Yes" : "No"
    }

    var answerIndex: Int {
        answerBool ? 1 : 0  // Yes = 1, No = 0
    }

    var category: String {
        "boolq"
    }

    // Full question includes the passage for context
    var fullQuestion: String {
        "\(passage)\n\nQuestion: \(question)"
    }

    // Conform to QuestionEntry protocol
    var answer: String {
        answerLetter ?? "A"
    }
}

typealias BoolQDataset = [BoolQEntry]

// asciiA is defined in MMLUEntry.swift

extension BoolQEntry {
    func answerLetter(for index: Int) -> String {
        String(Character(UnicodeScalar(65 + index)!))  // 65 = ASCII 'A'
    }

    var answerLetter: String? {
        guard answerIndex >= 0 && answerIndex < options.count else { return nil }
        return answerLetter(for: answerIndex)
    }

    var isValidIndex: Bool {
        return answerIndex >= 0 && answerIndex < options.count
    }

    var isValid: Bool {
        return !question.isEmpty && !passage.isEmpty
    }

    var selectedOption: String? {
        guard isValidIndex else { return nil }
        return options[answerIndex]
    }

    var formattedOptions: String {
        options.enumerated().reduce("") { prev, item in
            let (index, option) = item
            var result = prev.isEmpty ? prev : "\(prev), "
            let letter = String(Character(UnicodeScalar(65 + index)!))  // 65 = ASCII 'A'
            result += "\(letter). \(option)"
            return result
        }
    }
}

// MARK: - Download
extension BoolQDataset {
    /// Downloads BoolQ dataset from HuggingFace and saves as JSONL
    /// Returns the path to the cache directory
    static func downloadAndExtract(progressCallback: ((Double) -> Void)? = nil) async throws -> URL {
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache")
            .appendingPathComponent("boolq-dataset")

        // Check if already downloaded
        let validationPath = cacheDir.appendingPathComponent("validation.jsonl")
        if FileManager.default.fileExists(atPath: validationPath.path) {
            print("BoolQ dataset already cached at: \(cacheDir.path)")
            return cacheDir
        }

        // Create cache directory
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        print("Downloading BoolQ dataset from HuggingFace...")

        // HuggingFace datasets API - download each split
        // BoolQ has train and validation splits (no test split)
        // We'll use train for few-shot examples and validation for testing
        let splits = [
            ("train", "train.jsonl"),
            ("validation", "validation.jsonl"),
        ]

        for (split, filename) in splits {
            print("  Downloading \(split)...")
            let entries = try await downloadSplitFromHuggingFace(split: split)
            let outputPath = cacheDir.appendingPathComponent(filename)
            try saveAsJSONL(entries: entries, to: outputPath)
            print("    Saved \(entries.count) entries to \(filename)")
        }

        print("BoolQ dataset downloaded to: \(cacheDir.path)")
        return cacheDir
    }

    /// Downloads a split from HuggingFace using the datasets API
    private static func downloadSplitFromHuggingFace(split: String) async throws -> [BoolQEntry] {
        var allEntries: [BoolQEntry] = []
        var offset = 0
        let batchSize = 100
        let maxRetries = 10

        // Initial delay to avoid immediate rate limiting
        print("      Starting download (with rate limit handling)...")

        while true {
            let urlString = "https://datasets-server.huggingface.co/rows?dataset=google/boolq&config=default&split=\(split)&offset=\(offset)&length=\(batchSize)"
            guard let url = URL(string: urlString) else {
                throw NSError(domain: "BoolQDataset", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
            }

            var lastError: Error?
            var data: Data?

            // Retry loop with exponential backoff
            for attempt in 0..<maxRetries {
                do {
                    // Add delay before each request (longer for retries)
                    if attempt > 0 {
                        let waitTime = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000 // exponential backoff
                        print("      Retry \(attempt + 1)/\(maxRetries), waiting \(Int(pow(2.0, Double(attempt))))s...")
                        try await Task.sleep(nanoseconds: waitTime)
                    }

                    let (fetchedData, response) = try await URLSession.shared.data(from: url)

                    if let httpResponse = response as? HTTPURLResponse {
                        if httpResponse.statusCode == 200 {
                            data = fetchedData
                            break
                        } else if httpResponse.statusCode == 429 {
                            // Rate limited - continue to retry with backoff
                            lastError = NSError(domain: "BoolQDataset", code: 429, userInfo: [NSLocalizedDescriptionKey: "Rate limited"])
                            continue
                        } else {
                            lastError = NSError(domain: "BoolQDataset", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode)"])
                        }
                    }
                } catch {
                    lastError = error
                }
            }

            guard let fetchedData = data else {
                throw lastError ?? NSError(domain: "BoolQDataset", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch data from HuggingFace after \(maxRetries) retries"])
            }

            // Parse the response
            guard let json = try? JSONSerialization.jsonObject(with: fetchedData) as? [String: Any],
                  let rows = json["rows"] as? [[String: Any]] else {
                throw NSError(domain: "BoolQDataset", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to parse HuggingFace response"])
            }

            if rows.isEmpty {
                break
            }

            for row in rows {
                guard let rowData = row["row"] as? [String: Any],
                      let question = rowData["question"] as? String,
                      let answer = rowData["answer"] as? Bool,
                      let passage = rowData["passage"] as? String else {
                    continue
                }

                let entry = BoolQEntry(question: question, answerBool: answer, passage: passage)
                allEntries.append(entry)
            }

            offset += batchSize
            print("      Downloaded \(allEntries.count) entries...")

            // Delay between successful requests to avoid rate limiting
            try await Task.sleep(nanoseconds: 500_000_000) // 500ms between requests

            // Check if we've fetched all rows
            if rows.count < batchSize {
                break
            }
        }

        return allEntries
    }

    /// Saves entries as JSONL format
    private static func saveAsJSONL(entries: [BoolQEntry], to url: URL) throws {
        let encoder = JSONEncoder()
        var lines: [String] = []

        for entry in entries {
            let data = try encoder.encode(entry)
            if let line = String(data: data, encoding: .utf8) {
                lines.append(line)
            }
        }

        let content = lines.joined(separator: "\n")
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Loading
extension BoolQDataset {
    static func loadFromFile(at url: URL) throws -> BoolQDataset {
        let content = try String(contentsOf: url, encoding: .utf8)
        return try loadFromJSONL(content)
    }

    static func loadFromJSONL(_ jsonlString: String) throws -> BoolQDataset {
        let lines = jsonlString.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let decoder = JSONDecoder()
        var entries: BoolQDataset = []

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
                let entry = try decoder.decode(BoolQEntry.self, from: data)
                entries.append(entry)
            } catch {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: [],
                        debugDescription: "Failed to parse line \(index + 1): \(error.localizedDescription)"
                    )
                )
            }
        }

        return entries
    }
}

// MARK: - Prompt Building
extension BoolQEntry {
    /// Introduction text for BoolQ prompts - with optional reasoning (chain-of-thought)
    static func promptIntro(reasoning: Bool) -> String {
        if reasoning {
            // Reasoning / CoT mode
            return """
            You are answering yes/no questions based on a passage.
            Read the passage carefully, think step by step, then finish with "The answer is (A)" for No or "The answer is (B)" for Yes.
            """
        } else {
            // Direct-answer mode (no explanations)
            return """
            You are answering yes/no questions based on a passage.

            IMPORTANT:
            - Do NOT repeat or restate the passage or question.
            - Do NOT provide explanations or reasoning.
            - Answer ONLY in the format: "The answer is (A)" for No or "The answer is (B)" for Yes.
            """
        }
    }

    /// Lead-in text before model generates answer
    static func promptLeadIn(reasoning: Bool) -> String {
        if reasoning {
            // CoT mode: explicitly invite step-by-step thinking
            return "Let's think step by step."
        } else {
            // Direct mode: let the model generate the answer itself
            // Do NOT pre-seed with prefix – that conflicts with the system prompt
            return ""
        }
    }

    /// Format this entry as a few-shot example
    func formatAsExample(reasoning: Bool) -> String {
        let letter = answerBool ? "B" : "A"
        let word = answerBool ? "Yes" : "No"
        if reasoning {
            return """
                Passage: \(passage)

                Question: \(question)

                Answer: Let's think step by step. The answer is (\(letter)). \(word)

                ---

                """
        } else {
            return """
                Passage: \(passage)

                Question: \(question)

                Answer: The answer is (\(letter)).

                ---

                """
        }
    }

    /// Format this entry as the final question (without answer)
    func formatAsQuestion() -> String {
        return "Passage: \(passage)\n\nQuestion: \(question)"
    }
}

// MARK: - Filtering and Querying
extension Array where Element == BoolQEntry {
    var validQuestions: [BoolQEntry] {
        return self.filter(\.isValid)
    }

    func filter(byCategory category: String) -> [BoolQEntry] {
        if category == "boolq" {
            return validQuestions
        }
        return []
    }

    var uniqueCategories: Set<String> {
        return ["boolq"]
    }

    func groupedByCategory() -> [String: [BoolQEntry]] {
        return ["boolq": validQuestions]
    }

    var invalidQuestions: [BoolQEntry] {
        return self.filter { !$0.isValid }
    }
}
