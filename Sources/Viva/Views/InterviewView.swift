import SwiftUI

struct InterviewView: View {
    @StateObject private var engine: InterviewEngine
    @Environment(\.colorScheme) private var scheme
    let onDone: (DoneInfo) -> Void
    let onCancel: () -> Void
    @State private var confirmingAbort = false

    init(config: SessionConfig, onDone: @escaping (DoneInfo) -> Void, onCancel: @escaping () -> Void) {
        _engine = StateObject(wrappedValue: InterviewEngine(config: config))
        self.onDone = onDone
        self.onCancel = onCancel
    }

    private var timerText: String {
        let s = engine.remainingMs / 1000
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    var body: some View {
        let palette = Palette.forScheme(scheme)
        VStack(spacing: 0) {
            header(palette)
            Divider().overlay(palette.border)
            ZStack {
                if engine.ready { main(palette) }
                if let error = engine.camera.errorMessage {
                    VStack(spacing: 14) {
                        Text("Camera unavailable").font(.system(.title2, design: .serif))
                        Text(error).foregroundStyle(palette.textDim)
                        Button("Back to home", action: onCancel).buttonStyle(.borderedProminent)
                    }
                    .padding(40)
                } else if !engine.ready {
                    Text("Starting camera…").foregroundStyle(palette.textDim)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(palette.background)
        .onAppear {
            engine.onDone = onDone
            engine.begin()
        }
        .confirmationDialog(
            "End this session early? Answers recorded so far will be kept.",
            isPresented: $confirmingAbort
        ) {
            Button("End session", role: .destructive) { engine.abort() }
            Button("Keep going", role: .cancel) {}
        }
    }

    private func header(_ palette: Palette) -> some View {
        HStack {
            Text("Station \(engine.qIndex + 1) of \(engine.total)")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            phaseBadge(palette)
            Spacer()
            Button("End session") { confirmingAbort = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(palette.red)
        }
        .padding(.horizontal, 18)
        .padding(.top, 34)
        .padding(.bottom, 10)
        .background(palette.panel)
    }

    private func phaseBadge(_ palette: Palette) -> some View {
        let (label, color): (String, Color) = {
            switch engine.phase {
            case .delivery: return ("QUESTION", palette.accentText)
            case .reading: return ("READING TIME", palette.accentText)
            case .answer: return ("RECORDING ANSWER", palette.red)
            case .pause: return ("BREAK", palette.green)
            case .finished: return ("SAVING", palette.textDim)
            }
        }()
        return HStack(spacing: 7) {
            if engine.phase == .answer {
                Circle().fill(palette.red).frame(width: 8, height: 8)
            }
            Text(label).font(.system(size: 11, weight: .semibold)).tracking(0.8)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 13)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.13)))
    }

    @ViewBuilder
    private func main(_ palette: Palette) -> some View {
        if engine.phase == .pause {
            VStack(spacing: 14) {
                Text(timerText)
                    .font(.system(size: 72, weight: .bold).monospacedDigit())
                    .foregroundStyle(palette.green)
                Text("Break. Station \(engine.qIndex + 2) starts automatically, and recording begins the moment the question appears.")
                    .foregroundStyle(palette.textDim)
                Button("Skip break") { engine.skipBreak() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        } else {
            VStack(spacing: 18) {
                if engine.phase == .reading {
                    questionCard(palette, compact: false)
                    timerView(palette)
                    Text("Reading time. Recording starts automatically when the timer ends.")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textDim)
                    Button("Start answer now") { engine.skipReading() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else if engine.phase == .delivery || engine.config.timings.readingSec == 0 {
                    // Question read aloud, or no reading phase: keep the question fully legible beside the camera.
                    HStack(alignment: .top, spacing: 24) {
                        questionCard(palette, compact: false)
                        VStack(spacing: 14) {
                            timerView(palette)
                            Label(deliveryCaption, systemImage: engine.phase == .delivery ? "speaker.wave.2.fill" : "record.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(palette.textDim)
                                .multilineTextAlignment(.center)
                            CameraPreview(layer: engine.camera.previewLayer)
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .frame(maxWidth: 400)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            if engine.phase == .delivery {
                                Button("Skip reading") { engine.skipDelivery() }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            } else {
                                Button("End answer early") { engine.endAnswerEarly() }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                        .frame(maxWidth: 420)
                    }
                    .frame(maxWidth: 980)
                } else {
                    questionCard(palette, compact: true)
                    timerView(palette)
                    CameraPreview(layer: engine.camera.previewLayer)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(maxWidth: 620)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Button("End answer early") { engine.endAnswerEarly() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(28)
        }
    }

    private var deliveryCaption: String {
        if engine.phase == .delivery {
            return "The question is being read aloud. Recording starts the moment it finishes."
        }
        return engine.config.readAloud
            ? "Recording started when the reading finished. Thinking time counts toward the timer."
            : "Recording started when the question appeared. Thinking time counts toward the timer."
    }

    private func questionCard(_ palette: Palette, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let theme = engine.question.theme {
                Text(theme.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(palette.amber)
            }
            Text(engine.question.text)
                .font(.system(size: compact ? 14 : 20, design: .serif))
                .lineSpacing(4)
        }
        .padding(compact ? 16 : 26)
        .frame(maxWidth: 760, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(palette.panel))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
    }

    private func timerView(_ palette: Palette) -> some View {
        Text(timerText)
            .font(.system(size: 64, weight: .bold).monospacedDigit())
            .foregroundStyle(
                engine.remainingMs <= 30_000 && engine.phase != .pause && engine.phase != .delivery ? palette.amber : palette.text
            )
    }
}
