import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var analysis: AnalysisManager
    @EnvironmentObject var setup: SetupManager
    @Environment(\.colorScheme) private var scheme
    @StateObject private var testCamera = CameraManager()
    @State private var mics: [AudioInput] = []
    @StateObject private var reader = QuestionReader()
    @StateObject private var liveFace = LiveFaceAnalyzer()
    @State private var testing = false
    @State private var importMessage: String?
    @State private var claudeStatus: String?
    @State private var checkingClaude = false

    var body: some View {
        let palette = Palette.forScheme(scheme)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Settings").font(.system(.title, design: .serif))

                VStack(alignment: .leading, spacing: 12) {
                    Text("Setup").font(.system(.title3, design: .serif))
                    Text("Recording works out of the box, transcription is built in. These one-time downloads unlock the rest of the AI feedback.")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textDim)
                    setupRow(
                        palette, name: "Speech model", detail: "2.9 GB, one time",
                        state: setup.model, install: { setup.installModel() }
                    )
                    setupRow(
                        palette, name: "Facial analysis engine", detail: "about 2 GB, one time, optional",
                        state: setup.facial, install: { setup.installFacial() }
                    )
                    setupRow(
                        palette, name: "Claude CLI", detail: "for Claude feedback, needs a Claude subscription",
                        state: setup.claude, install: { setup.installClaude() },
                        login: { setup.openLogin(provider: "claude") }
                    )
                    setupRow(
                        palette, name: "ChatGPT Codex CLI", detail: "for ChatGPT feedback, needs a ChatGPT subscription",
                        state: setup.codex, install: { setup.installCodex() },
                        login: { setup.openLogin(provider: "codex") }
                    )
                }
                .card(palette)
                .onAppear { setup.refresh(settings: store.settings) }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Appearance").font(.system(.title3, design: .serif))
                    Picker("", selection: themeBinding) {
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                        Text("Auto").tag("system")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("Auto follows your macOS appearance setting.")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textDim)
                }
                .card(palette)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Recordings folder").font(.system(.title3, design: .serif))
                    HStack {
                        Text(store.settings.saveDir ?? "No folder chosen yet")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.textDim)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer()
                        Button("Choose…") { store.chooseSaveDir() }.buttonStyle(.bordered)
                    }
                    Text("Every session, its recordings, transcript, and feedback live in a subfolder here.")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textDim)
                }
                .card(palette)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Quick test mode").font(.system(.title3, design: .serif))
                    Toggle(isOn: quickTestBinding) {
                        Text("Short timers (0:15 answer, 0:05 break) for trying the app out.")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.textDim)
                    }
                    .toggleStyle(.switch)
                    .tint(palette.accent)
                }
                .card(palette)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Question delivery").font(.system(.title3, design: .serif))
                    Toggle(isOn: readAloudBinding) {
                        Text("Read each question aloud, then start recording when it finishes")
                            .font(.system(size: 13))
                    }
                    .toggleStyle(.switch)
                    .tint(palette.accent)
                    HStack(spacing: 10) {
                        Button(reader.speaking ? "Stop" : "Preview voice") {
                            if reader.speaking {
                                reader.stop()
                            } else {
                                reader.speak("Here is how each question will sound. Recording starts as soon as I finish speaking.") {}
                            }
                        }
                        .buttonStyle(.bordered)
                        Text("Voice: \(QuestionReader.voiceLabel)")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.textDim)
                    }
                    Text("Stands in for the interviewer video in the real MMI: the question is spoken with its text on screen, and recording begins the moment it ends. More natural voices can be downloaded under System Settings › Accessibility › Spoken Content.")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textDim)
                }
                .card(palette)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Question sets").font(.system(.title3, design: .serif))
                    HStack {
                        Button("Import question set (JSON)…") {
                            importMessage = store.importQuestionSet()
                        }
                        .buttonStyle(.bordered)
                        if let importMessage {
                            Text(importMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(palette.textDim)
                        }
                    }
                }
                .card(palette)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Camera and microphone").font(.system(.title3, design: .serif))
                    HStack(spacing: 10) {
                        Text("Microphone").font(.system(size: 13))
                        Picker("", selection: micBinding) {
                            Text("Automatic (Mac's built-in mic)").tag("")
                            ForEach(mics) { m in
                                Text(m.kind.isEmpty ? m.name : "\(m.name) · \(m.kind)").tag(m.uid)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 360)
                        Button("Refresh") { mics = AudioInputs.available() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    Text("Bluetooth headphones drop to a low-quality headset profile whenever their mic is in use, which also degrades what you hear. Automatic records from the Mac's built-in microphone when it is available, so headphones stay playback-only.")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textDim)
                    Button(testing ? "Stop test" : "Test camera and microphone") {
                        if testing {
                            testCamera.stop()
                            testing = false
                        } else {
                            testCamera.start(micUID: store.settings.micID)
                            testing = true
                        }
                    }
                    .buttonStyle(.bordered)
                    if testing {
                        CameraPreview(layer: testCamera.previewLayer)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .frame(width: 320)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        ZStack(alignment: .leading) {
                            Capsule().fill(palette.border.opacity(0.5))
                            Capsule()
                                .fill(palette.green)
                                .frame(width: 320 * testCamera.micLevel)
                        }
                        .frame(width: 320, height: 8)
                        Text("Speak normally. The bar should move with your voice.")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.textDim)
                    }
                }
                .card(palette)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Facial recognition test").font(.system(.title3, design: .serif))
                    Button(liveFace.running ? "Stop live test" : "Start live test") {
                        if liveFace.running {
                            liveFace.stop()
                        } else {
                            liveFace.start(pythonPath: store.settings.analysis?.pythonPath)
                        }
                    }
                    .buttonStyle(.bordered)
                    if liveFace.running {
                        ZStack {
                            CameraPreview(layer: liveFace.previewLayer)
                            FaceOverlay(reading: liveFace.reading)
                        }
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(width: 520)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .topTrailing) { emotionChip }
                        if !liveFace.status.isEmpty {
                            Text(liveFace.status)
                                .font(.system(size: 11))
                                .foregroundStyle(palette.textDim)
                        }
                        Text("The same Py-Feat model used for session analysis, running a few frames per second. Just a playground for now.")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.textDim)
                    }
                }
                .card(palette)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Feedback").font(.system(.title3, design: .serif))
                    Picker("", selection: providerBinding) {
                        Text("Claude").tag("claude")
                        Text("ChatGPT (Codex)").tag("codex")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                    Text(
                        providerBinding.wrappedValue == "codex"
                            ? "Uses the Codex CLI with your ChatGPT login (run `codex login` once). Answers are transcribed locally, only text leaves your Mac."
                            : "Claude Opus 5 at max effort, via your Claude Code login. Answers are transcribed locally, only text leaves your Mac."
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textDim)
                    Toggle(isOn: analysisEnabledBinding) {
                        Text("Auto-analyze sessions after they finish").font(.system(size: 13))
                    }
                    .toggleStyle(.switch)
                    .tint(palette.accent)
                    Toggle(isOn: facialBinding) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Facial expression analysis").font(.system(size: 13))
                            Text("A local model (Py-Feat) reads emotion and facial muscle activity from the recordings and feeds it into the feedback. Slower but fully offline.")
                                .font(.system(size: 11))
                                .foregroundStyle(palette.textDim)
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(palette.accent)
                    HStack {
                        Button("Test connection") {
                            checkingClaude = true
                            claudeStatus = "Testing connection…"
                            Task {
                                claudeStatus = await analysis.checkProvider()
                                checkingClaude = false
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(checkingClaude)
                        if let claudeStatus {
                            Text(claudeStatus)
                                .font(.system(size: 11))
                                .foregroundStyle(claudeStatus.hasPrefix("✓") ? palette.green : palette.textDim)
                        }
                    }
                }
                .card(palette)
            }
            .padding(26)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(palette.background)
        .onAppear { mics = AudioInputs.available() }
        .onDisappear {
            reader.stop()
            if testing {
                testCamera.stop()
                testing = false
            }
            if liveFace.running { liveFace.stop() }
        }
    }

    @ViewBuilder
    private func setupRow(
        _ palette: Palette,
        name: String,
        detail: String,
        state: SetupManager.ComponentState,
        install: @escaping () -> Void,
        login: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: state == .ready ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(state == .ready ? palette.green : palette.textDim)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 13))
                    Text(detail).font(.system(size: 10)).foregroundStyle(palette.textDim)
                }
                Spacer()
                switch state {
                case .ready:
                    if let login {
                        Button("Log in…", action: login).buttonStyle(.bordered).controlSize(.small)
                    }
                case .missing, .failed:
                    Button("Install", action: install).buttonStyle(.bordered).controlSize(.small)
                case .checking, .working:
                    EmptyView()
                }
            }
            if case .working(let label, let fraction) = state {
                HStack(spacing: 8) {
                    if let fraction {
                        ProgressView(value: fraction).frame(width: 180)
                        Text("\(Int(fraction * 100))%").font(.system(size: 10).monospacedDigit())
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(label).font(.system(size: 10)).foregroundStyle(palette.textDim)
                }
                .padding(.leading, 26)
            }
            if case .failed(let message) = state {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.amber)
                    .padding(.leading, 26)
            }
        }
    }

    @ViewBuilder
    private var emotionChip: some View {
        if let r = liveFace.reading {
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(r.dominant.capitalized) \(Int((r.confidence * 100).rounded()))%")
                    .font(.system(size: 14, weight: .semibold))
                ForEach(r.top.dropFirst(), id: \.name) { e in
                    Text("\(e.name.capitalized) \(Int((e.value * 100).rounded()))%")
                        .font(.system(size: 10))
                        .opacity(0.75)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.55)))
            .padding(10)
        }
    }

    private var micBinding: Binding<String> {
        Binding(
            get: {
                let saved = store.settings.micID ?? ""
                return mics.contains { $0.uid == saved } ? saved : ""
            },
            set: {
                store.settings.micID = $0.isEmpty ? nil : $0
                store.saveSettings()
                if testing { testCamera.setMic(uid: store.settings.micID) }
            }
        )
    }

    private var readAloudBinding: Binding<Bool> {
        Binding(
            get: { store.settings.readAloud != false },
            set: {
                store.settings.readAloud = $0
                store.saveSettings()
            }
        )
    }

    private var themeBinding: Binding<String> {
        Binding(
            get: { store.settings.theme ?? "system" },
            set: {
                store.settings.theme = $0
                store.saveSettings()
            }
        )
    }

    private var quickTestBinding: Binding<Bool> {
        Binding(
            get: { store.settings.quickTest == true },
            set: {
                store.settings.quickTest = $0
                store.saveSettings()
            }
        )
    }

    private var providerBinding: Binding<String> {
        Binding(
            get: { store.settings.analysis?.provider ?? "claude" },
            set: {
                var a = store.settings.analysis ?? AnalysisSettings()
                a.provider = $0
                store.settings.analysis = a
                store.saveSettings()
            }
        )
    }

    private var analysisEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.settings.analysis?.enabled != false },
            set: {
                var a = store.settings.analysis ?? AnalysisSettings()
                a.enabled = $0
                store.settings.analysis = a
                store.saveSettings()
            }
        )
    }

    private var facialBinding: Binding<Bool> {
        Binding(
            get: { store.settings.analysis?.facial != false },
            set: {
                var a = store.settings.analysis ?? AnalysisSettings()
                a.facial = $0
                store.settings.analysis = a
                store.saveSettings()
            }
        )
    }
}
