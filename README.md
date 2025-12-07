# `foundation-model-evals`

> **Forked from**: https://github.com/pcuenca/foundation-model-evals/

> **Research Use Only**: This tool is intended for research and educational purposes to evaluate language model performance on standard benchmarks. It is designed to support academic research into LoRA fine-tuning of Apple Foundation Models.

Evaluate foundation models on various benchmarks using macOS 26 "Tahoe" local models.

## Purpose

This project enables researchers to:
- Evaluate baseline performance of Apple Foundation Models on standard benchmarks
- Compare performance of LoRA fine-tuned variants against baseline
- Conduct reproducible evaluations for academic research

**Disclaimer**: This tool is for research purposes only. Users are responsible for ensuring compliance with all applicable licenses and terms of service when using this tool with any models.

## Supported Benchmarks

| Benchmark | Questions | Download | Description |
|-----------|-----------|----------|-------------|
| **MMLU** | ~12k | Auto | Massive Multitask Language Understanding (57 subjects) |
| **ARC-Easy** | ~2.4k | Auto | AI2 Reasoning Challenge (science, easy) |
| **ARC-Challenge** | ~1.2k | Auto | AI2 Reasoning Challenge (science, hard) |
| **BoolQ** | ~3.3k | Auto | Boolean Questions (reading comprehension) |

## Usage

### Basic Usage

```bash
# Run MMLU evaluation (default)
swift run FoundationModelEval

# Run ARC-Easy evaluation
swift run FoundationModelEval arc-easy

# Run BoolQ evaluation
swift run FoundationModelEval boolq

# Run multiple benchmarks in sequence
swift run FoundationModelEval boolq arc-easy arc-challenge 1 5 --max 100
```

### Prompt Modes

Two evaluation modes are available:

| Mode | Flag | Description |
|------|------|-------------|
| **Direct** | (default) | Direct answer prompting (no reasoning) |
| **Reasoning** | `--reason` or `--think` | Chain-of-thought prompting ("Think step by step...") |

```bash
# Direct answer mode (default)
swift run FoundationModelEval arc-easy 1 3

# With reasoning (chain-of-thought)
swift run FoundationModelEval arc-easy 1 3 --reason
```

### Command Line Arguments

```
FoundationModelEval [benchmarks...] [startQuestion] [maxShots] [--reason|--think] [--max N] [--save-samples]

Arguments:
  benchmarks       - One or more: mmlu, arc-easy, arc-challenge, boolq (default: mmlu)
  startQuestion    - Question number to start from (default: 1)
  maxShots         - Number of few-shot examples (0-10, default: 5)
  --reason/--think - Enable chain-of-thought prompting
  --max N          - Maximum number of samples per benchmark (default: all)
  --save-samples   - Save per-sample detailed results (default: summary only)
```

### Examples

```bash
# MMLU: Start from question 1, 5-shot (default, direct answer)
swift run FoundationModelEval

# MMLU: Start from question 50, 3-shot, with reasoning
swift run FoundationModelEval mmlu 50 3 --reason

# ARC-Easy: Start from question 1, 3-shot
swift run FoundationModelEval arc-easy 1 3

# ARC-Challenge: Start from question 100, 0-shot
swift run FoundationModelEval arc-challenge 100 0

# BoolQ: Start from question 1, 5-shot
swift run FoundationModelEval boolq 1 5

# Quick test: Run only 100 samples
swift run FoundationModelEval mmlu 1 5 --max 100

# Multiple benchmarks: Run BoolQ and ARC-Easy with 100 samples each
swift run FoundationModelEval boolq arc-easy 1 5 --max 100

# All benchmarks: Run full suite
swift run FoundationModelEval mmlu arc-easy arc-challenge boolq 1 5 --max 100

# Save per-sample detailed results (in addition to summary)
swift run FoundationModelEval boolq 1 5 --max 100 --save-samples
```

## Features

- **Auto-download** - All datasets download automatically from HuggingFace
- **Color-coded output** - Blue for model response, green/red for correct/incorrect
- **Real-time progress** - Shows accuracy, questions per second, and ETA
- **Context management** - Automatically reduces examples if context window exceeded
- **Evaluation summary** - Detailed summary at the end with benchmark settings
- **Answer extraction** - Robust regex patterns to extract answers in various formats
- **Permissive guardrails** - Reduces blocking on sensitive content

## Output

### During Evaluation
```
═══════════════════════════════════════════════════════════════
[Q29/12031 ID:98 Category:business]
Question: What is the primary function of...
Options: A. Option 1, B. Option 2, C. Option 3, D. Option 4
═══════════════════════════════════════════════════════════════
Model Response:
[blue] The answer is (B). Option 2 because... [/blue]
[green] Model: B, Correct: B [/green]
Eval[Acc: 75.00% | QPS: 2.50 | ETA: 1:23] [████████░░░░░░░░] 50.0%
```

### Final Summary
```
============================================================
EVALUATION SUMMARY
============================================================
Benchmark:      arc-easy
Prompt mode:    reasoning (chain-of-thought)
Few-shot:       3-shot
Questions:      100 (started at #1)
Total time:     5:32
------------------------------------------------------------
Accuracy:       75.00%
Correct:        75 / 100
============================================================
```

### Combined Report (Multiple Benchmarks)
When running multiple benchmarks, a combined report is displayed and saved:
```
════════════════════════════════════════════════════════════
COMBINED RESULTS REPORT
════════════════════════════════════════════════════════════
Prompt mode:    direct answer (no reasoning)
Few-shot:       5-shot
Max samples:    100 per benchmark
------------------------------------------------------------
Benchmark         Accuracy    Correct       Time
------------------------------------------------------------
boolq              80.00%     80/100      2m30s
arc-easy           75.00%     75/100      3m15s
arc-challenge      60.00%     60/100      4m45s
------------------------------------------------------------
OVERALL            71.67%    215/300     10m30s
════════════════════════════════════════════════════════════
```

### Saved Files

Results are saved to the `results/` folder:

| File | When Saved | Contents |
|------|------------|----------|
| `*_summary.json` | Always | Benchmark settings, accuracy, timing |
| `*_answers.json` | With `--save-samples` | Per-question predictions and correctness |
| `combined_*_report.json` | Multiple benchmarks | Aggregated results across all benchmarks |

## Dataset Caching

Downloaded datasets are cached locally:
- MMLU: `~/.cache/huggingface/...`
- ARC: `~/.cache/arc-dataset/`
- BoolQ: `~/.cache/boolq-dataset/`

## Requirements

- macOS 26 "Tahoe" (with Foundation Models support)
- Swift 6.2+
- Internet connection (for initial dataset downloads)

## Architecture

Each benchmark has its own dataset file with:
- Data structures for entries
- Download/loading logic
- Benchmark-specific prompts (`promptIntro`, `promptLeadIn`, `formatAsExample`)

```
Sources/FoundationModelEval/
├── FoundationModelEval.swift  # Main evaluation loop
├── MMLUDataset.swift          # MMLU benchmark
├── ARCDataset.swift           # ARC benchmark
├── BoolQDataset.swift         # BoolQ benchmark
└── CLIProgressBar.swift       # Progress display
```
