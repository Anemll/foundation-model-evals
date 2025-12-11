import Foundation

/// Entry for standard MMLU benchmark (cais/mmlu on HuggingFace)
/// Standard MMLU has 4 choices (A-D) and 57 subjects
struct StdMMLUEntry: Codable {
    let question: String
    let subject: String
    let choices: [String]
    let answerIdx: Int  // 0-3 maps to A-D

    enum CodingKeys: String, CodingKey {
        case question, subject, choices
        case answerIdx = "answer"  // JSON has "answer" as Int
    }

    // Computed properties to match the interface expected by evaluation
    var questionId: Int {
        // Generate a stable ID from question hash
        abs(question.hashValue) % 1000000
    }

    var options: [String] { choices }

    var category: String { subject }

    var answerIndex: Int { answerIdx }

    // QuestionEntry protocol requires `answer` as String (the letter)
    var answer: String {
        guard answerIdx >= 0 && answerIdx < 4 else { return "A" }
        return String(Character(UnicodeScalar(65 + answerIdx)!)) // 65 = 'A'
    }
}

// Conformance to QuestionEntry protocol
extension StdMMLUEntry: QuestionEntry {}

typealias StdMMLUDataset = [StdMMLUEntry]

extension StdMMLUEntry {
    func answerLetter(for index: Int) -> String {
        String(Character(UnicodeScalar(Int(asciiA) + index)!))
    }

    var answerLetter: String? {
        guard isValidIndex else { return nil }
        return answerLetter(for: answerIdx)
    }

    var isValidIndex: Bool {
        return answerIdx >= 0 && answerIdx < choices.count
    }

    var isValid: Bool {
        return isValidIndex && choices.count == 4
    }

    var selectedOption: String? {
        guard isValidIndex else { return nil }
        return choices[answerIdx]
    }

    var formattedOptions: String {
        choices.enumerated().reduce("") { prev, item in
            let (index, choice) = item
            let separator = prev.isEmpty ? "" : ", "
            return "\(prev)\(separator)\(answerLetter(for: index)). \(choice)"
        }
    }
}

// MARK: - Download from HuggingFace
extension StdMMLUDataset {
    /// Downloads standard MMLU dataset from HuggingFace and saves as JSONL
    /// Returns the path to the cache directory
    static func downloadAndExtract(progressCallback: ((Double) -> Void)? = nil) async throws -> URL {
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache")
            .appendingPathComponent("stdmmlu-dataset")

        // Check if already downloaded
        let testPath = cacheDir.appendingPathComponent("test.jsonl")
        if FileManager.default.fileExists(atPath: testPath.path) {
            print("Standard MMLU dataset already cached at: \(cacheDir.path)")
            return cacheDir
        }

        // Create cache directory
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        print("Downloading standard MMLU dataset from HuggingFace...")

        // Download test split from all subjects combined
        let splits = ["test", "validation", "dev"]

        for split in splits {
            print("  Downloading \(split) split...")
            let entries = try await downloadSplitFromHuggingFace(config: "all", split: split)
            let outputPath = cacheDir.appendingPathComponent("\(split).jsonl")
            try saveAsJSONL(entries: entries, to: outputPath)
            print("    Saved \(entries.count) entries to \(split).jsonl")
        }

        print("Standard MMLU dataset downloaded to: \(cacheDir.path)")
        return cacheDir
    }

    /// Downloads a split from HuggingFace using the datasets API
    private static func downloadSplitFromHuggingFace(config: String, split: String) async throws -> [StdMMLUEntry] {
        var allEntries: [StdMMLUEntry] = []
        var offset = 0
        let batchSize = 100
        let maxRetries = 10  // More retries for persistent rate limiting
        var consecutiveRateLimits = 0

        while true {
            let urlString = "https://datasets-server.huggingface.co/rows?dataset=cais/mmlu&config=\(config)&split=\(split)&offset=\(offset)&length=\(batchSize)"
            guard let url = URL(string: urlString) else {
                throw NSError(domain: "StdMMLUDataset", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
            }

            // Retry loop with exponential backoff
            var lastError: Error?
            var rows: [[String: Any]]?

            for attempt in 0..<maxRetries {
                do {
                    let (data, response) = try await URLSession.shared.data(from: url)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        lastError = NSError(domain: "StdMMLUDataset", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid response type"])
                        continue
                    }

                    if httpResponse.statusCode == 429 {
                        // Rate limited - wait longer with each consecutive rate limit
                        consecutiveRateLimits += 1
                        let baseWait = Double(Swift.min(1 << attempt, 64))  // Cap at 64 seconds
                        let extraWait = Double(consecutiveRateLimits * 10)  // Add 10s per consecutive rate limit
                        let waitTime = baseWait + extraWait
                        print("    Rate limited (attempt \(attempt + 1)/\(maxRetries)), waiting \(Int(waitTime))s...")
                        try await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
                        continue
                    }

                    guard httpResponse.statusCode == 200 else {
                        lastError = NSError(domain: "StdMMLUDataset", code: 2, userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode) from HuggingFace"])
                        let waitTime = Double(Swift.min(1 << attempt, 32))
                        print("    HTTP error \(httpResponse.statusCode), retrying in \(Int(waitTime))s...")
                        try await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
                        continue
                    }

                    // Parse the response
                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let parsedRows = json["rows"] as? [[String: Any]] else {
                        lastError = NSError(domain: "StdMMLUDataset", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to parse HuggingFace response"])
                        continue
                    }

                    rows = parsedRows
                    consecutiveRateLimits = 0  // Reset on success
                    break  // Success!

                } catch {
                    lastError = error
                    let waitTime = Double(Swift.min(1 << attempt, 32))
                    print("    Network error, retrying in \(Int(waitTime))s...")
                    try await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
                }
            }

            guard let fetchedRows = rows else {
                throw lastError ?? NSError(domain: "StdMMLUDataset", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch data after \(maxRetries) retries"])
            }

            if fetchedRows.isEmpty {
                break
            }

            for row in fetchedRows {
                guard let rowData = row["row"] as? [String: Any],
                      let question = rowData["question"] as? String,
                      let subject = rowData["subject"] as? String,
                      let choices = rowData["choices"] as? [String],
                      let answer = rowData["answer"] as? Int else {
                    continue
                }

                let entry = StdMMLUEntry(question: question, subject: subject, choices: choices, answerIdx: answer)
                allEntries.append(entry)
            }

            offset += batchSize

            // Check if we've fetched all rows
            if fetchedRows.count < batchSize {
                break
            }

            // Progress indicator
            if offset % 1000 == 0 {
                print("    Downloaded \(offset) entries...")
            }

            // Delay between requests - increase if we've been rate limited recently
            let delayMs = consecutiveRateLimits > 0 ? 500 : 100  // 500ms if recent rate limit, else 100ms
            try await Task.sleep(nanoseconds: UInt64(delayMs * 1_000_000))
        }

        return allEntries
    }

    /// Saves entries as JSONL format
    private static func saveAsJSONL(entries: [StdMMLUEntry], to url: URL) throws {
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
extension StdMMLUDataset {
    static func loadFromFile(at url: URL) throws -> StdMMLUDataset {
        let content = try String(contentsOf: url, encoding: .utf8)
        return loadFromJSONL(content)  // Use fault-tolerant loading
    }

    /// Fault-tolerant JSONL loading - skips malformed lines instead of failing
    static func loadFromJSONL(_ jsonlString: String) -> StdMMLUDataset {
        let lines = jsonlString.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let decoder = JSONDecoder()
        var entries: StdMMLUDataset = []
        var skippedCount = 0

        for (index, line) in lines.enumerated() {
            guard let data = line.data(using: .utf8) else {
                print("  Warning: Line \(index + 1) could not be converted to UTF-8, skipping")
                skippedCount += 1
                continue
            }

            do {
                let entry = try decoder.decode(StdMMLUEntry.self, from: data)
                entries.append(entry)
            } catch {
                // Skip malformed lines instead of failing
                if skippedCount < 5 {
                    print("  Warning: Line \(index + 1) parse error, skipping: \(error.localizedDescription)")
                } else if skippedCount == 5 {
                    print("  Warning: Additional parse errors suppressed...")
                }
                skippedCount += 1
            }
        }

        if skippedCount > 0 {
            print("  Skipped \(skippedCount) malformed entries, loaded \(entries.count) valid entries")
        }

        return entries
    }
}

// MARK: - Prompt Building
extension StdMMLUEntry {
    /// Introduction text for standard MMLU prompts - includes subject
    static func promptIntro(for subject: String, reasoning: Bool) -> String {
        // Format subject name (replace underscores with spaces)
        let formattedSubject = subject.replacingOccurrences(of: "_", with: " ")

        if reasoning {
            // Reasoning / CoT mode
            return "The following are multiple choice questions (with answers) about \(formattedSubject). Think step by step and then finish your answer with \"The answer is (X)\" where X is the correct letter choice (A, B, C, or D)."
        } else {
            // Direct-answer MCQ mode (no explanations)
            return """
            You are answering multiple-choice exam questions about \(formattedSubject).

            IMPORTANT:
            - Do NOT repeat or restate the question.
            - Do NOT list the answer choices again.
            - Do NOT include any explanation or reasoning.
            - Answer ONLY in the format: "The answer is (X)" where X is A, B, C, or D.
            """
        }
    }

    /// Lead-in text before model generates answer
    static func promptLeadIn(reasoning: Bool) -> String {
        if reasoning {
            // CoT mode: explicitly invite step-by-step thinking
            return "Let's think step by step."
        } else {
            // Direct mode: let the model generate "The answer is (X)" itself
            return ""
        }
    }

    /// Format this entry as a few-shot example
    func formatAsExample(reasoning: Bool) -> String {
        let letter = answer  // Use the computed answer property (String)
        if reasoning {
            return """
                Question: \(question)
                Options: \(formattedOptions)
                Answer: Let's think step by step. The answer is (\(letter)).


                """
        } else {
            return """
                Question: \(question)
                Options: \(formattedOptions)
                Answer: The answer is (\(letter)).


                """
        }
    }

    /// Format this entry as the final question (without answer)
    func formatAsQuestion() -> String {
        return "Question: \(question)\nOptions: \(formattedOptions)"
    }
}

// MARK: - Filtering and Querying
extension Array where Element == StdMMLUEntry {
    var validQuestions: [StdMMLUEntry] {
        return self.filter(\.isValid)
    }

    func filter(byCategory category: String) -> [StdMMLUEntry] {
        return validQuestions.filter { $0.subject == category }
    }

    func filter(bySubject subject: String) -> [StdMMLUEntry] {
        return validQuestions.filter { $0.subject == subject }
    }

    var uniqueCategories: Set<String> {
        return Set(self.map { $0.subject })
    }

    var uniqueSubjects: Set<String> {
        return uniqueCategories
    }

    func groupedByCategory() -> [String: [StdMMLUEntry]] {
        return Dictionary(grouping: self, by: { $0.subject })
    }

    func groupedBySubject() -> [String: [StdMMLUEntry]] {
        return groupedByCategory()
    }

    var invalidQuestions: [StdMMLUEntry] {
        return self.filter { !$0.isValid }
    }
}
