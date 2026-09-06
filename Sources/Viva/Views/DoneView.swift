import AppKit
import SwiftUI

struct DoneView: View {
    let info: DoneInfo
    let onHome: () -> Void
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var analysis: AnalysisManager
    @Environment(\.colorScheme) private var scheme
    @State private var summary: String?
    @State private var transcript: String?
    @State private var started = false

    var body: some View {
        let palette = Palette.forScheme(scheme)
        let progress = analysis.progress[info.sessionDir.path] ?? ""

        ScrollView {
            VStack(spacing: 12) {
                Text(info.aborted ? "Session ended early" : "Session complete")
                    .font(.system(.largeTitle, design: .serif))
                    .padding(.top, 46)
                Text("\(info.completed) of \(info.total) answers recorded")
                    .foregroundStyle(palette.textDim)
                Text(info.sessionDir.path)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textDim)
                    .lineLimit(1)
                    .truncationMode(.head)
                HStack(spacing: 12) {
                    Button("Open session folder") {
                        NSWorkspace.shared.open(info.sessionDir)
                    }
                    .buttonStyle(.bordered)
                    Button("Back to home", action: onHome)
                        .buttonStyle(.borderedProminent)
                        .tint(palette.accent)
                }
                .padding(.top, 4)

                if !progress.isEmpty {
                    HStack(spacing: 8) {
                        if !progress.hasPrefix("Error") { ProgressView().controlSize(.small) }
                        Text(progress)
                            .font(.system(size: 12))
                            .foregroundStyle(progress.hasPrefix("Error") ? palette.amber : palette.textDim)
                    }
                    .padding(.top, 14)
                }

                if let summary {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Interview feedback")
                            .font(.system(.title3, design: .serif))
                        SummaryTabs(summary: summary, transcript: transcript, palette: palette)
                    }
                    .card(palette)
                    .padding(.top, 18)
                }
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 40)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(palette.background)
        .onAppear { startAnalysisIfNeeded() }
        .onChange(of: analysis.completedTick) { _, _ in loadSummary() }
    }

    private func startAnalysisIfNeeded() {
        guard !started else { return }
        started = true
        loadSummary()
        guard summary == nil, info.completed > 0,
              store.settings.analysis?.enabled != false else { return }
        analysis.analyze(info.sessionDir)
    }

    private func loadSummary() {
        let url = info.sessionDir.appendingPathComponent("summary.md")
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            summary = text
        }
        transcript = try? String(
            contentsOf: info.sessionDir.appendingPathComponent("transcript.md"),
            encoding: .utf8
        )
    }
}
