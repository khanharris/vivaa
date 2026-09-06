import AVFoundation
import CoreImage
import SwiftUI

// Realtime facial analysis playground: streams downscaled frames to a
// persistent Py-Feat process and overlays the model's 68 landmarks plus the
// current emotion reading. Same model the session analysis uses.
final class LiveFaceAnalyzer: NSObject, ObservableObject {
    struct Reading {
        let dominant: String
        let confidence: Double
        let top: [(name: String, value: Double)]
        let landmarks: [CGPoint]
        let imageSize: CGSize
    }

    @Published var reading: Reading?
    @Published var status: String = ""
    @Published var running = false

    let session = AVCaptureSession()
    let previewLayer = AVCaptureVideoPreviewLayer()

    private let queue = DispatchQueue(label: "viva.liveface")
    private let videoOutput = AVCaptureVideoDataOutput()
    private var configured = false
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutBuffer = Data()
    private var inFlight = false
    private var modelReady = false
    private let ciContext = CIContext()
    private let framePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("viva-live-frame.jpg")

    override init() {
        super.init()
        previewLayer.videoGravity = .resizeAspectFill
    }

    func start(pythonPath: String?) {
        guard !running else { return }
        running = true
        reading = nil
        status = "Loading model… this takes 10-20 seconds."
        launchPython(pythonPath: pythonPath)
        guard process != nil else { return }
        AVCaptureDevice.requestAccess(for: .video) { granted in
            self.queue.async { self.configureSession(granted: granted) }
        }
    }

    func stop() {
        running = false
        reading = nil
        status = ""
        process?.terminate()
        process = nil
        stdinPipe = nil
        queue.async {
            self.modelReady = false
            self.inFlight = false
            self.stdoutBuffer.removeAll()
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.previewLayer.session = nil }
        }
    }

    private func configureSession(granted: Bool) {
        guard granted else {
            DispatchQueue.main.async { self.status = "Camera access denied." }
            return
        }
        if !configured {
            session.beginConfiguration()
            session.sessionPreset = .hd1280x720
            if let cam = AVCaptureDevice.default(for: .video),
               let input = try? AVCaptureDeviceInput(device: cam),
               session.canAddInput(input) {
                session.addInput(input)
            }
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
            session.commitConfiguration()
            configured = true
        }
        if previewLayer.session !== session { previewLayer.session = session }
        if let conn = previewLayer.connection, conn.isVideoMirroringSupported, !conn.isVideoMirrored {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = true
        }
        if !session.isRunning { session.startRunning() }
    }

    private func launchPython(pythonPath: String?) {
        guard let script = Bundle.main.resourceURL?
                .appendingPathComponent("scripts/face_live.py").path,
              FileManager.default.fileExists(atPath: script),
              let python = firstExisting([
                  pythonPath,
                  Paths.appSupport.appendingPathComponent("pyvenv/bin/python").path,
                  Paths.appSupport.appendingPathComponent("python/bin/python3").path
              ])
        else {
            status = "Python environment not configured."
            running = false
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = [script]
        let inPipe = Pipe()
        let outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = Pipe()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.consume(data) }
        }
        do {
            try p.run()
            process = p
            stdinPipe = inPipe
        } catch {
            status = "Could not start the model: \(error.localizedDescription)"
            running = false
        }
    }

    // Runs on `queue`.
    private func consume(_ data: Data) {
        stdoutBuffer.append(data)
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = Data(stdoutBuffer.prefix(upTo: newline))
            stdoutBuffer.removeSubrange(...newline)
            handleLine(line)
        }
    }

    private struct LiveResponse: Codable {
        let ready: Bool?
        let ok: Bool?
        let dominant: String?
        let emotions: [String: Double]?
        let landmarks: [[Double]]?
        let w: Double?
        let h: Double?
        let error: String?
    }

    // Runs on `queue`.
    private func handleLine(_ data: Data) {
        guard let resp = try? JSONDecoder().decode(LiveResponse.self, from: data) else { return }
        if let ready = resp.ready {
            modelReady = ready
            DispatchQueue.main.async {
                self.status = ready
                    ? "Model ready. Looking for a face…"
                    : "Model failed to load: \(resp.error ?? "unknown error")"
            }
            return
        }
        inFlight = false
        guard resp.ok == true,
              let emotions = resp.emotions,
              let dominant = resp.dominant,
              let w = resp.w, let h = resp.h
        else {
            DispatchQueue.main.async {
                if self.running {
                    self.reading = nil
                    self.status = "No face detected."
                }
            }
            return
        }
        let sorted = emotions.sorted { $0.value > $1.value }
        let result = Reading(
            dominant: dominant,
            confidence: emotions[dominant] ?? 0,
            top: sorted.prefix(3).map { (name: $0.key, value: $0.value) },
            landmarks: (resp.landmarks ?? []).compactMap { pair in
                pair.count == 2 ? CGPoint(x: pair[0], y: pair[1]) : nil
            },
            imageSize: CGSize(width: w, height: h)
        )
        DispatchQueue.main.async {
            if self.running {
                self.reading = result
                self.status = ""
            }
        }
    }
}

extension LiveFaceAnalyzer: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard modelReady, !inFlight,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        inFlight = true
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = 640 / image.extent.width
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        do {
            try ciContext.writeJPEGRepresentation(
                of: image,
                to: framePath,
                colorSpace: CGColorSpaceCreateDeviceRGB(),
                options: [:]
            )
            if let data = (framePath.path + "\n").data(using: .utf8) {
                stdinPipe?.fileHandleForWriting.write(data)
            }
        } catch {
            inFlight = false
        }
    }
}

// Draws the model's landmarks over the mirrored, aspect-filled preview.
struct FaceOverlay: View {
    let reading: LiveFaceAnalyzer.Reading?

    var body: some View {
        Canvas { context, size in
            guard let r = reading, r.imageSize.width > 0, r.imageSize.height > 0 else { return }
            let scale = max(size.width / r.imageSize.width, size.height / r.imageSize.height)
            let offX = (size.width - r.imageSize.width * scale) / 2
            let offY = (size.height - r.imageSize.height * scale) / 2
            for p in r.landmarks {
                let x = size.width - (p.x * scale + offX)
                let y = p.y * scale + offY
                let dot = CGRect(x: x - 2, y: y - 2, width: 4, height: 4)
                context.fill(Path(ellipseIn: dot), with: .color(.green.opacity(0.85)))
            }
        }
        .allowsHitTesting(false)
    }
}
