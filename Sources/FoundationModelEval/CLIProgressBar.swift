//
//  CLIProgressBar.swift
//  FoundationModelEval
//
//  Created by Pedro Cuenca on 13/6/25.
//

import Foundation

struct CLIProgressBar {
    let width: Int
    let fillChar: Character
    let emptyChar: Character
    let prefix: String

    init(width: Int = 50, fillChar: Character = "█", emptyChar: Character = "░", prefix: String = "") {
        self.width = width
        self.fillChar = fillChar
        self.emptyChar = emptyChar
        self.prefix = prefix
    }

    func update(_ progress: Progress, info: String? = nil) {
        let percentage = progress.fractionCompleted
        let filledWidth = Int(percentage * Double(width))
        let emptyWidth = width - filledWidth

        let filledBar = String(repeating: fillChar, count: filledWidth)
        let emptyBar = String(repeating: emptyChar, count: emptyWidth)
        let percentageText = String(format: "%.1f%%", percentage * 100)

        let currentPrefix = prefix + (info ?? "")
        print("\r\(currentPrefix) [\(filledBar)\(emptyBar)] \(percentageText)", terminator: "")
        fflush(stdout)

        if progress.isFinished {
            print()
        }
    }
}
