import Foundation
import FoundationModels
import Hub

func formattedQuestion(from entry: MMLUEntry) -> String {
    return "**Question**: \(entry.question)"
}

func formattedOptions(from entry: MMLUEntry) -> String {
    return "**Options**: \(entry.formattedOptions)"
}

func formattedAnswer(from entry: MMLUEntry) -> String {
    // Note cotContent starts with "A: ", but the appendix says we need to use **Answer**:
    return "**Answer**: \(entry.cotContent.trimmingPrefix("A: "))"
}

struct Dataset {
    var validation: MMLUDataset
    var test: MMLUDataset

    var categories: [String] {
        validation.groupedByCategory().map { $0.key }
    }

    // Build 5-shot instructions, see Table 7 in appendix https://arxiv.org/pdf/2406.01574
    lazy var prompts : [String : String] = {
        var instructions: [String : String] = [:]
        let validationQuestions = validation.groupedByCategory()
        for (category, entries) in validationQuestions {
            let intro = "The following are multiple choice questions (with answers) about \(category). Think step by step and then finish your answer with \"The answer is (X)\" where X is the correct letter choice."
            let examples = entries.map { entry in
                return """
                    \(formattedQuestion(from: entry))
                    \(formattedOptions(from: entry))
                    \(formattedAnswer(from: entry))
                    
                    
                    """
            }
            instructions[category] = "\(intro)\n\n\(examples.joined())"
        }
        return instructions
    }()

    static func load(from datasetURL: URL) throws -> Dataset {
        let validationSplit = try MMLUDataset.loadFromFile(at: datasetURL.appending(path: "validation.json")).validQuestions
        let testSplit = try MMLUDataset.loadFromFile(at: datasetURL.appending(path: "test.json")).validQuestions
        return Dataset(validation: validationSplit, test: testSplit)
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
        let progressBar = CLIProgressBar(prefix: "Dataset download")
        let repo = Hub.Repo(id: "pcuenq/MMLU-Pro-json", type: .datasets)
        let datasetURL = try await Hub.snapshot(from: repo, matching: "*.json") { @Sendable progress in
            progressBar.update(progress)
        }

        //            let session = LanguageModelSession(instructions: "You have expert knowledge about various topics, and your only task is to respond to a single question. You will be shown 5 multiple choice questions with answers. They are unrelated, but they belong to the same category of the question you have to answer. You don't have to answer to the example questions, they are provided as examples. The final question (the one you have to answer), is followed by the beginning of your answer. You must complete this answer, starting with your reasoning and thoughts. After you have pondered the various options, you must finish your response using a line with the structure `The answer is (X).`, where `X` is the letter of the correct answer. Please, stop immediately afterwards and don't engage in conversation.")

        //You have to follow To help you with the format we need you to respond with, you will be shown 5 unrelated multiple choice questions with answers that belong to the same category of the question we need you to respond. These examples will be followed by our question, a list of choices prefixed by letters, and the beginning words of your answer. You don't have to engage in conversation, you need to provide your answer following the style and format used in the examples. You must include your reasoning process, and end with a line like `The answer is (X)`, where `X` is the letter choice of your answer. Make sure you think about the problem and that your answer matches your reasoning.")
        var session = LanguageModelSession(instructions: "You have expert knowledge about various topics, and your only task is to respond to a single question. Please, follow the examples faithfully and answer the question using the same format asked for. Think carefull about the options, explain your reasoning, and make sure your answer ends with a line that has the same format as the ones in the examples.")
        //            let session = LanguageModelSession()

        var dataset = try Dataset.load(from: datasetURL)
        var answers: [Answer] = []
        var scores: [String : Score] = Dictionary(uniqueKeysWithValues: zip(dataset.categories, Array(repeating: Score(total: 0, correct: 0), count: dataset.categories.count)))
        let evalProgressBar = CLIProgressBar(prefix: "Eval")
        let totalEntries = dataset.test.count
        let progress = Progress(totalUnitCount: Int64(totalEntries))
        for entry in dataset.test {
            guard let prompt = dataset.prompts[entry.category] else {
                fatalError("No prompt for category \(entry.category)")
            }
            let finalPrompt = "\(prompt)\n\(formattedQuestion(from: entry))\n\(formattedOptions(from: entry))\n**Answer**: Let's think step by step."
//            print(finalPrompt)

            let predictedAnswer: String
            do {
                let options = GenerationOptions(sampling: .greedy)
                let response = try await session.respond(to: finalPrompt, options: options)
                predictedAnswer = response.content
            } catch {
                // Getting guard rail violations, client rate limits, ...
                print("Model exception: \(error)")
                predictedAnswer = ""
            }
            print(predictedAnswer)

            // Reuse instructions from the previous sessions; not sure if this helps
            session = LanguageModelSession(transcript: Transcript(entries: Array(session.transcript.entries[0..<1])))

            let answer: String
            let answerRE = /answer is \((.).*/.ignoresCase()
            if let result = try? answerRE.firstMatch(in: predictedAnswer) {
                answer = String(result.1).uppercased()
                print("Model: \(answer), Correct: \(entry.answer)")
            } else {
                // Random choice
                answer = entry.answerLetter(for: (0..<entry.options.count).randomElement()!)
                print("Random: \(answer), Correct: \(entry.answer)")
            }
            scores[entry.category] = scores[entry.category]?.updated(with: answer == entry.answer)

            // Store all answers for debugging
            let loggedAnswer = Answer(questionId: entry.questionId, category: entry.category, correctChoice: entry.answerLetter!, predictedChoice: answer, predictedAnswer: predictedAnswer)
            answers.append(loggedAnswer)

            progress.completedUnitCount += 1

            let accuracyPercent = String(format: "%.2f", answers.macroAccuracy * 100)
            evalProgressBar.update(progress, info: "[Acc: \(accuracyPercent)%]")

            // Getting "Client rate limit exceeded" errors, despite the model being local, and after disabling the network
//            usleep(1_000_000)
        }

        print(scores)
        print("Macro accuracy: \(answers.macroAccuracy)")

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(answers)
            let fileURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("answers.json")
            try jsonData.write(to: fileURL)
            print("Saved answers to \(fileURL.path)")
        } catch {
            print("Failed to save answers: \(error)")
        }
    }
}
