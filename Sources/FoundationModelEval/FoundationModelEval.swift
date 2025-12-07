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

enum DatasetType {
    case mmlu(validation: MMLUDataset, test: MMLUDataset)
    case arc(validation: ARCDataset, test: ARCDataset)
    case boolq(validation: BoolQDataset, test: BoolQDataset)

    var categories: [String] {
        switch self {
        case .mmlu(let validation, _):
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
                    validationSplit = try ARCDataset.loadFromFile(at: path)
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
                    testSplit = try ARCDataset.loadFromFile(at: path)
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

        default: // mmlu
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

    var isCorrect: Bool { correctChoice == predictedChoice }
}

struct Score {
    var total: Int
    var correct: Int

    func updated(with correctEntry: Bool) -> Score {
        let updatedCorrect = correctEntry ? correct + 1 : correct
        return Score(total: total+1, correct: updatedCorrect)
    }
}

extension Array where Element == Answer {
    var macroAccuracy: Float {
        guard !self.isEmpty else { return 0 }
        let correctAnswers = self.filter { $0.isCorrect }
        return Float(correctAnswers.count) / Float(self.count)
    }
}

@main
struct FoundationModelEval {
    static func main() async throws {
        // Parse command line arguments
        // Usage: FoundationModelEval [benchmarks...] [startQuestionNumber] [maxShots] [--reason|--think] [--max N]
        // Example: FoundationModelEval mmlu 29 5  (MMLU benchmark, starts from question 29, uses 5-shot)
        // Example: FoundationModelEval arc-easy 1 3   (ARC-Easy, starts from question 1, uses 3-shot)
        // Example: FoundationModelEval boolq arc-easy 1 5 --max 100  (Multiple benchmarks)
        // Example: FoundationModelEval arc-easy 1 3 --reason  (ARC-Easy with chain-of-thought reasoning)
        // Supported benchmarks: mmlu, arc-easy, arc-challenge, boolq
        // --reason or --think: Enable chain-of-thought prompting (default: direct answer mode)
        // --max N: Maximum number of samples to evaluate (default: all)
        let validBenchmarks = ["mmlu", "arc-easy", "arc-challenge", "boolq"]
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

        // Check for --save-samples flag (save per-sample detailed results)
        let saveSamples = CommandLine.arguments.contains("--save-samples")
        if saveSamples {
            print("Will save per-sample detailed results")
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
            default: // mmlu
                print("Downloading MMLU dataset...")
                let repo = Hub.Repo(id: "pcuenq/MMLU-Pro-json", type: .datasets)
                datasetURL = try await Hub.snapshot(from: repo, matching: "*.json") { @Sendable progress in
                    progressBar.update(progress)
                }
                print("MMLU dataset downloaded to: \(datasetURL.path)")
            }

            // Use SystemLanguageModel with permissive guardrails to avoid getting stuck on guardrail violations
            let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)

            // Shorter prompt to reduce token usage
            let instructions = "You have expert knowledge about various topics, and your only task is to respond to a single question. Please, follow the examples faithfully and answer the question using the same format asked for. Think carefull about the options, explain your reasoning, and make sure your answer ends with a line that has the same format as the ones in the examples."

            let dataset = try Dataset.load(from: datasetURL, benchmark: benchmark)
            var answers: [Answer] = []
            var scores: [String : Score] = Dictionary(uniqueKeysWithValues: zip(dataset.categories, Array(repeating: Score(total: 0, correct: 0), count: dataset.categories.count)))
            let evalProgressBar = CLIProgressBar(prefix: "Eval")

            // Calculate effective total entries (accounting for startQuestion and maxSamples)
            let availableEntries = dataset.testCount - startQuestion + 1
            let effectiveTotal: Int
            if let max = maxSamples {
                effectiveTotal = min(max, availableEntries)
            } else {
                effectiveTotal = availableEntries
            }
            let progress = Progress(totalUnitCount: Int64(effectiveTotal))
            let startTime = Date()
            var questionIndex = 0
            for i in 0..<dataset.testCount {
                guard let entry = dataset.getTestEntry(at: i) else { continue }
                questionIndex += 1

                // Skip questions before the start question
                if questionIndex < startQuestion {
                    continue
                }

                // Stop if we've reached maxSamples
                if let max = maxSamples, answers.count >= max {
                    break
                }

                // ANSI color codes for question display
                let cyan = "\u{001B}[36m"
                let resetQ = "\u{001B}[0m"

                print("\n\(cyan)═══════════════════════════════════════════════════════════════\(resetQ)")
                print("\(cyan)[Q\(answers.count + 1)/\(effectiveTotal) ID:\(entry.questionId) Category:\(entry.category)]\(resetQ)")

                // Print the question (with passage for BoolQ)
                if let boolqEntry = entry as? BoolQEntry {
                    // Truncate passage if too long
                    let maxPassageLen = 500
                    let passage = boolqEntry.passage.count > maxPassageLen
                        ? String(boolqEntry.passage.prefix(maxPassageLen)) + "..."
                        : boolqEntry.passage
                    print("\(cyan)Passage:\(resetQ) \(passage)")
                    print("\(cyan)Question:\(resetQ) \(boolqEntry.question)")
                } else {
                    print("\(cyan)Question:\(resetQ) \(entry.question)")
                }
                print("\(cyan)Options:\(resetQ) \(entry.formattedOptions)")
                print("\(cyan)═══════════════════════════════════════════════════════════════\(resetQ)")

                // Create a new session for each evaluation to reset context (stateless behavior)
                let session = LanguageModelSession(model: model, instructions: instructions)

                // Try with decreasing number of examples if context window is exceeded
                var predictedAnswer: String = ""
                var numExamples = maxShots // Start with the configured max shots
                var success = false
                var attempt = 0

                while !success && numExamples >= 0 {
                    attempt += 1
                    // Build prompt with current number of examples
                    guard let prompt = dataset.buildPrompt(for: entry.category, numExamples: numExamples, reasoning: useReasoning) else {
                        fatalError("No prompt for category \(entry.category)")
                    }
                    // Build final prompt - use dataset-specific formatting
                    let finalPrompt: String
                    if let boolqEntry = entry as? BoolQEntry {
                        finalPrompt = "\(prompt)\n\(boolqEntry.formatAsQuestion())\n\n\(BoolQEntry.promptLeadIn(reasoning: useReasoning))"
                    } else if let arcEntry = entry as? ARCEntry {
                        finalPrompt = "\(prompt)\n\(arcEntry.formatAsQuestion())\n\(ARCEntry.promptLeadIn(reasoning: useReasoning))"
                    } else if let mmluEntry = entry as? MMLUEntry {
                        finalPrompt = "\(prompt)\n\(mmluEntry.formatAsQuestion())\n\(MMLUEntry.promptLeadIn(reasoning: useReasoning))"
                    } else {
                        let leadIn = useReasoning ? "**Answer**: Let's think step by step." : "**Answer**: The answer is ("
                        finalPrompt = "\(prompt)\n\(formattedQuestion(from: entry))\n\(formattedOptions(from: entry))\n\(leadIn)"
                    }

                    if attempt > 1 {
                        print("\n  Retry attempt \(attempt) with \(numExamples)-shot prompt...", terminator: "")
                    }

                    do {
                        let options = GenerationOptions(sampling: .greedy)
                        let response = try await session.respond(to: finalPrompt, options: options)
                        predictedAnswer = response.content
                        success = true
                        if numExamples < maxShots {
                            print("\n  Note: Used \(numExamples)-shot prompt due to context limits (started with \(maxShots)-shot)")
                        }
                    } catch {
                        let errorString = String(describing: error)
                        if (errorString.contains("exceededContextWindowSize") || errorString.contains("exceeds the maximum allowed context size")) && numExamples > 0 {
                            print("\n  Context window exceeded, trying with fewer examples...")
                            numExamples = max(0, numExamples - 2)
                            if numExamples == 0 {
                                print("  Warning: Context window exceeded even with 0 examples. Using minimal prompt.")
                            }
                        } else {
                            print("\n  Model exception: \(error)")
                            success = true
                        }
                    }
                }

                // ANSI color codes
                let blue = "\u{001B}[34m"
                let green = "\u{001B}[32m"
                let red = "\u{001B}[31m"
                let reset = "\u{001B}[0m"

                print("Model Response:")
                if !predictedAnswer.isEmpty {
                    print("\(blue)\(predictedAnswer)\(reset)")
                } else {
                    print("  [No response generated]")
                }

                let answer: String
                // Try multiple patterns to extract the answer (support A-J for MMLU's 10 options)
                let answerRE1 = /answer is \(([A-Ja-j])\)/.ignoresCase()
                let answerRE2 = /answer is:?\s*([A-Ja-j])[\.\s,]/.ignoresCase()
                let answerRE3 = /(?:correct )?answer(?:\sis)?:?\s*([A-Ja-j])[\.\s,\)]/.ignoresCase()
                let answerRE4 = /^([A-Ja-j])(?:[\.\)\s]|$)/.ignoresCase()
                let answerRE5 = /^\(?([A-Ja-j])\)\.?/.ignoresCase()
                let answerRE6 = /answer:\s*([A-Ja-j])/.ignoresCase()

                if let result = try? answerRE1.firstMatch(in: predictedAnswer) {
                    answer = String(result.1).uppercased()
                    let isCorrect = answer == entry.answer
                    let resultColor = isCorrect ? green : red
                    print("\(resultColor)Model: \(answer), Correct: \(entry.answer)\(reset)")
                } else if let result = try? answerRE2.firstMatch(in: predictedAnswer) {
                    answer = String(result.1).uppercased()
                    let isCorrect = answer == entry.answer
                    let resultColor = isCorrect ? green : red
                    print("\(resultColor)Model: \(answer), Correct: \(entry.answer)\(reset)")
                } else if let result = try? answerRE3.firstMatch(in: predictedAnswer) {
                    answer = String(result.1).uppercased()
                    let isCorrect = answer == entry.answer
                    let resultColor = isCorrect ? green : red
                    print("\(resultColor)Model: \(answer), Correct: \(entry.answer)\(reset)")
                } else if let result = try? answerRE4.firstMatch(in: predictedAnswer.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    answer = String(result.1).uppercased()
                    let isCorrect = answer == entry.answer
                    let resultColor = isCorrect ? green : red
                    print("\(resultColor)Model: \(answer), Correct: \(entry.answer)\(reset)")
                } else if let result = try? answerRE5.firstMatch(in: predictedAnswer.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    answer = String(result.1).uppercased()
                    let isCorrect = answer == entry.answer
                    let resultColor = isCorrect ? green : red
                    print("\(resultColor)Model: \(answer), Correct: \(entry.answer)\(reset)")
                } else if let result = try? answerRE6.firstMatch(in: predictedAnswer) {
                    answer = String(result.1).uppercased()
                    let isCorrect = answer == entry.answer
                    let resultColor = isCorrect ? green : red
                    print("\(resultColor)Model: \(answer), Correct: \(entry.answer)\(reset)")
                } else {
                    // Random choice - model didn't provide answer in expected format
                    let randomIndex = (0..<entry.options.count).randomElement() ?? 0
                    if let mmluEntry = entry as? MMLUEntry {
                        answer = mmluEntry.answerLetter(for: randomIndex)
                    } else if let arcEntry = entry as? ARCEntry {
                        answer = arcEntry.answerLetter(for: randomIndex)
                    } else if let boolqEntry = entry as? BoolQEntry {
                        answer = boolqEntry.answerLetter(for: randomIndex)
                    } else {
                        answer = String(Character(UnicodeScalar(Int(asciiA) + randomIndex)!))
                    }
                    let isCorrect = answer == entry.answer
                    let resultColor = isCorrect ? green : red
                    print("\(resultColor)Random: \(answer), Correct: \(entry.answer) (model format not recognized)\(reset)")
                }
                scores[entry.category] = scores[entry.category]?.updated(with: answer == entry.answer)

                // Store all answers for debugging
                let correctChoice: String
                if let mmluEntry = entry as? MMLUEntry, let letter = mmluEntry.answerLetter {
                    correctChoice = letter
                } else if let arcEntry = entry as? ARCEntry, let letter = arcEntry.answerLetter {
                    correctChoice = letter
                } else if let boolqEntry = entry as? BoolQEntry, let letter = boolqEntry.answerLetter {
                    correctChoice = letter
                } else {
                    correctChoice = entry.answer
                }
                let loggedAnswer = Answer(questionId: entry.questionId, category: entry.category, correctChoice: correctChoice, predictedChoice: answer, predictedAnswer: predictedAnswer)
                answers.append(loggedAnswer)

                progress.completedUnitCount += 1

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
            } // End of questions loop

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
            print("Questions:      \(answers.count) (started at #\(startQuestion))")
            print("Total time:     \(totalTimeString)")
            print(String(repeating: "-", count: 60))
            print("Accuracy:       \(String(format: "%.2f", answers.macroAccuracy * 100))%")
            print("Correct:        \(answers.filter { $0.isCorrect }.count) / \(answers.count)")
            print(String(repeating: "=", count: 60))

            // Print per-category scores
            if scores.count > 1 {
                print("\nPer-category scores:")
                for (category, score) in scores.sorted(by: { $0.key < $1.key }) {
                    let catAcc = score.total > 0 ? Float(score.correct) / Float(score.total) * 100 : 0
                    print("  \(category): \(String(format: "%.1f", catAcc))% (\(score.correct)/\(score.total))")
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
                let summary: [String: Any] = [
                    "benchmark": benchmark,
                    "prompt_mode": useReasoning ? "reasoning" : "direct",
                    "few_shot": maxShots,
                    "start_question": startQuestion,
                    "total_questions": answers.count,
                    "correct": correctCount,
                    "accuracy": answers.macroAccuracy * 100,
                    "total_time_seconds": totalTime,
                    "timestamp": timestamp
                ]
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
            if let max = maxSamples {
                print("Max samples:    \(max) per benchmark")
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

            let combinedReport: [String: Any] = [
                "benchmarks": allResults.map { ["benchmark": $0.benchmark, "accuracy": $0.accuracy * 100, "correct": $0.correct, "total": $0.total, "time_seconds": $0.time] },
                "overall_accuracy": overallAccuracy,
                "total_correct": totalCorrect,
                "total_questions": totalQuestions,
                "total_time_seconds": totalTime,
                "prompt_mode": useReasoning ? "reasoning" : "direct",
                "few_shot": maxShots,
                "timestamp": timestamp
            ]

            if let combinedData = try? JSONSerialization.data(withJSONObject: combinedReport, options: [.prettyPrinted, .sortedKeys]) {
                let combinedURL = resultsDir.appendingPathComponent(combinedFilename)
                try? combinedData.write(to: combinedURL)
                print("\nSaved combined report to \(combinedURL.path)")
            }
        }
    }
}
