import AVFoundation
import SwiftUI

// Camera + mic capture with hardware H.264 encoding.
//
// Threading rules (the previous version deadlocked without them):
// - Every AVCaptureSession mutation happens on one serial queue.
// - The manager owns a single long-lived preview layer; views only attach and
//   detach it from the layer tree, never destroy it. Its session reference is
//   cleared on the main thread only after the session has fully stopped.
// - Recording start is asynchronous, so a stop that arrives before the start
//   has been confirmed is queued and executed the moment recording begins.
final class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()
    let previewLayer = AVCaptureVideoPreviewLayer()
    @Published var ready = false
    @Published var errorMessage: String?
    @Published var micLevel: Double = 0  // 0...1, from the capture session's audio channel

    private let queue = DispatchQueue(label: "viva.camera")
    private let movieOutput = AVCaptureMovieFileOutput()
    private var configured = false
    private var micUID: String?
    private var levelTimer: DispatchSourceTimer?

    // Recording state, touched only on `queue`.
    private var startIssued = false
    private var startConfirmed = false
    private var pendingStop = false
    private var recordStart: Date?
    private var finishHandler: ((Int, Bool) -> Void)?

    override init() {
        super.init()
        previewLayer.videoGravity = .resizeAspectFill
    }

    // micUID selects the microphone (see AudioInputs); nil means the built-in mic.
    func start(micUID: String? = nil) {
        AVCaptureDevice.requestAccess(for: .video) { videoOK in
            AVCaptureDevice.requestAccess(for: .audio) { audioOK in
                self.queue.async {
                    self.micUID = micUID
                    self.configureAndRun(videoOK: videoOK, audioOK: audioOK)
                }
            }
        }
    }

    private func configureAndRun(videoOK: Bool, audioOK: Bool) {
        guard videoOK, audioOK else {
            DispatchQueue.main.async {
                self.errorMessage =
                    "Camera or microphone access is denied. Enable Viva in System Settings, Privacy and Security."
            }
            return
        }
        if !configured {
            session.beginConfiguration()
            session.sessionPreset = .hd1920x1080
            if let cam = AVCaptureDevice.default(for: .video),
               let input = try? AVCaptureDeviceInput(device: cam),
               session.canAddInput(input) {
                session.addInput(input)
            }
            if let mic = AudioInputs.device(preferredUID: micUID),
               let input = try? AVCaptureDeviceInput(device: mic),
               session.canAddInput(input) {
                session.addInput(input)
            }
            if session.canAddOutput(movieOutput) {
                session.addOutput(movieOutput)
            }
            session.commitConfiguration()
            if let conn = movieOutput.connection(with: .video) {
                movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.h264], for: conn)
            }
            configured = true
        }
        if previewLayer.session !== session {
            previewLayer.session = session
        }
        if let conn = previewLayer.connection, conn.isVideoMirroringSupported, !conn.isVideoMirrored {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = true
        }
        if !session.isRunning {
            session.startRunning()
        }
        startLevelMeter()
        let inputCount = session.inputs.count
        DispatchQueue.main.async {
            if inputCount < 2 {
                self.errorMessage = "No camera or microphone found."
            } else {
                self.ready = true
            }
        }
    }

    func stop() {
        queue.async {
            self.levelTimer?.cancel()
            self.levelTimer = nil
            DispatchQueue.main.async { self.micLevel = 0 }
            if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
            if self.session.isRunning { self.session.stopRunning() }
            // Detach only after the session has fully stopped; doing this while
            // stopRunning holds the session lock is the deadlock we hit.
            DispatchQueue.main.async { self.previewLayer.session = nil }
        }
    }

    // Swap the microphone on a configured session, e.g. from the Settings picker.
    func setMic(uid: String?) {
        queue.async {
            self.micUID = uid
            guard self.configured else { return }
            self.session.beginConfiguration()
            for input in self.session.inputs {
                if let deviceInput = input as? AVCaptureDeviceInput, deviceInput.device.hasMediaType(.audio) {
                    self.session.removeInput(deviceInput)
                }
            }
            if let mic = AudioInputs.device(preferredUID: uid),
               let input = try? AVCaptureDeviceInput(device: mic),
               self.session.canAddInput(input) {
                self.session.addInput(input)
            }
            self.session.commitConfiguration()
        }
    }

    // Publishes the mic level from the session's own audio connection, so the
    // meter reflects the microphone that will actually be recorded.
    private func startLevelMeter() {
        levelTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let channels = self.movieOutput.connection(with: .audio)?.audioChannels ?? []
            guard let db = channels.map({ Double($0.averagePowerLevel) }).max() else { return }
            let level = min(1, pow(10, db / 20) * 4)
            DispatchQueue.main.async { self.micLevel = level }
        }
        timer.resume()
        levelTimer = timer
    }

    func startRecording(to url: URL) {
        queue.async {
            guard !self.startIssued, !self.movieOutput.isRecording else { return }
            self.startIssued = true
            self.startConfirmed = false
            self.pendingStop = false
            self.recordStart = Date()
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    // completion(answeredMs, fileWritten) on the main thread.
    func stopRecording(completion: @escaping (Int, Bool) -> Void) {
        queue.async {
            guard self.startIssued else {
                DispatchQueue.main.async { completion(0, false) }
                return
            }
            self.finishHandler = completion
            if self.startConfirmed {
                self.movieOutput.stopRecording()
            } else {
                self.pendingStop = true
            }
        }
    }
}

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        queue.async {
            self.startConfirmed = true
            if self.pendingStop {
                self.pendingStop = false
                self.movieOutput.stopRecording()
            }
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        queue.async {
            let ms = self.recordStart.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
            let wrote = FileManager.default.fileExists(atPath: outputFileURL.path)
            if let error, !wrote {
                DispatchQueue.main.async {
                    self.errorMessage = "Recording failed: \(error.localizedDescription)"
                }
            }
            self.startIssued = false
            self.startConfirmed = false
            self.pendingStop = false
            let handler = self.finishHandler
            self.finishHandler = nil
            DispatchQueue.main.async { handler?(ms, wrote) }
        }
    }
}

// Attaches the manager's long-lived preview layer; never destroys it.
struct CameraPreview: NSViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.masksToBounds = true
        attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if layer.superlayer !== nsView.layer {
            layer.removeFromSuperlayer()
            attach(to: nsView)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = nsView.bounds
        CATransaction.commit()
    }

    private func attach(to view: NSView) {
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        nsView.layer?.sublayers?
            .filter { $0 is AVCaptureVideoPreviewLayer }
            .forEach { $0.removeFromSuperlayer() }
    }
}

// Timer cue tones, generated with AVAudioEngine.
final class Beeper {
    static let shared = Beeper()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var started = false

    private func ensure() {
        guard !started else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        do {
            try engine.start()
            player.play()
            started = true
        } catch {
            // no audio output available; stay silent
        }
    }

    func tone(_ freq: Double, ms: Double, delay: Double = 0) {
        ensure()
        guard started else { return }
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        let sampleRate = format.sampleRate
        let frames = AVAudioFrameCount(sampleRate * ms / 1000)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buf.frameLength = frames
        for ch in 0..<Int(format.channelCount) {
            guard let data = buf.floatChannelData?[ch] else { continue }
            for i in 0..<Int(frames) {
                let t = Double(i) / sampleRate
                let envelope = max(0, min(1, min(t / 0.01, (ms / 1000 - t) / 0.05)))
                data[i] = Float(sin(2 * .pi * freq * t) * 0.22 * envelope)
            }
        }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.player.scheduleBuffer(buf)
            }
        } else {
            player.scheduleBuffer(buf)
        }
    }

    func warning() { tone(660, ms: 200) }
    func phaseChange() {
        tone(880, ms: 160)
        tone(880, ms: 160, delay: 0.25)
    }
}
