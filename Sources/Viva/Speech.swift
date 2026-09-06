import AVFoundation
import Combine

// Reads a station's prompts aloud with the system voice, standing in for the
// interviewer video that precedes each answer in the real MMI. Lines are spoken
// with a short pause between them; the completion fires once, after the last.
final class QuestionReader: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var speaking = false

    private let synth = AVSpeechSynthesizer()
    private var completion: (() -> Void)?
    private var pending = 0

    override init() {
        super.init()
        synth.delegate = self
    }

    // Best installed English voice: quality first, then the listener's own region.
    static let voice: AVSpeechSynthesisVoice? = {
        let region = Locale.current.region?.identifier ?? "US"
        func score(_ v: AVSpeechSynthesisVoice) -> Int {
            guard v.language.hasPrefix("en") else { return -1 }
            var s: Int
            switch v.quality {
            case .premium: s = 300
            case .enhanced: s = 200
            default: s = 100
            }
            if v.language.hasSuffix("-\(region)") { s += 3 }
            else if v.language == "en-GB" { s += 2 }
            else if v.language == "en-US" { s += 1 }
            // Within the standard tier, the tiny "super-compact" and legacy "eloquence"
            // voices sound far worse than a compact one, whatever the accent.
            if v.identifier.contains("super-compact") { s -= 50 }
            if v.identifier.contains("eloquence") { s -= 80 }
            return s
        }
        return AVSpeechSynthesisVoice.speechVoices().filter { score($0) >= 0 }.max { score($0) < score($1) }
    }()

    static var voiceLabel: String {
        guard let v = voice else { return "system default" }
        let quality = v.quality == .premium ? "premium" : v.quality == .enhanced ? "enhanced" : "standard"
        return "\(v.name), \(v.language), \(quality)"
    }

    // Initialisms the synthesizer would otherwise try to pronounce as words. Any short
    // all-caps run is spelled out, apart from the few that really are read as words.
    private static let pronounced: Set<String> = [
        "AIDS", "NASA", "NATO", "UNESCO", "UNICEF", "ANZAC", "SIDS", "PET", "MRSA", "OK", "I", "A"
    ]

    static func spokenForm(_ text: String) -> String {
        var out = text
        let pattern = "\\b[A-Z]{2,6}\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return out }
        let matches = regex.matches(in: out, range: NSRange(out.startIndex..., in: out))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            let token = String(out[range])
            guard !pronounced.contains(token) else { continue }
            out.replaceSubrange(range, with: token.map(String.init).joined(separator: " "))
        }
        return out.replacingOccurrences(of: "\\bDr\\.?(?=\\s)", with: "Doctor", options: .regularExpression)
    }

    func speak(_ text: String, completion: @escaping () -> Void) {
        stop()
        let lines = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            completion()
            return
        }
        self.completion = completion
        pending = lines.count
        speaking = true
        for (i, line) in lines.enumerated() {
            let utterance = AVSpeechUtterance(string: Self.spokenForm(line))
            utterance.voice = Self.voice
            utterance.rate = 0.47
            utterance.preUtteranceDelay = i == 0 ? 0.6 : 0  // let the station cue tone finish first
            utterance.postUtteranceDelay = i == lines.count - 1 ? 0.4 : 0.8
            synth.speak(utterance)
        }
    }

    func stop() {
        completion = nil
        pending = 0
        speaking = false
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            guard self.pending > 0 else { return }
            self.pending -= 1
            if self.pending == 0 {
                self.speaking = false
                let done = self.completion
                self.completion = nil
                done?()
            }
        }
    }
}
