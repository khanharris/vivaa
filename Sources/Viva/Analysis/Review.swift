import Foundation

// Cross-session coaching review.
//
// A single session's summary.md can only see that session. This pass reads the
// whole practice history in chronological order and asks the provider for the
// patterns that only emerge across sessions: habits that keep recurring, advice
// from earlier sessions that was or was not acted on, and where the marks are
// actually being lost.

struct StationDigest {
    let index: Int
    let theme: String?
    let question: String
    let score: Double?
    let durationLabel: String
    let words: Int
    let wpm: Int
    let fillers: String
    let transcript: String
    let weaknesses: String
    let fixNextTime: String
    let facial: String?
}

struct SessionDigest {
    let id: String
    let questionSet: String
    let aborted: Bool
    let stations: [StationDigest]
    let overall: String
}

// Plain speech and delivery metrics recovered from a session's transcript.md.
// Lines look like: [0:00-0:04] "spoken text" (facial cues)
private struct ParsedTranscript {
    var speech: [Int: String] = [:]
    var metrics: [Int: (words: Int, duration: String, wpm: Int, fillers: String)] = [:]
}

private func parseTranscript(_ raw: String) -> ParsedTranscript {
    var out = ParsedTranscript()
    var current: Int?
    var buffer: [String] = []

    let heading = try? NSRegularExpression(pattern: "^##\\s*Q(\\d+)")
    let timed = try? NSRegularExpression(pattern: "^\\[[0-9:.\\-]+\\]\\s*(.*)$")
    let metric = try? NSRegularExpression(
        pattern: "^\\*(\\d+) words in ([0-9:]+) · (\\d+) wpm · fillers: (.*)\\*$"
    )

    func flush() {
        if let q = current, !buffer.isEmpty {
            out.speech[q, default: ""] += buffer.joined(separator: " ")
        }
        buffer = []
    }

    for rawLine in raw.components(separatedBy: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        let range = NSRange(line.startIndex..., in: line)

        if let m = heading?.firstMatch(in: line, range: range),
           let r = Range(m.range(at: 1), in: line) {
            flush()
            current = Int(line[r])
            continue
        }
        if let m = metric?.firstMatch(in: line, range: range), let q = current {
            func group(_ i: Int) -> String {
                Range(m.range(at: i), in: line).map { String(line[$0]) } ?? ""
            }
            out.metrics[q] = (Int(group(1)) ?? 0, group(2), Int(group(3)) ?? 0, group(4))
            continue
        }
        if line.isEmpty || line.hasPrefix(">") || line.hasPrefix("#") || line.hasPrefix("*") || line.hasPrefix("_") {
            continue
        }

        var body = line
        if let m = timed?.firstMatch(in: line, range: range),
           let r = Range(m.range(at: 1), in: line) {
            body = String(line[r])
        }
        body = body.trimmingCharacters(in: .whitespaces)
        // What remains is `"spoken text"` with an optional ` (facial cues)` suffix.
        // The cues carry their own brackets, as in "(AU10)", so the quotes are the
        // reliable anchor: the closing quote is the last one on the line.
        if body.hasPrefix("\"") {
            let afterOpen = body.index(after: body.startIndex)
            if let close = body.lastIndex(of: "\""), close > afterOpen {
                body = String(body[afterOpen..<close])
            } else {
                body = String(body[afterOpen...])
            }
        }
        body = body.trimmingCharacters(in: .whitespaces)
        if !body.isEmpty { buffer.append(body) }
    }
    flush()
    return out
}

// Pulls one labelled block out of a summary's per-question body, e.g.
// "- **Weaknesses:**" and the bullets beneath it, up to the next label.
private func labelledSection(_ body: String, _ label: String) -> String {
    var collected: [String] = []
    var inside = false
    let labelPattern = try? NSRegularExpression(pattern: "^[-*]\\s*\\*\\*([^*]+?):?\\*\\*:?\\s*(.*)$")

    for rawLine in body.components(separatedBy: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        let range = NSRange(line.startIndex..., in: line)
        if let m = labelPattern?.firstMatch(in: line, range: range),
           let nameRange = Range(m.range(at: 1), in: line) {
            let name = line[nameRange].trimmingCharacters(in: .whitespaces).lowercased()
            if name == label.lowercased() {
                inside = true
                let rest = Range(m.range(at: 2), in: line).map { String(line[$0]) } ?? ""
                if !rest.isEmpty { collected.append(rest) }
            } else {
                inside = false
            }
            continue
        }
        if inside, !line.isEmpty {
            collected.append(line.hasPrefix("- ") || line.hasPrefix("* ") ? String(line.dropFirst(2)) : line)
        }
    }
    return collected.joined(separator: "; ")
}

private struct FacesSummaryFile: Codable {
    let summary_text: String?
}

func gatherSessions(saveDir: String) -> (sessions: [SessionDigest], skipped: Int) {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: saveDir)
    guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
        return ([], 0)
    }

    var digests: [SessionDigest] = []
    var skipped = 0

    for dir in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        guard let metaData = try? Data(contentsOf: dir.appendingPathComponent("session.json")),
              let meta = try? JSONDecoder().decode(SessionMeta.self, from: metaData) else { continue }
        let answered = meta.questions.filter { $0.file != nil }
        guard !answered.isEmpty else { continue }

        guard let transcriptRaw = try? String(
            contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8
        ) else {
            skipped += 1
            continue
        }
        let parsed = parseTranscript(transcriptRaw)

        var scores: [Int: Double] = [:]
        var bodies: [Int: String] = [:]
        var overall = ""
        if let summaryRaw = try? String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8) {
            scores = parseScores(summaryRaw)
            let parsedSummary = parseSummary(summaryRaw)
            overall = parsedSummary.overall
            for q in parsedSummary.questions { bodies[q.n] = q.body }
        }

        let stations: [StationDigest] = answered.map { q in
            let metric = parsed.metrics[q.index]
            let facial = (try? Data(contentsOf: dir.appendingPathComponent("q\(q.index).faces.json")))
                .flatMap { try? JSONDecoder().decode(FacesSummaryFile.self, from: $0) }?
                .summary_text
            let body = bodies[q.index] ?? ""
            return StationDigest(
                index: q.index,
                theme: q.theme,
                question: q.text,
                score: scores[q.index],
                durationLabel: metric?.duration ?? AnalysisManager.durationLabel(q.answeredMs),
                words: metric?.words ?? 0,
                wpm: metric?.wpm ?? 0,
                fillers: metric?.fillers ?? "unknown",
                transcript: parsed.speech[q.index] ?? "",
                weaknesses: labelledSection(body, "Weaknesses"),
                fixNextTime: labelledSection(body, "Fix next time"),
                facial: facial
            )
        }

        digests.append(
            SessionDigest(
                id: meta.id,
                questionSet: meta.questionSet,
                aborted: meta.aborted,
                stations: stations,
                overall: overall
            )
        )
    }
    return (digests, skipped)
}

// Full transcripts are the evidence base, but they are also the bulk of the
// prompt. Newest sessions keep theirs; older ones fall back to metrics and the
// per-station feedback once the budget runs out.
private let transcriptBudget = 240_000

func buildReviewPrompt(sessions: [SessionDigest], rubric: String) -> String {
    var remaining = transcriptBudget
    var includeTranscript = Set<String>()
    for (offset, session) in sessions.reversed().enumerated() {
        let cost = session.stations.reduce(0) { $0 + $1.transcript.count }
        if offset == 0 || cost <= remaining {
            includeTranscript.insert(session.id)
            remaining -= cost
        }
    }

    let header = """
    You are an experienced medical school interview coach. You are reviewing a candidate's entire practice history so far, not a single session.

    The candidate practises with an app that runs recorded interview stations: each question is delivered, recording starts immediately, and they have 5 minutes to think and answer with no interviewer present. Each session was already given its own feedback at the time, and the weaknesses and advice from that feedback are included below.

    Sessions appear oldest first, so you can see how the candidate has changed and whether earlier advice was acted on. Transcripts come from automatic speech recognition, so ignore obvious transcription artifacts and do not nitpick grammar. Where facial cues are given, they come from an automated model, so treat them as tendencies rather than facts and never use them to diagnose the person.

    Your job is to find what a single session's feedback cannot see: the habits that keep recurring, the advice that has not stuck, and the specific things that are costing the most marks. Be concrete and quote the candidate's own words. Avoid generic interview advice that could apply to anyone. If the evidence is thin for a claim, say so rather than inventing a pattern.

    Do not use any tools; reply with plain markdown only. Never use em dashes in your writing.

    Structure your review exactly like this:

    ## Where you stand
    Three or four sentences: the honest headline. What is genuinely working, and the single biggest thing holding the marks down.

    ## Your recurring pitfalls
    The four to six habits costing the most marks, worst first. For each one:

    ### <short, memorable name for the pitfall>
    - **What it looks like:** the behaviour in one or two sentences
    - **Evidence:** at least two moments from different sessions, each quoting the candidate's actual words, naming the session date and station
    - **What it costs:** which part of the rubric this loses marks against
    - **The fix:** a change that can be practised, including the exact words to say instead

    ## Has earlier advice stuck?
    Take the significant "fix next time" points from earlier sessions and say for each whether later sessions show it applied, partly applied, or ignored, with evidence. Be blunt where something has been repeated and not acted on.

    ## Station types
    Which themes are strongest and weakest, and why, in terms of what the candidate does differently in each. Do not simply restate the scores.

    ## Delivery
    Pace, filler words, use of the 5 minutes, openings, endings, and recovery from stumbles, tracked across sessions. Say whether each is improving, flat, or getting worse, and give the numbers that show it.

    ## Your next three sessions
    A specific plan. For each session say what to practise, which station types to draw, and the one thing to consciously do differently. Make it something that can be followed without further interpretation.

    ## Phrases to steal
    Eight to twelve ready-made lines the candidate can actually say: openings, signposting, stakeholder framing, buying thinking time, recovering a lost thread, and closing. Base them on the candidate's own strengths and voice, not generic filler.

    ## The rubric being marked against

    \(rubric)

    ## Practice history

    """

    var body = ""
    for session in sessions {
        let scored = session.stations.compactMap(\.score)
        let average = scored.isEmpty ? nil : scored.reduce(0, +) / Double(scored.count)
        body += "\n\n---\n\n### Session \(session.id) · set: \(session.questionSet)"
        if let average {
            body += String(format: " · average %.1f/10", average)
        }
        if session.aborted { body += " · ended early" }
        body += "\n"

        for station in session.stations {
            body += "\n#### Station \(station.index)"
            if let theme = station.theme { body += " (\(theme))" }
            if let score = station.score { body += String(format: " · scored %.0f/10", score) }
            body += " · \(station.durationLabel) used of 5:00, \(station.words) words, \(station.wpm) wpm, fillers: \(station.fillers)\n\n"
            body += "Question asked:\n> \(station.question.replacingOccurrences(of: "\n", with: "\n> "))\n"
            if let facial = station.facial {
                body += "\nFacial cues across the answer: \(facial)\n"
            }
            if !station.weaknesses.isEmpty {
                body += "\nWeaknesses noted at the time: \(station.weaknesses)\n"
            }
            if !station.fixNextTime.isEmpty {
                body += "\nAdvice given at the time: \(station.fixNextTime)\n"
            }
            if includeTranscript.contains(session.id), !station.transcript.isEmpty {
                body += "\nWhat they actually said:\n\"\"\"\n\(station.transcript)\n\"\"\"\n"
            }
        }

        if !session.overall.isEmpty {
            body += "\nOverall feedback given at the time:\n\(session.overall)\n"
        }
    }

    return header + body + "\n"
}

extension AnalysisManager {
    var reviewFile: URL? {
        store.settings.saveDir.map { URL(fileURLWithPath: $0).appendingPathComponent("coaching-review.md") }
    }

    func runReview() {
        guard !reviewRunning else { return }
        guard let saveDir = store.settings.saveDir, let outFile = reviewFile else {
            reviewProgress = "Error: choose a recordings folder first."
            return
        }
        reviewRunning = true
        reviewProgress = "Reading your past sessions…"
        let settings = store.settings

        Task {
            let (sessions, skipped) = await Task.detached { gatherSessions(saveDir: saveDir) }.value
            guard sessions.count >= 2 else {
                await MainActor.run {
                    self.reviewProgress =
                        "Error: a review needs at least two analyzed sessions. Analyze more sessions first."
                    self.reviewRunning = false
                }
                return
            }

            let stationCount = sessions.reduce(0) { $0 + $1.stations.count }
            let provider = FeedbackProvider.from(settings)
            await MainActor.run {
                let note = skipped > 0 ? " (\(skipped) not yet analyzed, skipped)" : ""
                self.reviewProgress =
                    "Reviewing \(stationCount) answers across \(sessions.count) sessions with \(provider.label)\(note). This takes a few minutes."
            }

            let prompt = buildReviewPrompt(sessions: sessions, rubric: AnalysisManager.loadRubric())
            let result = await AnalysisManager.feedback(
                provider: provider, prompt: prompt, settings: settings, timeout: 1800
            )

            await MainActor.run {
                switch result {
                case .success(let text):
                    let stamped = """
                    <!-- Generated \(isoNow()) from \(sessions.count) sessions, \(stationCount) answers -->

                    \(text)
                    """
                    do {
                        try (stamped + "\n").write(to: outFile, atomically: true, encoding: .utf8)
                        self.reviewProgress = ""
                        self.reviewTick += 1
                    } catch {
                        self.reviewProgress = "Error: could not save the review: \(error.localizedDescription)"
                    }
                case .failure(let message):
                    self.reviewProgress = "Error: \(message)"
                }
                self.reviewRunning = false
            }
        }
    }
}
