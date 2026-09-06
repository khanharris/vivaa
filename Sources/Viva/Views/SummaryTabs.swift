import SwiftUI

// Splits summary.md into Overall plus per-question tabs.
struct ParsedSummary {
    var overall: String
    var questions: [(n: Int, title: String, body: String)]
}

func parseSummary(_ raw: String) -> ParsedSummary {
    var text = raw
    if let blockRange = text.range(of: "```json") {
        text = String(text[..<blockRange.lowerBound])
    }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)

    var questions: [(Int, String, String)] = []
    var overall: [String] = []
    var preamble: [String] = []
    var currentIndex: Int? = nil
    var inOverall = false
    let qRegex = try? NSRegularExpression(pattern: "^###\\s*Q(\\d+)\\b[\\s:·—-]*(.*)$")

    for line in text.components(separatedBy: "\n") {
        let range = NSRange(line.startIndex..., in: line)
        if let m = qRegex?.firstMatch(in: line, range: range),
           let numRange = Range(m.range(at: 1), in: line),
           let n = Int(line[numRange]) {
            let title = Range(m.range(at: 2), in: line).map { String(line[$0]) } ?? ""
            questions.append((n, title.trimmingCharacters(in: .whitespaces), ""))
            currentIndex = questions.count - 1
            inOverall = false
            continue
        }
        if line.range(of: "^##\\s*Overall", options: .regularExpression) != nil {
            inOverall = true
            currentIndex = nil
            continue
        }
        if inOverall {
            overall.append(line)
        } else if let i = currentIndex {
            questions[i].2 += line + "\n"
        } else {
            preamble.append(line)
        }
    }

    let overallText = [
        preamble.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
        overall.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    ].filter { !$0.isEmpty }.joined(separator: "\n\n")

    return ParsedSummary(
        overall: overallText.isEmpty ? text : overallText,
        questions: questions.map { (n: $0.0, title: $0.1, body: $0.2) }
    )
}

struct SummaryTabs: View {
    let summary: String
    var transcript: String? = nil
    let palette: Palette
    @State private var tab = "overall"

    var body: some View {
        let parsed = parseSummary(summary)
        VStack(alignment: .leading, spacing: 12) {
            if !parsed.questions.isEmpty || transcript != nil {
                Picker("", selection: $tab) {
                    Text("Overall").tag("overall")
                    ForEach(parsed.questions, id: \.n) { q in
                        Text("Q\(q.n)").tag("q\(q.n)")
                    }
                    if transcript != nil {
                        Text("Transcript").tag("transcript")
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ScrollView {
                if tab == "transcript", let transcript {
                    MarkdownText(text: transcript, palette: palette)
                } else if tab == "overall" || parsed.questions.isEmpty {
                    MarkdownText(text: parsed.overall, palette: palette)
                } else if let q = parsed.questions.first(where: { "q\($0.n)" == tab }) {
                    MarkdownText(
                        text: (q.title.isEmpty ? "" : "**\(q.title)**\n\n") + q.body,
                        palette: palette
                    )
                }
            }
            .frame(maxHeight: 420)
        }
    }
}
