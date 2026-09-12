import AVFoundation
import AppKit

// Builds one continuous review video for a session.
//
// The question is read aloud before recording starts, so it exists in no video
// file. Each station therefore gets a generated title card showing the prompt,
// with the same synthesized voice the interview used speaking it, spliced in
// front of the recorded answer.

private let cardLeadIn = CMTime(seconds: 0.6, preferredTimescale: 600)
private let cardTail = CMTime(seconds: 1.0, preferredTimescale: 600)
private let cardFPS: Int32 = 12

// MARK: - Title card rendering

private func renderCard(size: CGSize, station: Int, total: Int, theme: String?, text: String) -> CGImage? {
    // Drawn into an explicit bitmap context rather than NSImage.lockFocus, which
    // depends on window-server state and yields nothing when focus is still held.
    guard let ctx = CGContext(
        data: nil,
        width: Int(size.width),
        height: Int(size.height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

    func color(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
    // The app's light palette, so the video matches the interface.
    color(0xFAF9F5).setFill()
    NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()

    let margin: CGFloat = size.width * 0.11
    let width = size.width - margin * 2

    let heading = NSMutableAttributedString(
        string: "STATION \(station) OF \(total)",
        attributes: [
            .font: NSFont.systemFont(ofSize: size.height * 0.026, weight: .semibold),
            .foregroundColor: color(0x83827D),
            .kern: size.height * 0.004
        ]
    )
    if let theme, !theme.isEmpty {
        heading.append(NSAttributedString(
            string: "   \(theme.uppercased())",
            attributes: [
                .font: NSFont.systemFont(ofSize: size.height * 0.026, weight: .semibold),
                .foregroundColor: color(0xB8860B),
                .kern: size.height * 0.004
            ]
        ))
    }

    // Serif prompt, shrinking a little when the question is long.
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineHeightMultiple = 1.28
    paragraph.alignment = .left
    var fontSize = size.height * (text.count > 420 ? 0.038 : text.count > 220 ? 0.045 : 0.055)
    var body = NSAttributedString()
    var bodyRect = CGRect.zero
    let maxHeight = size.height * 0.62
    while true {
        let font = NSFont(descriptor: NSFont.systemFont(ofSize: fontSize).fontDescriptor.withDesign(.serif)
            ?? NSFont.systemFont(ofSize: fontSize).fontDescriptor, size: fontSize)
            ?? NSFont.systemFont(ofSize: fontSize)
        body = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: color(0x3D3929), .paragraphStyle: paragraph]
        )
        bodyRect = body.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        if bodyRect.height <= maxHeight || fontSize <= size.height * 0.022 { break }
        fontSize -= size.height * 0.004
    }

    let blockHeight = bodyRect.height
    // Non-flipped context: y grows upward, so lay out from the bottom.
    let bodyY = (size.height - blockHeight) / 2 - size.height * 0.02
    body.draw(with: CGRect(x: margin, y: bodyY, width: width, height: blockHeight),
              options: [.usesLineFragmentOrigin, .usesFontLeading])
    heading.draw(at: CGPoint(x: margin, y: bodyY + blockHeight + size.height * 0.06))

    return ctx.makeImage()
}

private func pixelBuffer(from image: CGImage, size: CGSize, pool: CVPixelBufferPool) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
          let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let ctx = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer),
        width: Int(size.width),
        height: Int(size.height),
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return nil }
    ctx.draw(image, in: CGRect(origin: .zero, size: size))
    return buffer
}

// A silent H.264 clip holding one still image for `duration`.
private func writeStillVideo(image: CGImage, size: CGSize, duration: CMTime, to url: URL) async -> Bool {
    try? FileManager.default.removeItem(at: url)
    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
    )
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
        ]
    )
    guard writer.canAdd(input) else { return false }
    writer.add(input)
    guard writer.startWriting() else { return false }
    writer.startSession(atSourceTime: .zero)

    guard let pool = adaptor.pixelBufferPool,
          let buffer = pixelBuffer(from: image, size: size, pool: pool) else {
        writer.cancelWriting()
        return false
    }
    let frames = max(2, Int((duration.seconds * Double(cardFPS)).rounded()))
    for i in 0..<frames {
        while !input.isReadyForMoreMediaData {
            try? await Task.sleep(nanoseconds: 4_000_000)
        }
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: cardFPS))
    }
    input.markAsFinished()
    await writer.finishWriting()
    return writer.status == .completed
}

// MARK: - Spoken question

private func silentBuffer(format: AVAudioFormat, seconds: Double) -> AVAudioPCMBuffer? {
    let frames = AVAudioFrameCount(seconds * format.sampleRate)
    guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
    buffer.frameLength = frames
    for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
        if let data = audioBuffer.mData { memset(data, 0, Int(audioBuffer.mDataByteSize)) }
    }
    return buffer
}

// Renders the prompt to an audio file with the interview's own voice, padded with
// real silence at each end. Padding with silence rather than an empty composition
// range matters: empty ranges at the end of a composition track are discarded, so
// the audio would drift out of step with the video from the second station on.
private func synthesizeQuestion(_ text: String, to url: URL) async -> CMTime? {
    let spoken = QuestionReader.spokenForm(
        text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: ". ")
    )
    guard !spoken.isEmpty else { return nil }
    try? FileManager.default.removeItem(at: url)

    let utterance = AVSpeechUtterance(string: spoken)
    utterance.voice = QuestionReader.voice
    utterance.rate = 0.47
    // Synthesized speech lands far hotter than a webcam recording of someone
    // talking across a room. Pulled down so the narration sits a little above the
    // answers rather than roughly 18 dB over them.
    utterance.volume = 0.4
    let synthesizer = AVSpeechSynthesizer()

    let spokenBuffers: [AVAudioPCMBuffer] = await withCheckedContinuation { continuation in
        var collected: [AVAudioPCMBuffer] = []
        var done = false
        synthesizer.write(utterance) { buffer in
            _ = synthesizer  // keep the synthesizer alive for the whole write
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                guard !done else { return }
                done = true
                continuation.resume(returning: collected)
                return
            }
            collected.append(pcm)
        }
    }
    guard let format = spokenBuffers.first?.format else { return nil }

    guard let file = try? AVAudioFile(forWriting: url, settings: format.settings) else { return nil }
    var written: AVAudioFramePosition = 0
    func append(_ buffer: AVAudioPCMBuffer?) {
        guard let buffer else { return }
        try? file.write(from: buffer)
        written += AVAudioFramePosition(buffer.frameLength)
    }
    append(silentBuffer(format: format, seconds: cardLeadIn.seconds))
    spokenBuffers.forEach { append($0) }
    append(silentBuffer(format: format, seconds: cardTail.seconds))
    guard written > 0 else { return nil }
    return CMTime(seconds: Double(written) / format.sampleRate, preferredTimescale: 600)
}

// MARK: - Building the session video

enum SessionVideo {
    static let filename = "session-video.mp4"

    static func build(
        dir: URL,
        report: @escaping @Sendable (String) -> Void
    ) async -> Result<URL, String> {
        let fm = FileManager.default
        guard let metaData = try? Data(contentsOf: dir.appendingPathComponent("session.json")),
              let meta = try? JSONDecoder().decode(SessionMeta.self, from: metaData) else {
            return .failure("Could not read session.json.")
        }
        let answered = meta.questions.filter { $0.file != nil }
        guard !answered.isEmpty else { return .failure("This session has no recorded answers.") }

        let work = fm.temporaryDirectory.appendingPathComponent("viva-stitch-\(meta.id)")
        try? fm.removeItem(at: work)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return .failure("Could not create the video composition.")
        }

        var cursor = CMTime.zero
        var renderSize = CGSize(width: 1920, height: 1080)

        for (i, question) in answered.enumerated() {
            report("Building station \(i + 1) of \(answered.count)…")
            let answerURL = dir.appendingPathComponent(question.file ?? "")
            let answer = AVURLAsset(url: answerURL)
            guard let answerVideo = try? await answer.loadTracks(withMediaType: .video).first else {
                return .failure("Could not read \(answerURL.lastPathComponent).")
            }
            let answerAudio = try? await answer.loadTracks(withMediaType: .audio).first
            let answerDuration = (try? await answer.load(.duration)) ?? .zero
            if i == 0, let size = try? await answerVideo.load(.naturalSize) {
                renderSize = size
            }

            // Title card: the prompt on screen, spoken with the interview voice.
            let audioURL = work.appendingPathComponent("q\(question.index).caf")
            let cardURL = work.appendingPathComponent("card\(question.index).mov")
            let spokenDuration = await synthesizeQuestion(question.text, to: audioURL)
                ?? CMTime(seconds: 3, preferredTimescale: 600)

            if let image = renderCard(
                size: renderSize,
                station: question.index,
                total: answered.count,
                theme: question.theme,
                text: question.text
            ), await writeStillVideo(image: image, size: renderSize, duration: spokenDuration, to: cardURL) {
                let cardAsset = AVURLAsset(url: cardURL)
                let voiceAsset = AVURLAsset(url: audioURL)
                let cardVideo = try? await cardAsset.loadTracks(withMediaType: .video).first
                let cardVoice = try? await voiceAsset.loadTracks(withMediaType: .audio).first

                // Insert exactly what was written, never a requested length: asking for
                // a range even microseconds longer than the asset makes the insert throw
                // and the card silently vanishes from the finished video.
                let videoLength = (try? await cardAsset.load(.duration)) ?? .zero
                let voiceLength = (try? await voiceAsset.load(.duration)) ?? .zero
                let cardDuration = min(videoLength, voiceLength)

                if let cardVideo, let cardVoice, cardDuration.seconds > 0.1 {
                    let cardRange = CMTimeRange(start: .zero, duration: cardDuration)
                    do {
                        try videoTrack.insertTimeRange(cardRange, of: cardVideo, at: cursor)
                        try audioTrack.insertTimeRange(cardRange, of: cardVoice, at: cursor)
                        cursor = cursor + cardDuration
                    } catch {
                        return .failure("Could not add the station \(question.index) title card: \(error.localizedDescription)")
                    }
                }
            }

            let videoRange = (try? await answerVideo.load(.timeRange)) ?? CMTimeRange(start: .zero, duration: answerDuration)
            let audioRange = answerAudio == nil
                ? videoRange
                : ((try? await answerAudio!.load(.timeRange)) ?? videoRange)
            let usable = min(videoRange.duration, audioRange.duration)
            let answerRange = CMTimeRange(start: .zero, duration: usable)
            do {
                try videoTrack.insertTimeRange(answerRange, of: answerVideo, at: cursor)
                if let answerAudio {
                    try audioTrack.insertTimeRange(answerRange, of: answerAudio, at: cursor)
                }
            } catch {
                return .failure("Could not add \(answerURL.lastPathComponent): \(error.localizedDescription)")
            }
            cursor = cursor + usable
        }

        report("Encoding the finished video… this is the slow part.")
        let outURL = dir.appendingPathComponent(filename)
        try? fm.removeItem(at: outURL)
        guard let export = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPreset1920x1080) else {
            return .failure("Could not create the video exporter.")
        }
        export.outputURL = outURL
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true

        await export.export()
        if export.status == .completed {
            return .success(outURL)
        }
        return .failure("Export failed: \(export.error?.localizedDescription ?? "unknown error").")
    }
}

extension AnalysisManager {
    func makeSessionVideo(_ dir: URL) {
        guard !stitchRunning.contains(dir.path) else { return }
        stitchRunning.insert(dir.path)
        stitchProgress[dir.path] = "Preparing…"
        Task {
            let result = await SessionVideo.build(dir: dir) { [weak self] message in
                Task { @MainActor in self?.stitchProgress[dir.path] = message }
            }
            await MainActor.run {
                switch result {
                case .success:
                    self.stitchProgress[dir.path] = ""
                case .failure(let message):
                    self.stitchProgress[dir.path] = "Error: \(message)"
                }
                self.stitchRunning.remove(dir.path)
                self.completedTick += 1
            }
        }
    }
}
