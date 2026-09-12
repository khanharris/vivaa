import SwiftUI

struct SessionTabView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.colorScheme) private var scheme
    let onStart: (SessionConfig) -> Void

    @StateObject private var camera = CameraManager()
    @State private var selectedSet = ""
    @State private var selectedStation = allStations
    @State private var errorMessage: String?

    // Sentinel for the station picker: run the whole set rather than one station.
    private static let allStations = -1

    private var currentSet: QuestionSet? {
        store.questionSets.first { $0.name == selectedSet } ?? store.questionSets.first
    }

    // What Start actually runs: the whole set, or a one-station set built from it.
    // An out-of-range station falls back to the whole set rather than trapping.
    private var effectiveSet: QuestionSet? {
        guard let set = currentSet else { return nil }
        guard selectedStation >= 0, selectedStation < set.questions.count else { return set }
        return QuestionSet(
            name: "\(set.name) · station \(selectedStation + 1)",
            questions: [set.questions[selectedStation]]
        )
    }

    private var estimateLine: String {
        guard let set = effectiveSet else {
            return "No question sets yet. Import one from Settings (JSON)."
        }
        let count = set.questions.count
        let t = store.timings
        let totalSec = count * (t.readingSec + t.answerSec) + max(0, count - 1) * t.breakSec
        let minutes = max(1, Int((Double(totalSec) / 60).rounded()))
        let quick = store.settings.quickTest == true ? " · quick test mode" : ""
        let label = count == 1 ? "1 station" : "\(count) stations"
        return "\(label) · about \(minutes) min\(quick)"
    }

    var body: some View {
        let palette = Palette.forScheme(scheme)
        VStack(spacing: 14) {
            preview
            warnings(palette)
            startButton(palette)
            setPicker
            stationPicker
            Text(estimateLine)
                .font(.system(size: 12))
                .foregroundStyle(palette.textDim)
        }
        .padding(22)
        .frame(maxWidth: 980)
        .onAppear {
            camera.start(micUID: store.settings.micID)
            syncSelection()
        }
        .onDisappear { camera.stop() }
        .onChange(of: store.questionSets) { _, _ in syncSelection() }
        // Station numbers only mean something within one set.
        .onChange(of: selectedSet) { _, _ in selectedStation = Self.allStations }
    }

    // Keep the picker pointing at a real set when sets are added or removed.
    private func syncSelection() {
        if !store.questionSets.contains(where: { $0.name == selectedSet }) {
            selectedSet = store.questionSets.first?.name ?? ""
            selectedStation = Self.allStations
        }
    }

    // Enough of the prompt to recognise the station, not so much that picking it
    // gives the whole question away before recording starts.
    private func stationLabel(_ question: Question, _ index: Int) -> String {
        let firstLine = question.text.components(separatedBy: "\n").first ?? question.text
        let opening = firstLine.count > 58
            ? String(firstLine.prefix(58)).trimmingCharacters(in: .whitespaces) + "…"
            : firstLine
        let theme = question.theme.map { "\($0) · " } ?? ""
        return "\(index + 1). \(theme)\(opening)"
    }

    @ViewBuilder
    private var stationPicker: some View {
        if let set = currentSet, set.questions.count > 1 {
            Picker("", selection: $selectedStation) {
                Text("All \(set.questions.count) stations").tag(Self.allStations)
                ForEach(Array(set.questions.enumerated()), id: \.offset) { index, question in
                    Text(stationLabel(question, index)).tag(index)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 560)
        }
    }

    private var preview: some View {
        CameraPreview(layer: camera.previewLayer)
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private func warnings(_ palette: Palette) -> some View {
        if let message = camera.errorMessage ?? errorMessage {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(palette.amber)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(palette.amber.opacity(0.12)))
        }
    }

    private func startButton(_ palette: Palette) -> some View {
        Button(action: start) {
            Text("Start session")
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.accent))
        .foregroundStyle(.white)
        .disabled(currentSet == nil)
        .opacity(currentSet == nil ? 0.5 : 1)
    }

    @ViewBuilder
    private var setPicker: some View {
        if store.questionSets.isEmpty {
            Text("No question sets")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        } else {
            Picker("", selection: $selectedSet) {
                ForEach(store.questionSets) { s in
                    Text(s.name).tag(s.name)
                }
            }
            .labelsHidden()
        }
    }

    private func start() {
        errorMessage = nil
        guard let set = effectiveSet else {
            errorMessage = "No question sets found. Import one from Settings first."
            return
        }
        if store.settings.saveDir == nil {
            store.chooseSaveDir()
        }
        guard let saveDir = store.settings.saveDir else {
            errorMessage = "Choose a folder to save recordings first."
            return
        }
        let id = sessionIdNow()
        let dir = URL(fileURLWithPath: saveDir).appendingPathComponent(id)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Could not create the session folder: \(error.localizedDescription)"
            return
        }
        camera.stop()
        onStart(SessionConfig(set: set, timings: store.timings, sessionDir: dir, sessionId: id, micID: store.settings.micID, readAloud: store.settings.readAloud != false))
    }
}
