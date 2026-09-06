import Foundation

// Post-session pipeline:
// afconvert -> whisper (timestamped JSON) -> Py-Feat facial analysis ->
// annotated transcript -> Claude (Opus, max effort) -> summary.md.

private let defaultModel = "claude-opus-5"
private let defaultEffort = "max"

private var whisperCandidates: [String] {
    var paths: [String] = []
    if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/whisper-cli").path {
        paths.append(bundled)
    }
    paths.append(contentsOf: ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"])
    return paths
}
private var claudeCandidates: [String] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return [
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        home + "/.local/bin/claude",
        home + "/.claude/local/claude"
    ]
}
private var codexCandidates: [String] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return [
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        home + "/.local/bin/codex",
        Paths.appSupport.appendingPathComponent("bin/codex").path
    ]
}

enum FeedbackProvider {
    case claude, codex

    static func from(_ settings: Settings) -> FeedbackProvider {
        settings.analysis?.provider == "codex" ? .codex : .claude
    }

    var label: String { self == .claude ? "Claude" : "ChatGPT (Codex)" }
}
private let whisperModels = [
    "ggml-large-v3.bin", "ggml-large-v3-turbo.bin", "ggml-medium.en.bin",
    "ggml-small.en.bin", "ggml-base.en.bin"
]

private let verbatimPrompt =
    "Umm, let me think, like, hmm... Okay, so, uh, here's what I, you know, I mean, I was thinking."

private let fillerPatterns = ["um", "uh", "er", "ah", "you know", "sort of", "kind of", "basically"]

private let defaultRubric = """
# Interview Answer Rubric

Edit this file to change how answers are judged (it lives in the app's data folder as rubric.md).

## Structure (all questions)
- Signposted opening that addresses the question directly
- Logical progression; 2-4 developed points rather than many shallow ones
- Balanced consideration of other perspectives where relevant
- Clear conclusion that actually answers the question asked

## Ethics & situational judgment
- Identifies the ethical tension explicitly
- Applies principles: autonomy, beneficence, non-maleficence, justice
- Considers all stakeholders and consequences; avoids absolutist positions
- Arrives at a defensible, compassionate position

## Motivation & personal questions
- Specific personal evidence rather than generic claims
- Genuine reflection: what was learned and how it changed them
- Links back to medicine and to the school applied for, where natural, without sounding rehearsed

## Public health, Indigenous health, rural health
- Understands systemic factors and social determinants of health
- Cultural safety and humility, especially for Indigenous health
- Realistic about trade-offs; aware of workforce and access issues

## Communication & delivery
- Pace roughly 110-160 words per minute; minimal filler words
- Uses a good portion of the available time without rambling or repeating
- Warm, professional, first-person voice
"""

private struct QuestionAnalysis {
    let index: Int
    let theme: String?
    let text: String
    var transcript: String
    var segments: [TranscriptSegment]
    var words: Int
    var wpm: Int
    var durationLabel: String
    var fillers: String
    var facial: String?
    var faces: [FaceFrame]?
}

private struct WhisperJSON: Codable {
    struct Segment: Codable {
        struct Offsets: Codable {
            let from: Int?
            let to: Int?
        }
        let offsets: Offsets?
        let text: String?
    }
    let transcription: [Segment]?
}

private struct FacesFile: Codable {
    let summary_text: String?
    let timeline: [FaceFrame]?
}

@MainActor
final class AnalysisManager: ObservableObject {
    // sessionDir path -> progress message; empty when idle.
    @Published var progress: [String: String] = [:]
    @Published var completedTick = 0
    private var running = Set<String>()
    let store: AppStore

    init(store: AppStore) {
        self.store = store
    }

    func isRunning(_ dir: URL) -> Bool { running.contains(dir.path) }

    func analyze(_ dir: URL) {
        guard !running.contains(dir.path) else { return }
        running.insert(dir.path)
        let settings = store.settings
        Task {
            await Self.pipeline(dir: dir, settings: settings) { [weak self] message in
                Task { @MainActor in self?.progress[dir.path] = message }
            }
            await MainActor.run {
                self.running.remove(dir.path)
                self.completedTick += 1
            }
        }
    }

    func checkProvider() async -> String {
        let settings = store.settings
        switch await Self.feedback(
            provider: FeedbackProvider.from(settings),
            prompt: "Reply with exactly: OK",
            settings: settings
        ) {
        case .success(let text):
            return text.contains("OK")
                ? "✓ Connected: \(FeedbackProvider.from(settings).label)"
                : "✗ Unexpected reply: \(String(text.prefix(120)))"
        case .failure(let message):
            return "✗ \(message)"
        }
    }

    // MARK: - Pipeline

    private static func pipeline(
        dir: URL,
        settings: Settings,
        report: @escaping @Sendable (String) -> Void
    ) async {
        do {
            try await runPipeline(dir: dir, settings: settings, report: report)
        } catch {
            report("Error: \(error.localizedDescription)")
        }
    }

    private static func runPipeline(
        dir: URL,
        settings: Settings,
        report: @escaping @Sendable (String) -> Void
    ) async throws {
        let fm = FileManager.default
        let metaData = try Data(contentsOf: dir.appendingPathComponent("session.json"))
        let meta = try JSONDecoder().decode(SessionMeta.self, from: metaData)
        let answered = meta.questions.filter { $0.file != nil }
        guard !answered.isEmpty else {
            report("Error: no recorded answers in this session.")
            return
        }

        guard let whisper = firstExisting([settings.analysis?.whisperPath] + whisperCandidates) else {
            report("Error: whisper-cli not found. Install it with: brew install whisper-cpp")
            return
        }
        guard let model = firstExisting(whisperModels.map { Paths.modelsDir.appendingPathComponent($0).path }) else {
            report("Error: no Whisper model found in the app's models folder.")
            return
        }

        var questions: [QuestionAnalysis] = []
        let tmp = fm.temporaryDirectory

        for (i, q) in answered.enumerated() {
            report("Transcribing answer \(i + 1) of \(answered.count)…")
            let media = dir.appendingPathComponent(q.file ?? "")
            let wav = tmp.appendingPathComponent("viva-\(meta.id)-q\(q.index).wav")
            let jsonBase = tmp.appendingPathComponent("viva-\(meta.id)-q\(q.index)")
            defer {
                try? fm.removeItem(at: wav)
                try? fm.removeItem(at: jsonBase.appendingPathExtension("json"))
            }

            // A too-short answer can have no audio track at all; treat any
            // extraction or transcription failure as "no speech" for that
            // question rather than aborting the whole session's analysis.
            var segments: [TranscriptSegment] = []
            do {
                let conv = try await runProcess(
                    "/usr/bin/afconvert",
                    ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", media.path, wav.path],
                    timeout: 300
                )
                if conv.code == 0 {
                    let wr = try await runProcess(
                        whisper,
                        ["-m", model, "-f", wav.path, "-l", "en", "--prompt", verbatimPrompt, "-np", "-oj", "-of", jsonBase.path],
                        timeout: 1800
                    )
                    if wr.code == 0,
                       let wjData = try? Data(contentsOf: jsonBase.appendingPathExtension("json")),
                       let wj = try? JSONDecoder().decode(WhisperJSON.self, from: wjData) {
                        segments = (wj.transcription ?? []).compactMap { s in
                            let text = (s.text ?? "").trimmingCharacters(in: .whitespaces)
                            guard !text.isEmpty else { return nil }
                            return TranscriptSegment(fromMs: s.offsets?.from ?? 0, toMs: s.offsets?.to ?? 0, text: text)
                        }
                    }
                }
            } catch {
                // fall through with no segments
            }
            let transcript = segments.map(\.text).joined(separator: " ")
            let words = transcript.split(whereSeparator: { $0.isWhitespace }).count
            let minutes = Double(max(q.answeredMs, 1000)) / 60000
            questions.append(
                QuestionAnalysis(
                    index: q.index,
                    theme: q.theme,
                    text: q.text,
                    transcript: transcript,
                    segments: segments,
                    words: words,
                    wpm: Int((Double(words) / minutes).rounded()),
                    durationLabel: durationLabel(q.answeredMs),
                    fillers: fillerSummary(transcript),
                    facial: nil,
                    faces: nil
                )
            )
        }

        // Facial analysis. Failures degrade gracefully.
        if settings.analysis?.facial != false {
            let script = firstExisting([
                Bundle.main.resourceURL?.appendingPathComponent("scripts/facial_analysis.py").path
            ])
            let python = firstExisting([
                settings.analysis?.pythonPath,
                Paths.appSupport.appendingPathComponent("pyvenv/bin/python").path,
                Paths.appSupport.appendingPathComponent("python/bin/python3").path
            ])
            if let script, let python {
                for (i, q) in answered.enumerated() {
                    report("Analyzing facial expressions, answer \(i + 1) of \(answered.count)… (this is the slow part)")
                    let media = dir.appendingPathComponent(q.file ?? "")
                    let out = dir.appendingPathComponent("q\(q.index).faces.json")
                    do {
                        let res = try await runProcess(
                            python,
                            [script, media.path, "--out", out.path, "--fps", "2"],
                            timeout: 1800
                        )
                        if res.code == 0,
                           let data = try? Data(contentsOf: out),
                           let faces = try? JSONDecoder().decode(FacesFile.self, from: data),
                           let idx = questions.firstIndex(where: { $0.index == q.index }) {
                            questions[idx].facial = faces.summary_text
                            if let timeline = faces.timeline, !timeline.isEmpty {
                                questions[idx].faces = timeline
                            }
                        }
                    } catch {
                        report("Facial analysis failed for answer \(q.index): \(error.localizedDescription)")
                    }
                }
            } else {
                report("Facial analysis skipped: Python environment not configured.")
            }
        }

        try buildTranscriptMd(meta: meta, questions: questions)
            .write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)

        let rubric = loadRubric()
        let prompt = buildPrompt(meta: meta, questions: questions, rubric: rubric)
        let provider = FeedbackProvider.from(settings)
        report("Analyzing with \(provider.label)… this can take a few minutes.")

        let summary: String
        switch await feedback(provider: provider, prompt: prompt, settings: settings) {
        case .success(let text):
            summary = text
        case .failure(let message):
            report("Error: \(message)")
            return
        }
        try (summary + "\n").write(to: dir.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        report("")
    }

    private enum FeedbackResult {
        case success(String)
        case failure(String)
    }

    private static func feedback(
        provider: FeedbackProvider,
        prompt: String,
        settings: Settings
    ) async -> FeedbackResult {
        let fm = FileManager.default
        switch provider {
        case .claude:
            guard let claude = firstExisting([settings.analysis?.claudePath] + claudeCandidates) else {
                return .failure("Transcript saved, but the claude CLI was not found. Install it with: npm install -g @anthropic-ai/claude-code")
            }
            let model = settings.analysis?.model ?? defaultModel
            let effort = settings.analysis?.effort ?? defaultEffort
            do {
                let res = try await runProcess(
                    claude,
                    ["-p", "--model", model, "--effort", effort, "--no-session-persistence"],
                    stdin: prompt,
                    cwd: fm.temporaryDirectory,
                    timeout: 900
                )
                let combined = res.stdout + res.stderr
                if combined.lowercased().contains("not logged in") {
                    return .failure("Claude CLI is not logged in. Run `claude` in Terminal, /login once, then Re-analyze.")
                }
                let text = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                guard res.code == 0, !text.isEmpty else {
                    return .failure("Claude analysis failed: \(String(combined.suffix(250)))")
                }
                return .success(text)
            } catch {
                return .failure(error.localizedDescription)
            }
        case .codex:
            guard let codex = firstExisting([settings.analysis?.codexPath] + codexCandidates) else {
                return .failure("Transcript saved, but the codex CLI was not found. Install it with: npm install -g @openai/codex")
            }
            let outFile = fm.temporaryDirectory.appendingPathComponent("viva-codex-\(UUID().uuidString).txt")
            defer { try? fm.removeItem(at: outFile) }
            do {
                let res = try await runProcess(
                    codex,
                    ["exec", "--skip-git-repo-check", "--output-last-message", outFile.path],
                    stdin: prompt,
                    cwd: fm.temporaryDirectory,
                    timeout: 900
                )
                let combined = res.stdout + res.stderr
                let lower = combined.lowercased()
                if lower.contains("not logged in") || lower.contains("codex login") {
                    return .failure("Codex CLI is not logged in. Run `codex login` in Terminal once, then Re-analyze.")
                }
                let fileText = (try? String(contentsOf: outFile, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let text = fileText.isEmpty
                    ? res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    : fileText
                guard res.code == 0, !text.isEmpty else {
                    return .failure("Codex analysis failed: \(String(combined.suffix(250)))")
                }
                return .success(text)
            } catch {
                return .failure(error.localizedDescription)
            }
        }
    }

    // MARK: - Helpers

    private static func loadRubric() -> String {
        if let text = try? String(contentsOf: Paths.rubricFile, encoding: .utf8) { return text }
        try? defaultRubric.write(to: Paths.rubricFile, atomically: true, encoding: .utf8)
        return defaultRubric
    }

    // Stations can have several prompts on separate lines; keep every line quoted.
    private static func quoteBlock(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "\n> ")
    }

    private static func durationLabel(_ ms: Int) -> String {
        let total = Int((Double(ms) / 1000).rounded())
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    private static func fillerSummary(_ text: String) -> String {
        let lower = text.lowercased()
        var parts: [String] = []
        for f in fillerPatterns {
            let pattern = "\\b" + f.replacingOccurrences(of: " ", with: "\\s+") + "\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let count = regex.numberOfMatches(in: lower, range: NSRange(lower.startIndex..., in: lower))
            if count > 0 { parts.append("\(f)×\(count)") }
        }
        return parts.isEmpty ? "none detected" : parts.joined(separator: ", ")
    }

    private static func buildTranscriptMd(meta: SessionMeta, questions: [QuestionAnalysis]) -> String {
        var lines: [String] = [
            "# Transcript: \(meta.id)",
            "",
            "Question set: \(meta.questionSet)",
            "Format: \(meta.timings.readingSec)s reading / \(meta.timings.answerSec)s answer / \(meta.timings.breakSec)s break",
            ""
        ]
        for q in questions {
            lines.append("## Q\(q.index)" + (q.theme.map { " (\($0))" } ?? ""))
            lines.append("")
            lines.append("> \(quoteBlock(q.text))")
            lines.append("")
            if !q.segments.isEmpty {
                lines.append(contentsOf: annotatedTranscriptLines(q.segments, frames: q.faces).map { $0 + "  " })
            } else {
                lines.append(q.transcript.isEmpty ? "_(no speech detected)_" : q.transcript)
            }
            lines.append("")
            lines.append("*\(q.words) words in \(q.durationLabel) · \(q.wpm) wpm · fillers: \(q.fillers)*")
            if let facial = q.facial {
                lines.append("")
                lines.append("*Facial cues: \(facial)*")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func buildPrompt(meta: SessionMeta, questions: [QuestionAnalysis], rubric: String) -> String {
        let header = """
        You are an experienced medical school interview coach. A student has completed a practice interview in a recorded online multiple mini interview format, with no interviewer present. Each question is delivered and recording starts immediately; the student has 5 minutes to think and answer, and thinking time counts toward those 5 minutes.

        Assess the transcripts below against the rubric. The transcripts come from automatic speech recognition, so ignore obvious transcription artifacts and do not nitpick grammar. Do not use any tools; reply with plain markdown only.

        For EACH question output:

        ### Q<n>: <theme>
        - **Score:** x/10 against the rubric
        - **Strengths:** 2-3 specific bullets
        - **Weaknesses:** 2-3 specific bullets
        - **Fix next time:** the single highest-impact change
        - **Model answer outline:** a 4-6 bullet skeleton of a strong answer to this exact question

        Then finish with:

        ## Overall
        - Patterns across the answers (good and bad)
        - **Top 3 priorities before the next session**

        After the Overall section, end with a fenced ```json code block of the form {"scores": [{"q": 1, "score": 7}, {"q": 2, "score": 5}]}, one entry per question with your x/10 score, and nothing after the block. This feeds the app's statistics.

        Delivery metrics (duration, words per minute, filler words) are provided per question; comment on pace and time use where relevant. The target is using most of the 5 minutes without rambling, and very short answers should be flagged as such.

        When facial data is available, every transcript line is annotated with the facial cues measured during that exact time window: dominant emotion with its share of frames, elevated facial action units, gaze direction, and valence (negative to positive mood, -1 to 1). Coach like an experienced interviewer sitting directly opposite the candidate: connect what was said to how it looked at that exact moment, quote the specific phrases where expression, gaze, or tension shifted, and point out small details a human observer would catch (a brow furrow on a difficult clause, gaze dropping during a claim, a flat face while describing something meant to be exciting, a genuine smile). These cues come from an automated model, so treat them as tendencies rather than facts, and never use them to diagnose the person. Never use em dashes in your writing.

        ## Rubric

        \(rubric)

        ## Session

        Question set: \(meta.questionSet)
        Session: \(meta.id)\(meta.aborted ? " (ended early)" : "")

        """
        let body = questions.map { q -> String in
            let transcriptBlock: String
            if !q.segments.isEmpty {
                transcriptBlock = "Transcript (each line annotated with facial cues from that exact window):\n"
                    + annotatedTranscriptLines(q.segments, frames: q.faces).joined(separator: "\n")
            } else {
                transcriptBlock = "Transcript:\n\"\"\"\n\(q.transcript.isEmpty ? "(no speech detected)" : q.transcript)\n\"\"\""
            }
            let quotedText = quoteBlock(q.text)
            return """

            ### Question \(q.index)\(q.theme.map { " (theme: \($0))" } ?? "") · answered in \(q.durationLabel), \(q.words) words, \(q.wpm) wpm, fillers: \(q.fillers)

            > \(quotedText)

            \(q.facial.map { "Overall facial summary: \($0)\n" } ?? "")
            \(transcriptBlock)
            """
        }.joined(separator: "\n")
        return header + body + "\n"
    }
}
