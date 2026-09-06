import AppKit
import SwiftUI

struct StatsView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var analysis: AnalysisManager
    @Environment(\.colorScheme) private var scheme
    @State private var stats: PracticeStats?
    @State private var monthCursor: (year: Int, month: Int) = {
        let c = Calendar.current.dateComponents([.year, .month], from: Date())
        return (c.year ?? 2026, (c.month ?? 1) - 1)
    }()
    @State private var summarySheet: (id: String, text: String, transcript: String?)?

    var body: some View {
        let palette = Palette.forScheme(scheme)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Statistics")
                    .font(.system(.title, design: .serif))

                if let stats, stats.totalSessions > 0 {
                    tiles(stats, palette)
                    calendarCard(stats, palette)
                    if !stats.themes.isEmpty { themesCard(stats, palette) }
                    sessionsCard(stats, palette)
                } else {
                    Text("No sessions yet. Statistics appear after your first practice run.")
                        .foregroundStyle(palette.textDim)
                }
            }
            .padding(26)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(palette.background)
        .onAppear { reload() }
        .onChange(of: analysis.completedTick) { _, _ in reload() }
        .sheet(isPresented: Binding(get: { summarySheet != nil }, set: { if !$0 { summarySheet = nil } })) {
            if let sheet = summarySheet {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Interview feedback").font(.system(.title3, design: .serif))
                    Text(sheet.id).font(.system(size: 11)).foregroundStyle(palette.textDim)
                    SummaryTabs(summary: sheet.text, transcript: sheet.transcript, palette: palette)
                    HStack {
                        Spacer()
                        Button("Close") { summarySheet = nil }.buttonStyle(.bordered)
                    }
                }
                .padding(22)
                .frame(width: 720, height: 560)
                .background(palette.background)
            }
        }
    }

    private func reload() {
        guard let saveDir = store.settings.saveDir else {
            stats = PracticeStats()
            return
        }
        Task.detached {
            let computed = computeStats(saveDir: saveDir)
            await MainActor.run { self.stats = computed }
        }
    }

    private func tiles(_ stats: PracticeStats, _ palette: Palette) -> some View {
        let items: [(String, String)] = [
            ("\(stats.currentStreak) day\(stats.currentStreak == 1 ? "" : "s")", "Current streak"),
            ("\(stats.longestStreak) day\(stats.longestStreak == 1 ? "" : "s")", "Longest streak"),
            ("\(stats.totalSessions)", "Sessions"),
            ("\(stats.totalAnswers)", "Answers recorded"),
            (practiceLabel(stats.totalPracticeMs), "Time answering")
        ]
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 10)], spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.0).font(.system(size: 20, weight: .bold).monospacedDigit())
                    Text(item.1.uppercased())
                        .font(.system(size: 9, weight: .medium))
                        .tracking(0.6)
                        .foregroundStyle(palette.textDim)
                }
                .card(palette)
            }
        }
    }

    private func practiceLabel(_ ms: Int) -> String {
        let minutes = Int((Double(ms) / 60000).rounded())
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    // MARK: - Calendar heatmap

    private func calendarCard(_ stats: PracticeStats, _ palette: Palette) -> some View {
        let weeks = buildMonthGrid(year: monthCursor.year, month: monthCursor.month, days: stats.days)
        let now = Calendar.current.dateComponents([.year, .month], from: Date())
        let atCurrent = monthCursor.year == (now.year ?? 0) && monthCursor.month == (now.month ?? 1) - 1
        let monthNames = DateFormatter().monthSymbols ?? []

        return VStack(alignment: .leading, spacing: 12) {
            Text("Practice activity").font(.system(.title3, design: .serif))
            VStack(spacing: 5) {
                HStack(spacing: 5) {
                    ForEach(Array(["M", "T", "W", "T", "F", "S", "S"].enumerated()), id: \.offset) { _, d in
                        Text(d)
                            .font(.system(size: 9))
                            .foregroundStyle(palette.textDim)
                            .frame(width: 36)
                    }
                }
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    HStack(spacing: 5) {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, cell in
                            if let cell {
                                Text("\(cell.day)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(cellText(cell, palette))
                                    .frame(width: 36, height: 36)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(cell.future ? Color.clear : heatColor(level: cell.level, dark: scheme == .dark))
                                    )
                                    .help(cell.label)
                            } else {
                                Color.clear.frame(width: 36, height: 36)
                            }
                        }
                    }
                }
                HStack(spacing: 10) {
                    Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Text("\(monthNames.indices.contains(monthCursor.month) ? monthNames[monthCursor.month] : "") \(String(monthCursor.year))")
                        .font(.system(size: 13))
                        .frame(minWidth: 130)
                    Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(atCurrent)
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
        }
        .card(palette)
    }

    private struct MonthCell {
        let day: Int
        let label: String
        let level: Int
        let future: Bool
    }

    private func cellText(_ cell: MonthCell, _ palette: Palette) -> Color {
        if cell.future { return palette.textDim.opacity(0.5) }
        if cell.level == 0 { return palette.textDim }
        if scheme == .dark { return Color.white.opacity(0.85) }
        return cell.level >= 4 ? Color.white.opacity(0.9) : Color.black.opacity(0.6)
    }

    private func buildMonthGrid(year: Int, month: Int, days: [String: DayActivity]) -> [[MonthCell?]] {
        var cal = Calendar.current
        cal.firstWeekday = 2
        let first = DateComponents(calendar: cal, year: year, month: month + 1, day: 1).date ?? Date()
        let weekday = cal.component(.weekday, from: first)
        let startOffset = (weekday + 5) % 7
        let daysInMonth = cal.range(of: .day, in: .month, for: first)?.count ?? 30
        let today = Date()

        var cells: [MonthCell?] = Array(repeating: nil, count: startOffset)
        for day in 1...daysInMonth {
            let key = String(format: "%04d-%02d-%02d", year, month + 1, day)
            let answers = days[key]?.answers ?? 0
            let date = DateComponents(calendar: cal, year: year, month: month + 1, day: day).date ?? Date()
            let level = answers == 0 ? 0 : answers <= 3 ? 1 : answers <= 7 ? 2 : answers <= 14 ? 3 : 4
            cells.append(
                MonthCell(
                    day: day,
                    label: "\(answers) answer\(answers == 1 ? "" : "s")",
                    level: level,
                    future: date > today
                )
            )
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) }
    }

    private func shiftMonth(_ delta: Int) {
        var m = monthCursor.month + delta
        var y = monthCursor.year
        if m < 0 { m = 11; y -= 1 }
        if m > 11 { m = 0; y += 1 }
        monthCursor = (y, m)
    }

    // MARK: - Themes and sessions

    private func themesCard(_ stats: PracticeStats, _ palette: Palette) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Average score by theme").font(.system(.title3, design: .serif))
            ForEach(stats.themes) { t in
                HStack(spacing: 10) {
                    Text(t.theme)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textDim)
                        .frame(width: 150, alignment: .trailing)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(palette.border.opacity(0.5))
                            Capsule()
                                .fill(palette.accent)
                                .frame(width: geo.size.width * t.avgScore / 10)
                        }
                    }
                    .frame(height: 9)
                    Text(String(format: "%.1f/10", t.avgScore))
                        .font(.system(size: 12).monospacedDigit())
                        .frame(width: 48, alignment: .leading)
                }
                .help("\(t.scored) scored answers")
            }
            Text("Scores come from the feedback analysis. Sessions without a summary are not counted.")
                .font(.system(size: 11))
                .foregroundStyle(palette.textDim)
        }
        .card(palette)
    }

    private func sessionsCard(_ stats: PracticeStats, _ palette: Palette) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Past sessions").font(.system(.title3, design: .serif))
            ForEach(stats.sessions.prefix(12)) { s in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(s.id).font(.system(size: 12))
                        Text("· \(s.answers) answers\(s.aborted ? " · ended early" : "")")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.textDim)
                        if let avg = s.avgScore {
                            Text(String(format: "· avg %.1f/10", avg))
                                .font(.system(size: 11))
                                .foregroundStyle(palette.textDim)
                        }
                        Spacer()
                        Button(s.hasSummary ? "Re-analyze" : "Analyze") { analysis.analyze(s.dir) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(analysis.isRunning(s.dir))
                        if s.hasSummary {
                            Button("View summary") {
                                if let text = try? String(
                                    contentsOf: s.dir.appendingPathComponent("summary.md"),
                                    encoding: .utf8
                                ) {
                                    let transcript = try? String(
                                        contentsOf: s.dir.appendingPathComponent("transcript.md"),
                                        encoding: .utf8
                                    )
                                    summarySheet = (s.id, text, transcript)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        Button("Open") { NSWorkspace.shared.open(s.dir) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    if let message = analysis.progress[s.dir.path], !message.isEmpty {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(message.hasPrefix("Error") ? palette.amber : palette.textDim)
                    }
                }
            }
        }
        .card(palette)
    }
}
