import Foundation

struct DayActivity {
    let date: String
    var sessions: Int
    var answers: Int
}

struct ThemeStat: Identifiable {
    let theme: String
    let avgScore: Double
    let scored: Int
    var id: String { theme }
}

struct SessionScore: Identifiable {
    let id: String
    let dir: URL
    let date: String
    let answers: Int
    let aborted: Bool
    let avgScore: Double?
    let hasSummary: Bool
}

struct PracticeStats {
    var days: [String: DayActivity] = [:]
    var totalSessions = 0
    var totalAnswers = 0
    var totalPracticeMs = 0
    var currentStreak = 0
    var longestStreak = 0
    var themes: [ThemeStat] = []
    var sessions: [SessionScore] = []
}

private func dateKey(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: d)
}

// Scores come from summary.md: preferably the machine-readable json block, with
// a regex fallback for older summaries.
func parseScores(_ summary: String) -> [Int: Double] {
    var map: [Int: Double] = [:]
    if let blockRange = summary.range(of: "```json"),
       let endRange = summary.range(of: "```", range: blockRange.upperBound..<summary.endIndex) {
        let jsonText = String(summary[blockRange.upperBound..<endRange.lowerBound])
        if let data = jsonText.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let scores = obj["scores"] as? [[String: Any]] {
            for s in scores {
                if let q = s["q"] as? Int, let score = s["score"] as? Double {
                    map[q] = score
                } else if let q = s["q"] as? Int, let score = s["score"] as? Int {
                    map[q] = Double(score)
                }
            }
            if !map.isEmpty { return map }
        }
    }
    var currentQ: Int?
    let qRegex = try? NSRegularExpression(pattern: "^###\\s*Q(\\d+)")
    let sRegex = try? NSRegularExpression(pattern: "\\*\\*Score:?\\*\\*:?\\s*([\\d.]+)\\s*/\\s*10")
    for line in summary.components(separatedBy: "\n") {
        let range = NSRange(line.startIndex..., in: line)
        if let m = qRegex?.firstMatch(in: line, range: range),
           let r = Range(m.range(at: 1), in: line) {
            currentQ = Int(line[r])
        }
        if let m = sRegex?.firstMatch(in: line, range: range),
           let r = Range(m.range(at: 1), in: line),
           let q = currentQ, map[q] == nil, let v = Double(line[r]) {
            map[q] = v
        }
    }
    return map
}

func computeStats(saveDir: String) -> PracticeStats {
    var stats = PracticeStats()
    var themeScores: [String: [Double]] = [:]
    let fm = FileManager.default
    let root = URL(fileURLWithPath: saveDir)
    guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
        return stats
    }

    for dir in entries {
        let metaURL = dir.appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(SessionMeta.self, from: data) else { continue }
        let answered = meta.questions.filter { $0.file != nil }
        guard !answered.isEmpty else { continue }

        let key = dateKey(parseISO(meta.startedAt) ?? Date())
        stats.days[key, default: DayActivity(date: key, sessions: 0, answers: 0)].sessions += 1
        stats.days[key]?.answers += answered.count
        stats.totalSessions += 1
        stats.totalAnswers += answered.count
        stats.totalPracticeMs += answered.reduce(0) { $0 + $1.answeredMs }

        let summaryURL = dir.appendingPathComponent("summary.md")
        var avg: Double?
        let hasSummary = fm.fileExists(atPath: summaryURL.path)
        if hasSummary, let summary = try? String(contentsOf: summaryURL, encoding: .utf8) {
            let scores = parseScores(summary)
            if !scores.isEmpty {
                avg = scores.values.reduce(0, +) / Double(scores.count)
                for (q, score) in scores {
                    let theme = meta.questions.first { $0.index == q }?.theme ?? "other"
                    themeScores[theme, default: []].append(score)
                }
            }
        }
        stats.sessions.append(
            SessionScore(
                id: meta.id,
                dir: dir,
                date: key,
                answers: answered.count,
                aborted: meta.aborted,
                avgScore: avg,
                hasSummary: hasSummary
            )
        )
    }

    // Streaks
    let sortedDates = stats.days.keys.sorted()
    var longest = 0
    var run = 0
    var prev: String?
    let dayFormatter = DateFormatter()
    dayFormatter.dateFormat = "yyyy-MM-dd"
    dayFormatter.locale = Locale(identifier: "en_US_POSIX")
    func daysBetween(_ a: String, _ b: String) -> Int {
        guard let da = dayFormatter.date(from: a), let db = dayFormatter.date(from: b) else { return 99 }
        return Int((db.timeIntervalSince(da) / 86_400).rounded())
    }
    for date in sortedDates {
        run = (prev != nil && daysBetween(prev!, date) == 1) ? run + 1 : 1
        longest = max(longest, run)
        prev = date
    }
    stats.longestStreak = longest

    var cursor = Date()
    if stats.days[dateKey(cursor)] == nil {
        cursor = Calendar.current.date(byAdding: .day, value: -1, to: cursor) ?? cursor
    }
    while stats.days[dateKey(cursor)] != nil {
        stats.currentStreak += 1
        cursor = Calendar.current.date(byAdding: .day, value: -1, to: cursor) ?? cursor
    }

    stats.themes = themeScores
        .map { ThemeStat(theme: $0.key, avgScore: $0.value.reduce(0, +) / Double($0.value.count), scored: $0.value.count) }
        .sorted { $0.avgScore > $1.avgScore }
    stats.sessions.sort { $0.id > $1.id }
    return stats
}
