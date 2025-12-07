import Foundation

struct ARCChoice: Codable {
    let label: String
    let text: String
}

struct ARCEntry: Codable {
    let id: String
    let question: String
    let choices: [ARCChoice]
    let answerKey: String
    
    // Convert to unified format for processing
    var questionId: Int {
        // Extract numeric ID from ARC ID (e.g., "Mercury_7065753" -> 7065753)
        if let numberPart = id.split(separator: "_").last, let num = Int(numberPart) {
            return num
        }
        return abs(id.hashValue) % 1000000
    }
    
    var options: [String] {
        choices.map { $0.text }
    }
    
    var answer: String {
        // Normalize answer to letter format (some ARC entries use 1,2,3,4 instead of A,B,C,D)
        if let index = choices.firstIndex(where: { $0.label == answerKey }) {
            return String(Character(UnicodeScalar(65 + index)!)) // 65 = 'A'
        }
        // If answerKey is already a letter, return it
        return answerKey.uppercased()
    }

    var answerIndex: Int {
        // Find index of choice with matching label
        if let index = choices.firstIndex(where: { $0.label == answerKey }) {
            return index
        }
        return 0
    }
    
    var category: String {
        "arc" // ARC doesn't have categories, use generic
    }
}

typealias ARCDataset = [ARCEntry]

extension ARCEntry {
    func answerLetter(for answerIndex: Int) -> String {
        String(Character(UnicodeScalar(Int(asciiA) + answerIndex)!))
    }
    
    var answerLetter: String? {
        guard answerIndex >= 0 && answerIndex < choices.count else { return nil }
        return self.answerLetter(for: answerIndex)
    }
    
    var isValidIndex: Bool {
        return answerIndex >= 0 && answerIndex < choices.count
    }
    
    var isValid: Bool {
        // ARC entries are valid if answerKey matches a choice label
        return choices.contains(where: { $0.label == answerKey })
    }
    
    var selectedOption: String? {
        guard isValidIndex else { return nil }
        return choices[answerIndex].text
    }
    
    var formattedOptions: String {
        choices.enumerated().reduce("") { prev, item in
            let (index, choice) = item
            var result = prev.isEmpty ? prev : "\(prev), "
            let letter = String(Character(UnicodeScalar(Int(asciiA) + index)!))
            result += "\(letter). \(choice.text)"
            return result
        }
    }
}

// MARK: - Download
extension ARCDataset {
    /// Downloads ARC dataset from HuggingFace and saves as JSONL
    /// Returns the path to the cache directory
    static func downloadAndExtract(progressCallback: ((Double) -> Void)? = nil) async throws -> URL {
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache")
            .appendingPathComponent("arc-dataset")

        // Check if already downloaded
        let easyTestPath = cacheDir.appendingPathComponent("ARC-Easy/ARC-Easy-Test.jsonl")
        if FileManager.default.fileExists(atPath: easyTestPath.path) {
            print("ARC dataset already cached at: \(cacheDir.path)")
            return cacheDir
        }

        // Create cache directories
        try FileManager.default.createDirectory(at: cacheDir.appendingPathComponent("ARC-Easy"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheDir.appendingPathComponent("ARC-Challenge"), withIntermediateDirectories: true)

        print("Downloading ARC dataset from HuggingFace...")

        // HuggingFace datasets API - download each split
        let splits = [
            ("ARC-Easy", "validation", "ARC-Easy-Dev.jsonl"),
            ("ARC-Easy", "test", "ARC-Easy-Test.jsonl"),
            ("ARC-Challenge", "validation", "ARC-Challenge-Dev.jsonl"),
            ("ARC-Challenge", "test", "ARC-Challenge-Test.jsonl"),
        ]

        for (config, split, filename) in splits {
            print("  Downloading \(config) \(split)...")
            let entries = try await downloadSplitFromHuggingFace(config: config, split: split)
            let outputPath = cacheDir.appendingPathComponent("\(config)/\(filename)")
            try saveAsJSONL(entries: entries, to: outputPath)
            print("    Saved \(entries.count) entries to \(filename)")
        }

        print("ARC dataset downloaded to: \(cacheDir.path)")
        return cacheDir
    }

    /// Downloads a split from HuggingFace using the datasets API
    private static func downloadSplitFromHuggingFace(config: String, split: String) async throws -> [ARCEntry] {
        // HuggingFace provides parquet files, but we can use the rows API for smaller datasets
        // The rows API returns JSON data directly
        // URL format: https://datasets-server.huggingface.co/rows?dataset=allenai/ai2_arc&config=ARC-Easy&split=test&offset=0&length=100

        var allEntries: [ARCEntry] = []
        var offset = 0
        let batchSize = 100

        while true {
            let urlString = "https://datasets-server.huggingface.co/rows?dataset=allenai/ai2_arc&config=\(config)&split=\(split)&offset=\(offset)&length=\(batchSize)"
            guard let url = URL(string: urlString) else {
                throw NSError(domain: "ARCDataset", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
            }

            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw NSError(domain: "ARCDataset", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch data from HuggingFace"])
            }

            // Parse the response
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = json["rows"] as? [[String: Any]] else {
                throw NSError(domain: "ARCDataset", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to parse HuggingFace response"])
            }

            if rows.isEmpty {
                break
            }

            for row in rows {
                guard let rowData = row["row"] as? [String: Any],
                      let id = rowData["id"] as? String,
                      let question = rowData["question"] as? String,
                      let choicesDict = rowData["choices"] as? [String: Any],
                      let labels = choicesDict["label"] as? [String],
                      let texts = choicesDict["text"] as? [String],
                      let answerKey = rowData["answerKey"] as? String else {
                    continue
                }

                let choices = zip(labels, texts).map { ARCChoice(label: $0.0, text: $0.1) }
                let entry = ARCEntry(id: id, question: question, choices: choices, answerKey: answerKey)
                allEntries.append(entry)
            }

            offset += batchSize

            // Check if we've fetched all rows
            if rows.count < batchSize {
                break
            }
        }

        return allEntries
    }

    /// Saves entries as JSONL format
    private static func saveAsJSONL(entries: [ARCEntry], to url: URL) throws {
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
extension ARCDataset {
    static func loadFromFile(at url: URL) throws -> ARCDataset {
        let content = try String(contentsOf: url, encoding: .utf8)
        return try loadFromJSONL(content)
    }
    
    static func loadFromJSONL(_ jsonlString: String) throws -> ARCDataset {
        let lines = jsonlString.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        let decoder = JSONDecoder()
        var entries: ARCDataset = []
        
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
                let entry = try decoder.decode(ARCEntry.self, from: data)
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
extension ARCEntry {
    /// Introduction text for ARC prompts - with reasoning (chain-of-thought)
    static func promptIntro(reasoning: Bool) -> String {
        if reasoning {
            return "The following are multiple choice questions (with answers). Think step by step and then finish your answer with \"The answer is (X)\" where X is the correct letter choice."
        } else {
            return "The following are multiple choice questions (with answers). Answer with \"The answer is (X)\" where X is the correct letter choice."
        }
    }

    /// Lead-in text before model generates answer
    static func promptLeadIn(reasoning: Bool) -> String {
        if reasoning {
            return "**Answer**: Let's think step by step."
        } else {
            return "**Answer**: The answer is ("
        }
    }

    /// Format this entry as a few-shot example
    func formatAsExample(reasoning: Bool) -> String {
        // Use normalized letter (converts 1,2,3,4 to A,B,C,D)
        let letter = answer
        let optionText = choices[answerIndex].text
        if reasoning {
            return """
                **Question**: \(question)
                **Options**: \(formattedOptions)
                **Answer**: The answer is (\(letter)). \(optionText)


                """
        } else {
            return """
                **Question**: \(question)
                **Options**: \(formattedOptions)
                **Answer**: The answer is (\(letter)).


                """
        }
    }

    /// Format this entry as the final question (without answer)
    func formatAsQuestion() -> String {
        return "**Question**: \(question)\n**Options**: \(formattedOptions)"
    }
}

// MARK: - Filtering and Querying
extension Array where Element == ARCEntry {
    var validQuestions: [ARCEntry] {
        return self.filter(\.isValid)
    }
    
    func filter(byCategory category: String) -> [ARCEntry] {
        // ARC doesn't have categories, so return all if category is "arc"
        if category == "arc" {
            return validQuestions
        }
        return []
    }
    
    var uniqueCategories: Set<String> {
        return ["arc"] // ARC doesn't have categories
    }
    
    func groupedByCategory() -> [String: [ARCEntry]] {
        // ARC doesn't have categories, group all under "arc"
        return ["arc": validQuestions]
    }
    
    var invalidQuestions: [ARCEntry] {
        return self.filter { !$0.isValid }
    }
}

