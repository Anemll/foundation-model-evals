import Foundation
import FoundationModels
import Hub

// MARK: - Unified Question Interface
protocol QuestionEntry {
    var questionId: Int { get }
    var question: String { get }
    var options: [String] { get }
    var answer: String { get }
    var answerIndex: Int { get }
    var category: String { get }
    var formattedOptions: String { get }
}

extension MMLUEntry: QuestionEntry {}

extension ARCEntry: QuestionEntry {}

extension BoolQEntry: QuestionEntry {}

// Generic formatting helpers (used as fallback)
func formattedQuestion(from entry: QuestionEntry) -> String {
    return "**Question**: \(entry.question)"
}

func formattedOptions(from entry: QuestionEntry) -> String {
    return "**Options**: \(entry.formattedOptions)"
}

/// Helper to sample entries for few-shot when dev split is missing
func sampleForFewShot(from entries: [StdMMLUEntry], perSubject: Int) -> [StdMMLUEntry] {
    var result: [StdMMLUEntry] = []
    let grouped = entries.groupedBySubject()
    for (_, subjectEntries) in grouped.sorted(by: { $0.key < $1.key }) {
        result.append(contentsOf: subjectEntries.prefix(perSubject))
    }
    return result
}

enum DatasetType {
    case mmlu(validation: MMLUDataset, test: MMLUDataset)
    case stdmmlu(validation: StdMMLUDataset, test: StdMMLUDataset)
    case arc(validation: ARCDataset, test: ARCDataset)
    case boolq(validation: BoolQDataset, test: BoolQDataset)

    var categories: [String] {
        switch self {
        case .mmlu(let validation, _):
            return validation.groupedByCategory().map { $0.key }
        case .stdmmlu(let validation, _):
            return validation.groupedByCategory().map { $0.key }
        case .arc(_, _):
            return ["arc"]
        case .boolq(_, _):
            return ["boolq"]
        }
    }

    var testCount: Int {
        switch self {
        case .mmlu(_, let test):
            return test.count
        case .stdmmlu(_, let test):
            return test.count
        case .arc(_, let test):
            return test.count
        case .boolq(_, let test):
            return test.count
        }
    }

    func getTestEntry(at index: Int) -> QuestionEntry? {
        switch self {
        case .mmlu(_, let test):
            guard index < test.count else { return nil }
            return test[index]
        case .stdmmlu(_, let test):
            guard index < test.count else { return nil }
            return test[index]
        case .arc(_, let test):
            guard index < test.count else { return nil }
            return test[index]
        case .boolq(_, let test):
            guard index < test.count else { return nil }
            return test[index]
        }
    }

    func buildPrompt(for category: String, numExamples: Int, reasoning: Bool) -> String? {
        switch self {
        case .mmlu(let validation, _):
            let intro = MMLUEntry.promptIntro(for: category, reasoning: reasoning)
            let validationQuestions = validation.groupedByCategory()
            guard let entries = validationQuestions[category] else { return nil }
            let examples = entries.prefix(numExamples).map { $0.formatAsExample(reasoning: reasoning) }
            return "\(intro)\n\n\(examples.joined())"

        case .stdmmlu(let validation, _):
            // Format subject name for display
            let formattedCategory = category.replacingOccurrences(of: "_", with: " ")
            let intro = StdMMLUEntry.promptIntro(for: formattedCategory, reasoning: reasoning)
            let validationQuestions = validation.groupedByCategory()
            guard let entries = validationQuestions[category] else { return nil }
            let examples = entries.prefix(numExamples).map { $0.formatAsExample(reasoning: reasoning) }
            return "\(intro)\n\n\(examples.joined())"

        case .arc(let validation, _):
            let intro = ARCEntry.promptIntro(reasoning: reasoning)
            let examples = validation.prefix(numExamples).map { $0.formatAsExample(reasoning: reasoning) }
            return "\(intro)\n\n\(examples.joined())"

        case .boolq(let validation, _):
            let intro = BoolQEntry.promptIntro(reasoning: reasoning)
            let examples = validation.prefix(numExamples).map { $0.formatAsExample(reasoning: reasoning) }
            return "\(intro)\n\n\(examples.joined())"
        }
    }
}

struct Dataset {
    var type: DatasetType
    
    var categories: [String] {
        type.categories
    }
    
    var testCount: Int {
        type.testCount
    }
    
    func getTestEntry(at index: Int) -> QuestionEntry? {
        type.getTestEntry(at: index)
    }
    
    // Build prompt with configurable number of examples and reasoning mode
    func buildPrompt(for category: String, numExamples: Int, reasoning: Bool) -> String? {
        type.buildPrompt(for: category, numExamples: numExamples, reasoning: reasoning)
    }


    static func load(from datasetURL: URL, benchmark: String) throws -> Dataset {
        switch benchmark {
        case "arc-easy", "arc-challenge":
            // ARC datasets: load from JSONL files
            // Try multiple possible file paths and structures
            let splitName = benchmark == "arc-easy" ? "ARC-Easy" : "ARC-Challenge"
            let baseName = splitName.replacingOccurrences(of: "ARC-", with: "")
            
            // List of possible file paths to try (includes both underscore and hyphen naming conventions)
            let possibleValidationPaths = [
                datasetURL.appending(path: "\(splitName)/\(splitName)-Dev.jsonl"),  // Allen AI format
                datasetURL.appending(path: "\(splitName)/\(splitName)_dev.jsonl"),
                datasetURL.appending(path: "\(splitName)/\(baseName)_dev.jsonl"),
                datasetURL.appending(path: "\(splitName)_dev.jsonl"),
                datasetURL.appending(path: "\(baseName)_dev.jsonl"),
                datasetURL.appending(path: "dev.jsonl"),
                datasetURL.appending(path: "\(splitName)/dev.jsonl"),
            ]

            let possibleTestPaths = [
                datasetURL.appending(path: "\(splitName)/\(splitName)-Test.jsonl"),  // Allen AI format
                datasetURL.appending(path: "\(splitName)/\(splitName)_test.jsonl"),
                datasetURL.appending(path: "\(splitName)/\(baseName)_test.jsonl"),
                datasetURL.appending(path: "\(splitName)_test.jsonl"),
                datasetURL.appending(path: "\(baseName)_test.jsonl"),
                datasetURL.appending(path: "test.jsonl"),
                datasetURL.appending(path: "\(splitName)/test.jsonl"),
            ]
            
            // Find validation file
            var validationSplit: ARCDataset?
            for path in possibleValidationPaths {
                if FileManager.default.fileExists(atPath: path.path) {
                    print("Found validation file at: \(path.path)")
                    validationSplit = try ARCDataset.loadFromFile(at: path).validQuestions
                    break
                }
            }
            
            guard let validation = validationSplit else {
                // List available files for debugging
                print("\nDataset URL: \(datasetURL.path)")
                print("Directory exists: \(FileManager.default.fileExists(atPath: datasetURL.path))")

                if FileManager.default.fileExists(atPath: datasetURL.path) {
                    print("\nContents of dataset directory:")
                    do {
                        let contents = try FileManager.default.contentsOfDirectory(at: datasetURL, includingPropertiesForKeys: [.isDirectoryKey])
                        if contents.isEmpty {
                            print("  (directory is empty)")
                        } else {
                            for itemURL in contents {
                                let itemName = itemURL.lastPathComponent
                                if let isDirectory = try? itemURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory {
                                    if isDirectory {
                                        print("  📁 \(itemName)/")
                                    } else {
                                        print("  📄 \(itemName)")
                                    }
                                } else {
                                    print("  ❓ \(itemName)")
                                }
                            }
                        }
                    } catch {
                        print("  Error listing directory: \(error)")
                    }
                }

                print("\nTried validation paths:")
                for path in possibleValidationPaths {
                    let exists = FileManager.default.fileExists(atPath: path.path)
                    print("  \(exists ? "✓" : "✗") \(path.path)")
                }

                throw NSError(domain: "DatasetError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not find ARC validation file. Tried: \(possibleValidationPaths.map { $0.path }.joined(separator: ", "))"])
            }
            
            // Find test file
            var testSplit: ARCDataset?
            for path in possibleTestPaths {
                if FileManager.default.fileExists(atPath: path.path) {
                    print("Found test file at: \(path.path)")
                    testSplit = try ARCDataset.loadFromFile(at: path).validQuestions
                    break
                }
            }
            
            guard let test = testSplit else {
                throw NSError(domain: "DatasetError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not find ARC test file. Tried: \(possibleTestPaths.map { $0.path }.joined(separator: ", "))"])
            }
            
            return Dataset(type: .arc(validation: validation, test: test))

        case "boolq":
            // BoolQ dataset: load from JSONL files
            // Uses train for few-shot examples and validation for testing
            let trainPath = datasetURL.appendingPathComponent("train.jsonl")
            let validationPath = datasetURL.appendingPathComponent("validation.jsonl")

            guard FileManager.default.fileExists(atPath: trainPath.path) else {
                throw NSError(domain: "DatasetError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not find BoolQ train file at: \(trainPath.path)"])
            }
            guard FileManager.default.fileExists(atPath: validationPath.path) else {
                throw NSError(domain: "DatasetError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not find BoolQ validation file at: \(validationPath.path)"])
            }

            print("Found train file at: \(trainPath.path)")
            print("Found validation file at: \(validationPath.path)")

            let trainSplit = try BoolQDataset.loadFromFile(at: trainPath).validQuestions
            let validationSplit = try BoolQDataset.loadFromFile(at: validationPath).validQuestions

            // Use train for few-shot examples, validation as the test set
            return Dataset(type: .boolq(validation: trainSplit, test: validationSplit))

        case "stdmmlu":
            // Standard MMLU: load from JSONL files (dev for few-shot, test for evaluation)
            let devPath = datasetURL.appendingPathComponent("dev.jsonl")
            let testPath = datasetURL.appendingPathComponent("test.jsonl")

            guard FileManager.default.fileExists(atPath: testPath.path) else {
                throw NSError(domain: "DatasetError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not find Standard MMLU test file at: \(testPath.path)"])
            }

            print("Found test file at: \(testPath.path)")

            // Load test split (required)
            let testSplit = try StdMMLUDataset.loadFromFile(at: testPath).validQuestions

            // Load dev split (optional - use test entries for few-shot if missing)
            var devSplit: StdMMLUDataset
            if FileManager.default.fileExists(atPath: devPath.path) {
                print("Found dev file at: \(devPath.path)")
                devSplit = try StdMMLUDataset.loadFromFile(at: devPath).validQuestions
                if devSplit.isEmpty {
                    print("  Dev file empty, using first 5 test entries per subject for few-shot")
                    devSplit = sampleForFewShot(from: testSplit, perSubject: 5)
                }
            } else {
                print("  Dev file not found, using first 5 test entries per subject for few-shot")
                devSplit = sampleForFewShot(from: testSplit, perSubject: 5)
            }

            print("Loaded \(devSplit.count) dev examples and \(testSplit.count) test questions")
            print("Subjects: \(testSplit.uniqueSubjects.count)")

            return Dataset(type: .stdmmlu(validation: devSplit, test: testSplit))

        default: // mmlu (MMLU-Pro)
            let validationSplit = try MMLUDataset.loadFromFile(at: datasetURL.appending(path: "validation.json")).validQuestions
            let testSplit = try MMLUDataset.loadFromFile(at: datasetURL.appending(path: "test.json")).validQuestions
            return Dataset(type: .mmlu(validation: validationSplit, test: testSplit))
        }
    }
}

struct Answer: Codable {
    var questionId: Int
    var category: String
    var correctChoice: String
    var predictedChoice: String
    var predictedAnswer: String
    var classification: ResponseClassification

    var isCorrect: Bool { correctChoice == predictedChoice }
    var isValidAnswer: Bool { classification == .validAnswer }
}

struct Score {
    var total: Int
    var correct: Int
    var validAnswers: Int
    var safetyRefusals: Int
    var formatFailures: Int

    func updated(with answer: Answer) -> Score {
        var newScore = self
        newScore.total += 1
        if answer.isValidAnswer && answer.isCorrect {
            newScore.correct += 1
        }
        switch answer.classification {
        case .validAnswer:
            newScore.validAnswers += 1
        case .safetyRefusal:
            newScore.safetyRefusals += 1
        case .formatFailure:
            newScore.formatFailures += 1
        }
        return newScore
    }

    static var zero: Score {
        Score(total: 0, correct: 0, validAnswers: 0, safetyRefusals: 0, formatFailures: 0)
    }
}

extension Array where Element == Answer {
    /// Raw accuracy (correct / total) - includes random guesses for refusals
    var macroAccuracy: Float {
        guard !self.isEmpty else { return 0 }
        let correctAnswers = self.filter { $0.isCorrect }
        return Float(correctAnswers.count) / Float(self.count)
    }

    /// True accuracy (correct / valid answers only) - excludes safety refusals and format failures
    var trueAccuracy: Float {
        let validAnswers = self.filter { $0.isValidAnswer }
        guard !validAnswers.isEmpty else { return 0 }
        let correctValid = validAnswers.filter { $0.isCorrect }
        return Float(correctValid.count) / Float(validAnswers.count)
    }

    /// Format success rate (valid answers / total)
    var formatSuccessRate: Float {
        guard !self.isEmpty else { return 0 }
        let validAnswers = self.filter { $0.isValidAnswer }
        return Float(validAnswers.count) / Float(self.count)
    }

    /// Safety refusal rate (safety refusals / total)
    var safetyRefusalRate: Float {
        guard !self.isEmpty else { return 0 }
        let refusals = self.filter { $0.classification == .safetyRefusal }
        return Float(refusals.count) / Float(self.count)
    }

    var validCount: Int { self.filter { $0.isValidAnswer }.count }
    var safetyRefusalCount: Int { self.filter { $0.classification == .safetyRefusal }.count }
    var formatFailureCount: Int { self.filter { $0.classification == .formatFailure }.count }
    var correctValidCount: Int { self.filter { $0.isValidAnswer && $0.isCorrect }.count }
}

// MARK: - Response Classification

/// Classification of model response for scientific evaluation
enum ResponseClassification: String, Codable, Sendable {
    case validAnswer = "valid"        // Model gave a parseable answer
    case safetyRefusal = "safety"     // Model refused due to content moderation
    case formatFailure = "format"     // Output exists but couldn't parse answer
}

/// Detects if a response is a safety refusal
func detectSafetyRefusal(_ response: String) -> Bool {
    let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)

    // Empty response is a safety refusal
    if trimmed.isEmpty {
        return true
    }

    // Common AFM safety refusal phrases
    let safetyPhrases = [
        "I cannot assist",
        "I'm unable to",
        "I can't help",
        "I cannot provide",
        "I'm not able to",
        "As an AI",
        "I don't feel comfortable",
        "I cannot engage",
        "I won't be able to",
        "I apologize, but I cannot",
        "I'm sorry, but I can't",
        "This request involves",
        "I cannot answer",
        "not appropriate for me to",
        "I must decline",
        "I cannot respond to"
    ]

    let lowercased = trimmed.lowercased()
    for phrase in safetyPhrases {
        if lowercased.contains(phrase.lowercased()) {
            return true
        }
    }

    return false
}

// MARK: - Guardrails Helper

/// Helper to create guardrails with safety filtering disabled via unsafe pointer manipulation
/// WARNING: This is for research/evaluation purposes only
enum GuardrailsHelper {
    static var disabled: SystemLanguageModel.Guardrails {
        var guardrails = SystemLanguageModel.Guardrails.default

        withUnsafeMutablePointer(to: &guardrails) { ptr in
            let rawPtr = UnsafeMutableRawPointer(ptr)
            let boolPtr = rawPtr.assumingMemoryBound(to: Bool.self)
            boolPtr.pointee = false
        }

        return guardrails
    }
}

// MARK: - Batch Processing Support

/// Result of evaluating a single question (for batch processing)
struct QuestionResult: Sendable {
    let questionIndex: Int
    let answer: Answer
    let predictedAnswer: String
    let extractedChoice: String
    let isCorrect: Bool
    let wasRandom: Bool
    let classification: ResponseClassification
    let inferenceTime: TimeInterval  // Seconds spent in inference
    let tokenCount: Int              // Number of tokens in response
}

/// Thread-safe actor for collecting results from parallel evaluations
actor ResultCollector {
    private var results: [QuestionResult] = []
    private var completedCount: Int = 0
    private let totalCount: Int
    private let startTime: Date

    init(totalCount: Int) {
        self.totalCount = totalCount
        self.startTime = Date()
    }

    func addResult(_ result: QuestionResult) {
        results.append(result)
        completedCount += 1
    }

    func getProgress() -> (completed: Int, total: Int, elapsed: TimeInterval) {
        return (completedCount, totalCount, Date().timeIntervalSince(startTime))
    }

    func getSortedResults() -> [QuestionResult] {
        return results.sorted { $0.questionIndex < $1.questionIndex }
    }

    func getAnswers() -> [Answer] {
        return getSortedResults().map { $0.answer }
    }
}

/// Extracts the predicted answer letter from model response
func extractAnswer(from predictedAnswer: String, entry: QuestionEntry) -> (choice: String, wasRandom: Bool) {
    // Try multiple patterns to extract the answer (support A-J for MMLU's 10 options)
    let answerRE1 = /answer is \(([A-Ja-j])\)/.ignoresCase()
    let answerRE2 = /answer is:?\s*([A-Ja-j])[\.\s,]/.ignoresCase()
    let answerRE3 = /(?:correct )?answer(?:\sis)?:?\s*([A-Ja-j])[\.\s,\)]/.ignoresCase()
    let answerRE4 = /^([A-Ja-j])(?:[\.\)\s]|$)/.ignoresCase()
    let answerRE5 = /^\(?([A-Ja-j])\)\.?/.ignoresCase()
    let answerRE6 = /answer:\s*([A-Ja-j])/.ignoresCase()

    if let result = try? answerRE1.firstMatch(in: predictedAnswer) {
        return (String(result.1).uppercased(), false)
    } else if let result = try? answerRE2.firstMatch(in: predictedAnswer) {
        return (String(result.1).uppercased(), false)
    } else if let result = try? answerRE3.firstMatch(in: predictedAnswer) {
        return (String(result.1).uppercased(), false)
    } else if let result = try? answerRE4.firstMatch(in: predictedAnswer.trimmingCharacters(in: .whitespacesAndNewlines)) {
        return (String(result.1).uppercased(), false)
    } else if let result = try? answerRE5.firstMatch(in: predictedAnswer.trimmingCharacters(in: .whitespacesAndNewlines)) {
        return (String(result.1).uppercased(), false)
    } else if let result = try? answerRE6.firstMatch(in: predictedAnswer) {
        return (String(result.1).uppercased(), false)
    } else {
        // Random choice - model didn't provide answer in expected format
        let randomIndex = (0..<entry.options.count).randomElement() ?? 0
        let answer: String
        if let mmluEntry = entry as? MMLUEntry {
            answer = mmluEntry.answerLetter(for: randomIndex)
        } else if let arcEntry = entry as? ARCEntry {
            answer = arcEntry.answerLetter(for: randomIndex)
        } else if let boolqEntry = entry as? BoolQEntry {
            answer = boolqEntry.answerLetter(for: randomIndex)
        } else {
            answer = String(Character(UnicodeScalar(Int(asciiA) + randomIndex)!))
        }
        return (answer, true)
    }
}

@main
struct FoundationModelEval {
    /// Static helper to extract answer from model response (for use in concurrent tasks)
    /// Returns: (choice, wasRandom, classification)
    static func extractAnswerFromResponse(_ predictedAnswer: String, optionsCount: Int) -> (choice: String, wasRandom: Bool, classification: ResponseClassification) {
        // First check for safety refusal
        if detectSafetyRefusal(predictedAnswer) {
            // Return random guess but mark as safety refusal
            let randomIndex = (0..<optionsCount).randomElement() ?? 0
            let answer = String(Character(UnicodeScalar(65 + randomIndex)!)) // 65 = 'A'
            return (answer, true, .safetyRefusal)
        }

        let answerRE1 = /answer is \(([A-Ja-j])\)/.ignoresCase()
        let answerRE2 = /answer is:?\s*([A-Ja-j])[\.\s,]/.ignoresCase()
        let answerRE3 = /(?:correct )?answer(?:\sis)?:?\s*([A-Ja-j])[\.\s,\)]/.ignoresCase()
        let answerRE4 = /^([A-Ja-j])(?:[\.\)\s]|$)/.ignoresCase()
        let answerRE5 = /^\(?([A-Ja-j])\)\.?/.ignoresCase()
        let answerRE6 = /answer:\s*([A-Ja-j])/.ignoresCase()
        let answerRE7 = /\*\*[Aa]nswer\*\*:\s*\(?([A-Ja-j])\)?/  // Markdown bold: **Answer**: X or **Answer**: (X)

        if let result = try? answerRE1.firstMatch(in: predictedAnswer) {
            return (String(result.1).uppercased(), false, .validAnswer)
        } else if let result = try? answerRE2.firstMatch(in: predictedAnswer) {
            return (String(result.1).uppercased(), false, .validAnswer)
        } else if let result = try? answerRE3.firstMatch(in: predictedAnswer) {
            return (String(result.1).uppercased(), false, .validAnswer)
        } else if let result = try? answerRE4.firstMatch(in: predictedAnswer.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return (String(result.1).uppercased(), false, .validAnswer)
        } else if let result = try? answerRE5.firstMatch(in: predictedAnswer.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return (String(result.1).uppercased(), false, .validAnswer)
        } else if let result = try? answerRE6.firstMatch(in: predictedAnswer) {
            return (String(result.1).uppercased(), false, .validAnswer)
        } else if let result = try? answerRE7.firstMatch(in: predictedAnswer) {
            return (String(result.1).uppercased(), false, .validAnswer)
        } else {
            // Format failure - model gave a response but we couldn't parse it
            let randomIndex = (0..<optionsCount).randomElement() ?? 0
            let answer = String(Character(UnicodeScalar(65 + randomIndex)!)) // 65 = 'A'
            return (answer, true, .formatFailure)
        }
    }

    static func main() async throws {
        // Parse command line arguments
        // Usage: FoundationModelEval [benchmarks...] [startQuestionNumber] [maxShots] [--reason|--think] [--max N] [--adapter PATH]
        // Example: FoundationModelEval mmlu 29 5  (MMLU benchmark, starts from question 29, uses 5-shot)
        // Example: FoundationModelEval arc-easy 1 3   (ARC-Easy, starts from question 1, uses 3-shot)
        // Example: FoundationModelEval boolq arc-easy 1 5 --max 100  (Multiple benchmarks)
        // Example: FoundationModelEval arc-easy 1 3 --reason  (ARC-Easy with chain-of-thought reasoning)
        // Example: FoundationModelEval mmlu 1 0 --max 50 --adapter /path/to/mmlu_adapter.fmadapter  (With custom adapter)
        // Supported benchmarks: mmlu, stdmmlu, arc-easy, arc-challenge, boolq
        // --reason or --think: Enable chain-of-thought prompting (default: direct answer mode)
        // --max N: Maximum number of samples to evaluate (default: all)
        // --adapter PATH: Path to .fmadapter bundle to use for evaluation
        let validBenchmarks = ["mmlu", "stdmmlu", "arc-easy", "arc-challenge", "boolq"]
        var benchmarks: [String] = []
        let startQuestion: Int
        let maxShots: Int

        // Parse benchmarks (can be multiple)
        var argIndex = 1
        while argIndex < CommandLine.arguments.count {
            let arg = CommandLine.arguments[argIndex].lowercased()
            if validBenchmarks.contains(arg) {
                benchmarks.append(arg)
                argIndex += 1
            } else {
                break // Stop when we hit a non-benchmark argument
            }
        }

        // Default to mmlu if no benchmarks specified
        if benchmarks.isEmpty {
            benchmarks = ["mmlu"]
            print("Using default benchmark: mmlu")
        } else {
            print("Benchmarks to run: \(benchmarks.joined(separator: ", "))")
        }

        if CommandLine.arguments.count > argIndex, let start = Int(CommandLine.arguments[argIndex]) {
            startQuestion = max(1, start) // Ensure at least 1
            print("Starting from question \(startQuestion)")
            argIndex += 1
        } else {
            startQuestion = 1
        }

        if CommandLine.arguments.count > argIndex, let shots = Int(CommandLine.arguments[argIndex]) {
            maxShots = max(0, min(shots, 10)) // Clamp between 0 and 10
            if maxShots != shots {
                print("Warning: maxShots clamped to \(maxShots)")
            } else {
                print("Using \(maxShots)-shot prompts")
            }
            argIndex += 1
        } else {
            maxShots = 5 // Default to 5-shot
        }

        // Check for --reason or --think flag (can appear anywhere in arguments)
        // Default is direct answer mode (no reasoning)
        let useReasoning = CommandLine.arguments.contains("--reason") || CommandLine.arguments.contains("--think")
        if useReasoning {
            print("Reasoning enabled (chain-of-thought mode)")
        }

        // Check for --max XXX flag (maximum samples to evaluate)
        var maxSamples: Int? = nil
        if let maxIndex = CommandLine.arguments.firstIndex(of: "--max"),
           maxIndex + 1 < CommandLine.arguments.count,
           let maxValue = Int(CommandLine.arguments[maxIndex + 1]) {
            maxSamples = max(1, maxValue)
            print("Maximum samples per benchmark: \(maxSamples!)")
        }

        // Check for --max-per-category N flag (sample N questions from each category)
        var maxPerCategory: Int? = nil
        if let maxPerCatIndex = CommandLine.arguments.firstIndex(of: "--max-per-category"),
           maxPerCatIndex + 1 < CommandLine.arguments.count,
           let maxPerCatValue = Int(CommandLine.arguments[maxPerCatIndex + 1]) {
            maxPerCategory = max(1, maxPerCatValue)
            print("Maximum samples per category: \(maxPerCategory!)")
        }

        // Check for --save-samples flag (save per-sample detailed results)
        let saveSamples = CommandLine.arguments.contains("--save-samples")
        if saveSamples {
            print("Will save per-sample detailed results")
        }

        // Check for --adapter PATH flag (load custom adapter)
        var adapterPath: String? = nil
        if let adapterIndex = CommandLine.arguments.firstIndex(of: "--adapter"),
           adapterIndex + 1 < CommandLine.arguments.count {
            adapterPath = CommandLine.arguments[adapterIndex + 1]
            print("Using adapter: \(adapterPath!)")
        }

        // Check for --batch X flag (parallel processing)
        var batchSize = 1
        if let batchIndex = CommandLine.arguments.firstIndex(of: "--batch"),
           batchIndex + 1 < CommandLine.arguments.count,
           let batchValue = Int(CommandLine.arguments[batchIndex + 1]) {
            batchSize = max(1, min(batchValue, 10)) // Clamp between 1 and 10
            if batchSize != batchValue {
                print("Warning: batch size clamped to \(batchSize)")
            } else {
                print("Batch size: \(batchSize) concurrent sessions")
            }
        }

        // Check for --no-guardrails flag (disable safety filtering)
        let noGuardrails = CommandLine.arguments.contains("--no-guardrails")
        if noGuardrails {
            print("⚠️  Guardrails DISABLED (research mode)")
        }

        // Check for --max-tokens N flag (limit response length)
        var maxTokens: Int? = nil
        if let maxTokensIndex = CommandLine.arguments.firstIndex(of: "--max-tokens"),
           maxTokensIndex + 1 < CommandLine.arguments.count,
           let maxTokensValue = Int(CommandLine.arguments[maxTokensIndex + 1]) {
            maxTokens = max(1, min(maxTokensValue, 4096)) // Clamp between 1 and 4096
            print("Max response tokens: \(maxTokens!)")
        }

        // Store all results for final report
        var allResults: [(benchmark: String, accuracy: Float, correct: Int, total: Int, time: TimeInterval)] = []

        // Run each benchmark
        for benchmark in benchmarks {
            print("\n" + String(repeating: "━", count: 60))
            print("STARTING BENCHMARK: \(benchmark.uppercased())")
            print(String(repeating: "━", count: 60))

            let progressBar = CLIProgressBar(prefix: "Dataset download")

            // Load dataset based on benchmark type (auto-download from HuggingFace)
            let datasetURL: URL
            switch benchmark {
            case "arc-easy", "arc-challenge":
                datasetURL = try await ARCDataset.downloadAndExtract()
            case "boolq":
                datasetURL = try await BoolQDataset.downloadAndExtract()
            case "stdmmlu":
                datasetURL = try await StdMMLUDataset.downloadAndExtract()
            case "mmlu":
                print("Downloading MMLU-Pro dataset...")
                let repo = Hub.Repo(id: "pcuenq/MMLU-Pro-json", type: .datasets)
                datasetURL = try await Hub.snapshot(from: repo, matching: "*.json") { @Sendable progress in
                    progressBar.update(progress)
                }
                print("MMLU-Pro dataset downloaded to: \(datasetURL.path)")
            default:
                print("Unknown benchmark: \(benchmark), skipping...")
                continue
            }

            // Shorter prompt to reduce token usage
            let instructions = "You have expert knowledge about various topics, and your only task is to respond to a single question. Please, follow the examples faithfully and answer the question using the same format asked for. Think carefully about the options, explain your reasoning, and make sure your answer ends with a line that has the same format as the ones in the examples."

            // Load adapter if specified
            var adapter: SystemLanguageModel.Adapter? = nil
            if let path = adapterPath {
                let adapterURL = URL(fileURLWithPath: path)
                do {
                    adapter = try SystemLanguageModel.Adapter(fileURL: adapterURL)
                    print("✓ Adapter loaded successfully from: \(path)")
                } catch {
                    print("⚠️ Failed to load adapter: \(error). Continuing without adapter.")
                }
            }

            let dataset = try Dataset.load(from: datasetURL, benchmark: benchmark)
            var answers: [Answer] = []
            var scores: [String : Score] = Dictionary(uniqueKeysWithValues: zip(dataset.categories, Array(repeating: Score.zero, count: dataset.categories.count)))
            let evalProgressBar = CLIProgressBar(prefix: "Eval")

            // Calculate effective total entries (accounting for startQuestion and maxSamples)
            // Note: For --max-per-category, we'll recalculate after collecting entries
            let availableEntries = max(0, dataset.testCount - startQuestion + 1)
            var effectiveTotal: Int
            if let maxPerCat = maxPerCategory {
                // Estimate: categories * maxPerCat (will be updated after collection)
                effectiveTotal = dataset.categories.count * maxPerCat
            } else if let max = maxSamples {
                effectiveTotal = min(max, availableEntries)
            } else {
                effectiveTotal = availableEntries
            }

            // Early exit if no questions available (only for non-per-category mode)
            if effectiveTotal == 0 && maxPerCategory == nil {
                print("Warning: No questions available (startQuestion \(startQuestion) exceeds dataset size \(dataset.testCount))")
                continue
            }
            let startTime = Date()

            // Collect entries to evaluate
            var entriesToEvaluate: [(index: Int, entry: QuestionEntry)] = []

            if let maxPerCat = maxPerCategory {
                // Per-category sampling: collect all entries first, group by category, then sample
                var entriesByCategory: [String: [QuestionEntry]] = [:]
                for i in 0..<dataset.testCount {
                    guard let entry = dataset.getTestEntry(at: i) else { continue }
                    entriesByCategory[entry.category, default: []].append(entry)
                }

                // Sample up to maxPerCat from each category
                var sampledEntries: [QuestionEntry] = []
                for category in dataset.categories.sorted() {
                    if let categoryEntries = entriesByCategory[category] {
                        let sampled = Array(categoryEntries.prefix(maxPerCat))
                        sampledEntries.append(contentsOf: sampled)
                    }
                }

                // Convert to indexed entries
                for (i, entry) in sampledEntries.enumerated() {
                    entriesToEvaluate.append((index: i, entry: entry))
                }

                print("Sampled \(entriesToEvaluate.count) questions across \(entriesByCategory.count) categories (max \(maxPerCat) per category)")
                // Update effectiveTotal to actual count
                effectiveTotal = entriesToEvaluate.count
            } else {
                // Original sequential collection
                var questionIndex = 0
                for i in 0..<dataset.testCount {
                    guard let entry = dataset.getTestEntry(at: i) else { continue }
                    questionIndex += 1

                    // Skip questions before the start question
                    if questionIndex < startQuestion {
                        continue
                    }

                    // Stop if we've reached maxSamples
                    if entriesToEvaluate.count >= effectiveTotal {
                        break
                    }

                    entriesToEvaluate.append((index: entriesToEvaluate.count, entry: entry))
                }
            }

            // Create progress tracker after we know the actual count
            let progress = Progress(totalUnitCount: Int64(effectiveTotal))

            // ANSI color codes
            let cyan = "\u{001B}[36m"
            let blue = "\u{001B}[34m"
            let green = "\u{001B}[32m"
            let red = "\u{001B}[31m"
            let reset = "\u{001B}[0m"

            // Process entries in batches
            var entryIndex = 0
            while entryIndex < entriesToEvaluate.count {
                let batchEnd = min(entryIndex + batchSize, entriesToEvaluate.count)
                let currentBatch = Array(entriesToEvaluate[entryIndex..<batchEnd])

                if batchSize > 1 {
                    print("\n\(cyan)━━━ Processing batch of \(currentBatch.count) questions [\(entryIndex + 1)-\(batchEnd)/\(effectiveTotal)] ━━━\(reset)")
                }

                // Pre-build prompts for batch (to avoid capturing dataset in tasks)
                var batchPrompts: [(idx: Int, entry: QuestionEntry, prompts: [Int: String], correctChoice: String)] = []
                for (idx, entry) in currentBatch {
                    var prompts: [Int: String] = [:]
                    for numEx in stride(from: maxShots, through: 0, by: -2) {
                        if let prompt = dataset.buildPrompt(for: entry.category, numExamples: numEx, reasoning: useReasoning) {
                            let finalPrompt: String
                            if let boolqEntry = entry as? BoolQEntry {
                                finalPrompt = "\(prompt)\n\(boolqEntry.formatAsQuestion())\n\n\(BoolQEntry.promptLeadIn(reasoning: useReasoning))"
                            } else if let arcEntry = entry as? ARCEntry {
                                finalPrompt = "\(prompt)\n\(arcEntry.formatAsQuestion())\n\(ARCEntry.promptLeadIn(reasoning: useReasoning))"
                            } else if let mmluEntry = entry as? MMLUEntry {
                                finalPrompt = "\(prompt)\n\(mmluEntry.formatAsQuestion())\n\(MMLUEntry.promptLeadIn(reasoning: useReasoning))"
                            } else if let stdMmluEntry = entry as? StdMMLUEntry {
                                finalPrompt = "\(prompt)\n\(stdMmluEntry.formatAsQuestion())\n\(StdMMLUEntry.promptLeadIn(reasoning: useReasoning))"
                            } else {
                                let leadIn = useReasoning ? "**Answer**: Let's think step by step." : "**Answer**: The answer is ("
                                finalPrompt = "\(prompt)\n\(formattedQuestion(from: entry))\n\(formattedOptions(from: entry))\n\(leadIn)"
                            }
                            prompts[numEx] = finalPrompt
                        }
                    }
                    let correctChoice: String
                    if let mmluEntry = entry as? MMLUEntry, let letter = mmluEntry.answerLetter {
                        correctChoice = letter
                    } else if let stdMmluEntry = entry as? StdMMLUEntry, let letter = stdMmluEntry.answerLetter {
                        correctChoice = letter
                    } else if let arcEntry = entry as? ARCEntry, let letter = arcEntry.answerLetter {
                        correctChoice = letter
                    } else if let boolqEntry = entry as? BoolQEntry, let letter = boolqEntry.answerLetter {
                        correctChoice = letter
                    } else {
                        correctChoice = entry.answer
                    }
                    batchPrompts.append((idx: idx, entry: entry, prompts: prompts, correctChoice: correctChoice))
                }

                // Process batch in parallel using TaskGroup
                // Create model outside task group (SystemLanguageModel is Sendable, Adapter is not)
                let taskModel: SystemLanguageModel
                if let loadedAdapter = adapter {
                    let guardrails: SystemLanguageModel.Guardrails = noGuardrails ? GuardrailsHelper.disabled : .default
                    taskModel = SystemLanguageModel(adapter: loadedAdapter, guardrails: guardrails)
                } else {
                    let guardrails: SystemLanguageModel.Guardrails = noGuardrails ? GuardrailsHelper.disabled : .permissiveContentTransformations
                    taskModel = SystemLanguageModel(guardrails: guardrails)
                }
                let taskMaxTokens = maxTokens  // Capture for concurrent access
                let batchResults = await withTaskGroup(of: QuestionResult?.self, returning: [QuestionResult].self) { group in
                    for item in batchPrompts {
                        let idx = item.idx
                        let prompts = item.prompts
                        let correctChoice = item.correctChoice
                        let questionId = item.entry.questionId
                        let category = item.entry.category
                        let optionsCount = item.entry.options.count

                        group.addTask { @Sendable in
                            // Create session with the pre-configured model
                            let session = LanguageModelSession(model: taskModel, instructions: instructions)

                            // Try with decreasing number of examples if context window is exceeded
                            var predictedAnswer: String = ""
                            var success = false
                            var tokenCount = 0
                            let inferenceStart = Date()

                            for numExamples in stride(from: maxShots, through: 0, by: -2) {
                                if success { break }
                                guard let finalPrompt = prompts[numExamples] else { continue }

                                do {
                                    var options = GenerationOptions(sampling: .greedy)
                                    if let maxTok = taskMaxTokens {
                                        options.maximumResponseTokens = maxTok
                                    }
                                    let response = try await session.respond(to: finalPrompt, options: options)
                                    predictedAnswer = response.content
                                    // Estimate token count (roughly 4 chars per token for English)
                                    tokenCount = max(1, predictedAnswer.count / 4)
                                    success = true
                                } catch {
                                    let errorString = String(describing: error)
                                    if !(errorString.contains("exceededContextWindowSize") || errorString.contains("exceeds the maximum allowed context size")) {
                                        success = true // Give up on non-context errors
                                    }
                                }
                            }

                            let inferenceTime = Date().timeIntervalSince(inferenceStart)

                            // Extract answer using regex patterns and classify response
                            let (extractedChoice, wasRandom, classification) = Self.extractAnswerFromResponse(predictedAnswer, optionsCount: optionsCount)

                            let loggedAnswer = Answer(
                                questionId: questionId,
                                category: category,
                                correctChoice: correctChoice,
                                predictedChoice: extractedChoice,
                                predictedAnswer: predictedAnswer,
                                classification: classification
                            )

                            return QuestionResult(
                                questionIndex: idx,
                                answer: loggedAnswer,
                                predictedAnswer: predictedAnswer,
                                extractedChoice: extractedChoice,
                                isCorrect: extractedChoice == correctChoice,
                                wasRandom: wasRandom,
                                classification: classification,
                                inferenceTime: inferenceTime,
                                tokenCount: tokenCount
                            )
                        }
                    }

                    var results: [QuestionResult] = []
                    for await result in group {
                        if let result = result {
                            results.append(result)
                        }
                    }
                    return results.sorted { $0.questionIndex < $1.questionIndex }
                }

                // Print results for each question in the batch (in order)
                for result in batchResults {
                    let entry = currentBatch.first { $0.index == result.questionIndex }!.entry
                    let displayNum = entryIndex + result.questionIndex - currentBatch.first!.index + 1

                    print("\n\(cyan)═══════════════════════════════════════════════════════════════\(reset)")
                    print("\(cyan)[Q\(displayNum)/\(effectiveTotal) ID:\(entry.questionId) Category:\(entry.category)]\(reset)")

                    // Print the question (with passage for BoolQ)
                    if let boolqEntry = entry as? BoolQEntry {
                        let maxPassageLen = 500
                        let passage = boolqEntry.passage.count > maxPassageLen
                            ? String(boolqEntry.passage.prefix(maxPassageLen)) + "..."
                            : boolqEntry.passage
                        print("\(cyan)Passage:\(reset) \(passage)")
                        print("\(cyan)Question:\(reset) \(boolqEntry.question)")
                    } else {
                        print("\(cyan)Question:\(reset) \(entry.question)")
                    }
                    print("\(cyan)Options:\(reset) \(entry.formattedOptions)")
                    print("\(cyan)═══════════════════════════════════════════════════════════════\(reset)")

                    print("Model Response:")
                    if !result.predictedAnswer.isEmpty {
                        print("\(blue)\(result.predictedAnswer)\(reset)")
                    } else {
                        print("  [No response generated]")
                    }

                    let resultColor = result.isCorrect ? green : red
                    let yellow = "\u{001B}[33m"

                    switch result.classification {
                    case .validAnswer:
                        print("\(resultColor)Model: \(result.extractedChoice), Correct: \(result.answer.correctChoice)\(reset)")
                    case .safetyRefusal:
                        print("\(yellow)[SAFETY REFUSAL] Random guess: \(result.extractedChoice), Correct: \(result.answer.correctChoice)\(reset)")
                    case .formatFailure:
                        print("\(yellow)[FORMAT FAILURE] Random guess: \(result.extractedChoice), Correct: \(result.answer.correctChoice)\(reset)")
                    }

                    // Show inference stats
                    let gray = "\u{001B}[90m"
                    let tps = result.inferenceTime > 0 ? Double(result.tokenCount) / result.inferenceTime : 0
                    print("\(gray)[Time: \(String(format: "%.2f", result.inferenceTime))s | Tokens: ~\(result.tokenCount) | TPS: \(String(format: "%.1f", tps))]\(reset)")

                    // Update scores and answers
                    scores[entry.category] = scores[entry.category]?.updated(with: result.answer)
                    answers.append(result.answer)
                }

                progress.completedUnitCount = Int64(answers.count)

                // Calculate questions per second and estimated time to completion
                let elapsedTime = Date().timeIntervalSince(startTime)
                let questionsPerSecond = elapsedTime > 0 ? Double(progress.completedUnitCount) / elapsedTime : 0.0
                let remainingQuestions = effectiveTotal - Int(progress.completedUnitCount)
                let estimatedSecondsRemaining = questionsPerSecond > 0 ? Double(remainingQuestions) / questionsPerSecond : 0.0

                let estimatedTimeString: String
                if estimatedSecondsRemaining >= 3600 {
                    let hours = Int(estimatedSecondsRemaining) / 3600
                    let minutes = (Int(estimatedSecondsRemaining) % 3600) / 60
                    let seconds = Int(estimatedSecondsRemaining) % 60
                    estimatedTimeString = String(format: "%d:%02d:%02d", hours, minutes, seconds)
                } else {
                    let minutes = Int(estimatedSecondsRemaining) / 60
                    let seconds = Int(estimatedSecondsRemaining) % 60
                    estimatedTimeString = String(format: "%d:%02d", minutes, seconds)
                }

                let accuracyPercent = String(format: "%.2f", answers.macroAccuracy * 100)
                let qpsString = String(format: "%.2f", questionsPerSecond)
                evalProgressBar.update(progress, info: "[Acc: \(accuracyPercent)% | QPS: \(qpsString) | ETA: \(estimatedTimeString)]")

                entryIndex = batchEnd
            } // End of batch loop

            // Print final summary for this benchmark
            let totalTime = Date().timeIntervalSince(startTime)
            let totalTimeString: String
            if totalTime >= 3600 {
                let hours = Int(totalTime) / 3600
                let minutes = (Int(totalTime) % 3600) / 60
                let seconds = Int(totalTime) % 60
                totalTimeString = String(format: "%d:%02d:%02d", hours, minutes, seconds)
            } else {
                let minutes = Int(totalTime) / 60
                let seconds = Int(totalTime) % 60
                totalTimeString = String(format: "%d:%02d", minutes, seconds)
            }

            print("\n" + String(repeating: "=", count: 60))
            print("EVALUATION SUMMARY")
            print(String(repeating: "=", count: 60))
            print("Benchmark:      \(benchmark)")
            print("Prompt mode:    \(useReasoning ? "reasoning (chain-of-thought)" : "direct answer (no reasoning)")")
            print("Few-shot:       \(maxShots)-shot")
            print("Guardrails:     \(noGuardrails ? "DISABLED" : "enabled")")
            if let path = adapterPath {
                print("Adapter:        \(path)")
            }
            if let maxTok = maxTokens {
                print("Max tokens:     \(maxTok)")
            }
            print("Questions:      \(answers.count) (started at #\(startQuestion))")
            print("Total time:     \(totalTimeString)")
            print(String(repeating: "-", count: 60))

            // Response Classification Breakdown
            print("Response Breakdown:")
            print("  Valid answers:    \(answers.validCount) (\(String(format: "%.1f", answers.formatSuccessRate * 100))%)")
            print("  Safety refusals:  \(answers.safetyRefusalCount) (\(String(format: "%.1f", answers.safetyRefusalRate * 100))%)")
            print("  Format failures:  \(answers.formatFailureCount)")
            print(String(repeating: "-", count: 60))

            // Accuracy Metrics
            print("Accuracy Metrics:")
            print("  True Accuracy:    \(String(format: "%.2f", answers.trueAccuracy * 100))% (\(answers.correctValidCount)/\(answers.validCount) valid)")
            print("  Raw Accuracy:     \(String(format: "%.2f", answers.macroAccuracy * 100))% (\(answers.filter { $0.isCorrect }.count)/\(answers.count) total)")
            print(String(repeating: "=", count: 60))

            // Print per-category scores
            if scores.count > 1 {
                print("\nPer-category scores (true accuracy on valid answers):")
                for (category, score) in scores.sorted(by: { $0.key < $1.key }) {
                    let trueAcc = score.validAnswers > 0 ? Float(score.correct) / Float(score.validAnswers) * 100 : 0
                    let refusalInfo = score.safetyRefusals > 0 ? " [\(score.safetyRefusals) refused]" : ""
                    print("  \(category): \(String(format: "%.1f", trueAcc))% (\(score.correct)/\(score.validAnswers))\(refusalInfo)")
                }
            }

            // Save results to results/ folder
            let resultsDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("results")
            do {
                try FileManager.default.createDirectory(at: resultsDir, withIntermediateDirectories: true)
            } catch {
                print("Warning: Could not create results directory: \(error)")
            }

            // Create timestamp for filenames
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
            let timestamp = dateFormatter.string(from: Date())
            let reasoningMode = useReasoning ? "reasoning" : "direct"
            let filenameBase = "\(benchmark)_\(maxShots)shot_\(reasoningMode)_\(timestamp)"

            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

                // Save detailed answers only if --save-samples flag is set
                if saveSamples {
                    let jsonData = try encoder.encode(answers)
                    let answersURL = resultsDir.appendingPathComponent("\(filenameBase)_answers.json")
                    try jsonData.write(to: answersURL)
                    print("\nSaved per-sample answers to \(answersURL.path)")
                }

                // Save summary (always)
                let correctCount = answers.filter { $0.isCorrect }.count
                var summary: [String: Any] = [
                    "benchmark": benchmark,
                    "prompt_mode": useReasoning ? "reasoning" : "direct",
                    "few_shot": maxShots,
                    "guardrails_disabled": noGuardrails,
                    "start_question": startQuestion,
                    "total_questions": answers.count,
                    "total_time_seconds": totalTime,
                    "timestamp": timestamp,
                    // Response classification
                    "valid_answers": answers.validCount,
                    "safety_refusals": answers.safetyRefusalCount,
                    "format_failures": answers.formatFailureCount,
                    // Accuracy metrics
                    "true_accuracy": answers.trueAccuracy * 100,
                    "true_correct": answers.correctValidCount,
                    "raw_accuracy": answers.macroAccuracy * 100,
                    "raw_correct": correctCount,
                    // Legacy fields for backwards compatibility
                    "correct": correctCount,
                    "accuracy": answers.macroAccuracy * 100
                ]
                if let path = adapterPath {
                    summary["adapter"] = path
                }
                if let maxTok = maxTokens {
                    summary["max_tokens"] = maxTok
                }
                let summaryData = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
                let summaryURL = resultsDir.appendingPathComponent("\(filenameBase)_summary.json")
                try summaryData.write(to: summaryURL)
                print("\nSaved summary to \(summaryURL.path)")

                // Store results for final report
                allResults.append((benchmark: benchmark, accuracy: answers.macroAccuracy, correct: correctCount, total: answers.count, time: totalTime))
            } catch {
                print("Failed to save results: \(error)")
            }
        } // End of benchmark loop

        // Print final combined report if multiple benchmarks were run
        if allResults.count > 1 {
            print("\n" + String(repeating: "═", count: 60))
            print("COMBINED RESULTS REPORT")
            print(String(repeating: "═", count: 60))
            print("Prompt mode:    \(useReasoning ? "reasoning (chain-of-thought)" : "direct answer (no reasoning)")")
            print("Few-shot:       \(maxShots)-shot")
            print("Guardrails:     \(noGuardrails ? "DISABLED" : "enabled")")
            if let path = adapterPath {
                print("Adapter:        \(path)")
            }
            if let max = maxSamples {
                print("Max samples:    \(max) per benchmark")
            }
            if let maxTok = maxTokens {
                print("Max tokens:     \(maxTok)")
            }
            print(String(repeating: "-", count: 60))
            // Use string padding instead of %s format (which expects C strings)
            print("Benchmark".padding(toLength: 15, withPad: " ", startingAt: 0) + "  Accuracy   Correct       Time")
            print(String(repeating: "-", count: 60))

            var totalCorrect = 0
            var totalQuestions = 0
            var totalTime: TimeInterval = 0

            for result in allResults {
                let timeStr: String
                if result.time >= 3600 {
                    let hours = Int(result.time) / 3600
                    let minutes = (Int(result.time) % 3600) / 60
                    timeStr = String(format: "%dh%02dm", hours, minutes)
                } else {
                    let minutes = Int(result.time) / 60
                    let seconds = Int(result.time) % 60
                    timeStr = String(format: "%dm%02ds", minutes, seconds)
                }
                let benchmarkPadded = result.benchmark.padding(toLength: 15, withPad: " ", startingAt: 0)
                let accuracyStr = String(format: "%6.2f%%", result.accuracy * 100)
                let correctStr = "\(result.correct)/\(result.total)"
                print("\(benchmarkPadded) \(accuracyStr)   \(correctStr.padding(toLength: 8, withPad: " ", startingAt: 0))  \(timeStr)")
                totalCorrect += result.correct
                totalQuestions += result.total
                totalTime += result.time
            }

            print(String(repeating: "-", count: 60))
            let overallAccuracy = totalQuestions > 0 ? Float(totalCorrect) / Float(totalQuestions) * 100 : 0
            let totalTimeStr: String
            if totalTime >= 3600 {
                let hours = Int(totalTime) / 3600
                let minutes = (Int(totalTime) % 3600) / 60
                totalTimeStr = String(format: "%dh%02dm", hours, minutes)
            } else {
                let minutes = Int(totalTime) / 60
                let seconds = Int(totalTime) % 60
                totalTimeStr = String(format: "%dm%02ds", minutes, seconds)
            }
            let overallPadded = "OVERALL".padding(toLength: 15, withPad: " ", startingAt: 0)
            let overallAccStr = String(format: "%6.2f%%", overallAccuracy)
            let overallCorrectStr = "\(totalCorrect)/\(totalQuestions)"
            print("\(overallPadded) \(overallAccStr)   \(overallCorrectStr.padding(toLength: 8, withPad: " ", startingAt: 0))  \(totalTimeStr)")
            print(String(repeating: "═", count: 60))

            // Save combined report
            let resultsDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("results")
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
            let timestamp = dateFormatter.string(from: Date())
            let reasoningMode = useReasoning ? "reasoning" : "direct"
            let benchmarkNames = allResults.map { $0.benchmark }.joined(separator: "_")
            let combinedFilename = "combined_\(benchmarkNames)_\(maxShots)shot_\(reasoningMode)_\(timestamp)_report.json"

            var combinedReport: [String: Any] = [
                "benchmarks": allResults.map { ["benchmark": $0.benchmark, "accuracy": $0.accuracy * 100, "correct": $0.correct, "total": $0.total, "time_seconds": $0.time] },
                "overall_accuracy": overallAccuracy,
                "total_correct": totalCorrect,
                "total_questions": totalQuestions,
                "total_time_seconds": totalTime,
                "prompt_mode": useReasoning ? "reasoning" : "direct",
                "few_shot": maxShots,
                "guardrails_disabled": noGuardrails,
                "timestamp": timestamp
            ]
            if let path = adapterPath {
                combinedReport["adapter"] = path
            }
            if let maxTok = maxTokens {
                combinedReport["max_tokens"] = maxTok
            }

            if let combinedData = try? JSONSerialization.data(withJSONObject: combinedReport, options: [.prettyPrinted, .sortedKeys]) {
                let combinedURL = resultsDir.appendingPathComponent(combinedFilename)
                try? combinedData.write(to: combinedURL)
                print("\nSaved combined report to \(combinedURL.path)")
            }
        }
    }
}
