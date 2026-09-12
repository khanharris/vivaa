import Combine
import Foundation

struct SessionConfig {
    let set: QuestionSet
    let timings: Timings
    let sessionDir: URL
    let sessionId: String
    let micID: String?
    let readAloud: Bool
}

struct DoneInfo {
    let sessionDir: URL
    let aborted: Bool
    let completed: Int
    let total: Int
}

// The phase state machine: delivery (question read aloud) -> reading -> answer (recording) -> break -> next question.
@MainActor
final class InterviewEngine: ObservableObject {
    enum Phase {
        case delivery, reading, answer, pause, finished
    }

    let config: SessionConfig
    let camera = CameraManager()
    private let reader = QuestionReader()

    @Published var qIndex = 0
    @Published var phase: Phase = .reading
    @Published var remainingMs: Int
    @Published var ready = false

    private var endsAt = Date.distantFuture
    private var timer: Timer?
    private var warned = false
    private var transitioning = false
    private var finished = false
    private var results: [QuestionResult] = []
    private var pendingStops = 0
    private var wantsFinish = false
    // With no break, the next station waits for the previous file to finish writing:
    // starting a recording while the last stop is still in flight would be dropped.
    private var pendingAdvance: (() -> Void)?
    private var abortedFlag = false
    private let startedAt = isoNow()
    private var bag = Set<AnyCancellable>()
    var onDone: ((DoneInfo) -> Void)?

    var total: Int { config.set.questions.count }
    var question: Question { config.set.questions[qIndex] }

    init(config: SessionConfig) {
        self.config = config
        let first = config.timings.readingSec > 0 ? config.timings.readingSec : config.timings.answerSec
        remainingMs = first * 1000
    }

    func begin() {
        camera.start(micUID: config.micID)
        camera.$ready
            .filter { $0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.ready else { return }
                self.ready = true
                self.startQuestion()
                self.startClock()
            }
            .store(in: &bag)
    }

    private func startClock() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard !finished, phase != .delivery else { return }
        let remaining = max(0, Int(endsAt.timeIntervalSinceNow * 1000))
        remainingMs = remaining
        if remaining <= 30_000, remaining > 0, !warned, phase != .pause {
            warned = true
            Beeper.shared.warning()
        }
        if remaining <= 0, !transitioning {
            transitioning = true
            advance()
        }
    }

    private func startPhase(_ p: Phase, seconds: Int) {
        phase = p
        endsAt = Date().addingTimeInterval(Double(seconds))
        remainingMs = seconds * 1000
        warned = false
        transitioning = false
        if p == .answer { startRecording() }
    }

    private func advance() {
        switch phase {
        case .reading:
            Beeper.shared.phaseChange()
            startPhase(.answer, seconds: config.timings.answerSec)
        case .answer:
            endAnswer()
        case .pause:
            qIndex += 1
            startQuestion()
        case .delivery, .finished:
            break
        }
    }

    // A station begins with the question read aloud (like the interviewer video in
    // the real MMI), then the timed phases. Reading time is optional: with none
    // configured (the default) recording starts the moment the reading ends.
    private func startQuestion() {
        Beeper.shared.phaseChange()
        if config.readAloud {
            phase = .delivery
            endsAt = .distantFuture
            remainingMs = config.timings.answerSec * 1000
            warned = false
            transitioning = false
            reader.speak(question.text) { [weak self] in
                Task { @MainActor in self?.deliveryFinished() }
            }
        } else {
            startTimedQuestion()
        }
    }

    private func startTimedQuestion() {
        if config.timings.readingSec > 0 {
            startPhase(.reading, seconds: config.timings.readingSec)
        } else {
            startPhase(.answer, seconds: config.timings.answerSec)
        }
    }

    private func deliveryFinished() {
        guard phase == .delivery, !finished else { return }
        Beeper.shared.phaseChange()
        startTimedQuestion()
    }

    func skipDelivery() {
        guard phase == .delivery, !finished else { return }
        reader.stop()
        deliveryFinished()
    }

    private func startRecording() {
        let filename = "q\(qIndex + 1).mov"
        camera.startRecording(to: config.sessionDir.appendingPathComponent(filename))
    }

    private func endAnswer() {
        let index = qIndex
        let q = question
        let isLast = qIndex >= total - 1
        pendingStops += 1
        camera.stopRecording { [weak self] ms, wrote in
            guard let self else { return }
            self.results.append(
                QuestionResult(
                    index: index + 1,
                    theme: q.theme,
                    text: q.text,
                    file: wrote ? "q\(index + 1).mov" : nil,
                    answeredMs: ms
                )
            )
            self.pendingStops -= 1
            if self.wantsFinish, self.pendingStops == 0 { self.finish() }
            if self.pendingStops == 0, let advance = self.pendingAdvance {
                self.pendingAdvance = nil
                advance()
            }
        }
        Beeper.shared.phaseChange()
        if isLast {
            wantsFinish = true
            phase = .finished
            if pendingStops == 0 { finish() }
        } else if config.timings.breakSec > 0 {
            startPhase(.pause, seconds: config.timings.breakSec)
        } else {
            let advance = { [weak self] in
                guard let self, !self.finished else { return }
                self.qIndex += 1
                self.startQuestion()
            }
            if pendingStops == 0 { advance() } else { pendingAdvance = advance }
        }
    }

    func skipReading() {
        guard phase == .reading, !transitioning, !finished else { return }
        transitioning = true
        advance()
    }

    func endAnswerEarly() {
        guard phase == .answer, !transitioning, !finished else { return }
        transitioning = true
        endAnswer()
    }

    func skipBreak() {
        guard phase == .pause, !transitioning, !finished else { return }
        transitioning = true
        advance()
    }

    func abort() {
        guard !finished else { return }
        abortedFlag = true
        if phase == .answer {
            wantsFinish = true
            endAnswer()
            // endAnswer set wantsFinish handling only for last question; force it:
            if phase == .pause {
                wantsFinish = true
                if pendingStops == 0 { finish() }
            }
        } else {
            wantsFinish = true
            if pendingStops == 0 { finish() }
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        pendingAdvance = nil
        reader.stop()
        timer?.invalidate()
        camera.stop()
        results.sort { $0.index < $1.index }
        let meta = SessionMeta(
            id: config.sessionId,
            questionSet: config.set.name,
            startedAt: startedAt,
            finishedAt: isoNow(),
            aborted: abortedFlag,
            timings: config.timings,
            questions: results
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(meta) {
            try? data.write(to: config.sessionDir.appendingPathComponent("session.json"))
        }
        onDone?(
            DoneInfo(
                sessionDir: config.sessionDir,
                aborted: abortedFlag,
                completed: results.count,
                total: total
            )
        )
    }
}
