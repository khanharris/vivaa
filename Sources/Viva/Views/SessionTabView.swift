import SwiftUI

struct SessionTabView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.colorScheme) private var scheme
    let onStart: (SessionConfig) -> Void

    @StateObject private var camera = CameraManager()
    @State private var selectedSet = ""
    @State private var errorMessage: String?

    private var currentSet: QuestionSet? {
        store.questionSets.first { $0.name == selectedSet } ?? store.questionSets.first
    }

    private var estimateLine: String {
        guard let set = currentSet else {
            return "No question sets yet. Import one from Settings (JSON)."
        }
        let t = store.timings
        let totalSec = set.questions.count * (t.readingSec + t.answerSec)
            + max(0, set.questions.count - 1) * t.breakSec
        let minutes = max(1, Int((Double(totalSec) / 60).rounded()))
        let quick = store.settings.quickTest == true ? " · quick test mode" : ""
        return "\(set.questions.count) stations · about \(minutes) min\(quick)"
    }

    var body: some View {
        let palette = Palette.forScheme(scheme)
        VStack(spacing: 14) {
            preview
            warnings(palette)
            startButton(palette)
            setPicker
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
    }

    // Keep the picker pointing at a real set when sets are added or removed.
    private func syncSelection() {
        if !store.questionSets.contains(where: { $0.name == selectedSet }) {
            selectedSet = store.questionSets.first?.name ?? ""
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
        guard let set = currentSet else {
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
